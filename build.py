#!/usr/bin/env python3
"""
build.py - builds a Roblox XML place file (.rbxlx) from src/ using Rojo file
conventions, and (re)writes a matching Rojo project file (default.project.json).

Usage:
    python3 build.py [--src DIR] [--out FILE] [--project FILE | --no-project]

Defaults: --src <project>/src, --out <project>/build/LastRun.rbxlx,
          --project <parent of src>/default.project.json

Mapping:
    src/shared/    -> ReplicatedStorage > Folder "Shared"
    src/server/    -> ServerScriptService > Folder "Server"
    src/client/    -> StarterPlayer > StarterPlayerScripts > Folder "Client"
    src/character/ -> StarterPlayer > StarterCharacterScripts (files directly)
    src/playerscripts/ -> StarterPlayer > StarterPlayerScripts (files directly, e.g. RbxCharacterSounds)

File naming:
    Name.server.lua -> Script, Name.client.lua -> LocalScript, Name.lua -> ModuleScript
    (.luau works the same), subdirectory -> Folder, subdirectory with
    init.lua / init.server.lua / init.client.lua -> that script, other files as children.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from xml.sax.saxutils import escape as _xml_escape

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJECT_NAME = "LastRun"
DEFAULT_SRC = os.path.join(ROOT, "src")
DEFAULT_OUT = os.path.join(ROOT, "build", "LastRun.rbxlx")

SCRIPT_CLASSES = ("Script", "LocalScript", "ModuleScript")
SUFFIXES = (
    (".server.lua", "Script"), (".client.lua", "LocalScript"),
    (".server.luau", "Script"), (".client.luau", "LocalScript"),
    (".lua", "ModuleScript"), (".luau", "ModuleScript"),
)
INIT_FILES = {"init" + suffix: cls for suffix, cls in SUFFIXES}

# (src subdirectory, container path under the DataModel, wrapping folder name or None)
MAPPING = (
    ("shared", ("ReplicatedStorage",), "Shared"),
    ("server", ("ServerScriptService",), "Server"),
    ("client", ("StarterPlayer", "StarterPlayerScripts"), "Client"),
    ("character", ("StarterPlayer", "StarterCharacterScripts"), None),
    ("playerscripts", ("StarterPlayer", "StarterPlayerScripts"), None),
)

SERVICE_ORDER = ("Workspace", "Lighting", "ReplicatedStorage", "ServerScriptService",
                 "StarterGui", "StarterPlayer", "SoundService")

# Characters that XML 1.0 forbids even inside CDATA.
INVALID_XML_CHARS = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f￾￿]")
REFERENT_RE = re.compile(r"^RBX[0-9A-F]{32}$")

ROBLOX_HEADER = ('<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
                 'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
                 'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">')


class BuildError(Exception):
    pass


class Instance:
    def __init__(self, cls: str, name: str, source: str | None = None, source_path: str | None = None):
        self.cls = cls
        self.name = name
        self.source = source
        self.source_path = source_path
        self.props: list[tuple[str, str, object]] = []
        self.children: list[Instance] = []


def classify(filename: str):
    """Returns (instance name, class) for a script file name, or None."""
    for suffix, cls in SUFFIXES:
        if filename.endswith(suffix) and len(filename) > len(suffix):
            return filename[:-len(suffix)], cls
    return None


def read_source(path: str) -> str:
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        raise BuildError(f"cannot read {path}: {exc.strerror}") from None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise BuildError(f"{path}: file is not valid UTF-8 ({exc})") from None
    if text.startswith("﻿"):
        text = text[1:]
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    m = INVALID_XML_CHARS.search(text)
    if m:
        line = text.count("\n", 0, m.start()) + 1
        raise BuildError(f"{path}:{line}: contains control character U+{ord(m.group()):04X}, "
                         "which cannot be stored in an XML place file")
    return text


def xml_attr(value: str) -> str:
    return _xml_escape(value, {'"': "&quot;"})


def cdata(text: str) -> str:
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


class Builder:
    def __init__(self, src_dir: str):
        self.src_dir = os.path.abspath(src_dir)
        self.skipped: list[str] = []
        self.notes: list[str] = []
        self.present: list[str] = []
        self.expected_sources: dict[str, str] = {}   # referent -> source
        self.class_counts: Counter = Counter()

    # -- filesystem -> instance tree ------------------------------------------
    def dir_instance(self, path: str, name: str) -> Instance:
        entries = sorted(os.listdir(path))
        inits = [e for e in entries if e in INIT_FILES and os.path.isfile(os.path.join(path, e))]
        if len(inits) > 1:
            raise BuildError(f"{path}: more than one init file ({', '.join(inits)})")
        if inits:
            init_path = os.path.join(path, inits[0])
            inst = Instance(INIT_FILES[inits[0]], name, read_source(init_path), init_path)
        else:
            inst = Instance("Folder", name)
        inst.children = self.children_of(path, skip=set(inits))
        return inst

    def children_of(self, path: str, skip=frozenset()) -> list[Instance]:
        children = []
        for entry in sorted(os.listdir(path)):
            if entry.startswith(".") or entry in skip:
                continue
            full = os.path.join(path, entry)
            if os.path.isdir(full):
                children.append(self.dir_instance(full, entry))
            elif os.path.isfile(full):
                kind = classify(entry)
                if kind is None:
                    self.skipped.append(full)
                    continue
                name, cls = kind
                children.append(Instance(cls, name, read_source(full), full))
        children.sort(key=lambda i: (i.name.lower(), i.name, i.cls))
        seen = Counter(c.name for c in children)
        for dup, count in seen.items():
            if count > 1:
                self.notes.append(f"warning: {count} instances named '{dup}' in {self.rel(path)} "
                                  "(require/FindFirstChild by name will be ambiguous)")
        return children

    def rel(self, path: str) -> str:
        return os.path.relpath(path, self.src_dir).replace(os.sep, "/")

    def build_tree(self) -> list[Instance]:
        if not os.path.isdir(self.src_dir):
            raise BuildError(f"source directory not found: {self.src_dir}")
        services = {name: Instance(name, name) for name in SERVICE_ORDER}
        services["Workspace"].props.append(("bool", "StreamingEnabled", False))
        # Освещение Future: тени, неон и туман как в оригинале (Enum.Technology.Future = 4)
        services["Lighting"].props.append(("token", "Technology", 4))
        player_scripts = Instance("StarterPlayerScripts", "StarterPlayerScripts")
        character_scripts = Instance("StarterCharacterScripts", "StarterCharacterScripts")
        services["StarterPlayer"].children = [player_scripts, character_scripts]
        containers = {
            ("ReplicatedStorage",): services["ReplicatedStorage"],
            ("ServerScriptService",): services["ServerScriptService"],
            ("StarterPlayer", "StarterPlayerScripts"): player_scripts,
            ("StarterPlayer", "StarterCharacterScripts"): character_scripts,
        }
        for sub, container_path, folder in MAPPING:
            d = os.path.join(self.src_dir, sub)
            if not os.path.isdir(d):
                self.notes.append(f"note: src/{sub}/ does not exist, skipped")
                continue
            self.present.append(sub)
            parent = containers[container_path]
            if folder:
                parent.children.append(self.dir_instance(d, folder))
            else:
                inits = [e for e in os.listdir(d) if e in INIT_FILES]
                if inits:
                    raise BuildError(f"{d}: init files are not allowed here, because src/{sub}/ maps "
                                     f"directly onto {container_path[-1]} ({', '.join(inits)})")
                parent.children.extend(self.children_of(d))
        return [services[name] for name in SERVICE_ORDER]

    def count_source_files(self) -> int:
        """Independent count of script files on disk (used to verify the output)."""
        total = 0
        for sub in self.present:
            for root, dirs, files in os.walk(os.path.join(self.src_dir, sub)):
                dirs[:] = [x for x in dirs if not x.startswith(".")]
                total += sum(1 for f in files if not f.startswith(".") and classify(f))
        return total

    # -- instance tree -> XML -------------------------------------------------
    def emit(self, services: list[Instance]) -> str:
        lines = [ROBLOX_HEADER,
                 "\t<Meta name=\"ExplicitAutoJoints\">true</Meta>",
                 "\t<External>null</External>",
                 "\t<External>nil</External>"]
        used_keys: set[str] = set()

        def referent(key: str) -> str:
            base, n = key, 1
            while key in used_keys:
                n += 1
                key = f"{base}#{n}"
            used_keys.add(key)
            return "RBX" + hashlib.md5(f"{PROJECT_NAME}|{key}".encode("utf-8")).hexdigest().upper()

        def walk(inst: Instance, depth: int, parent_key: str):
            key = f"{parent_key}/{inst.cls}:{inst.name}"
            if inst.source_path:
                key += "@" + self.rel(inst.source_path)
            ref = referent(key)
            ind = "\t" * depth
            lines.append(f'{ind}<Item class="{xml_attr(inst.cls)}" referent="{ref}">')
            lines.append(f"{ind}\t<Properties>")
            lines.append(f'{ind}\t\t<string name="Name">{_xml_escape(inst.name)}</string>')
            for ptype, pname, pvalue in inst.props:
                if ptype == "bool":
                    pvalue = "true" if pvalue else "false"
                    lines.append(f'{ind}\t\t<bool name="{pname}">{pvalue}</bool>')
                else:
                    lines.append(f'{ind}\t\t<{ptype} name="{pname}">{_xml_escape(str(pvalue))}</{ptype}>')
            if inst.cls in SCRIPT_CLASSES:
                source = inst.source or ""
                self.expected_sources[ref] = source
                lines.append(f'{ind}\t\t<ProtectedString name="Source">{cdata(source)}</ProtectedString>')
            lines.append(f"{ind}\t</Properties>")
            self.class_counts[inst.cls] += 1
            for child in inst.children:
                walk(child, depth + 1, key)
            lines.append(f"{ind}</Item>")

        for svc in services:
            walk(svc, 1, "")
        lines.append("</roblox>")
        return "\n".join(lines) + "\n"

    # -- verification -----------------------------------------------------------
    def verify(self, path: str, expected_scripts: int):
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            raise BuildError(f"output is not well-formed XML: {exc}") from None
        if root.tag != "roblox":
            raise BuildError(f"unexpected root element <{root.tag}>")
        items = list(root.iter("Item"))
        refs = [i.get("referent") for i in items]
        bad = [r for r in refs if not r or not REFERENT_RE.match(r)]
        if bad:
            raise BuildError(f"invalid referent(s): {bad[:3]}")
        if len(set(refs)) != len(refs):
            raise BuildError("duplicate referents in output")
        scripts = [i for i in items if i.get("class") in SCRIPT_CLASSES]
        if len(scripts) != expected_scripts:
            raise BuildError(f"script count mismatch: {len(scripts)} script Items in output, "
                             f"{expected_scripts} source files on disk")
        for item in scripts:
            ref = item.get("referent")
            node = item.find("Properties/ProtectedString[@name='Source']")
            if node is None:
                raise BuildError(f"script {ref} has no Source property")
            if (node.text or "") != self.expected_sources.get(ref):
                name = item.find("Properties/string[@name='Name']")
                raise BuildError(f"Source of '{name.text if name is not None else ref}' "
                                 "did not round-trip through XML")


def project_json(src_dir: str, project_path: str, present: list[str]) -> str:
    base = os.path.dirname(os.path.abspath(project_path))

    def path_of(sub):
        return os.path.relpath(os.path.join(src_dir, sub), base).replace(os.sep, "/")

    replicated = {"$className": "ReplicatedStorage"}
    server = {"$className": "ServerScriptService"}
    player_scripts = {"$className": "StarterPlayerScripts"}
    character_scripts = {"$className": "StarterCharacterScripts"}
    if "shared" in present:
        replicated["Shared"] = {"$path": path_of("shared")}
    if "server" in present:
        server["Server"] = {"$path": path_of("server")}
    if "client" in present:
        player_scripts["Client"] = {"$path": path_of("client")}
    if "character" in present:
        character_scripts["$path"] = path_of("character")
    if "playerscripts" in present:
        player_scripts["$path"] = path_of("playerscripts")
    project = {
        "name": PROJECT_NAME,
        "tree": {
            "$className": "DataModel",
            "Workspace": {"$className": "Workspace", "$properties": {"StreamingEnabled": False}},
            "Lighting": {"$className": "Lighting", "$properties": {"Technology": "Future"}},
            "ReplicatedStorage": replicated,
            "ServerScriptService": server,
            "StarterGui": {"$className": "StarterGui"},
            "StarterPlayer": {
                "$className": "StarterPlayer",
                "StarterPlayerScripts": player_scripts,
                "StarterCharacterScripts": character_scripts,
            },
            "SoundService": {"$className": "SoundService"},
        },
    }
    return json.dumps(project, indent=2, ensure_ascii=False) + "\n"


def write_text(path: str, text: str) -> str:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    return tmp


def display(path: str) -> str:
    rel = os.path.relpath(path)
    return path if rel.startswith("..") else rel


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Build a Roblox .rbxlx place from src/ (Rojo conventions).")
    ap.add_argument("--src", default=DEFAULT_SRC, help="source directory (default: %(default)s)")
    ap.add_argument("--out", default=DEFAULT_OUT, help="output .rbxlx file (default: %(default)s)")
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--project", help="Rojo project file to write (default: <parent of src>/default.project.json)")
    group.add_argument("--no-project", action="store_true", help="do not write default.project.json")
    args = ap.parse_args(argv)

    src = os.path.abspath(args.src)
    out = os.path.abspath(args.out)
    try:
        builder = Builder(src)
        services = builder.build_tree()
        xml_text = builder.emit(services)
        expected = builder.count_source_files()

        tmp = write_text(out, xml_text)
        try:
            builder.verify(tmp, expected)
        except BuildError as exc:
            raise BuildError(f"{exc} (broken output left at {tmp})") from None
        os.replace(tmp, out)
    except BuildError as exc:
        print(f"build.py: error: {exc}", file=sys.stderr)
        return 1

    for note in builder.notes:
        print(note, file=sys.stderr)
    if builder.skipped:
        print(f"note: skipped {len(builder.skipped)} non-script file(s): "
              + ", ".join(builder.rel(p) for p in builder.skipped[:5])
              + (" ..." if len(builder.skipped) > 5 else ""), file=sys.stderr)

    c = builder.class_counts
    print(f"Built {display(out)} ({os.path.getsize(out)} bytes, verified)")
    print(f"  Script:       {c['Script']}")
    print(f"  LocalScript:  {c['LocalScript']}")
    print(f"  ModuleScript: {c['ModuleScript']}")
    print(f"  Folder:       {c['Folder']}")
    print(f"  Source files: {expected}")

    if not args.no_project:
        project_path = os.path.abspath(args.project or os.path.join(os.path.dirname(src), "default.project.json"))
        tmp = write_text(project_path, project_json(src, project_path, builder.present))
        os.replace(tmp, project_path)
        print(f"Wrote {display(project_path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
