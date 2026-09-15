#!/usr/bin/env python3
"""Self-test for tools/luacheck.py.  Run:  python3 tools/test_luacheck.py -v"""
import contextlib
import io
import os
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import luacheck as lc  # noqa: E402


def issues(src):
    return lc.check_source(textwrap.dedent(src).lstrip("\n"))


def errors(src):
    return [i for i in issues(src) if i[2] == "error"]


def warnings(src):
    return [i for i in issues(src) if i[2] == "warning"]


GOOD = r'''
local Players = game:GetService("Players")
local M = {}
M.__index = M

function M.new(name, ...)
    local self = setmetatable({}, M)
    self.name = name
    self.args = { ... }
    self.count = select("#", ...)
    return self
end

function M:greet(greeting)
    return `{greeting or "Hi"}, {self.name}! You have {#self.args} args \{literal\}`
end

local function fib(n)
    if n < 2 then return n end
    return fib(n - 1) + fib(n - 2)
end

local t = { 1, 2; 3, x = 1, ["y z"] = 2, [10] = fib(5), nested = { a = { b = {} } }, }
local s1 = [[line1
line2]]
local s2 = [==[ contains ]] and ]=] inside ]==]
--[[ long
comment ]]
--[==[ another ]] long comment ]==]
local n = 0xFF + 1e-3 + .5 + 1_000_000 + 0b1010_1010 + 0x7FFF_FFFF + 3.14e+2 + 1.
local esc = "tab\tquote\"nl\n\x41\u{1F600}\065\z
    continued"
local e = 'single \'quoted\' Привет'
local cnt = 0
for i = 1, 10, 2 do
    if i % 3 == 0 then continue end
    cnt += i
end
for _, v in pairs(t) do
    cnt -= 1; cnt *= 2; cnt /= 2; cnt %= 7; cnt ^= 1; cnt //= 1
    if v then continue end
end
local str = "a"
str ..= "b"
local x = if cnt > 3 then "big" elseif cnt > 1 then "mid" else "small"
local y = 7 // 2
local z = -2 ^ 2 .. "x" .. "y"
local ok = not (x == y) and #str > 0 or false
while cnt > 0 do cnt -= 1 if cnt == 5 then break end end
repeat
    local done = cnt <= 0
until done
do local inner = 1; print(inner) end
print "hello"
print [[long]]
print { 1, 2 }
Players.PlayerAdded:Connect(function(player)
    print(player.Name, s1, s2, n, esc, e, x, y, z, ok)
    player:LoadCharacter()
    local function nested()
        return function(...) return ... end
    end
    nested()(1, 2)
end)
local greeting = M.new("a"):greet"hey"
local obj = M.new{1}
local continue = 5  -- 'continue' is not reserved in Luau
continue = continue + 1
task.wait(1)
print(greeting, obj, Vector3.new(1, 2, 3), Enum.KeyCode.E, workspace.CurrentCamera)
return M
'''


class GoodCode(unittest.TestCase):
    def test_good_snippet_is_clean(self):
        self.assertEqual(issues(GOOD), [])

    def test_empty_and_shebang(self):
        self.assertEqual(issues(""), [])
        self.assertEqual(issues("#!/usr/bin/lua\nprint(1)\n"), [])
        self.assertEqual(issues("﻿print(1)\r\nprint(2)\r\n"), [])

    def test_return_forms(self):
        self.assertEqual(issues("return"), [])
        self.assertEqual(issues("return;"), [])
        self.assertEqual(issues("do return end print(1)"), [])
        self.assertEqual(issues("local function f() return 1, 2 end return f()"), [])


class Precedence(unittest.TestCase):
    def ret(self, expr):
        return lc.parse("local a, b, c, x\nreturn " + expr).body[1].exprs[0]

    def test_pow_right_assoc(self):
        e = self.ret("2 ^ 3 ^ 2")
        self.assertEqual((e.op, e.left.kind, e.right.kind, e.right.op), ("^", "Number", "Binop", "^"))

    def test_concat_right_assoc(self):
        e = self.ret("a .. b .. c")
        self.assertEqual((e.op, e.left.kind, e.right.op), ("..", "Name", ".."))

    def test_unary_minus_vs_pow(self):
        e = self.ret("-x ^ 2")
        self.assertEqual((e.kind, e.op, e.operand.op), ("Unop", "-", "^"))

    def test_not_binds_tighter_than_eq(self):
        e = self.ret("not a == b")
        self.assertEqual((e.op, e.left.kind, e.left.op), ("==", "Unop", "not"))

    def test_arith(self):
        e = self.ret("1 + 2 * 3")
        self.assertEqual((e.op, e.right.op), ("+", "*"))
        e = self.ret("1 - 2 - 3")
        self.assertEqual((e.op, e.left.op), ("-", "-"))
        e = self.ret("7 // 2 * 3")
        self.assertEqual((e.op, e.left.op), ("*", "//"))
        e = self.ret("a or b and c")
        self.assertEqual((e.op, e.right.op), ("or", "and"))
        e = self.ret("a .. b == c")
        self.assertEqual((e.op, e.left.op), ("==", ".."))

    def test_if_expression_node(self):
        e = self.ret("if a then b elseif c then x else 1")
        self.assertEqual((e.kind, len(e.branches), e.else_value.kind), ("IfExpr", 2, "Number"))


