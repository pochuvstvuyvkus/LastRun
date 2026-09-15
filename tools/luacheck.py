#!/usr/bin/env python3
"""
luacheck.py - Lua 5.1 / Luau syntax checker and undefined-variable linter.

Standard library only.

Usage:
    python3 tools/luacheck.py <file-or-dir> [...] [--globals name1,name2]

Every *.lua / *.luau file found (recursively for directories) is tokenized,
parsed with a full recursive-descent Lua 5.1 parser (plus the Luau extensions
used in this project) and, if parsing succeeds, scope-analysed.

Output lines look like:
    path:line:col: error: message
    path:line:col: warning: message

Exit status is 1 if any error was reported, 0 otherwise (warnings alone -> 0).
"""
from __future__ import annotations

import difflib
import os
import sys

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

KEYWORDS = frozenset((
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true",
    "until", "while",
))

# Roblox Luau environment. Services (TweenService, Players, ...) are NOT
# globals: they must come from game:GetService.
KNOWN_GLOBALS = frozenset("""
    game workspace Workspace script plugin shared _G _VERSION
    Instance Vector3 Vector2 Vector3int16 Vector2int16 CFrame Color3
    ColorSequence ColorSequenceKeypoint NumberSequence NumberSequenceKeypoint
    NumberRange UDim UDim2 Rect Region3 Region3int16 Ray RaycastParams
    OverlapParams TweenInfo BrickColor PhysicalProperties Random Enum Faces
    Axes Font DateTime PathWaypoint SharedTable Content
    task math string table coroutine os debug utf8 bit32 buffer vector
    pairs ipairs next select type typeof tostring tonumber print warn error
    assert pcall xpcall require setmetatable getmetatable rawget rawset
    rawequal rawlen unpack tick time wait delay spawn elapsedTime gcinfo
    collectgarbage newproxy loadstring getfenv setfenv version stats settings
    UserSettings CatalogSearchParams DockWidgetPluginGuiInfo RotationCurveKey
    FloatCurveKey
""".split())

DEPRECATED_GLOBAL_CALLS = {
    "wait": "task.wait",
    "spawn": "task.spawn",
    "delay": "task.delay",
}

# Instance methods that are almost always a bug when called with '.'
# and a string literal as the first argument (the object is not passed as self).
LOOKUP_METHODS = frozenset((
    "GetService", "WaitForChild", "FindFirstChild", "FindFirstChildOfClass",
    "FindFirstChildWhichIsA", "FindFirstAncestor", "FindFirstAncestorOfClass",
    "FindFirstAncestorWhichIsA",
))

COMPOUND_OPS = frozenset(("+=", "-=", "*=", "/=", "//=", "%=", "^=", "..="))

BLOCK_FOLLOW = frozenset(("else", "elseif", "end", "until", "<eof>"))
UNARY_OPS = frozenset(("not", "-", "#"))
UNARY_PRIORITY = 8
# (left priority, right priority) - same table as Lua 5.1's lparser.c
BINARY_PRIORITY = {
    "or": (1, 1), "and": (2, 2),
    "<": (3, 3), ">": (3, 3), "<=": (3, 3), ">=": (3, 3), "~=": (3, 3), "==": (3, 3),
    "..": (5, 4),                                   # right associative
    "+": (6, 6), "-": (6, 6),
    "*": (7, 7), "/": (7, 7), "//": (7, 7), "%": (7, 7),
    "^": (10, 9),                                   # right associative
}

LUA_EXTENSIONS = (".lua", ".luau")

# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------


class LuaSyntaxError(Exception):
    def __init__(self, message: str, line: int, col: int):
        super().__init__(message)
        self.message = message
        self.line = line
        self.col = col


class Token:
    __slots__ = ("type", "value", "line", "col", "eline", "raw")

    def __init__(self, type_, value, line, col, eline, raw):
        self.type = type_      # '<name>', '<number>', '<string>', '<interp_*>', '<eof>', keyword or operator
        self.value = value
        self.line = line
        self.col = col
        self.eline = eline     # line on which the token ends (multi-line strings)
        self.raw = raw

    def __repr__(self):
        return f"Token({self.type!r}, {self.raw!r}, {self.line}:{self.col})"


