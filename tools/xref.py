import re, os, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src")
def read(p): return open(p, encoding="utf-8").read()

def members(src, modname):
    found = set()
    for m in re.finditer(r'function\s+%s[.:](\w+)\s*\(' % re.escape(modname), src): found.add(m.group(1))
    for m in re.finditer(r'^\s*%s\.(\w+)\s*=' % re.escape(modname), src, re.M): found.add(m.group(1))
    # initial table literal: local Mod = { a = 1, b = ... }
    m = re.search(r'local\s+%s\s*=\s*\{(.*?)\n\}' % re.escape(modname), src, re.S)
    if m:
        for f in re.finditer(r'^\s*(\w+)\s*=', m.group(1), re.M): found.add(f.group(1))
    return found

# server
main = read(os.path.join(root, "server/Main.server.lua"))
pairs_ = re.findall(r'\{\s*"(\w+)",\s*"(\w+)"\s*\}', main)
server_mods = {}
for key, file in pairs_:
    src = read(os.path.join(root, "server", file + ".lua"))
    m = re.search(r'return\s+(\w+)\s*$', src.strip())
    modname = m.group(1)
    server_mods[key] = (file, members(src, modname))
problems = 0
for fn in sorted(os.listdir(os.path.join(root, "server"))):
    src = read(os.path.join(root, "server", fn))
    for m in re.finditer(r'\bS\.(\w+)\.(\w+)', src):
        key, mem = m.groups()
        if key not in server_mods:
            print(f"server/{fn}: unknown service S.{key}"); problems += 1
        elif mem not in server_mods[key][1]:
            line = src[:m.start()].count("\n") + 1
            print(f"server/{fn}:{line}: S.{key}.{mem} not defined in {server_mods[key][0]}"); problems += 1
# aliases like PD = S.PlayerData
    for alias_m in re.finditer(r'\b(\w+)\s*=\s*S\.(\w+)\s*$', src, re.M):
        alias, key = alias_m.groups()
        if key not in server_mods: continue
        for m in re.finditer(r'\b%s\.(\w+)' % re.escape(alias), src):
            mem = m.group(1)
            if mem not in server_mods[key][1]:
                line = src[:m.start()].count("\n") + 1
                print(f"server/{fn}:{line}: {alias}.{mem} (S.{key}) not defined"); problems += 1

# client
cmain = read(os.path.join(root, "client/Main.client.lua"))
order = re.findall(r'"(\w+)"', re.search(r'local order = \{(.*?)\}', cmain).group(1))
client_mods = {}
for name in order:
    src = read(os.path.join(root, "client", name + ".lua"))
    modname = re.search(r'return\s+(\w+)\s*$', src.strip()).group(1)
    client_mods[name] = members(src, modname)
client_mods["State"] = {"Inventory", "WeaponOrder", "WeaponLevels", "Slots", "Active"}
client_mods["Player"] = set()
for fn in sorted(os.listdir(os.path.join(root, "client"))):
    src = read(os.path.join(root, "client", fn))
    for m in re.finditer(r'\bC\.(\w+)\.(\w+)', src):
        key, mem = m.groups()
        if key not in client_mods:
            print(f"client/{fn}: unknown C.{key}"); problems += 1
        elif client_mods[key] and mem not in client_mods[key]:
            line = src[:m.start()].count("\n") + 1
            print(f"client/{fn}:{line}: C.{key}.{mem} not defined"); problems += 1

# remotes
net = read(os.path.join(root, "shared/Net.lua"))
events = set(re.findall(r'^\s*"(\w+)",', re.search(r'Net\.Events = \{(.*?)\n\}', net, re.S).group(1), re.M))
used = set()
for d in ("server", "client", "shared"):
    for fn in os.listdir(os.path.join(root, d)):
        src = read(os.path.join(root, d, fn))
        for m in re.finditer(r'Net\.(?:Get|FireNear)\("(\w+)"', src):
            used.add(m.group(1))
            if m.group(1) not in events:
                line = src[:m.start()].count("\n") + 1
                print(f"{d}/{fn}:{line}: remote '{m.group(1)}' not in Net.Events"); problems += 1
print("unused remotes:", sorted(events - used))

# shared module members used as Shared requires: check X.Y against shared module definitions for common ones
shared_mods = {}
for fn in os.listdir(os.path.join(root, "shared")):
    src = read(os.path.join(root, "shared", fn))
    mm = re.search(r'return\s+(\w+)\s*$', src.strip())
    if mm: shared_mods[fn[:-4]] = members(src, mm.group(1))
for d in ("server", "client", "shared"):
    for fn in os.listdir(os.path.join(root, d)):
        src = read(os.path.join(root, d, fn))
        for req in re.finditer(r'local\s+(\w+)\s*=\s*require\(Shared\.(\w+)\)', src):
            alias, mod = req.groups()
            if mod not in shared_mods: print(f"{d}/{fn}: missing shared module {mod}"); problems += 1; continue
            for m in re.finditer(r'\b%s\.(\w+)' % re.escape(alias), src):
                mem = m.group(1)
                if mem not in shared_mods[mod]:
                    line = src[:m.start()].count("\n") + 1
                    print(f"{d}/{fn}:{line}: {alias}.{mem} not defined in shared/{mod}"); problems += 1
print("problems:", problems)