class Tokenizer(unittest.TestCase):
    def types(self, src):
        return [t.type for t in lc.tokenize(src)]

    def test_numbers(self):
        for num in ("0xFF", "1e-3", ".5", "1_000", "0b1010", "3.14", "1E+10", "0x7f_ff", "5."):
            toks = lc.tokenize(num)
            self.assertEqual((toks[0].type, toks[0].raw), ("<number>", num), num)

    def test_compound_and_floor_div(self):
        self.assertEqual(self.types("a //= b // c ..= d"),
                         ["<name>", "//=", "<name>", "//", "<name>", "..=", "<name>", "<eof>"])

    def test_interpolation_tokens(self):
        self.assertEqual(self.types("`a {b} c {d + {1}} e`"),
                         ["<interp_begin>", "<name>", "<interp_mid>", "<name>", "+", "{",
                          "<number>", "}", "<interp_end>", "<eof>"])

    def test_long_string_levels(self):
        toks = lc.tokenize("x = [==[ a ]] b ]=] c ]==] y")
        self.assertEqual(toks[2].type, "<string>")
        self.assertEqual(toks[2].value, " a ]] b ]=] c ")
        self.assertEqual(toks[3].raw, "y")

    def test_line_numbers_after_multiline_tokens(self):
        toks = lc.tokenize("--[[ a\nb\nc ]]\nlocal s = [[\nx\ny]]\nfoo")
        self.assertEqual((toks[-2].raw, toks[-2].line, toks[-2].col), ("foo", 7, 1))