_DIGITS = frozenset("0123456789")
_HEX = frozenset("0123456789abcdefABCDEF")
_NAME_START = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
_NAME_CHARS = _NAME_START | _DIGITS
_OPS3 = frozenset(("...", "..=", "//="))
_OPS2 = frozenset(("..", "//", "==", "~=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "^="))
_OPS1 = frozenset("+-*/%^#<>=(){}[];:,.")
_SIMPLE_ESCAPES = frozenset("abfnrtv\\\"'")


class Lexer:
    def __init__(self, src: str):
        src = src.replace("\r\n", "\n").replace("\r", "\n")
        if src.startswith("﻿"):
            src = src[1:]
        self.s = src
        self.n = len(src)
        self.i = 0
        self.line = 1
        self.line_start = 0
        # One entry per open interpolated-string expression: current '{' nesting depth.
        self.interp_depth: list[int] = []
        if src.startswith("#"):          # shebang line
            j = src.find("\n")
            self.i = self.n if j < 0 else j

    # -- helpers -----------------------------------------------------------
    def _col(self, i: int) -> int:
        return i - self.line_start + 1

    @staticmethod
    def _error(msg, line, col):
        raise LuaSyntaxError(msg, line, col)

    def _advance_lines(self, start: int, end: int):
        cnt = self.s.count("\n", start, end)
        if cnt:
            self.line += cnt
            self.line_start = self.s.rfind("\n", start, end) + 1

    def _long_level(self, i: int):
        """s[i] == '['. Returns the level of a long bracket opening at i, or None."""
        j = i + 1
        while j < self.n and self.s[j] == "=":
            j += 1
        if j < self.n and self.s[j] == "[":
            return j - i - 1
        return None

    def _read_long(self, i: int, level: int, what: str, line: int, col: int) -> str:
        start = i + level + 2
        close = "]" + "=" * level + "]"
        end = self.s.find(close, start)
        if end < 0:
            self._error(f"unfinished long {what} starting at line {line} (missing '{close}')", line, col)
        self._advance_lines(i, end + len(close))
        self.i = end + len(close)
        content = self.s[start:end]
        if content.startswith("\n"):
            content = content[1:]
        return content

    def _escape(self, j: int, line: int, col: int, interp: bool) -> int:
        """s[j] == '\\'. Validates the escape and returns the index after it."""
        s, n = self.s, self.n
        if j + 1 >= n:
            self._error("unfinished string", line, col)
        e = s[j + 1]
        ecol = self._col(j)
        if e == "\n":
            self.line += 1
            self.line_start = j + 2
            return j + 2
        if e in _SIMPLE_ESCAPES:
            return j + 2
        if e == "x":
            if j + 3 < n and s[j + 2] in _HEX and s[j + 3] in _HEX:
                return j + 4
            self._error("invalid hexadecimal escape sequence (expected '\\xXX')", self.line, ecol)
        if e == "z":
            k = j + 2
            while k < n and s[k] in " \t\f\v\n":
                if s[k] == "\n":
                    self.line += 1
                    self.line_start = k + 1
                k += 1
            return k
        if e == "u":
            k = j + 3
            ok = j + 2 < n and s[j + 2] == "{"
            start = k
            while ok and k < n and s[k] in _HEX:
                k += 1
            if not ok or k == start or k >= n or s[k] != "}" or int(s[start:k], 16) > 0x10FFFF:
                self._error("invalid unicode escape sequence (expected '\\u{XXXX}')", self.line, ecol)
            return k + 1
        if e in _DIGITS:
            k = j + 1
            while k < n and k < j + 4 and s[k] in _DIGITS:
                k += 1
            if int(s[j + 1:k]) > 255:
                self._error("decimal escape sequence too large (max \\255)", self.line, ecol)
            return k
        # Unknown escapes (including \{ and \` ) are accepted, like Lua 5.1/Luau do.
        return j + 2

    def _read_string(self, i: int, line: int, col: int) -> Token:
        s, n = self.s, self.n
        q = s[i]
        j = i + 1
        while True:
            if j >= n or s[j] == "\n":
                raw = s[i:j]
                if len(raw) > 30:
                    raw = raw[:30] + "..."
                self._error(f"unfinished string near '{raw}'", line, col)
            ch = s[j]
            if ch == q:
                j += 1
                break
            if ch == "\\":
                j = self._escape(j, line, col, interp=False)
                continue
            j += 1
        self.i = j
        raw = s[i:j]
        return Token("<string>", raw[1:-1], line, col, self.line, raw)

    def _read_interp(self, j: int, line: int, col: int, first: bool) -> Token:
        """Reads a segment of a backtick string, starting just after '`' or '}'."""
        s, n = self.s, self.n
        start = j - 1
        while True:
            if j >= n or s[j] == "\n":
                self._error("unfinished interpolated string", line, col)
            ch = s[j]
            if ch == "`":
                j += 1
                typ = "<interp_simple>" if first else "<interp_end>"
                break
            if ch == "{":
                if j + 1 < n and s[j + 1] == "{":
                    self._error("double braces are not permitted in interpolated strings; "
                                "use '\\{' for a literal brace", self.line, self._col(j))
                j += 1
                typ = "<interp_begin>" if first else "<interp_mid>"
                self.interp_depth.append(0)
                break
            if ch == "\\":
                j = self._escape(j, line, col, interp=True)
                continue
            j += 1
        self.i = j
        raw = s[start:j]
        return Token(typ, raw, line, col, self.line, raw)

    def _read_number(self, i: int, line: int, col: int) -> Token:
        s, n = self.s, self.n
        ok = True
        if s[i] == "0" and i + 1 < n and s[i + 1] in "xX":
            j = k = i + 2
            while j < n and (s[j] in _HEX or s[j] == "_"):
                j += 1
            ok = any(ch in _HEX for ch in s[k:j])
        elif s[i] == "0" and i + 1 < n and s[i + 1] in "bB":
            j = k = i + 2
            while j < n and s[j] in "01_":
                j += 1
            ok = any(ch in "01" for ch in s[k:j])
        else:
            j = i
            while j < n and (s[j] in _DIGITS or s[j] == "_"):
                j += 1
            if j < n and s[j] == ".":
                j += 1
                while j < n and (s[j] in _DIGITS or s[j] == "_"):
                    j += 1
            if j < n and s[j] in "eE":
                j += 1
                if j < n and s[j] in "+-":
                    j += 1
                k = j
                while j < n and (s[j] in _DIGITS or s[j] == "_"):
                    j += 1
                ok = any(ch in _DIGITS for ch in s[k:j])
        if j < n and (s[j] in _NAME_CHARS or s[j] == "." or s[j].isalnum()):
            ok = False
            while j < n and (s[j] in _NAME_CHARS or s[j] == "." or s[j].isalnum()):
                j += 1
        raw = s[i:j]
        if not ok:
            self._error(f"malformed number near '{raw}'", line, col)
        self.i = j
        return Token("<number>", raw, line, col, line, raw)

    # -- main entry --------------------------------------------------------
    def next_token(self) -> Token:
        s, n = self.s, self.n
        while True:
            i = self.i
            if i >= n:
                return Token("<eof>", None, self.line, self._col(i), self.line, "<eof>")
            c = s[i]
            if c == "\n":
                self.i = i + 1
                self.line += 1
                self.line_start = i + 1
                continue
            if c in " \t\f\v":
                self.i = i + 1
                continue
            if c == "-" and i + 1 < n and s[i + 1] == "-":
                line, col = self.line, self._col(i)
                j = i + 2
                if j < n and s[j] == "[":
                    level = self._long_level(j)
                    if level is not None:
                        self._read_long(j, level, "comment", line, col)
                        continue
                k = s.find("\n", j)
                self.i = n if k < 0 else k
                continue
            break

        line, col = self.line, self._col(i)

        if c in _NAME_START:
            j = i + 1
            while j < n and s[j] in _NAME_CHARS:
                j += 1
            word = s[i:j]
            self.i = j
            return Token(word if word in KEYWORDS else "<name>", word, line, col, line, word)

        if c in _DIGITS or (c == "." and i + 1 < n and s[i + 1] in _DIGITS):
            return self._read_number(i, line, col)

        if c == '"' or c == "'":
            return self._read_string(i, line, col)

        if c == "`":
            return self._read_interp(i + 1, line, col, first=True)

        if c == "[":
            level = self._long_level(i)
            if level is not None:
                content = self._read_long(i, level, "string", line, col)
                raw = s[i:self.i]
                return Token("<string>", content, line, col, self.line, raw)
            if i + 1 < n and s[i + 1] == "=":
                self._error("invalid long string delimiter near '[='", line, col)

        if c == "{":
            if self.interp_depth:
                self.interp_depth[-1] += 1
            self.i = i + 1
            return Token("{", "{", line, col, line, "{")

        if c == "}":
            if self.interp_depth:
                if self.interp_depth[-1] == 0:
                    self.interp_depth.pop()
                    return self._read_interp(i + 1, line, col, first=False)
                self.interp_depth[-1] -= 1
            self.i = i + 1
            return Token("}", "}", line, col, line, "}")

        op = s[i:i + 3]
        if op in _OPS3:
            self.i = i + 3
            return Token(op, op, line, col, line, op)
        op = s[i:i + 2]
        if op in _OPS2:
            self.i = i + 2
            return Token(op, op, line, col, line, op)
        if c in _OPS1:
            self.i = i + 1
            return Token(c, c, line, col, line, c)

        shown = c if c.isprintable() and not c.isspace() else repr(c)
        self._error(f"unexpected character '{shown}'", line, col)
        raise AssertionError("unreachable")


def tokenize(src: str) -> list[Token]:
    """Convenience helper (used by tests): returns all tokens including <eof>."""
    lx = Lexer(src)
    out = []
    while True:
        t = lx.next_token()
        out.append(t)
        if t.type == "<eof>":
            return out


# ---------------------------------------------------------------------------
# AST
# ---------------------------------------------------------------------------


class Node:
    def __init__(self, kind: str, line: int, col: int, **fields):
        self.kind = kind
        self.line = line
        self.col = col
        self.__dict__.update(fields)

    def __repr__(self):
        fields = {k: v for k, v in self.__dict__.items() if k not in ("kind", "line", "col")}
        return f"{self.kind}({fields})"


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------


class _FuncState:
    __slots__ = ("vararg", "loops")

    def __init__(self, vararg: bool):
        self.vararg = vararg
        self.loops = 0


class Parser:
    def __init__(self, src: str):
        self.lexer = Lexer(src)
        self.prev_eline = 1
        self._ahead = None
        self.tok = self.lexer.next_token()
        self.funcs: list[_FuncState] = []

    # -- token helpers -----------------------------------------------------
    def next(self):
        self.prev_eline = self.tok.eline
        if self._ahead is not None:
            self.tok, self._ahead = self._ahead, None
        else:
            self.tok = self.lexer.next_token()

    def peek(self) -> Token:
        if self._ahead is None:
            self._ahead = self.lexer.next_token()
        return self._ahead

    @staticmethod
    def near(tok: Token) -> str:
        if tok.type == "<eof>":
            return "<eof>"
        raw = tok.raw
        if "\n" in raw:
            raw = raw.split("\n", 1)[0] + "..."
        if len(raw) > 40:
            raw = raw[:40] + "..."
        return f"'{raw}'"

    def error(self, msg: str, tok: Token | None = None, with_near: bool = True):
        tok = tok or self.tok
        if with_near:
            msg = f"{msg} near {self.near(tok)}"
        raise LuaSyntaxError(msg, tok.line, tok.col)

    def error_at(self, msg: str, line: int, col: int):
        raise LuaSyntaxError(msg, line, col)

    def expect(self, ttype: str, context: str = ""):
        if self.tok.type != ttype:
            what = "identifier" if ttype == "<name>" else f"'{ttype}'"
            self.error(f"expected {what}{context}")
        self.next()

    def check_match(self, what: str, who: str, line: int):
        if self.tok.type != what:
            self.error(f"expected '{what}' to close '{who}' at line {line}")
        self.next()

    def name(self) -> Token:
        t = self.tok
        if t.type != "<name>":
            if t.type in KEYWORDS:
                self.error(f"expected identifier, got keyword '{t.type}'", with_near=False)
            self.error("expected identifier")
        self.next()
        return t

    # -- blocks & statements -----------------------------------------------
    def parse_chunk(self) -> Node:
        self.funcs.append(_FuncState(vararg=True))
        body = self.block()
        if self.tok.type != "<eof>":
            self.error(f"unexpected '{self.tok.type}' (there is no open block for it to close)",
                       with_near=False)
        self.funcs.pop()
        return Node("Chunk", 1, 1, body=body)

    def block(self) -> list[Node]:
        stmts: list[Node] = []
        while self.tok.type not in BLOCK_FOLLOW:
            if self.tok.type == ";":
                self.next()
                continue
            st = self.statement()
            stmts.append(st)
            if self.tok.type == ";":
                self.next()
            if st.kind in ("Return", "Break", "Continue"):
                if self.tok.type not in BLOCK_FOLLOW:
                    kw = st.kind.lower()
                    self.error(f"'{kw}' must be the last statement in a block "
                               f"(found code after the '{kw}' at line {st.line})")
                break
        return stmts

    def loop_body(self) -> list[Node]:
        fs = self.funcs[-1]
        fs.loops += 1
        body = self.block()
        fs.loops -= 1
        return body

    def statement(self) -> Node:
        t = self.tok
        k = t.type
        if k == "if":
            return self.if_stat()
        if k == "while":
            self.next()
            cond = self.expr()
            self.expect("do", " after 'while' condition")
            body = self.loop_body()
            self.check_match("end", "while", t.line)
            return Node("While", t.line, t.col, cond=cond, body=body)
        if k == "do":
            self.next()
            body = self.block()
            self.check_match("end", "do", t.line)
            return Node("Do", t.line, t.col, body=body)
        if k == "for":
            return self.for_stat()
        if k == "repeat":
            self.next()
            body = self.loop_body()
            self.check_match("until", "repeat", t.line)
            cond = self.expr()
            return Node("Repeat", t.line, t.col, body=body, cond=cond)
        if k == "function":
            return self.function_stat()
        if k == "local":
            self.next()
            if self.tok.type == "function":
                self.next()
                n = self.name()
                func = self.func_body(t, is_method=False)
                return Node("LocalFunction", t.line, t.col, name=(n.value, n.line, n.col), func=func)
            names = []
            while True:
                n = self.name()
                names.append((n.value, n.line, n.col))
                if self.tok.type != ",":
                    break
                self.next()
            exprs = []
            if self.tok.type == "=":
                self.next()
                exprs = self.expr_list()
            return Node("Local", t.line, t.col, names=names, exprs=exprs)
        if k == "return":
            self.next()
            exprs = []
            if self.tok.type not in BLOCK_FOLLOW and self.tok.type != ";":
                exprs = self.expr_list()
            return Node("Return", t.line, t.col, exprs=exprs)
        if k == "break":
            if self.funcs[-1].loops == 0:
                self.error("'break' outside a loop", with_near=False)
            self.next()
            return Node("Break", t.line, t.col)
        return self.expr_stat()

    def if_stat(self) -> Node:
        t = self.tok
        clauses = []
        self.next()
        cond = self.expr()
        self.expect("then", f" after 'if' condition (line {t.line})")
        clauses.append((cond, self.block()))
        else_body = None
        while True:
            k = self.tok.type
            if k == "elseif":
                et = self.tok
                self.next()
                cond = self.expr()
                self.expect("then", f" after 'elseif' condition (line {et.line})")
                clauses.append((cond, self.block()))
            elif k == "else":
                self.next()
                else_body = self.block()
                self.check_match("end", "if", t.line)
                break
            else:
                self.check_match("end", "if", t.line)
                break
        return Node("If", t.line, t.col, clauses=clauses, else_body=else_body)

    def for_stat(self) -> Node:
        t = self.tok
        self.next()
        n1 = self.name()
        if self.tok.type == "=":
            self.next()
            start = self.expr()
            self.expect(",", " in numeric 'for'")
            stop = self.expr()
            step = None
            if self.tok.type == ",":
                self.next()
                step = self.expr()
            self.expect("do", f" after 'for' header (line {t.line})")
            body = self.loop_body()
            self.check_match("end", "for", t.line)
            return Node("NumFor", t.line, t.col, var=(n1.value, n1.line, n1.col),
                        start=start, stop=stop, step=step, body=body)
        if self.tok.type in (",", "in"):
            names = [(n1.value, n1.line, n1.col)]
            while self.tok.type == ",":
                self.next()
                n = self.name()
                names.append((n.value, n.line, n.col))
            self.expect("in", " in generic 'for'")
            exprs = self.expr_list()
            self.expect("do", f" after 'for' header (line {t.line})")
            body = self.loop_body()
            self.check_match("end", "for", t.line)
            return Node("GenFor", t.line, t.col, names=names, exprs=exprs, body=body)
        self.error("expected '=' or 'in' in 'for' statement")
        raise AssertionError("unreachable")

    def function_stat(self) -> Node:
        t = self.tok
        self.next()
        n = self.name()
        target = Node("Name", n.line, n.col, name=n.value)
        while self.tok.type == ".":
            self.next()
            k = self.name()
            key = Node("String", k.line, k.col, value=k.value, raw=k.value, name_key=True)
            target = Node("Index", k.line, k.col, obj=target, key=key)
        is_method = False
        if self.tok.type == ":":
            self.next()
            k = self.name()
            key = Node("String", k.line, k.col, value=k.value, raw=k.value, name_key=True)
            target = Node("Index", k.line, k.col, obj=target, key=key)
            is_method = True
        func = self.func_body(t, is_method)
        return Node("FunctionStat", t.line, t.col, target=target, is_method=is_method, func=func)

    def func_body(self, start_tok: Token, is_method: bool) -> Node:
        line = start_tok.line
        if self.tok.type != "(":
            self.error("expected '(' to start function parameters")
        open_tok = self.tok
        self.next()
        params = []
        vararg = False
        if self.tok.type != ")":
            while True:
                if self.tok.type == "<name>":
                    params.append((self.tok.value, self.tok.line, self.tok.col))
                    self.next()
                elif self.tok.type == "...":
                    vararg = True
                    self.next()
                    break
                else:
                    self.error("expected parameter name or '...'")
                if self.tok.type != ",":
                    break
                self.next()
        self.check_match(")", "(", open_tok.line)
        self.funcs.append(_FuncState(vararg))
        body = self.block()
        self.funcs.pop()
        self.check_match("end", "function", line)
        return Node("Function", start_tok.line, start_tok.col, params=params, vararg=vararg,
                    body=body, is_method=is_method)

    def expr_stat(self) -> Node:
        start = self.tok
        e = self.suffixed_expr()
        k = self.tok.type
        if k in ("=", ","):
            targets = [self.check_assignable(e)]
            while self.tok.type == ",":
                self.next()
                targets.append(self.check_assignable(self.suffixed_expr()))
            self.expect("=", " in assignment")
            exprs = self.expr_list()
            return Node("Assign", start.line, start.col, targets=targets, exprs=exprs)
        if k in COMPOUND_OPS:
            self.check_assignable(e)
            op = k
            self.next()
            value = self.expr()
            return Node("CompoundAssign", start.line, start.col, op=op, target=e, value=value)
        if e.kind in ("Call", "MethodCall"):
            return Node("CallStat", start.line, start.col, call=e)
        if e.kind == "Name" and e.name == "continue":
            if self.funcs[-1].loops == 0:
                self.error_at("'continue' outside a loop", e.line, e.col)
            return Node("Continue", start.line, start.col)
        msg = "incomplete statement: expected assignment or a function call"
        if e.kind == "Name":
            close = difflib.get_close_matches(e.name, KEYWORDS | {"continue"}, n=1, cutoff=0.75)
            if close:
                msg += f" (did you mean '{close[0]}' instead of '{e.name}'?)"
        self.error(msg)
        raise AssertionError("unreachable")

    def check_assignable(self, e: Node) -> Node:
        if e.kind not in ("Name", "Index"):
            what = {"Call": "a function call", "MethodCall": "a method call",
                    "Paren": "a parenthesized expression"}.get(e.kind, "this expression")
            self.error_at(f"syntax error: cannot assign to {what}", e.line, e.col)
        return e

    # -- expressions ---------------------------------------------------------
    def expr_list(self) -> list[Node]:
        exprs = [self.expr()]
        while self.tok.type == ",":
            self.next()
            exprs.append(self.expr())
        return exprs

    def expr(self, limit: int = 0) -> Node:
        t = self.tok
        if t.type in UNARY_OPS:
            self.next()
            operand = self.expr(UNARY_PRIORITY)
            left = Node("Unop", t.line, t.col, op=t.type, operand=operand)
        else:
            left = self.simple_expr()
        while True:
            op = self.tok.type
            prio = BINARY_PRIORITY.get(op)
            if prio is None or prio[0] <= limit:
                break
            self.next()
            right = self.expr(prio[1])
            left = Node("Binop", left.line, left.col, op=op, left=left, right=right)
        return left

    def simple_expr(self) -> Node:
        t = self.tok
        k = t.type
        if k == "<number>":
            self.next()
            return Node("Number", t.line, t.col, raw=t.raw)
        if k in ("<string>", "<interp_simple>"):
            self.next()
            return Node("String", t.line, t.col, value=t.value, raw=t.raw, name_key=False)
        if k == "<interp_begin>":
            return self.interp_string()
        if k == "nil":
            self.next()
            return Node("Nil", t.line, t.col)
        if k == "true" or k == "false":
            self.next()
            return Node("Bool", t.line, t.col, value=(k == "true"))
        if k == "...":
            if not self.funcs[-1].vararg:
                self.error("cannot use '...' outside a vararg function", with_near=False)
            self.next()
            return Node("Vararg", t.line, t.col)
        if k == "{":
            return self.table()
        if k == "function":
            self.next()
            return self.func_body(t, is_method=False)
        if k == "if":
            return self.if_expr()
        return self.suffixed_expr()

    def if_expr(self) -> Node:
        t = self.tok
        self.next()
        branches = []
        cond = self.expr()
        self.expect("then", f" in if-expression (line {t.line})")
        branches.append((cond, self.expr()))
        while self.tok.type == "elseif":
            self.next()
            cond = self.expr()
            self.expect("then", f" in if-expression (line {t.line})")
            branches.append((cond, self.expr()))
        if self.tok.type != "else":
            self.error(f"expected 'else' in if-expression started at line {t.line} "
                       "(if-expressions require an 'else' branch)")
        self.next()
        else_value = self.expr()
        return Node("IfExpr", t.line, t.col, branches=branches, else_value=else_value)

    def interp_string(self) -> Node:
        t = self.tok
        self.next()
        parts = []
        while True:
            parts.append(self.expr())
            if self.tok.type == "<interp_mid>":
                self.next()
                continue
            if self.tok.type == "<interp_end>":
                self.next()
                break
            self.error(f"expected '}}' to close expression in interpolated string at line {t.line}")
        return Node("Interp", t.line, t.col, parts=parts)

    def primary_expr(self) -> Node:
        t = self.tok
        if t.type == "<name>":
            self.next()
            return Node("Name", t.line, t.col, name=t.value)
        if t.type == "(":
            self.next()
            inner = self.expr()
            self.check_match(")", "(", t.line)
            return Node("Paren", t.line, t.col, expr=inner)
        if t.type in COMPOUND_OPS:
            self.error(f"compound assignment '{t.type}' can only be used as a statement "
                       f"(e.g. 'x {t.type} 1')", with_near=False)
        self.error("unexpected symbol")
        raise AssertionError("unreachable")

    def suffixed_expr(self) -> Node:
        e = self.primary_expr()
        while True:
            t = self.tok
            k = t.type
            if k == ".":
                self.next()
                n = self.name()
                key = Node("String", n.line, n.col, value=n.value, raw=n.value, name_key=True)
                e = Node("Index", e.line, e.col, obj=e, key=key)
            elif k == "[":
                self.next()
                key = self.expr()
                self.check_match("]", "[", t.line)
                e = Node("Index", e.line, e.col, obj=e, key=key)
            elif k == ":":
                self.next()
                n = self.name()
                args = self.call_args()
                e = Node("MethodCall", e.line, e.col, obj=e, method=n.value, args=args)
            elif k in ("(", "<string>", "{"):
                if k == "(" and t.line != self.prev_eline:
                    self.error("ambiguous syntax (function call x new statement); "
                               "put the '(' on the previous line or add ';'", with_near=False)
                args = self.call_args()
                e = Node("Call", e.line, e.col, func=e, args=args)
            elif k in ("<interp_simple>", "<interp_begin>"):
                self.error("interpolated strings cannot be used as call arguments without parentheses")
            else:
                return e

    def call_args(self) -> list[Node]:
        t = self.tok
        if t.type == "<string>":
            self.next()
            return [Node("String", t.line, t.col, value=t.value, raw=t.raw, name_key=False)]
        if t.type == "{":
            return [self.table()]
        if t.type == "(":
            self.next()
            args = []
            if self.tok.type != ")":
                args = self.expr_list()
            self.check_match(")", "(", t.line)
            return args
        self.error("expected function arguments")
        raise AssertionError("unreachable")

    def table(self) -> Node:
        t = self.tok
        self.next()
        fields = []
        while self.tok.type != "}":
            ft = self.tok
            if ft.type == "[":
                self.next()
                key = self.expr()
                self.check_match("]", "[", ft.line)
                self.expect("=", " after '[key]' in table constructor")
                fields.append(("key", key, self.expr()))
            elif ft.type == "<name>" and self.peek().type == "=":
                self.next()
                self.next()
                key = Node("String", ft.line, ft.col, value=ft.value, raw=ft.value, name_key=True)
                fields.append(("name", key, self.expr()))
            else:
                fields.append(("pos", None, self.expr()))
            if self.tok.type in (",", ";"):
                self.next()
            elif self.tok.type != "}":
                self.error(f"expected ',' or '}}' to close '{{' at line {t.line}")
        self.next()
        return Node("Table", t.line, t.col, fields=fields)


def parse(src: str) -> Node:
    return Parser(src).parse_chunk()


# ---------------------------------------------------------------------------
# Scope analysis
# ---------------------------------------------------------------------------

_LEAF_EXPRS = frozenset(("Number", "String", "Nil", "Bool", "Vararg"))


class Analyzer:
    def __init__(self, known_globals=KNOWN_GLOBALS):
        self.known = known_globals
        self.scopes: list[set[str]] = []
        self.issues: list[tuple[int, int, str, str]] = []
        self.pending_reads: list[tuple[str, int, int]] = []
        self.global_writes: set[str] = set()

    def warn(self, line, col, msg):
        self.issues.append((line, col, "warning", msg))

    def analyze(self, chunk: Node):
        self.scopes.append(set())
        self.stmts(chunk.body)
        self.scopes.pop()
        for name, line, col in self.pending_reads:
            # A global that is assigned somewhere in the file was already reported
            # at the assignment; don't repeat it for every read.
            if name not in self.global_writes:
                self.warn(line, col, f"undefined global '{name}'")
        self.issues.sort()
        return self.issues

    # -- scope helpers -----------------------------------------------------
    def is_local(self, name: str) -> bool:
        for sc in reversed(self.scopes):
            if name in sc:
                return True
        return False

    def read(self, name, line, col):
        if not self.is_local(name) and name not in self.known:
            self.pending_reads.append((name, line, col))

    def write(self, name, line, col):
        if self.is_local(name):
            return
        if name in self.known:
            self.warn(line, col, f"assignment to built-in global '{name}'")
        else:
            self.warn(line, col, f"assignment to undeclared global '{name}'")
            self.global_writes.add(name)

    def block(self, stmts):
        self.scopes.append(set())
        self.stmts(stmts)
        self.scopes.pop()

    def stmts(self, stmts):
        for st in stmts:
            getattr(self, "s_" + st.kind)(st)

    def function(self, f: Node):
        params = {p[0] for p in f.params}
        if f.is_method:
            params.add("self")
        self.scopes.append(params)
        self.stmts(f.body)
        self.scopes.pop()

    def target(self, t: Node):
        if t.kind == "Name":
            self.write(t.name, t.line, t.col)
        else:
            self.expr(t.obj)
            self.expr(t.key)

    # -- statements ----------------------------------------------------------
    def s_Local(self, st):
        for e in st.exprs:
            self.expr(e)
        for name, _l, _c in st.names:
            self.scopes[-1].add(name)

    def s_LocalFunction(self, st):
        self.scopes[-1].add(st.name[0])
        self.function(st.func)

    def s_FunctionStat(self, st):
        t = st.target
        if t.kind == "Name":
            self.write(t.name, t.line, t.col)
        else:
            self.expr(t.obj)
        self.function(st.func)

    def s_Assign(self, st):
        for e in st.exprs:
            self.expr(e)
        for t in st.targets:
            self.target(t)

    def s_CompoundAssign(self, st):
        t = st.target
        if t.kind == "Name":
            self.read(t.name, t.line, t.col)
        self.expr(st.value)
        self.target(t)

    def s_CallStat(self, st):
        self.expr(st.call)

    def s_Do(self, st):
        self.block(st.body)

    def s_While(self, st):
        self.expr(st.cond)
        self.block(st.body)

    def s_Repeat(self, st):
        self.scopes.append(set())
        self.stmts(st.body)
        self.expr(st.cond)          # 'until' sees the body's locals
        self.scopes.pop()

    def s_If(self, st):
        for cond, body in st.clauses:
            self.expr(cond)
            self.block(body)
        if st.else_body is not None:
            self.block(st.else_body)

    def s_NumFor(self, st):
        self.expr(st.start)
        self.expr(st.stop)
        if st.step is not None:
            self.expr(st.step)
        self.scopes.append({st.var[0]})
        self.stmts(st.body)
        self.scopes.pop()

    def s_GenFor(self, st):
        for e in st.exprs:
            self.expr(e)
        self.scopes.append({n[0] for n in st.names})
        self.stmts(st.body)
        self.scopes.pop()

    def s_Return(self, st):
        for e in st.exprs:
            self.expr(e)

    def s_Break(self, st):
        pass

    def s_Continue(self, st):
        pass

    # -- expressions ---------------------------------------------------------
    def expr(self, e: Node):
        if e.kind in _LEAF_EXPRS:
            return
        getattr(self, "e_" + e.kind)(e)

    def e_Name(self, e):
        self.read(e.name, e.line, e.col)

    def e_Index(self, e):
        self.expr(e.obj)
        self.expr(e.key)

    def e_Call(self, e):
        f = e.func
        if f.kind == "Name" and f.name in DEPRECATED_GLOBAL_CALLS and not self.is_local(f.name):
            self.warn(f.line, f.col, f"'{f.name}' is deprecated; use '{DEPRECATED_GLOBAL_CALLS[f.name]}' instead")
        elif f.kind == "Index" and f.key.kind == "String" and f.key.name_key:
            m = f.key.value
            if (m in LOOKUP_METHODS and 1 <= len(e.args) <= 2 and e.args[0].kind == "String") or \
               (m in ("Connect", "Once") and len(e.args) == 1
                    and f.obj.kind in ("Index", "Call", "MethodCall")):
                self.warn(f.key.line, f.key.col,
                          f"'.{m}(...)' called with '.', did you mean ':{m}(...)'?")
        self.expr(f)
        for a in e.args:
            self.expr(a)

    def e_MethodCall(self, e):
        self.expr(e.obj)
        for a in e.args:
            self.expr(a)

    def e_Function(self, e):
        self.function(e)

    def e_Binop(self, e):
        self.expr(e.left)
        self.expr(e.right)

    def e_Unop(self, e):
        self.expr(e.operand)

    def e_Paren(self, e):
        self.expr(e.expr)

    def e_Interp(self, e):
        for p in e.parts:
            self.expr(p)

    def e_IfExpr(self, e):
        for cond, value in e.branches:
            self.expr(cond)
            self.expr(value)
        self.expr(e.else_value)

    def e_Table(self, e):
        seen: dict[str, int] = {}
        for kind, key, value in e.fields:
            if key is not None:
                self.expr(key)
                if key.kind == "String" and "\\" not in key.raw:
                    k = key.value
                    if k in seen:
                        self.warn(key.line, key.col,
                                  f"duplicate key '{k}' in table constructor (first defined at line {seen[k]})")
                    else:
                        seen[k] = key.line
            self.expr(value)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def check_source(src: str, known_globals=KNOWN_GLOBALS) -> list[tuple[int, int, str, str]]:
    """Returns a list of (line, col, severity, message)."""
    try:
        chunk = parse(src)
    except LuaSyntaxError as exc:
        return [(exc.line, exc.col, "error", exc.message)]
    except RecursionError:
        return [(1, 1, "error", "code is nested too deeply to analyse")]
    try:
        return Analyzer(known_globals).analyze(chunk)
    except RecursionError:
        return [(1, 1, "error", "code is nested too deeply to analyse")]


def iter_lua_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith("."))
                for f in sorted(files):
                    if f.endswith(LUA_EXTENSIONS) and not f.startswith("."):
                        yield os.path.join(root, f)
        else:
            yield p


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    extra_globals: set[str] = set()
    paths = []
    it = iter(argv)
    for a in it:
        if a in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        if a == "--globals":
            extra_globals.update(x for x in next(it, "").split(",") if x)
        elif a.startswith("--globals="):
            extra_globals.update(x for x in a.split("=", 1)[1].split(",") if x)
        else:
            paths.append(a)
    if not paths:
        print("usage: luacheck.py <file-or-dir> [...] [--globals a,b]", file=sys.stderr)
        return 2
    known = KNOWN_GLOBALS | extra_globals

    files = errors = warnings = 0
    for path in iter_lua_files(paths):
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as exc:
            print(f"{path}:1:1: error: cannot read file: {exc.strerror}")
            errors += 1
            continue
        files += 1
        src = data.decode("utf-8", errors="replace")
        for line, col, sev, msg in check_source(src, known):
            print(f"{path}:{line}:{col}: {sev}: {msg}")
            if sev == "error":
                errors += 1
            else:
                warnings += 1
    print(f"Checked {files} file(s): {errors} error(s), {warnings} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.setrecursionlimit(20000)
    sys.exit(main())