class SyntaxErrors(unittest.TestCase):
    def assertError(self, src, fragment, line=None):
        errs = errors(src)
        self.assertEqual(len(errs), 1, f"expected exactly one error, got {issues(src)}")
        self.assertIn(fragment, errs[0][3])
        if line is not None:
            self.assertEqual(errs[0][0], line, errs[0])
        return errs[0]

    def test_missing_end(self):
        self.assertError("""
            local function f()
                if x then
                    print(1)
                end

            local y = 2
        """, "expected 'end' to close 'function' at line 1 near <eof>")

    def test_else_without_if(self):
        self.assertError("""
            function foo()
              if a then
                b()
              end
              else
            end
        """, "expected 'end' to close 'function' at line 1 near 'else'", line=5)

    def test_missing_then(self):
        self.assertError("if x == 1\n    print(x)\nend\n", "expected 'then' after 'if' condition", line=2)

    def test_missing_do(self):
        self.assertError("for i = 1, 3\n  print(i)\nend", "expected 'do'", line=2)

    def test_unbalanced_parens(self):
        self.assertError("print((1 + 2)\nlocal a = 1\n", "expected ')' to close '(' at line 1 near 'local'", line=2)
        self.assertError("print(1))", "unexpected symbol near ')'", line=1)

    def test_bad_tables(self):
        self.assertError("local t = {a = 1 b = 2}", "expected ',' or '}' to close '{' at line 1 near 'b'")
        self.assertError("local t = {[1] 2}", "expected '='")
        self.assertError("local t = {1, 2,\nprint(t)", "expected ',' or '}' to close '{' at line 1", line=2)
        self.assertError("local t = {= 1}", "unexpected symbol near '='")

    def test_return_not_last(self):
        self.assertError("local function f()\n    return 1\n    print(2)\nend\n",
                         "'return' must be the last statement in a block", line=3)

    def test_break_continue_rules(self):
        self.assertError("while true do\n break\n print(1)\nend", "'break' must be the last statement", line=3)
        self.assertError("local x = 1\nbreak\n", "'break' outside a loop", line=2)
        self.assertError("local x = 1\ncontinue\n", "'continue' outside a loop", line=2)
        self.assertError("for i=1,2 do local f = function() continue end end", "'continue' outside a loop")
        self.assertEqual(issues("for i=1,2 do local f = function() for j=1,2 do continue end end end"), [])

    def test_compound_assignment_errors(self):
        self.assertError("local f\nf() += 1", "cannot assign to a function call")
        self.assertError("local a\nlocal b = a += 1", "compound assignment '+=' can only be used as a statement")

    def test_if_expression_requires_else(self):
        self.assertError("local a\nlocal v = if a then 1\nprint(v)", "expected 'else' in if-expression")

    def test_typo_keyword(self):
        self.assertError("locl x = 1", "did you mean 'local'")
        self.assertError("x", "incomplete statement")

    def test_varargs_outside_vararg_function(self):
        self.assertError("local function f() return ... end", "cannot use '...' outside a vararg function")
        self.assertEqual(issues("local function f(a, ...) return a, ... end\nprint(...)"), [])

    def test_strings(self):
        self.assertError("local s = [==[ abc ]] \n\n", "unfinished long string starting at line 1", line=1)
        self.assertError("--[[ never closed\nprint(1)", "unfinished long comment", line=1)
        self.assertError('local s = "abc\nprint(s)', "unfinished string", line=1)
        self.assertError('local s = "\\x4g"', "invalid hexadecimal escape")
        self.assertError('local s = "\\u{110000}"', "invalid unicode escape")
        self.assertError('local s = "\\300"', "decimal escape sequence too large")
        self.assertError("local s = [=hello", "invalid long string delimiter")

    def test_numbers(self):
        self.assertError("local n = 3x", "malformed number near '3x'")
        self.assertError("local n = 0x", "malformed number")
        self.assertError("local n = 1..2", "malformed number")
        self.assertError("local n = 1e", "malformed number")

    def test_interpolated_strings(self):
        self.assertError("local s = `abc {1}", "unfinished interpolated string")
        self.assertError("local s = `a {{1}}`", "double braces")
        self.assertError("print`x`", "interpolated strings cannot be used as call arguments")
        self.assertError("local s = `a {1, 2}`", "expected '}' to close expression in interpolated string")

    def test_ambiguous_call(self):
        self.assertError("local f, g\nlocal a = f\n(g)()", "ambiguous syntax", line=3)

    def test_stray_end(self):
        self.assertError("print(1)\nend\n", "unexpected 'end'", line=2)

    def test_keyword_as_name(self):
        self.assertError("local end = 1", "expected identifier, got keyword 'end'")

    def test_bad_assignment_target(self):
        self.assertError("local a\n(a) = 1", "cannot assign to a parenthesized expression")

    def test_bad_character(self):
        self.assertError("local a = 1 ~ 2", "unexpected character '~'")

    def test_accurate_line_after_long_tokens(self):
        self.assertError("--[[ c\nc\nc ]]\nlocal s = [[\na\nb]]\nlocal = 5\n", "expected identifier", line=7)

    def test_only_first_error_reported(self):
        self.assertEqual(len(issues("if then\nlocal = \nend end end")), 1)


class Scope(unittest.TestCase):
    def msgs(self, src):
        return [(w[0], w[3]) for w in warnings(src)]

    def test_typo_undefined_global(self):
        src = """
            local Players = game:GetService("Players")
            Players.PlayerAdded:Connect(function(player)
                print(plaeyr.Name)
            end)
        """
        self.assertEqual(self.msgs(src), [(3, "undefined global 'plaeyr'")])
        self.assertEqual(warnings(src)[0][1], 11)  # column

    def test_service_is_not_global(self):
        self.assertEqual(self.msgs("TweenService:Create()"), [(1, "undefined global 'TweenService'")])

    def test_global_assignment(self):
        src = "count = 1\nprint(count)\ncount += 1\n"
        self.assertEqual(self.msgs(src), [(1, "assignment to undeclared global 'count'"),
                                          (3, "assignment to undeclared global 'count'")])
        self.assertEqual(self.msgs("function helper() end\nhelper()"),
                         [(1, "assignment to undeclared global 'helper'")])
        self.assertEqual(self.msgs("game = nil"), [(1, "assignment to built-in global 'game'")])

    def test_local_function_sees_itself(self):
        self.assertEqual(self.msgs("local function f(n) return f(n) end"), [])
        self.assertEqual(self.msgs("local g = function() return g end"), [(1, "undefined global 'g'")])
        self.assertEqual(self.msgs("local x = x"), [(1, "undefined global 'x'")])

    def test_method_self(self):
        self.assertEqual(self.msgs("local M = {}\nfunction M:foo() return self end"), [])
        self.assertEqual(self.msgs("local M = {}\nfunction M.bar() return self end"),
                         [(2, "undefined global 'self'")])
        self.assertEqual(self.msgs("local M = {a = {}}\nfunction M.a.b:c(x) return self, x end"), [])

    def test_loop_and_block_scopes(self):
        self.assertEqual(self.msgs("for i = 1, 3 do end\nprint(i)"), [(2, "undefined global 'i'")])
        self.assertEqual(self.msgs("for k, v in pairs({}) do print(k, v) end\nprint(v)"),
                         [(2, "undefined global 'v'")])
        self.assertEqual(self.msgs("local c = true\nif c then local q = 1 else print(q) end"),
                         [(2, "undefined global 'q'")])
        self.assertEqual(self.msgs("do local d = 1 end\nprint(d)"), [(2, "undefined global 'd'")])
        self.assertEqual(self.msgs("while true do local w = 1 end\nprint(w)"), [(2, "undefined global 'w'")])

    def test_repeat_until_sees_body_locals(self):
        self.assertEqual(self.msgs("repeat local done = true until done"), [])
        self.assertEqual(self.msgs("repeat local done = true until done\nprint(done)"),
                         [(2, "undefined global 'done'")])

    def test_nested_functions_upvalues(self):
        src = """
            local function outer(a, ...)
                local b = select("#", ...)
                local function mid(c)
                    return function(d)
                        return a + b + c + d
                    end
                end
                return mid
            end
            print(outer(1)(2)(3), e)
        """
        self.assertEqual(self.msgs(src), [(10, "undefined global 'e'")])

    def test_interpolation_reads_are_checked(self):
        self.assertEqual(self.msgs("local name = 'x'\nprint(`hi {name} {nmae}`)"),
                         [(2, "undefined global 'nmae'")])

    def test_deprecated_calls(self):
        src = "wait(1)\nspawn(function() end)\ndelay(1, print)\n"
        self.assertEqual([m for _, m in self.msgs(src)],
                         ["'wait' is deprecated; use 'task.wait' instead",
                          "'spawn' is deprecated; use 'task.spawn' instead",
                          "'delay' is deprecated; use 'task.delay' instead"])
        self.assertEqual(self.msgs("local wait = task.wait\nwait(1)"), [])
        self.assertEqual(self.msgs("task.wait(1) task.spawn(print) task.delay(1, print)"), [])

    def test_dot_instead_of_colon(self):
        self.assertEqual(self.msgs('local p = game.GetService("Players")'),
                         [(1, "'.GetService(...)' called with '.', did you mean ':GetService(...)'?")])
        self.assertEqual(len(self.msgs("game.Players.PlayerAdded.Connect(print)")), 1)
        self.assertEqual(self.msgs("local Signal = {}\nSignal.Connect(print)"), [])

    def test_duplicate_table_key(self):
        self.assertEqual(self.msgs('local t = {a = 1, ["a"] = 2}'),
                         [(1, "duplicate key 'a' in table constructor (first defined at line 1)")])

    def test_continue_as_identifier(self):
        self.assertEqual(self.msgs("local continue = 1\ncontinue += 1\nprint(continue)"), [])


class CommandLine(unittest.TestCase):
    def run_main(self, *args):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = lc.main(list(args))
        return code, buf.getvalue()

    def test_directory_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "sub"))
            with open(os.path.join(d, "ok.lua"), "w", encoding="utf-8") as fh:
                fh.write("-- Привет\nprint(undefinedThing)\n")
            with open(os.path.join(d, "notes.txt"), "w") as fh:
                fh.write("ignored")
            code, out = self.run_main(d)
            self.assertEqual(code, 0, out)
            self.assertIn("ok.lua:2:7: warning: undefined global 'undefinedThing'", out)
            self.assertIn("Checked 1 file(s): 0 error(s), 1 warning(s)", out)

            with open(os.path.join(d, "sub", "bad.lua"), "w", encoding="utf-8") as fh:
                fh.write("local function f()\n")
            code, out = self.run_main(d)
            self.assertEqual(code, 1, out)
            self.assertIn("bad.lua:2:1: error: expected 'end' to close 'function' at line 1 near <eof>", out)
            self.assertIn("Checked 2 file(s): 1 error(s), 1 warning(s)", out)

            code, out = self.run_main(os.path.join(d, "ok.lua"), "--globals", "undefinedThing")
            self.assertEqual((code, out.strip()), (0, "Checked 1 file(s): 0 error(s), 0 warning(s)"))


if __name__ == "__main__":
    sys.setrecursionlimit(20000)
    unittest.main()
