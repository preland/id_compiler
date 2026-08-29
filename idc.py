#!/usr/bin/env python3
"""idc -- compiler for the `id` language (transpiles to C, then invokes cc).

Usage:
    idc.py PATH [-o OUTPUT] [--emit-c FILE] [--keep-c] [--cc CC]
                [--tests] [--require-tests]

PATH is either a single .id file (handy for tutorials) or a project directory.
A project is a directory *tree*: every directory in it may hold at most 3
entries (counting .id files and subdirectories combined), and all .id files in
the tree are compiled together as one program -- so functions and exported
variables resolve across the whole project.
"""

import argparse
import difflib
import json
import math
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

ACTION_LIMIT = 3
FUNCS_PER_FILE_LIMIT = 3
NEST_LIMIT = 2  # how deeply blocks may nest; deeper code must become a function

# The complete list of `id` builtins, in the order they should be advertised to
# users -- kept in exactly one place so the "did you mean" hint and the
# "available builtins" listing (used when a call resolves to neither a
# defined function nor a builtin) can never drift from what the backends
# actually implement.
BUILTIN_NAMES = (
    "print", "input", "read_all", "len", "push", "pop", "to_int", "charat",
    "chr", "put", "flush", "getkey", "sleep_ms", "ticks",
    # systems builtins: a flat, bounds-checked byte store, and the four
    # operations where unsigned genuinely differs from signed. See
    # "The flat store" below.
    "alloc", "store_size",
    "peek8", "peek16", "peek32", "peek64",
    "poke8", "poke16", "poke32", "poke64",
    "udiv", "umod", "ult", "ushr",
    "str_of_mem", "mem_of_str",
)

# `word` is a 64-bit two's-complement machine word: the type of an address in
# the flat store, and of any integer wider than `int`. It exists because a
# language cannot describe a machine it has no word for -- see
# ../linux_id/docs/ID_EXTENSIONS.md for the full rationale. Arithmetic on it
# wraps rather than overflowing, which is what hardware does and what the code
# being modelled assumes.
BASE_TYPES = {"int", "float", "string", "void", "word"}
KEYWORDS = BASE_TYPES | {"if", "else", "while", "return", "export", "import"}

C_TYPES = {
    "int": "int",
    "float": "double",
    "string": "char*",
    "void": "void",
    "word": "long long",
    "int[]": "IdList*",
    "float[]": "IdList*",
    "string[]": "IdList*",
    "word[]": "IdList*",
}


def c_type(typ):
    """C type for an id type; any list type T[] is the generic IdList*."""
    if typ.endswith("[]"):
        return "IdList*"
    return C_TYPES[typ]


def box(code, typ):
    """Wrap a value of id type `typ` into a uniform list cell (long long)."""
    if typ == "int":
        return f"(long long)({code})"
    if typ == "word":
        # The cast is not redundant. List cells are filled through
        # id_list_lit's varargs and read back with va_arg(ap, long long), so an
        # `int`-typed expression stored into a word[] must be widened *here* --
        # default argument promotion only takes it to `int`, and reading those
        # 4 bytes as 8 yields garbage in the top half.
        return f"(long long)({code})"
    if typ == "float":
        return f"id_box_f({code})"
    return f"(long long)(intptr_t)({code})"   # string or any list (pointer)


def unbox(code, typ):
    """Read a list cell back as id type `typ`."""
    if typ == "int":
        return f"(int)({code})"
    if typ == "word":
        return f"(long long)({code})"
    if typ == "float":
        return f"id_unbox_f({code})"
    if typ == "string":
        return f"(char*)(intptr_t)({code})"
    return f"(IdList*)(intptr_t)({code})"     # any list type


class CompileError(Exception):
    def __init__(self, file, line, msg):
        super().__init__(f"{file}:{line}: error: {msg}")


def warn(file, line, msg):
    print(f"{file}:{line}: warning: {msg}", file=sys.stderr)


def builtin_hint(name) -> str:
    """' did you mean the builtin '<X>'?' if `name` is a close match to a
    known builtin, else ''. Shared by every diagnostic about a call to a
    name that isn't a defined function or a builtin."""
    matches = difflib.get_close_matches(name, BUILTIN_NAMES, n=1)
    return f" did you mean the builtin '{matches[0]}'?" if matches else ""


def no_such_function_msg(name) -> str:
    """The full diagnostic for a call to a name that resolves to neither a
    defined function nor a builtin: the "did you mean" hint (if any) plus
    the complete list of builtins, so users guessing at a name (e.g.
    `char_at` for `charat`) get pointed at the real one instead of a bare
    linker error further down the pipeline."""
    return (f"no such function '{name}';{builtin_hint(name)} "
            f"available builtins: {', '.join(BUILTIN_NAMES)}")


# ---------------------------------------------------------------- lexer

@dataclass
class Tok:
    kind: str   # 'int' | 'float' | 'string' | 'ident' | 'kw' | 'op' | 'eof'
    value: str
    file: str
    line: int


# `hex` and `bin` must precede `int`, or "0x1f" lexes as 0 followed by the
# identifier "x1f". `<<`/`>>`/`&&`/`||` must precede the single-character class
# for the same reason.
TOKEN_RE = re.compile(
    r"""(?P<ws>\s+)
      | (?P<comment>//[^\n]*)
      | (?P<blockcomment>/\*)
      | (?P<hex>0[xX][0-9a-fA-F]+)
      | (?P<bin>0[bB][01]+)
      | (?P<float>\d+\.\d+)
      | (?P<int>\d+)
      | (?P<string>"(?:\\.|[^"\\])*")
      | (?P<ident>[A-Za-z_]\w*)
      | (?P<op><<|>>|==|!=|<=|>=|&&|\|\||[+\-*/%<>=!&|^~(){}\[\],;:])
    """,
    re.VERBOSE,
)


def lex(src: str, fname: str) -> List[Tok]:
    toks = []
    pos = 0
    line = 1
    while pos < len(src):
        m = TOKEN_RE.match(src, pos)
        if not m:
            raise CompileError(fname, line, f"unexpected character {src[pos]!r}")
        text = m.group(0)
        kind = m.lastgroup
        if kind == "ws" or kind == "comment":
            pass
        elif kind == "blockcomment":
            # `id` has line comments and nothing else. Without this the `/`
            # and `*` lex as operators and the words inside the comment lex
            # as identifiers, so one comment became a page of diagnostics
            # about names nobody wrote.
            raise CompileError(fname, line,
                               "block comments are not supported; "
                               "use // for a line comment")
        elif kind == "hex":
            # Hex is a spelling, not a type: 0xff is the int token 255. The
            # rest of the compiler never has to know the literal was written
            # in hex, which is why mask constants can be written the way the
            # hardware documentation writes them.
            toks.append(Tok("int", str(int(text, 16)), fname, line))
        elif kind == "bin":
            # Same deal as hex: 0b1010 is the int token 10, so a bit pattern
            # can be written the way a register diagram draws it.
            toks.append(Tok("int", str(int(text, 2)), fname, line))
        elif kind == "ident":
            if text in KEYWORDS:
                toks.append(Tok("kw", text, fname, line))
            else:
                toks.append(Tok("ident", text, fname, line))
        else:
            toks.append(Tok(kind, text, fname, line))
        line += text.count("\n")
        pos = m.end()
    toks.append(Tok("eof", "", fname, line))
    return toks


# ---------------------------------------------------------------- AST

@dataclass
class Expr:
    file: str
    line: int


@dataclass
class IntLit(Expr):
    value: str


@dataclass
class FloatLit(Expr):
    value: str


@dataclass
class StrLit(Expr):
    raw: str  # includes quotes, escapes preserved


@dataclass
class VarRef(Expr):
    name: str


@dataclass
class ImportRef(Expr):
    name: str


@dataclass
class CallExpr(Expr):
    name: str
    args: List[Expr]


@dataclass
class IndexExpr(Expr):
    base: Expr
    index: Expr


@dataclass
class ArrayLit(Expr):
    elems: List[Expr]


@dataclass
class BinOp(Expr):
    op: str
    left: Expr
    right: Expr


@dataclass
class UnOp(Expr):
    op: str
    operand: Expr


@dataclass
class Stmt:
    file: str
    line: int


@dataclass
class DeclStmt(Stmt):
    typ: str
    name: str
    expr: Expr
    exported: bool


@dataclass
class AssignStmt(Stmt):
    name: str
    expr: Expr


@dataclass
class IndexAssignStmt(Stmt):
    base: Expr
    index: Expr
    expr: Expr


@dataclass
class IfStmt(Stmt):
    cond: Expr
    then: List[Stmt]
    els: Optional[object]  # List[Stmt] | IfStmt | None


@dataclass
class WhileStmt(Stmt):
    cond: Expr
    body: List[Stmt]


@dataclass
class ExprStmt(Stmt):
    expr: Expr


@dataclass
class TestCase:
    """One `(ARGS):(EXPECTED)[CONSTRAINTS]` line under a function. `expected`
    is a single value for a function that returns one, and the arguments as
    they must look *after* the call for a void function. See docs/TESTS.md."""
    args: List[Expr]
    expected: List[Expr]
    constraints: List[Tuple[str, str]]   # ('time'|'mem', 'O(n)')
    file: str
    line: int


@dataclass
class FuncDef:
    name: str
    params: List[Tuple[str, str]]  # (type, name)
    body: List[Stmt]
    rettype: str
    retexpr: Optional[Expr]
    file: str
    line: int
    cases: List[TestCase] = field(default_factory=list)


# The scaling claims a test case may carry. Anything else is rejected by name
# rather than silently ignored -- see docs/TESTS.md.
BIG_O = ("O(1)", "O(log n)", "O(n)", "O(n log n)", "O(n^2)")


def check_case_literal(e: Expr):
    """A case's arguments and expected value are literals, so the harness can
    build them without running any of the program. Anything else (a variable, a
    call, arithmetic) is rejected here rather than at codegen, where the
    diagnostic would be about a name that isn't in scope."""
    if isinstance(e, (IntLit, FloatLit, StrLit)):
        return
    if isinstance(e, UnOp) and e.op == "-" and isinstance(e.operand, (IntLit, FloatLit)):
        return
    if isinstance(e, ArrayLit):
        for el in e.elems:
            check_case_literal(el)
        return
    raise CompileError(e.file, e.line,
                       "a test case takes literals only (a number, a string, or "
                       "a list of those)")


def literal_text(e: Expr) -> str:
    """A case literal written back out the way it was written, for diagnostics."""
    if isinstance(e, (IntLit, FloatLit)):
        return e.value
    if isinstance(e, StrLit):
        return e.raw
    if isinstance(e, UnOp):
        return "-" + literal_text(e.operand)
    return "[" + ", ".join(literal_text(x) for x in e.elems) + "]"


def c_string(s: str) -> str:
    """`s` as a C string literal. Used for the harness's own messages, which
    quote id source text verbatim."""
    body = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{body}"'


def literal_size(e: Expr) -> int:
    """The `n` a case's argument contributes: the length of a list or string,
    or the value of an integer. A float has no size and contributes none."""
    if isinstance(e, ArrayLit):
        return len(e.elems)
    if isinstance(e, StrLit):
        return len(unescape_id_string(e.raw))
    if isinstance(e, IntLit):
        return int(e.value)
    if isinstance(e, UnOp) and isinstance(e.operand, IntLit):
        return -int(e.operand.value)
    return 0


# ---------------------------------------------------------------- parser

class Parser:
    def __init__(self, toks: List[Tok]):
        self.toks = toks
        self.pos = 0

    def peek(self, off=0) -> Tok:
        return self.toks[min(self.pos + off, len(self.toks) - 1)]

    def next(self) -> Tok:
        t = self.toks[self.pos]
        if t.kind != "eof":
            self.pos += 1
        return t

    def at(self, kind, value=None) -> bool:
        t = self.peek()
        return t.kind == kind and (value is None or t.value == value)

    # Human phrases for token *kinds*, used when a KIND (not a specific
    # literal value) was expected -- newcomers can't decode raw kind names
    # like 'kw' or 'op'.
    KIND_PHRASES = {
        "kw": "a keyword",
        "ident": "an identifier (a name)",
        "op": "an operator",
        "int": "an integer literal",
        "float": "a float literal",
        "string": "a string literal",
        "eof": "end of input",
    }

    def expect(self, kind, value=None, what=None) -> Tok:
        t = self.peek()
        if not self.at(kind, value):
            if value is not None:
                want = f"'{value}'"
            else:
                want = what if what is not None else self.KIND_PHRASES.get(kind, kind)
            raise CompileError(t.file, t.line, f"expected {want}, found '{t.value or t.kind}'")
        return self.next()

    def accept(self, kind, value=None) -> bool:
        if self.at(kind, value):
            self.next()
            return True
        return False

    # -- types

    def at_type(self) -> bool:
        return self.peek().kind == "kw" and self.peek().value in BASE_TYPES

    def parse_type(self) -> str:
        t = self.expect("kw", what="a type (int, string, void, or a T[] array type)")
        if t.value not in BASE_TYPES:
            raise CompileError(t.file, t.line,
                                f"expected a type (int, string, void, or a T[] array type), found '{t.value}'")
        typ = t.value
        while self.accept("op", "["):
            self.expect("op", "]")
            if typ == "void":
                raise CompileError(t.file, t.line, "'void[]' is not a valid type")
            typ += "[]"
        return typ

    # -- top level

    def parse_file(self) -> List[FuncDef]:
        funcs = []
        while not self.at("eof"):
            funcs.append(self.parse_function())
        return funcs

    def parse_function(self) -> FuncDef:
        name_tok = self.expect("ident")
        self.expect("op", "(")
        params = []
        if not self.at("op", ")"):
            while True:
                ptype = self.parse_type()
                pname = self.expect("ident")
                params.append((ptype, pname.value))
                if not self.accept("op", ","):
                    break
        self.expect("op", ")")
        body = self.parse_block()
        # the return clause lives *after* the closing brace
        rt = self.expect("kw", "return")
        if self.at("kw", "void") and not (self.peek(1).kind == "op" and self.peek(1).value == "["):
            self.next()
            rettype, retexpr = "void", None
        else:
            rettype = self.parse_type()
            retexpr = self.parse_expr()
        self.accept("op", ";")
        # Test cases follow the return clause, one per line. There is no
        # ambiguity with the next function: a function starts `ident (`, a
        # case starts `(`.
        cases = []
        while self.at("op", "("):
            cases.append(self.parse_case())
        return FuncDef(name_tok.value, params, body, rettype, retexpr,
                       name_tok.file, name_tok.line, cases)

    # -- test cases: (ARGS):(EXPECTED)[CONSTRAINTS]

    def parse_case(self) -> TestCase:
        t = self.peek()
        args = self.parse_case_tuple()
        self.expect("op", ":",
                    what="':' between a case's arguments and its expected value")
        expected = self.parse_case_tuple()
        constraints = self.parse_constraints() if self.at("op", "[") else []
        return TestCase(args, expected, constraints, t.file, t.line)

    def parse_case_tuple(self) -> List[Expr]:
        self.expect("op", "(")
        items = []
        if not self.at("op", ")"):
            while True:
                items.append(self.parse_expr())
                if not self.accept("op", ","):
                    break
        self.expect("op", ")")
        for e in items:
            check_case_literal(e)
        return items

    def parse_constraints(self) -> List[Tuple[str, str]]:
        self.expect("op", "[")
        out = []
        while True:
            k = self.expect("ident", what="'time' or 'mem'")
            if k.value not in ("time", "mem"):
                raise CompileError(k.file, k.line,
                                   f"unknown constraint '{k.value}'; a case "
                                   f"constrains 'time' or 'mem'")
            self.expect("op", ":")
            out.append((k.value, self.parse_big_o()))
            if not self.accept("op", ","):
                break
        self.expect("op", "]")
        return out

    def parse_big_o(self) -> str:
        o = self.expect("ident", what="a bound, e.g. O(n)")
        self.expect("op", "(")
        parts = []
        while not self.at("op", ")"):
            if self.at("eof"):
                t = self.peek()
                raise CompileError(t.file, t.line, "unterminated constraint bound")
            parts.append(self.next().value)
        self.expect("op", ")")
        text = f"{o.value}(" + " ".join(parts).replace(" ^ ", "^") + ")"
        if text not in BIG_O:
            raise CompileError(o.file, o.line,
                               f"unknown bound '{text}'; the bounds a case may "
                               f"claim are {', '.join(BIG_O)}")
        return text

    def parse_block(self) -> List[Stmt]:
        self.expect("op", "{")
        stmts = []
        while not self.at("op", "}"):
            stmts.append(self.parse_stmt())
        self.expect("op", "}")
        return stmts

    # -- statements

    def parse_stmt(self) -> Stmt:
        t = self.peek()
        if self.at("kw", "if"):
            return self.parse_if()
        if self.at("kw", "while"):
            self.next()
            self.expect("op", "(")
            cond = self.parse_expr()
            self.expect("op", ")")
            body = self.parse_block()
            return WhileStmt(t.file, t.line, cond, body)
        if self.at("kw", "export"):
            self.next()
            typ = self.parse_type()
            name = self.expect("ident")
            self.expect("op", "=")
            expr = self.parse_expr()
            self.accept("op", ";")
            return DeclStmt(t.file, t.line, typ, name.value, expr, True)
        if self.at_type():
            typ = self.parse_type()
            name = self.expect("ident")
            self.expect("op", "=")
            expr = self.parse_expr()
            self.accept("op", ";")
            return DeclStmt(t.file, t.line, typ, name.value, expr, False)
        if self.at("ident") and self.peek(1).kind == "op" and self.peek(1).value == "=":
            name = self.next()
            self.next()  # '='
            expr = self.parse_expr()
            self.accept("op", ";")
            return AssignStmt(t.file, t.line, name.value, expr)
        if self.at("ident") and self.peek(1).kind == "op" and self.peek(1).value == "[":
            target = self.parse_postfix()   # a list element: xs[i] (or xs[i][j])
            self.expect("op", "=")
            expr = self.parse_expr()
            self.accept("op", ";")
            if isinstance(target, IndexExpr):
                return IndexAssignStmt(t.file, t.line, target.base, target.index, expr)
            raise CompileError(t.file, t.line,
                               "can only assign to a variable or a list element")
        if self.at("kw", "return"):
            raise CompileError(t.file, t.line,
                               "'return' belongs after the function's closing brace")
        expr = self.parse_expr()
        self.accept("op", ";")
        return ExprStmt(t.file, t.line, expr)

    def parse_if(self) -> IfStmt:
        t = self.expect("kw", "if")
        self.expect("op", "(")
        cond = self.parse_expr()
        self.expect("op", ")")
        then = self.parse_block()
        els = None
        if self.accept("kw", "else"):
            if self.at("kw", "if"):
                els = self.parse_if()
            else:
                els = self.parse_block()
        return IfStmt(t.file, t.line, cond, then, els)

    # -- expressions (precedence climbing)
    # NOTE: a bare '=' inside an expression is equality comparison; assignment
    # is only a statement form, so there is no ambiguity.

    def parse_expr(self) -> Expr:
        return self.parse_or()

    def parse_or(self) -> Expr:
        e = self.parse_and()
        while self.at("op", "||"):
            t = self.next()
            e = BinOp(t.file, t.line, "||", e, self.parse_and())
        return e

    def parse_and(self) -> Expr:
        e = self.parse_equality()
        while self.at("op", "&&"):
            t = self.next()
            e = BinOp(t.file, t.line, "&&", e, self.parse_equality())
        return e

    def parse_equality(self) -> Expr:
        e = self.parse_relational()
        while self.at("op", "==") or self.at("op", "!=") or self.at("op", "="):
            t = self.next()
            op = "==" if t.value == "=" else t.value
            e = BinOp(t.file, t.line, op, e, self.parse_relational())
        return e

    def parse_relational(self) -> Expr:
        e = self.parse_bitor()
        while self.peek().kind == "op" and self.peek().value in ("<", ">", "<=", ">="):
            t = self.next()
            e = BinOp(t.file, t.line, t.value, e, self.parse_bitor())
        return e

    # The bitwise operators sit *below* the comparisons, so `flags & MASK != 0`
    # means `(flags & MASK) != 0` -- what anyone reading it expects. C famously
    # binds them the other way round, which is a historical accident that has
    # been generating parenthesis bugs since 1972; `id` does not inherit it.
    # Among themselves the levels follow C: | then ^ then & then shifts.

    def parse_bitor(self) -> Expr:
        e = self.parse_bitxor()
        while self.at("op", "|"):
            t = self.next()
            e = BinOp(t.file, t.line, "|", e, self.parse_bitxor())
        return e

    def parse_bitxor(self) -> Expr:
        e = self.parse_bitand()
        while self.at("op", "^"):
            t = self.next()
            e = BinOp(t.file, t.line, "^", e, self.parse_bitand())
        return e

    def parse_bitand(self) -> Expr:
        e = self.parse_shift()
        while self.at("op", "&"):
            t = self.next()
            e = BinOp(t.file, t.line, "&", e, self.parse_shift())
        return e

    def parse_shift(self) -> Expr:
        e = self.parse_additive()
        while self.peek().kind == "op" and self.peek().value in ("<<", ">>"):
            t = self.next()
            e = BinOp(t.file, t.line, t.value, e, self.parse_additive())
        return e

    def parse_additive(self) -> Expr:
        e = self.parse_multiplicative()
        while self.peek().kind == "op" and self.peek().value in ("+", "-"):
            t = self.next()
            e = BinOp(t.file, t.line, t.value, e, self.parse_multiplicative())
        return e

    def parse_multiplicative(self) -> Expr:
        e = self.parse_unary()
        while self.peek().kind == "op" and self.peek().value in ("*", "/", "%"):
            t = self.next()
            e = BinOp(t.file, t.line, t.value, e, self.parse_unary())
        return e

    def parse_unary(self) -> Expr:
        t = self.peek()
        if self.at("op", "-") or self.at("op", "!") or self.at("op", "~"):
            self.next()
            return UnOp(t.file, t.line, t.value, self.parse_unary())
        return self.parse_postfix()

    def parse_postfix(self) -> Expr:
        e = self.parse_primary()
        while True:
            if self.at("op", "["):
                t = self.next()
                idx = self.parse_expr()
                self.expect("op", "]")
                e = IndexExpr(t.file, t.line, e, idx)
            else:
                return e

    def parse_primary(self) -> Expr:
        t = self.peek()
        if self.at("int"):
            self.next()
            return IntLit(t.file, t.line, t.value)
        if self.at("float"):
            self.next()
            return FloatLit(t.file, t.line, t.value)
        if self.at("string"):
            self.next()
            return StrLit(t.file, t.line, t.value)
        if self.at("kw", "import"):
            self.next()
            name = self.expect("ident")
            return ImportRef(t.file, t.line, name.value)
        if self.at("op", "("):
            self.next()
            e = self.parse_expr()
            self.expect("op", ")")
            return e
        if self.at("op", "["):
            self.next()
            elems = []
            if not self.at("op", "]"):
                while True:
                    elems.append(self.parse_expr())
                    if not self.accept("op", ","):
                        break
            self.expect("op", "]")
            return ArrayLit(t.file, t.line, elems)
        if self.at("ident"):
            name = self.next()
            if self.accept("op", "("):
                args = []
                if not self.at("op", ")"):
                    while True:
                        args.append(self.parse_expr())
                        if not self.accept("op", ","):
                            break
                self.expect("op", ")")
                return CallExpr(t.file, t.line, name.value, args)
            return VarRef(t.file, t.line, name.value)
        raise CompileError(t.file, t.line, f"unexpected token '{t.value or t.kind}'")


# ---------------------------------------------------------------- semantics + codegen

RUNTIME = r"""/* generated by idc -- the `id` language compiler */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <limits.h>
#include <termios.h>
#include <unistd.h>
#include <time.h>

/* ---- allocation arena -----------------------------------------------------
   Every heap block the runtime allocates (list headers/cells, and the C
   strings built by concat/str_of_int/str_of_float/input/read_all/chr) is
   wrapped with a small intrusive header and linked into one list, so the
   whole arena can be released in a single pass at process exit (the free-all
   is registered with atexit on the first allocation). id programs never call
   free() themselves, so without this a long-running program (e.g. string
   concatenation in a loop) would leak every intermediate string forever;
   with it, nothing outlives the process. This bounds *leaks*, not *peak*
   memory during the run -- a program that builds one huge string still holds
   every intermediate allocation live until exit, same as before this change.
   Every allocation in this file goes through id_alloc/id_realloc below, which
   also check for allocation failure and for size-computation overflow,
   aborting with a clear message instead of continuing with a NULL pointer or
   a wrapped-around size. */
typedef struct IdAllocHdr { struct IdAllocHdr* prev; struct IdAllocHdr* next; } IdAllocHdr;
static IdAllocHdr* id_arena_head = NULL;
static int id_arena_hooked = 0;
static void id_arena_free_all(void) {
    IdAllocHdr* h = id_arena_head;
    while (h) { IdAllocHdr* nx = h->next; free(h); h = nx; }
    id_arena_head = NULL;
}
static void id_arena_link(IdAllocHdr* h) {
    h->prev = NULL;
    h->next = id_arena_head;
    if (id_arena_head) id_arena_head->prev = h;
    id_arena_head = h;
    if (!id_arena_hooked) { atexit(id_arena_free_all); id_arena_hooked = 1; }
}
static void id_arena_unlink(IdAllocHdr* h) {
    if (h->prev) h->prev->next = h->next; else id_arena_head = h->next;
    if (h->next) h->next->prev = h->prev;
}
static size_t id_add_check(size_t a, size_t b, const char* what) {
    if (a > SIZE_MAX - b) {
        fprintf(stderr, "id: allocation size overflow (%s)\n", what);
        exit(1);
    }
    return a + b;
}
static size_t id_mul_check(size_t a, size_t b, const char* what) {
    if (a != 0 && b > SIZE_MAX / a) {
        fprintf(stderr, "id: allocation size overflow (%s)\n", what);
        exit(1);
    }
    return a * b;
}
/* String lengths, remembered.
   A `string` is a NUL-terminated char*, so its length is a strlen -- and every
   id program walks text with charat, which needs the length to know where the
   end is. One remembered length made a single scan O(n) instead of O(n^2). It
   did not make *two* scans O(n): a parser that reads its input and builds a
   string alternates between two pointers, misses the memo on every call, and
   pays a strlen of the whole input per character. Measured on an OpenDocument
   content.xml, that was 46.8 seconds for 3.5 MB.
   So the memo holds several. ID_LEN_MEMO is the number of strings that may be
   walked at once before the cost comes back; eight covers a parser reading one
   input while building a name and comparing against a keyword, with room over.
   Raising it costs one pointer comparison per miss.
   The real answer is a string that carries its own length, which would remove
   the question rather than bound it -- and which means changing how a literal
   is emitted, so it is a decision about the language rather than about this
   file. See docs/FRICTION.md. */
#define ID_LEN_MEMO 8
static const char* id_lm_s[ID_LEN_MEMO];
static size_t id_lm_n[ID_LEN_MEMO];
static unsigned id_lm_at = 0;
static size_t id_slen(const char* s) {
    unsigned i;
    for (i = 0; i < ID_LEN_MEMO; i++) if (id_lm_s[i] == s) return id_lm_n[i];
    i = id_lm_at;
    id_lm_at = (id_lm_at + 1) % ID_LEN_MEMO;
    id_lm_s[i] = s;
    id_lm_n[i] = strlen(s);
    return id_lm_n[i];
}
/* A block that moved may be reused by a later string at the same address, so
   every remembered length has to go with it. Only when it actually moved: a
   realloc that grows in place invalidates nothing. */
static void id_lm_forget(void) {
    unsigned i;
    for (i = 0; i < ID_LEN_MEMO; i++) id_lm_s[i] = NULL;
}
static void* id_alloc(size_t n) {
    IdAllocHdr* h = (IdAllocHdr*)malloc(id_add_check(n, sizeof(IdAllocHdr), "alloc"));
    if (!h) { fprintf(stderr, "id: out of memory (%zu bytes)\n", n); exit(1); }
    id_arena_link(h);
    return (void*)(h + 1);
}
static void* id_realloc(void* p, size_t n) {
    if (!p) return id_alloc(n);
    IdAllocHdr* h = (IdAllocHdr*)p - 1;
    id_arena_unlink(h);
    IdAllocHdr* nh = (IdAllocHdr*)realloc(h, id_add_check(n, sizeof(IdAllocHdr), "realloc"));
    if (!nh) { fprintf(stderr, "id: out of memory (%zu bytes)\n", n); exit(1); }
    if (nh != h) id_lm_forget();
    id_arena_link(nh);
    return (void*)(nh + 1);
}

/* Growable, heap-allocated, reference-semantic list. Every element is stored
   in a uniform 8-byte cell; the compiler boxes/unboxes per the static element
   type. Because a list is a pointer, passing one to a function and mutating it
   is visible to the caller -- this is how id gets shared mutable state.
   Every index access is bounds-checked: an out-of-range get/set/pop is a
   clear, fatal runtime error (never silent corruption or UB), matching id's
   contract that a bug aborts loudly instead of reading/writing garbage. */
typedef struct { int len, cap; long long* data; } IdList;
static IdList* id_list_new(void) {
    IdList* L = (IdList*)id_alloc(sizeof(IdList));
    L->len = 0; L->cap = 4;
    L->data = (long long*)id_alloc(id_mul_check(sizeof(long long), (size_t)L->cap, "list init"));
    return L;
}
static void id_list_push(IdList* L, long long v) {
    if (L->len >= L->cap) {
        if (L->cap > INT_MAX / 2) {
            fprintf(stderr, "id: list capacity overflow\n");
            exit(1);
        }
        int ncap = L->cap * 2;
        L->data = (long long*)id_realloc(L->data,
            id_mul_check(sizeof(long long), (size_t)ncap, "list growth"));
        L->cap = ncap;
    }
    L->data[L->len++] = v;
}
static long long id_list_get(IdList* L, int i) {
    if (i < 0 || i >= L->len) {
        fprintf(stderr, "id: index %d out of bounds (len %d)\n", i, L->len);
        exit(1);
    }
    return L->data[i];
}
static void id_list_set(IdList* L, int i, long long v) {
    if (i < 0 || i >= L->len) {
        fprintf(stderr, "id: index %d out of bounds (len %d)\n", i, L->len);
        exit(1);
    }
    L->data[i] = v;
}
static int id_list_len(IdList* L) { return L->len; }
static long long id_list_pop(IdList* L) {   /* remove & return the last cell */
    if (L->len <= 0) {
        fprintf(stderr, "id: pop from empty list\n");
        exit(1);
    }
    return L->data[--L->len];
}
static IdList* id_list_lit(int n, ...) {   /* elements are pre-boxed to cells */
    IdList* L = id_list_new();
    va_list ap; va_start(ap, n);
    for (int k = 0; k < n; k++) id_list_push(L, va_arg(ap, long long));
    va_end(ap);
    return L;
}
static long long id_box_f(double d) { long long x; memcpy(&x, &d, 8); return x; }
static double id_unbox_f(long long x) { double d; memcpy(&d, &x, 8); return d; }
static int id_to_int(const char* s) { return atoi(s); }

static char* id_concat(const char* a, const char* b) {
    size_t la = strlen(a), lb = strlen(b);
    size_t n = id_add_check(id_add_check(la, lb, "concat"), 1, "concat");
    char* r = (char*)id_alloc(n);
    memcpy(r, a, la);
    memcpy(r + la, b, lb + 1);
    return r;
}
static char* id_str_of_int(int x) {
    char* r = (char*)id_alloc(32); snprintf(r, 32, "%d", x); return r;
}
static char* id_str_of_word(long long x) {
    char* r = (char*)id_alloc(32); snprintf(r, 32, "%lld", x); return r;
}

/* ---- word arithmetic with no undefined behaviour ------------------------
   C leaves division by zero, INT_MIN/-1, and shifts by 64-or-more undefined.
   id gives all three a defined answer -- a loud abort for the first two,
   which are always bugs, and the obvious result for the third -- on the same
   principle as bounds-checked list indexing: a mistake stops the program
   instead of quietly producing nonsense. */
static void id_trap(const char* what) {
    fprintf(stderr, "id: %s\n", what);
    exit(1);
}
static long long id_sdiv(long long a, long long b) {
    if (b == 0) id_trap("division by zero");
    if (b == -1 && a == LLONG_MIN) id_trap("division overflow");
    return a / b;
}
static long long id_smod(long long a, long long b) {
    if (b == 0) id_trap("remainder by zero");
    if (b == -1) return 0;              /* would overflow; the answer is 0 */
    return a % b;
}
/* The same two checks for `int`. They used to be word-only, on the grounds
   that trapping was a new behaviour and `int` division should stay exactly as
   it was -- but "exactly as it was" meant a SIGFPE and a core dump with no
   message, while the identical mistake on a `word` printed one line and
   exited 1. Two spellings of one bug do not deserve two failure modes, and
   gcc folds the check away whenever the divisor is a nonzero constant. */
static int id_idiv(int a, int b) {
    if (b == 0) id_trap("division by zero");
    if (b == -1 && a == INT_MIN) id_trap("division overflow");
    return a / b;
}
static int id_imod(int a, int b) {
    if (b == 0) id_trap("remainder by zero");
    if (b == -1) return 0;              /* would overflow; the answer is 0 */
    return a % b;
}
static long long id_shl(long long a, long long n) {
    if (n < 0) id_trap("shift by a negative amount");
    if (n >= 64) return 0;
    return (long long)((unsigned long long)a << n);
}
static long long id_sar(long long a, long long n) {   /* arithmetic: `>>` */
    if (n < 0) id_trap("shift by a negative amount");
    if (n >= 64) return a < 0 ? -1 : 0;
    return a >> n;
}
static long long id_ushr(long long a, long long n) {  /* logical: `ushr` */
    if (n < 0) id_trap("shift by a negative amount");
    if (n >= 64) return 0;
    return (long long)((unsigned long long)a >> n);
}
static long long id_udiv(long long a, long long b) {
    if (b == 0) id_trap("division by zero");
    return (long long)((unsigned long long)a / (unsigned long long)b);
}
static long long id_umod(long long a, long long b) {
    if (b == 0) id_trap("remainder by zero");
    return (long long)((unsigned long long)a % (unsigned long long)b);
}
static long long id_ult(long long a, long long b) {
    return (unsigned long long)a < (unsigned long long)b;
}

/* ---- the flat store -----------------------------------------------------
   One flat, byte-addressed memory. An address is an ordinary word, so
   structs become offsets, arrays become strides, and taking the address of
   something is arithmetic -- none of which the language needs syntax for.

   Address 0 is never handed out, so it can mean "null" the way it does
   everywhere else. Every access is bounds-checked against the high-water
   mark: the class of mistake that silently corrupts memory in C is a clean
   abort here, which is the entire reason the store is a primitive rather
   than a library. The store grows on demand and is freed at exit with the
   rest of the arena. */
static unsigned char* id_store = NULL;
static long long id_store_used = 1;    /* 0 is reserved for null */
static long long id_store_cap = 0;

static void id_store_grow(long long need) {
    long long cap = id_store_cap ? id_store_cap : 65536;
    while (cap < need) {
        if (cap > (long long)1 << 44) id_trap("store too large");
        cap *= 2;
    }
    id_store = (unsigned char*)id_realloc(id_store, (size_t)cap);
    memset(id_store + id_store_cap, 0, (size_t)(cap - id_store_cap));
    id_store_cap = cap;
}
static long long id_mem_alloc(long long n) {
    if (n < 0) id_trap("negative allocation size");
    /* 8-align every allocation so a 64-bit field is never split awkwardly */
    long long base = (id_store_used + 7) & ~(long long)7;
    long long end = base + n;
    if (end < base) id_trap("allocation size overflow");
    if (end > id_store_cap) id_store_grow(end);
    id_store_used = end;
    return base;
}
static long long id_mem_size(void) { return id_store_used; }

/* Every load and store funnels through this one check. */
static unsigned char* id_at(long long addr, long long width) {
    if (addr <= 0 || addr + width > id_store_used) {
        fprintf(stderr, "id: store address %lld out of range (size %lld)\n",
                addr, id_store_used);
        exit(1);
    }
    return id_store + addr;
}
/* Little-endian, byte at a time: the same bytes on every host, and no
   alignment requirement -- C code casts pointers to odd addresses freely. */
static long long id_peek_n(long long addr, int width) {
    unsigned char* p = id_at(addr, width);
    unsigned long long v = 0;
    for (int i = width - 1; i >= 0; i--) v = (v << 8) | p[i];
    return (long long)v;
}
static void id_poke_n(long long addr, long long value, int width) {
    unsigned char* p = id_at(addr, width);
    unsigned long long v = (unsigned long long)value;
    for (int i = 0; i < width; i++) { p[i] = (unsigned char)(v & 0xff); v >>= 8; }
}
static long long id_peek8(long long a)  { return id_peek_n(a, 1); }
static long long id_peek16(long long a) { return id_peek_n(a, 2); }
static long long id_peek32(long long a) { return id_peek_n(a, 4); }
static long long id_peek64(long long a) { return id_peek_n(a, 8); }
static void id_poke8(long long a, long long v)  { id_poke_n(a, v, 1); }
static void id_poke16(long long a, long long v) { id_poke_n(a, v, 2); }
static void id_poke32(long long a, long long v) { id_poke_n(a, v, 4); }
static void id_poke64(long long a, long long v) { id_poke_n(a, v, 8); }

/* Bridges between the store and id's own strings, so a program working in
   the store can still print. */
static char* id_str_of_mem(long long addr, long long n) {
    if (n < 0) id_trap("negative length");
    unsigned char* p = id_at(addr, n);
    char* r = (char*)id_alloc((size_t)n + 1);
    memcpy(r, p, (size_t)n);
    r[n] = '\0';
    return r;
}
static long long id_mem_of_str(const char* s) {
    size_t n = strlen(s);
    long long a = id_mem_alloc((long long)n + 1);
    memcpy(id_store + a, s, n + 1);
    return a;
}
static char* id_str_of_float(double x) {
    char* r = (char*)id_alloc(64); snprintf(r, 64, "%g", x); return r;
}
static void id_print(const char* s) { puts(s); }
static char* id_input(void) {
    /* read one line from stdin, drop the trailing newline; "" on EOF */
    char buf[1024];
    if (!fgets(buf, sizeof(buf), stdin)) {
        char* e = (char*)id_alloc(1); e[0] = '\0'; return e;
    }
    size_t n = strlen(buf);
    if (n > 0 && buf[n - 1] == '\n') { buf[--n] = '\0'; }
    char* r = (char*)id_alloc(n + 1); memcpy(r, buf, n + 1); return r;
}
static char* id_read_all(void) {
    /* slurp all of stdin into one string (grows as needed) */
    size_t cap = 4096, n = 0;
    char* r = (char*)id_alloc(cap);
    for (;;) {
        if (n + 1 >= cap) {
            if (cap > SIZE_MAX / 2) {
                fprintf(stderr, "id: allocation size overflow (read_all)\n");
                exit(1);
            }
            cap *= 2;
            r = (char*)id_realloc(r, cap);
        }
        size_t got = fread(r + n, 1, cap - n - 1, stdin);
        n += got;
        if (got == 0) break;
    }
    r[n] = '\0';
    return r;
}
static int id_len(const char* s) { return (int)id_slen(s); }
/* charat's bounds check used to be a strlen per character, which makes walking
   a string O(n^2) -- and walking a string with charat is how every id program
   reads text, because there is no substr and no file I/O. Lexing a 128 KB
   source took 378 ms; with the length of the last string remembered it takes
   12 ms, and the answer is the same.
   The memo is keyed on the pointer, which is sound because an id string is
   immutable and its block is never released before exit. The one place a block
   can be released early is id_realloc (list growth), whose freed address could
   later be handed to a new string -- so it clears the memo. */
static int id_charat(const char* s, int i) {
    if (i < 0) return -1;
    if ((size_t)i >= id_slen(s)) return -1;        /* out of range -> -1 */
    return (unsigned char)s[i];
}
static char* id_chr(int code) {
    char* r = (char*)id_alloc(2);
    r[0] = (char)code; r[1] = '\0';
    return r;
}

/* real-time terminal I/O: write without a newline, flush, poll a single key
   without blocking (raw mode is entered lazily and restored at exit), and
   sleep. Together these let id drive an animated full-screen frame loop. */
static void id_put(const char* s) { fputs(s, stdout); }
static void id_flush(void) { fflush(stdout); }
static struct termios id_saved_termios;
static int id_raw_active = 0;
static void id_term_restore(void) {
    if (id_raw_active) {
        tcsetattr(STDIN_FILENO, TCSANOW, &id_saved_termios);
        id_raw_active = 0;
    }
}
static void id_term_raw(void) {
    struct termios t;
    if (id_raw_active) return;
    if (tcgetattr(STDIN_FILENO, &id_saved_termios) != 0) return;
    t = id_saved_termios;
    t.c_lflag &= ~(tcflag_t)(ICANON | ECHO);
    t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 0;   /* read() returns at once, 0 on no key */
    tcsetattr(STDIN_FILENO, TCSANOW, &t);
    id_raw_active = 1;
    atexit(id_term_restore);
}
static int id_getkey(void) {
    unsigned char c;
    id_term_raw();
    if (read(STDIN_FILENO, &c, 1) == 1) return (int)c;
    return -1;   /* no key available this poll */
}
static void id_sleep_ms(int ms) {
    struct timespec ts;
    if (ms < 0) ms = 0;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}
static int id_ticks(void) {   /* monotonic milliseconds, for timing and seeding */
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}
"""


# Names an `id` program may not give a function, because the runtime prelude
# above already defines a C function of that name.
#
# Every id function is emitted as `id_<name>`, so `str_of_int` in id becomes
# `id_str_of_int` in C -- which the runtime declares. Left unchecked, that is a
# C error attributed to nobody: `cc` says "conflicting types for
# 'id_str_of_int'", idc.py reports a raw "C compilation failed", and bin/idc
# reported it as "this is a bug in the self-hosted compiler; please report it"
# -- telling a user to file a bug about their own typo.
#
# It matters more now than it used to. A standard library wants exactly these
# names: idstd tried to provide `str_of_int` and `str_of_word` and could have
# neither, and found this diagnostic while doing it.
#
# Derived from RUNTIME rather than listed, so the two cannot drift: adding a
# helper to the prelude reserves its name in the same commit.
# tools/gen_runtime_id.py regenerates the id-side copy of this list from here.
RUNTIME_HELPERS = frozenset(re.findall(r"\bid_([a-z_0-9]+)\s*\(", RUNTIME))


def instrumented_runtime() -> str:
    """RUNTIME with the two test counters spliced in.

    This is used ONLY by the test harness, which is a separate translation unit
    built and run before the real output exists. A normal build must emit
    RUNTIME verbatim, because tools/parity.sh compares that text byte for byte
    against the self-hosted compiler's."""
    rt = RUNTIME.replace(
        "#define ID_LEN_MEMO 8",
        "static long long id_ctr_time = 0;\n"
        "static long long id_ctr_mem = 0;\n"
        "#define ID_LEN_MEMO 8", 1)
    rt = rt.replace(
        "static void* id_alloc(size_t n) {",
        "static void* id_alloc(size_t n) {\n"
        "    id_ctr_mem += (long long)n;", 1)
    if "id_ctr_time = 0" not in rt:
        raise AssertionError("the length memo moved; the counters are no "
                             "longer declared before the helper that uses them")
    rt = rt.replace(
        "static void* id_realloc(void* p, size_t n) {",
        "static void* id_realloc(void* p, size_t n) {\n"
        "    id_ctr_mem += (long long)n;", 1)
    if rt.count("id_ctr_mem +=") != 2:
        raise AssertionError("the allocation helpers moved; the mem counter "
                             "is no longer being incremented")

    # The runtime helpers have to be counted too, or the counter measures the
    # wrong thing. An id-level loop that concatenates one character per
    # iteration is one loop -- linear by the generated code's own arithmetic --
    # while the work it causes is quadratic, because each concat copies the
    # whole string so far. Counting only generated code would pass
    # `[time:O(n)]` on exactly the regression this feature exists to catch
    # (docs/GAPS.md 3: id_charat calling strlen per access made every text
    # program quadratic, and nothing noticed for months).
    #
    # So each helper charges the work it actually does, in bytes touched.
    rt = rt.replace(
        "    size_t la = strlen(a), lb = strlen(b);",
        "    size_t la = strlen(a), lb = strlen(b);\n"
        "    id_ctr_time += (long long)(la + lb);", 1)
    rt = rt.replace(
        "static int id_len(const char* s) { return (int)id_slen(s); }",
        "static int id_len(const char* s) {\n"
        "    size_t n = strlen(s); id_ctr_time += (long long)n; return (int)n;\n"
        "}", 1)
    # charat is memoised, so a miss is the only place it does O(n) work --
    # which is precisely the thing that regressed before. The memo is in
    # id_slen, so that is where the miss is charged.
    rt = rt.replace(
        "    id_lm_n[i] = strlen(s);",
        "    id_lm_n[i] = strlen(s);\n"
        "    id_ctr_time += (long long)id_lm_n[i];", 1)
    if rt.count("id_ctr_time +=") != 3:
        raise AssertionError("a counted runtime helper moved; the time "
                             "counter no longer sees the work it does")
    return rt


def reserved_name_msg(name) -> str:
    """The diagnostic for a function named after a runtime helper. Shared with
    the self-hosted compiler, which must produce the same text."""
    return (f"function '{name}' collides with a runtime helper: every id "
            f"function is emitted as 'id_<name>', and the runtime already "
            f"defines 'id_{name}'. Choose another name")


# -------------------------------------------------------- the flat store
#
# `id` models memory the way the machine does: one flat, byte-addressed store,
# reached only through these builtins. An address is an ordinary `word`, so
# structs are offsets, arrays are strides, and `&x` is arithmetic -- none of
# which the language needs syntax for.
#
# Every access is bounds-checked against the live allocation set. That is the
# whole point: the class of bug that turns into a CVE in real systems code
# becomes a loud abort here, exactly as an out-of-range list index already
# does.
#
# name -> (arity, C helper, id result type)
STORE_BUILTINS = {
    "alloc":      (1, "id_mem_alloc", "word"),
    "store_size": (0, "id_mem_size", "word"),
    "peek8":      (1, "id_peek8", "word"),
    "peek16":     (1, "id_peek16", "word"),
    "peek32":     (1, "id_peek32", "word"),
    "peek64":     (1, "id_peek64", "word"),
    "poke8":      (2, "id_poke8", "void"),
    "poke16":     (2, "id_poke16", "void"),
    "poke32":     (2, "id_poke32", "void"),
    "poke64":     (2, "id_poke64", "void"),
}

# The four operations where unsigned genuinely differs from signed. The plain
# operators keep their signed meaning; these spell out the unsigned one, so
# the signedness of an operation is visible where it happens rather than
# implied by a declaration in another file.
WORD_BUILTINS = {
    "udiv": (2, "id_udiv", "word"),
    "umod": (2, "id_umod", "word"),
    "ult":  (2, "id_ult", "int"),
    "ushr": (2, "id_ushr", "word"),
}


def is_numeric(t):
    return t in ("int", "float", "word")


def is_integral(t):
    """int-like: the types bitwise operators and the flat store accept.
    `float` is excluded -- shifting a double is not a thing."""
    return t in ("int", "word")


def arith_result(lt, rt):
    """The type of an arithmetic expression mixing `lt` and `rt`. Widening
    order is int < word < float, so mixing an index with an address gives an
    address rather than silently truncating it to 32 bits."""
    if "float" in (lt, rt):
        return "float"
    if "word" in (lt, rt):
        return "word"
    return "int"


def compatible(want, got):
    if want == got:
        return True
    return is_numeric(want) and is_numeric(got)


class Compiler:
    def __init__(self, funcs_by_file, has_backend=False, instrument=False,
                 units=None):
        # Build the test harness instead of the program: count time/mem, keep
        # every function (a tested function need not be reachable from main),
        # and replace the user's entry point with one that runs the cases.
        # Never set on the compiler whose output the user asked for.
        self.instrument = instrument
        self.tc_helpers = {}       # generated harness helper name -> its C code
        self.funcs = {}            # name -> FuncDef
        self.exported = {}         # name -> (type, owner fn name)
        self.var_owner = {}        # var name -> (fn name, file, line)
        self.unknown_fns = {}      # name -> (file, line) of first call
        # Whether this build was given --backend: native backends legitimately
        # provide external functions, so a call to an undefined, non-builtin
        # name should only become an `extern` forward declaration (with a
        # warning) when a backend is in play. With no backend, the same call
        # is almost always a typo (e.g. `char_at` for `charat`) and should be
        # a hard error instead of a cryptic linker error later. See
        # gen_expr's call-codegen (the C backend, the only one with an extern
        # mechanism -- LLVM/wasm always reject undefined calls outright).
        self.has_backend = has_backend
        self.lines = []

        for fname, funcs in funcs_by_file.items():
            if len(funcs) > FUNCS_PER_FILE_LIMIT:
                f = funcs[FUNCS_PER_FILE_LIMIT]
                raise CompileError(f.file, f.line,
                                   f"too many functions in this file ({len(funcs)}); "
                                   f"the limit is {FUNCS_PER_FILE_LIMIT} per file")
            for fn in funcs:
                if fn.name in self.funcs:
                    prev = self.funcs[fn.name]
                    raise CompileError(fn.file, fn.line,
                                       f"function '{fn.name}' already defined at "
                                       f"{prev.file}:{prev.line}")
                if fn.name in RUNTIME_HELPERS:
                    raise CompileError(fn.file, fn.line, reserved_name_msg(fn.name))
                self.funcs[fn.name] = fn

        # Which compilation unit each source file belongs to: the program's own
        # tree, or one imported dependency such as the standard library (see
        # source_unit). None means one unit, which is what a build assembled
        # by hand rather than by main() gets.
        self.units = units or {}
        self.var_types = {}        # (unit, non-exported name) -> its single type

        # pass 1: claim exported names (these become reserved globals)
        for fn in self.funcs.values():
            for stmt in walk_stmts(fn.body):
                if isinstance(stmt, DeclStmt) and stmt.exported:
                    if stmt.name in self.exported:
                        owner = self.exported[stmt.name][1]
                        raise CompileError(stmt.file, stmt.line,
                                           f"'{stmt.name}' is already an exported "
                                           f"global (exported by '{owner}')")
                    self.exported[stmt.name] = (stmt.typ, fn.name)

        # pass 2: every variable declaration. A name may repeat across functions
        # only if it always has the same type; an exported name is reserved and
        # cannot be reused by any other variable.
        for fn in self.funcs.values():
            seen = set()
            for ptype, pname in fn.params:
                self.register_var(pname, ptype, fn, fn.file, fn.line, False, seen)
            for stmt in walk_stmts(fn.body):
                if isinstance(stmt, DeclStmt):
                    self.register_var(stmt.name, stmt.typ, fn, stmt.file, stmt.line,
                                      stmt.exported, seen)

    def register_var(self, name, typ, fn, file, line, exported, seen):
        if name in self.funcs:
            raise CompileError(file, line,
                               f"'{name}' is already the name of a function")
        if name in seen:
            raise CompileError(file, line,
                               f"variable '{name}' is declared twice in function "
                               f"'{fn.name}'")
        seen.add(name)
        if name in self.exported and not exported:
            owner = self.exported[name][1]
            raise CompileError(file, line,
                               f"'{name}' is an exported global (by '{owner}'); "
                               f"another variable cannot reuse that name -- read "
                               f"the global with 'import {name}'")
        if not exported:
            # One name, one type -- within one unit. The rule exists so that a
            # name cannot mean two things in the program someone is reading,
            # and an imported library's internals are not that program: before
            # this was per-unit, a local named `s` in a user's function was
            # rejected because the standard library had a `string s`, and both
            # diagnostics named library files the user had never opened.
            key = (self.units.get(fn.file, 0), name)
            if key in self.var_types and self.var_types[key] != typ:
                raise CompileError(file, line,
                                   f"variable '{name}' is declared {typ} here but "
                                   f"{self.var_types[key]} elsewhere; a name must "
                                   f"keep one type across the whole program")
            self.var_types[key] = typ
        self.var_owner.setdefault(name, (fn.name, file, line))

    # -- entry point

    def check_unique_functions(self):
        seen = {}  # canonical fingerprint -> the first function with it
        for fn in self.funcs.values():
            key = canonical_function(fn)
            if key in seen:
                orig = seen[key]
                raise CompileError(
                    fn.file, fn.line,
                    f"function '{fn.name}' has the same signature and logic as "
                    f"'{orig.name}' (defined at {orig.file}:{orig.line}); functions "
                    f"must be unique -- remove one and call it from both places, or "
                    f"make them genuinely differ")
            seen[key] = fn

    def validate(self):
        """Run the checks that don't depend on which backend will emit code
        (function uniqueness, the action/nesting limits). Non-C backends call
        this instead of compile() -- they share this checked AST (self.funcs,
        self.exported, self.var_owner, self.var_types) and the rest of the
        semantic checking (variable resolution, type compatibility) that
        happens inline in each backend's own expression/statement codegen, and
        only diverge from the C backend at codegen itself."""
        self.check_unique_functions()
        self.check_dead_exports()
        if STRICT_CONST:
            self.check_assigned_once()
        for fn in self.funcs.values():
            self.check_action_limit(fn)
            self.check_discarded_comparison(fn)

    # -- a statement that compares instead of assigning
    #
    # Assignment exists only as a statement, and only when the parser can see
    # a statement-shaped assignment: `x = v` and `xs[i] = v` where the target
    # starts with a plain identifier. Anything else the parser meets is an
    # *expression* statement, and a bare `=` inside an expression is equality.
    # So `(import xs)[i] = v;` compiles to a comparison whose result is thrown
    # away -- it type-checks, it links, it runs, and it does nothing.
    #
    # That is the language's worst trap: the whole `lset` idiom exists to work
    # around it, and every program in this tree that writes through a global
    # already pays for it. Rejecting it costs nothing -- a comparison
    # evaluated for no reason is never what anyone meant -- and turns a silent
    # wrong answer into a message that names the fix.
    #
    # `=` and `==` are one op by the time the parser is done (parse_equality
    # folds the first into the second), so both spellings are caught. That is
    # the right net anyway: `x == 2;` as a statement is as pointless as the
    # assignment it is usually a typo for.
    def check_discarded_comparison(self, fn: FuncDef):
        for stmt in walk_stmts(fn.body):
            if not isinstance(stmt, ExprStmt):
                continue
            e = stmt.expr
            if not (isinstance(e, BinOp) and e.op == "=="):
                continue
            hint = ""
            if isinstance(e.left, IndexExpr):
                hint = (" -- an imported list or a call result cannot be "
                        "index-assigned directly; pass the list to a helper "
                        "that takes it as a parameter, as "
                        "lset(int[] xs, int i, int v) { xs[i] = v; }")
            raise CompileError(stmt.file, stmt.line,
                               "this statement compares instead of assigning: "
                               "'=' in an expression is equality, so the "
                               "statement has no effect" + hint)

    # -- an export whose declaring function is never reached
    #
    # `export T name = v;` is a declaration *inside a function body*: the C
    # global exists from the start, but its initializer is an assignment that
    # runs only when that function runs. A function nothing calls therefore
    # leaves every global it declares NULL/0, and every `(import name)`
    # reading it gets that, silently, at run time.
    #
    # `id` has no function pointers, so the call graph is exact and this is
    # decidable rather than approximate. It is worth deciding: allocation is
    # one chain of small functions (a 3-action block caps it at two exports
    # plus one call), so dropping a link is a one-line mistake -- and this
    # repo shipped one. demos/fpsmaze defined scene_init(), nothing called it,
    # and the game drew its maze with no walls and no targets.
    #
    # What is reported is the *read*, not the dead function: a file that
    # declares an export and never wires it up is unfinished or illustrative,
    # and demos/hello is deliberately the latter. A reachable `(import x)`
    # whose owner is unreachable is neither -- it is a guaranteed read of an
    # uninitialised global, at a place the program actually goes.
    def check_dead_exports(self):
        main = self.funcs.get("main")
        if main is None:
            return          # a library: every function is an entry point
        reachable, stack = set(), ["main"]
        while stack:
            name = stack.pop()
            if name in reachable:
                continue
            reachable.add(name)
            fn = self.funcs.get(name)
            if fn is None:
                continue    # a builtin, or a link-time symbol
            for e in walk_exprs_in(fn):
                if isinstance(e, CallExpr) and e.name not in reachable:
                    stack.append(e.name)
        owner_of_export = {}
        for fn in self.funcs.values():
            for stmt in walk_stmts(fn.body):
                if isinstance(stmt, DeclStmt) and stmt.exported:
                    owner_of_export.setdefault(stmt.name, fn.name)
        for fn in self.funcs.values():
            if fn.name not in reachable:
                continue
            for e in walk_exprs_in(fn):
                if not isinstance(e, ImportRef):
                    continue
                owner = owner_of_export.get(e.name)
                if owner is None or owner in reachable:
                    continue
                raise CompileError(
                    e.file, e.line,
                    f"'{e.name}' is exported by '{owner}', which nothing "
                    f"calls -- an export is initialised when its declaring "
                    f"function runs, so this reads an uninitialised global. "
                    f"Call '{owner}' from main's setup chain")

    def _written_params(self, fname):
        """Which parameter positions of `fname` are written through: assigned,
        or index-assigned. A list parameter is a reference, so writing one is
        how a function mutates its caller's list."""
        # Builtins are not in self.funcs and some of them write through their
        # first argument. push and pop are how a list grows and shrinks, so a
        # missing entry here reports every accumulator in the language as a
        # constant -- which is exactly what happened when this table did not
        # exist: every project in the repository, idstd included.
        if fname in ("push", "pop"):
            return {0}
        fn = self.funcs.get(fname)
        if fn is None:
            return set()            # another builtin, or a link-time symbol
        pos = {pname: i for i, (_ptype, pname) in enumerate(fn.params)}
        out = set()
        for stmt in walk_stmts(fn.body):
            if isinstance(stmt, IndexAssignStmt):
                base = stmt.base
                if isinstance(base, VarRef) and base.name in pos:
                    out.add(pos[base.name])
            elif isinstance(stmt, AssignStmt) and stmt.name in pos:
                out.add(pos[stmt.name])
        return out

    def check_assigned_once(self):
        """An exported value that never changes is a constant, and a constant
        does not need a function to exist. Say so, and name conf.id.

        Three questions, in order, because each only makes sense if the one
        before it held:

          1. Is the name SET exactly once across the whole project? A write
             through a helper -- `lset((import xs), i, v)`, the idiom the
             compiler's own diagnostic recommends -- counts as a set. Without
             that, every stateful module in idstd looks constant: err_n is
             `[0, 0]` at its declaration and incremented through lset on every
             error, and telling someone to move a counter into configuration
             would be exactly wrong.
          2. Is that one set a DIRECT assignment -- no call in the value? A
             value computed by calling something is not available before the
             program runs. rnd_st is `[fx_abs(seed % 2147483646) + 1]`, one
             assignment, and not a constant.
          3. If it is set in several places but every one of them is the same
             direct assignment, that is the same fact written repeatedly, and
             it belongs in conf.id too.
        """
        sets, mutated = self._export_writes()
        for name in sorted(sets):
            places = sets[name]
            if name in mutated:
                continue
            if len({v for v, _, _, _ in places}) != 1:
                continue
            if any(isinstance(sub, CallExpr)
                   for _, expr, _, _ in places for sub in walk_expr(expr)):
                continue
            _, _, file, line = places[0]
            many = (f" It is assigned identically in {len(places)} places, which "
                    f"is one fact written {len(places)} times." if len(places) > 1 else "")
            raise CompileError(
                file, line,
                f"'{name}' is assigned once and never changed, so it is a "
                f"constant, not state.{many} Declare it in {IMPORT_MANIFEST} "
                f"instead of in a function that exists only to assign it")

    def _export_writes(self):
        """Every write to an exported name, and the set of names written
        THROUGH a call. `lset((import xs), i, v)` is the second kind, and it is
        the idiom the compiler's own diagnostic recommends -- without counting
        it, every accumulator in the language looks like a constant."""
        sets, mutated = {}, set()
        for fn in self.funcs.values():
            names = {}
            cn = lambda n: names.setdefault(n, n)
            for stmt in walk_stmts(fn.body):
                if isinstance(stmt, DeclStmt) and stmt.exported:
                    where = stmt
                elif isinstance(stmt, AssignStmt) and stmt.name in self.exported:
                    where = stmt
                else:
                    continue
                if where.expr is not None:
                    sets.setdefault(where.name, []).append(
                        (_canon_expr(where.expr, cn, fn.name), where.expr,
                         where.file, where.line))
            for e in walk_exprs_in(fn):
                if not isinstance(e, CallExpr):
                    continue
                written = self._written_params(e.name)
                for i, arg in enumerate(e.args):
                    if isinstance(arg, ImportRef) and i in written:
                        mutated.add(arg.name)
        return sets, mutated

    # -- dead-code elimination
    #
    # Emit only what the program can reach. This is not an optimisation, it is
    # what makes a standard library affordable: idstd is merged into EVERY
    # program, and without this a hello-world pays for all of it. Measured on a
    # synthetic library of trivial functions, before this existed:
    #
    #     none          0.18 s   16 KB
    #     243 functions 0.36 s   33 KB
    #     729 functions 0.75 s   75 KB
    #
    # A real standard library is 500-700 functions with real bodies, so the tax
    # on every program in the language was roughly +0.6 s and +60 KB.
    #
    # Two rules about what this may and may not do:
    #
    #   * It runs AFTER every check, never before. A dead function still has to
    #     obey the action limit, the nesting limit and every type rule -- code
    #     that stops being checked because nothing calls it is exactly how a
    #     library rots, and it would silently stop checking a user's own dead
    #     code too.
    #   * A program with no `main` is a library, compiled to a .o, and every one
    #     of its functions is an entry point. Nothing is pruned there.
    #
    # `asm` functions are held outside self.funcs and are unaffected.
    def reachable_functions(self):
        """The set of function names reachable from `main`, or None when the
        program has no `main` (a library: everything is an entry point).

        `id` has no function pointers, so the call graph is exact."""
        if "main" not in self.funcs:
            return None
        reachable, stack = set(), ["main"]
        while stack:
            name = stack.pop()
            if name in reachable:
                continue
            reachable.add(name)
            fn = self.funcs.get(name)
            if fn is None:
                continue    # a builtin, or a link-time symbol
            for e in walk_exprs_in(fn):
                if isinstance(e, CallExpr) and e.name not in reachable:
                    stack.append(e.name)
        return reachable

    def is_live(self, reachable, name):
        """Should `name`'s definition be emitted? Everything is live in a
        program with no `main` (reachable is None: a library, compiled to a .o,
        where every function is an entry point)."""
        return reachable is None or name in reachable

    def build_env(self, fn: FuncDef) -> dict:
        """name -> id type for every parameter and every declared local
        (hoisted, function-scoped) in `fn`. Shared by every codegen backend."""
        env = {pname: ptype for ptype, pname in fn.params}
        for stmt in walk_stmts(fn.body):
            if isinstance(stmt, DeclStmt):
                env[stmt.name] = stmt.typ
        return env

    def compile(self) -> str:
        self.check_unique_functions()
        self.check_dead_exports()
        if STRICT_CONST:
            self.check_assigned_once()
        live = None if self.instrument else self.reachable_functions()
        # EVERY function is checked and generated, including the dead ones, and
        # only then is the dead code dropped. That order is not incidental: a
        # good deal of this compiler's checking (the export/import access rules
        # above all) happens inside gen_function, so generating only the live
        # functions silently stopped enforcing those rules on the rest --
        # tests/invalid's `import_without_export` and `unexported_access` both
        # started compiling clean, while bin/idc (whose checks all run before
        # emission) still rejected them. Dead code is still code, and it is
        # still checked; it is just not emitted.
        bodies = []
        for fn in self.funcs.values():
            self.check_action_limit(fn)
            self.check_discarded_comparison(fn)
            code = self.gen_function(fn)
            if self.is_live(live, fn.name):
                bodies.append(code)

        out = [instrumented_runtime() if self.instrument else RUNTIME]

        if self.unknown_fns:
            out.append("/* functions not defined in any input file (resolved at link time) */")
            for name in self.unknown_fns:
                out.append(f"extern int id_{name}();")
            out.append("")

        out.append("/* forward declarations */")
        for fn in self.funcs.values():
            if self.is_live(live, fn.name):
                out.append(self.signature(fn) + ";")
        out.append("")

        if self.exported:
            out.append("/* exported variables */")
            for name, (typ, owner) in self.exported.items():
                out.append(f"{self.c_decl(typ, name)};  /* exported by {owner}() */")
            out.append("")

        out.extend(bodies)
        out.append(self.gen_test_main() if self.instrument else self.gen_entrypoint())
        return "\n".join(out) + "\n"

    # -- the 3-action rule: EVERY block (the function body and the body of each
    #    if/else/while) may perform at most 3 actions. Each statement is one
    #    action; an `if` is one and each chained `else` is another; a `while` is
    #    one. The return clause is free. Blocks may also nest only NEST_LIMIT
    #    deep -- code below that must be split into its own function.

    def block_actions(self, body) -> int:
        n = 0
        for s in body:
            if isinstance(s, IfStmt):
                n += 1
                cur = s.els
                while cur is not None:
                    n += 1  # each `else` (or `else if`) is an action
                    cur = cur.els if isinstance(cur, IfStmt) else None
            else:
                n += 1
        return n

    def check_action_limit(self, fn: FuncDef):
        self.check_block(fn.body, 0, fn, fn.file, fn.line)

    def check_block(self, body, depth, fn, file, line):
        if depth > NEST_LIMIT:
            raise CompileError(file, line,
                               f"code in '{fn.name}' is nested too deeply "
                               f"({depth} levels); the maximum is {NEST_LIMIT}. "
                               f"Split the inner block into its own function")
        n = self.block_actions(body)
        if n > ACTION_LIMIT:
            raise CompileError(file, line,
                               f"a block in '{fn.name}' performs {n} actions; the "
                               f"limit is {ACTION_LIMIT} (each statement, if, else, "
                               f"and while is one action; return is free) -- move "
                               f"some statements into a helper function to stay "
                               f"within the limit")
        for s in body:
            if isinstance(s, IfStmt):
                cur = s
                while isinstance(cur, IfStmt):  # walk an if / else-if chain
                    self.check_block(cur.then, depth + 1, fn, cur.file, cur.line)
                    cur = cur.els
                if cur is not None:             # trailing plain `else` block
                    self.check_block(cur, depth + 1, fn, s.file, s.line)
            elif isinstance(s, WhileStmt):
                self.check_block(s.body, depth + 1, fn, s.file, s.line)

    # -- codegen helpers

    def c_decl(self, typ, name):
        return f"{c_type(typ)} {name}"

    def signature(self, fn: FuncDef) -> str:
        ps = ", ".join(self.c_decl(t, n) for t, n in fn.params) or "void"
        return f"{c_type(fn.rettype)} id_{fn.name}({ps})"

    def gen_function(self, fn: FuncDef) -> str:
        lines = [self.signature(fn) + " {"]

        # hoist local declarations to function scope: variables are
        # function-scoped (the trailing return clause may reference them)
        env = self.build_env(fn)
        hoisted = [f"    {self.c_decl(stmt.typ, stmt.name)};"
                   for stmt in walk_stmts(fn.body)
                   if isinstance(stmt, DeclStmt) and not stmt.exported]
        lines.extend(hoisted)
        if self.instrument:
            lines.append("    id_ctr_time++;")

        for stmt in fn.body:
            lines.extend(self.gen_stmt(stmt, fn, env, 1))

        if fn.rettype == "void":
            lines.append("    return;")
        else:
            code, typ = self.gen_expr(fn.retexpr, fn, env, fn.rettype)
            if not compatible(fn.rettype, typ):
                raise CompileError(fn.retexpr.file, fn.retexpr.line,
                                   f"function '{fn.name}' returns {fn.rettype} but "
                                   f"the expression has type {typ}")
            lines.append(f"    return {code};")
        lines.append("}")
        lines.append("")
        return "\n".join(lines)

    def gen_stmt(self, stmt, fn, env, depth) -> List[str]:
        ind = "    " * depth
        if isinstance(stmt, DeclStmt):
            code, typ = self.gen_expr(stmt.expr, fn, env, stmt.typ)
            if not compatible(stmt.typ, typ):
                raise CompileError(stmt.file, stmt.line,
                                   f"cannot initialize {stmt.typ} '{stmt.name}' "
                                   f"with a {typ} value")
            return [f"{ind}{stmt.name} = {code};"]
        if isinstance(stmt, AssignStmt):
            if stmt.name not in env:
                self.explain_bad_var(stmt.name, fn, stmt.file, stmt.line)
            code, typ = self.gen_expr(stmt.expr, fn, env, env[stmt.name])
            if not compatible(env[stmt.name], typ):
                raise CompileError(stmt.file, stmt.line,
                                   f"cannot assign a {typ} value to "
                                   f"{env[stmt.name]} '{stmt.name}'")
            return [f"{ind}{stmt.name} = {code};"]
        if isinstance(stmt, IndexAssignStmt):
            base, btyp = self.gen_expr(stmt.base, fn, env)
            if not btyp.endswith("[]"):
                raise CompileError(stmt.file, stmt.line, f"cannot index a {btyp}")
            idx, ityp = self.gen_expr(stmt.index, fn, env)
            if ityp != "int":
                raise CompileError(stmt.file, stmt.line,
                                   f"list index must be int, got {ityp}")
            elem = btyp[:-2]
            code, typ = self.gen_expr(stmt.expr, fn, env, elem)
            if not compatible(elem, typ):
                raise CompileError(stmt.file, stmt.line,
                                   f"cannot store a {typ} into a {btyp}")
            return [f"{ind}id_list_set({base}, {idx}, {box(code, elem)});"]
        if isinstance(stmt, IfStmt):
            cond, ctyp = self.gen_expr(stmt.cond, fn, env)
            if ctyp == "void":
                raise CompileError(stmt.file, stmt.line, "condition has type void")
            out = [f"{ind}if ({cond}) {{"]
            for s in stmt.then:
                out.extend(self.gen_stmt(s, fn, env, depth + 1))
            out.append(f"{ind}}}")
            if stmt.els is not None:
                if isinstance(stmt.els, IfStmt):
                    else_lines = self.gen_stmt(stmt.els, fn, env, depth)
                    out[-1] = f"{ind}}} else " + else_lines[0].lstrip()
                    out.extend(else_lines[1:])
                else:
                    out[-1] = f"{ind}}} else {{"
                    for s in stmt.els:
                        out.extend(self.gen_stmt(s, fn, env, depth + 1))
                    out.append(f"{ind}}}")
            return out
        if isinstance(stmt, WhileStmt):
            cond, ctyp = self.gen_expr(stmt.cond, fn, env)
            if ctyp == "void":
                raise CompileError(stmt.file, stmt.line, "loop condition has type void")
            out = [f"{ind}while ({cond}) {{"]
            if self.instrument:
                out.append(f"{ind}    id_ctr_time++;")
            for s in stmt.body:
                out.extend(self.gen_stmt(s, fn, env, depth + 1))
            out.append(f"{ind}}}")
            return out
        if isinstance(stmt, ExprStmt):
            code, _ = self.gen_expr(stmt.expr, fn, env)
            return [f"{ind}{code};"]
        raise AssertionError(stmt)

    def explain_bad_var(self, name, fn, file, line):
        if name in self.var_owner:
            owner = self.var_owner[name][0]
            if name in self.exported:
                raise CompileError(file, line,
                                   f"variable '{name}' belongs to function '{owner}'; "
                                   f"read it with 'import {name}'")
            raise CompileError(file, line,
                               f"variable '{name}' belongs to function '{owner}' and "
                               f"is not exported; variables are only globally "
                               f"accessible if export/import is used")
        raise CompileError(file, line, f"undefined variable '{name}'")

    # -- expressions: returns (c_code, id_type)

    def gen_expr(self, e, fn, env, expected=None) -> Tuple[str, str]:
        if isinstance(e, IntLit):
            # A literal too big for a 32-bit int is a word, not a silently
            # truncated int -- so 0xffffffffffffffff means what it says.
            if int(e.value) > 0x7fffffff:
                return f"{e.value}LL", "word"
            return e.value, "int"
        if isinstance(e, FloatLit):
            return e.value, "float"
        if isinstance(e, StrLit):
            return e.raw, "string"
        if isinstance(e, VarRef):
            if e.name not in env:
                self.explain_bad_var(e.name, fn, e.file, e.line)
            return e.name, env[e.name]
        if isinstance(e, ImportRef):
            if e.name not in self.exported:
                if e.name in self.var_owner:
                    owner = self.var_owner[e.name][0]
                    raise CompileError(e.file, e.line,
                                       f"variable '{e.name}' (in function '{owner}') "
                                       f"is not exported")
                raise CompileError(e.file, e.line,
                                   f"no exported variable named '{e.name}'")
            return e.name, self.exported[e.name][0]
        if isinstance(e, IndexExpr):
            base, btyp = self.gen_expr(e.base, fn, env)
            if not btyp.endswith("[]"):
                raise CompileError(e.file, e.line, f"cannot index a {btyp}")
            idx, ityp = self.gen_expr(e.index, fn, env)
            if ityp != "int":
                raise CompileError(e.file, e.line, f"array index must be int, got {ityp}")
            elem = btyp[:-2]
            return unbox(f"id_list_get({base}, {idx})", elem), elem
        if isinstance(e, ArrayLit):
            if not e.elems:
                if expected is None or not expected.endswith("[]"):
                    raise CompileError(e.file, e.line,
                                       "an empty list literal needs a known list "
                                       "type here (e.g. on a typed declaration)")
                return "id_list_lit(0)", expected
            raw, etyp = [], None
            for el in e.elems:
                code, typ = self.gen_expr(el, fn, env)
                if etyp is None:
                    etyp = typ
                elif not compatible(etyp, typ):
                    raise CompileError(el.file, el.line,
                                       f"list element has type {typ}, expected {etyp}")
                if is_numeric(etyp) and typ == "float":
                    etyp = "float"
                raw.append(code)
            cells = ", ".join(box(c, etyp) for c in raw)
            return f"id_list_lit({len(raw)}, {cells})", etyp + "[]"
        if isinstance(e, CallExpr):
            return self.gen_call(e, fn, env)
        if isinstance(e, UnOp):
            code, typ = self.gen_expr(e.operand, fn, env)
            if e.op == "-" and not is_numeric(typ):
                raise CompileError(e.file, e.line, f"cannot negate a {typ}")
            if e.op == "!" and not is_integral(typ):
                raise CompileError(e.file, e.line, f"cannot apply '!' to a {typ}")
            if e.op == "~":
                if not is_integral(typ):
                    raise CompileError(e.file, e.line,
                                       f"cannot apply '~' to a {typ}")
                return f"(~{code})", typ
            if e.op == "!":
                return f"(!{code})", "int"
            return f"({e.op}{code})", typ
        if isinstance(e, BinOp):
            return self.gen_binop(e, fn, env)
        raise AssertionError(e)

    def gen_call(self, e: CallExpr, fn, env) -> Tuple[str, str]:
        if e.name == "print":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "print takes exactly one argument")
            code, typ = self.gen_expr(e.args[0], fn, env)
            return f"id_print({self.to_string(code, typ, e)})", "void"
        if e.name == "input":
            if len(e.args) != 0:
                raise CompileError(e.file, e.line, "input takes no arguments")
            return "id_input()", "string"
        if e.name == "read_all":
            if len(e.args) != 0:
                raise CompileError(e.file, e.line, "read_all takes no arguments")
            return "id_read_all()", "string"
        if e.name == "len":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "len takes exactly one argument")
            code, typ = self.gen_expr(e.args[0], fn, env)
            if typ == "string":
                return f"id_len({code})", "int"
            if typ.endswith("[]"):
                return f"id_list_len({code})", "int"
            raise CompileError(e.file, e.line,
                               f"len expects a string or list, got {typ}")
        if e.name == "push":
            if len(e.args) != 2:
                raise CompileError(e.file, e.line, "push takes exactly two arguments")
            lc, lt = self.gen_expr(e.args[0], fn, env)
            if not lt.endswith("[]"):
                raise CompileError(e.file, e.line, f"push expects a list, got {lt}")
            elem = lt[:-2]
            vc, vt = self.gen_expr(e.args[1], fn, env, elem)
            if not compatible(elem, vt):
                raise CompileError(e.file, e.line,
                                   f"cannot push a {vt} onto a {lt}")
            return f"id_list_push({lc}, {box(vc, elem)})", "void"
        if e.name == "pop":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "pop takes exactly one argument")
            lc, lt = self.gen_expr(e.args[0], fn, env)
            if not lt.endswith("[]"):
                raise CompileError(e.file, e.line, f"pop expects a list, got {lt}")
            elem = lt[:-2]
            return unbox(f"id_list_pop({lc})", elem), elem
        if e.name == "to_int":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "to_int takes exactly one argument")
            code, typ = self.gen_expr(e.args[0], fn, env)
            if typ != "string":
                raise CompileError(e.file, e.line, f"to_int expects a string, got {typ}")
            return f"id_to_int({code})", "int"
        if e.name == "charat":
            if len(e.args) != 2:
                raise CompileError(e.file, e.line, "charat takes exactly two arguments")
            sc, st = self.gen_expr(e.args[0], fn, env)
            ic, it = self.gen_expr(e.args[1], fn, env)
            if st != "string":
                raise CompileError(e.file, e.line, f"charat expects a string, got {st}")
            if it != "int":
                raise CompileError(e.file, e.line, f"charat index must be int, got {it}")
            return f"id_charat({sc}, {ic})", "int"
        if e.name == "chr":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "chr takes exactly one argument")
            code, typ = self.gen_expr(e.args[0], fn, env)
            if typ != "int":
                raise CompileError(e.file, e.line, f"chr expects an int, got {typ}")
            return f"id_chr({code})", "string"
        if e.name == "put":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "put takes exactly one argument")
            code, typ = self.gen_expr(e.args[0], fn, env)
            return f"id_put({self.to_string(code, typ, e)})", "void"
        if e.name == "flush":
            if len(e.args) != 0:
                raise CompileError(e.file, e.line, "flush takes no arguments")
            return "id_flush()", "void"
        if e.name == "getkey":
            if len(e.args) != 0:
                raise CompileError(e.file, e.line, "getkey takes no arguments")
            return "id_getkey()", "int"
        if e.name == "sleep_ms":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "sleep_ms takes exactly one argument")
            code, typ = self.gen_expr(e.args[0], fn, env)
            if typ != "int":
                raise CompileError(e.file, e.line, f"sleep_ms expects an int, got {typ}")
            return f"id_sleep_ms({code})", "void"
        if e.name == "ticks":
            if len(e.args) != 0:
                raise CompileError(e.file, e.line, "ticks takes no arguments")
            return "id_ticks()", "int"
        if e.name in STORE_BUILTINS or e.name in WORD_BUILTINS:
            return self.gen_systems_call(e, fn, env)
        if e.name == "str_of_mem":
            if len(e.args) != 2:
                raise CompileError(e.file, e.line,
                                   "str_of_mem takes exactly two arguments")
            ac, at = self.gen_expr(e.args[0], fn, env)
            nc, nt = self.gen_expr(e.args[1], fn, env)
            if not is_integral(at) or not is_integral(nt):
                raise CompileError(e.file, e.line,
                                   "str_of_mem takes an address and a length")
            return f"id_str_of_mem((long long)({ac}), (long long)({nc}))", "string"
        if e.name == "mem_of_str":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line,
                                   "mem_of_str takes exactly one argument")
            code, typ = self.gen_expr(e.args[0], fn, env)
            if typ != "string":
                raise CompileError(e.file, e.line,
                                   f"mem_of_str expects a string, got {typ}")
            return f"id_mem_of_str({code})", "word"
        args = [self.gen_expr(a, fn, env) for a in e.args]
        callee = self.funcs.get(e.name)
        if callee is None:
            if e.name in self.var_owner:
                raise CompileError(e.file, e.line, f"'{e.name}' is a variable, not a function")
            if not self.has_backend:
                # No --backend means there is nowhere this name could be
                # resolved from at link time, so it's almost certainly a
                # typo'd builtin or a forgotten function -- fail now with a
                # helpful message instead of an `extern` that turns into a
                # bare linker error.
                raise CompileError(e.file, e.line, no_such_function_msg(e.name))
            if e.name not in self.unknown_fns:
                hint = builtin_hint(e.name)
                warn(e.file, e.line,
                     f"call to function '{e.name}' which is not defined in any input "
                     f"file; it must be provided at link time"
                     + (f".{hint}" if hint else ""))
                self.unknown_fns[e.name] = (e.file, e.line)
            return f"id_{e.name}({', '.join(c for c, _ in args)})", "int"
        if len(args) != len(callee.params):
            raise CompileError(e.file, e.line,
                               f"function '{e.name}' takes {len(callee.params)} "
                               f"argument(s), got {len(args)}")
        for (ptype, pname), (code, typ), arg in zip(callee.params, args, e.args):
            if not compatible(ptype, typ):
                raise CompileError(arg.file, arg.line,
                                   f"argument '{pname}' of '{e.name}' expects "
                                   f"{ptype}, got {typ}")
        return f"id_{e.name}({', '.join(c for c, _ in args)})", callee.rettype

    def gen_systems_call(self, e: CallExpr, fn, env) -> Tuple[str, str]:
        """The flat-store and unsigned-word builtins. They all take and return
        machine words, so one shared shape covers every one of them."""
        arity, helper, restype = (STORE_BUILTINS.get(e.name)
                                  or WORD_BUILTINS[e.name])
        if len(e.args) != arity:
            plural = "" if arity == 1 else "s"
            raise CompileError(e.file, e.line,
                               f"{e.name} takes exactly {arity} argument{plural}, "
                               f"got {len(e.args)}")
        codes = []
        for arg in e.args:
            code, typ = self.gen_expr(arg, fn, env)
            if not is_integral(typ):
                raise CompileError(arg.file, arg.line,
                                   f"{e.name} expects int or word arguments, "
                                   f"got {typ}")
            codes.append(f"(long long)({code})")
        return f"{helper}({', '.join(codes)})", restype

    def to_string(self, code, typ, e) -> str:
        if typ == "string":
            return code
        if typ == "word":
            return f"id_str_of_word({code})"
        if typ == "int":
            return f"id_str_of_int({code})"
        if typ == "float":
            return f"id_str_of_float({code})"
        raise CompileError(e.file, e.line, f"cannot convert {typ} to string")

    def gen_binop(self, e: BinOp, fn, env) -> Tuple[str, str]:
        lc, lt = self.gen_expr(e.left, fn, env)
        rc, rt = self.gen_expr(e.right, fn, env)
        op = e.op
        if op == "+" and (lt == "string" or rt == "string"):
            return (f"id_concat({self.to_string(lc, lt, e.left)}, "
                    f"{self.to_string(rc, rt, e.right)})"), "string"
        if op in ("==", "!="):
            if lt == "string" and rt == "string":
                return f"(strcmp({lc}, {rc}) {op} 0)", "int"
            if is_numeric(lt) and is_numeric(rt):
                return f"({lc} {op} {rc})", "int"
            raise CompileError(e.file, e.line, f"cannot compare {lt} with {rt}")
        if op in ("<", "<=", ">", ">="):
            if is_numeric(lt) and is_numeric(rt):
                return f"({lc} {op} {rc})", "int"
            raise CompileError(e.file, e.line, f"cannot order {lt} and {rt}")
        if op in ("&&", "||"):
            if is_integral(lt) and is_integral(rt):
                return f"({lc} {op} {rc})", "int"
            raise CompileError(e.file, e.line, f"'{op}' requires int operands")
        if op in ("&", "|", "^"):
            if is_integral(lt) and is_integral(rt):
                return f"({lc} {op} {rc})", arith_result(lt, rt)
            raise CompileError(e.file, e.line,
                               f"'{op}' requires int or word operands, got {lt} and {rt}")
        if op in ("<<", ">>"):
            # A shift by a count outside 0..63 is undefined behaviour in C, so
            # it goes through a runtime helper that gives it a defined answer
            # instead -- the same bargain id already makes for list indexing.
            # `>>` is the *signed* (arithmetic) shift; `ushr` is the unsigned one.
            if is_integral(lt) and is_integral(rt):
                helper = "id_shl" if op == "<<" else "id_sar"
                return f"{helper}({lc}, {rc})", arith_result(lt, rt)
            raise CompileError(e.file, e.line,
                               f"'{op}' requires int or word operands, got {lt} and {rt}")
        if op in ("+", "-", "*", "/", "%"):
            if is_numeric(lt) and is_numeric(rt):
                if op == "%" and (lt == "float" or rt == "float"):
                    raise CompileError(e.file, e.line, "'%' requires int operands")
                res = arith_result(lt, rt)
                if op in ("/", "%") and res in ("int", "word"):
                    # Division by zero, and the MIN/-1 overflow, are undefined
                    # in C: on this machine the first is a SIGFPE and a core
                    # dump with no message at all. Both go through a helper
                    # that traps the way an out-of-range list index traps.
                    # Float division is left alone -- IEEE gives it an answer.
                    pfx = "id_s" if res == "word" else "id_i"
                    return (f"{pfx}{'div' if op == '/' else 'mod'}"
                            f"({lc}, {rc})"), res
                return f"({lc} {op} {rc})", res
            raise CompileError(e.file, e.line, f"cannot apply '{op}' to {lt} and {rt}")
        raise AssertionError(op)

    # -- C entrypoint wrapper around the id main()

    def gen_entrypoint(self) -> str:
        m = self.funcs.get("main")
        if m is None:
            return ""
        ptypes = [t for t, _ in m.params]
        prelude = ""
        if ptypes == ["int", "string[]"]:
            # marshal C argv (char**) into an id string[] list
            prelude = ("IdList* id_args = id_list_new();\n"
                       "    for (int i = 0; i < argc; i++)\n"
                       "        id_list_push(id_args, (long long)(intptr_t)argv[i]);\n    ")
            call = "id_main(argc, id_args)"
        elif ptypes == []:
            call = "id_main()"
        else:
            raise CompileError(m.file, m.line,
                               "main must take (int, string[]) or no parameters")
        if m.rettype == "int":
            body = f"return {call};"
        else:
            body = f"{call}; return 0;"
        return (f"int main(int argc, char** argv) {{ (void)argc; (void)argv;\n    "
                f"{prelude}{body} }}\n")

    # ------------------------------------------------------------ test harness
    #
    # A second translation unit: the same functions, instrumented, plus an
    # entry point of its own that runs every case. The user's `main` (if there
    # is one) is compiled but never called -- the harness tests functions, it
    # does not run the program. Emitted only when self.instrument is set, so
    # none of this can reach the C the user asked for.

    def tc_compare(self, a, b, typ) -> str:
        """C expression: do `a` and `b`, both of id type `typ`, match?"""
        if typ.endswith("[]"):
            return f"{self.tc_eq_helper(typ[:-2])}({a}, {b})"
        if typ == "string":
            return f"(strcmp({a}, {b}) == 0)"
        return f"({a} == {b})"

    def tc_show(self, code, typ) -> str:
        """C statement printing `code` to stderr the way a case writes it."""
        if typ.endswith("[]"):
            return f"{self.tc_show_helper(typ[:-2])}({code});"
        if typ == "string":
            return f'fprintf(stderr, "\\"%s\\"", {code});'
        if typ == "float":
            return f'fprintf(stderr, "%g", {code});'
        if typ == "word":
            return f'fprintf(stderr, "%lld", {code});'
        return f'fprintf(stderr, "%d", {code});'

    def tc_helper(self, name, make):
        """Register a harness helper once, keyed by name. Reserved before the
        body is built so a list of lists doesn't recurse forever."""
        if name not in self.tc_helpers:
            self.tc_helpers[name] = ""
            self.tc_helpers[name] = make()
        return name

    def tc_eq_helper(self, elem) -> str:
        name = "idtc_eq_" + elem.replace("[]", "_l")

        def make():
            cmp = self.tc_compare(unbox("a->data[i]", elem),
                                  unbox("b->data[i]", elem), elem)
            return "\n".join([
                f"static int {name}(IdList* a, IdList* b) {{",
                "    if (a->len != b->len) return 0;",
                "    for (int i = 0; i < a->len; i++)",
                f"        if (!{cmp}) return 0;",
                "    return 1;",
                "}",
            ])
        return self.tc_helper(name, make)

    def tc_show_helper(self, elem) -> str:
        name = "idtc_show_" + elem.replace("[]", "_l")

        def make():
            return "\n".join([
                f"static void {name}(IdList* a) {{",
                '    fputs("[", stderr);',
                "    for (int i = 0; i < a->len; i++) {",
                '        if (i) fputs(", ", stderr);',
                "        " + self.tc_show(unbox("a->data[i]", elem), elem),
                "    }",
                '    fputs("]", stderr);',
                "}",
            ])
        return self.tc_helper(name, make)

    def tc_value(self, e, want) -> str:
        """C code building a case literal at the id type the function declares.
        The declared type is what the value is built at -- inferring it from the
        literal instead would make `([1, 2]):(...)` on a `word[]` parameter a
        type error about a list nobody wrote."""
        if want.endswith("[]"):
            if not isinstance(e, ArrayLit):
                raise CompileError(e.file, e.line,
                                   f"this case gives {literal_text(e)} where a "
                                   f"{want} is required")
            elem = want[:-2]
            cells = [box(self.tc_value(el, elem), elem) for el in e.elems]
            return "id_list_lit(" + ", ".join([str(len(cells))] + cells) + ")"
        if isinstance(e, ArrayLit):
            raise CompileError(e.file, e.line,
                               f"this case gives a list where a {want} is required")
        code, typ = self.gen_expr(e, None, {})
        if not compatible(want, typ):
            raise CompileError(e.file, e.line,
                               f"this case gives a {typ} where a {want} is required")
        return code

    def gen_test_case(self, fn: FuncDef, idx: int, case: TestCase) -> List[str]:
        if len(case.args) != len(fn.params):
            raise CompileError(case.file, case.line,
                               f"this case passes {len(case.args)} argument(s) to "
                               f"'{fn.name}', which takes {len(fn.params)}")
        out = ["    {"]
        for i, (ptype, _) in enumerate(fn.params):
            out.append(f"        {c_type(ptype)} idtc_a{i} = "
                       f"{self.tc_value(case.args[i], ptype)};")
        call = f"id_{fn.name}(" + ", ".join(f"idtc_a{i}" for i in
                                            range(len(fn.params))) + ")"
        out.append("        id_ctr_time = 0; id_ctr_mem = 0;")
        if fn.rettype == "void":
            out.append(f"        {call};")
        else:
            out.append(f"        {c_type(fn.rettype)} idtc_got = {call};")
        # read the counters before building the expected values: id_list_lit
        # allocates, and that allocation is not the function's.
        out.append("        long long idtc_t = id_ctr_time, idtc_m = id_ctr_mem;")

        if fn.rettype == "void":
            # A void function is judged by what it left in its arguments, which
            # the expected side describes positionally. It may stop early: only
            # the arguments it names are checked.
            if len(case.expected) > len(fn.params):
                raise CompileError(case.file, case.line,
                                   f"this case expects {len(case.expected)} "
                                   f"argument(s) after the call, but '{fn.name}' "
                                   f"takes {len(fn.params)}")
            checked = [(f"idtc_a{i}", fn.params[i][0], e)
                       for i, e in enumerate(case.expected)]
        else:
            if len(case.expected) != 1:
                raise CompileError(case.file, case.line,
                                   f"'{fn.name}' returns {fn.rettype}, so its case "
                                   f"expects exactly one value, not "
                                   f"{len(case.expected)}")
            checked = [("idtc_got", fn.rettype, case.expected[0])]

        conds = []
        for j, (got, typ, e) in enumerate(checked):
            out.append(f"        {c_type(typ)} idtc_e{j} = {self.tc_value(e, typ)};")
            conds.append(self.tc_compare(got, f"idtc_e{j}", typ))
        argtext = ", ".join(literal_text(a) for a in case.args)
        exptext = ", ".join(literal_text(e) for e in case.expected)
        if len(checked) != 1:
            exptext = f"({exptext})"
        out.append(f"        if (!({' && '.join(conds) or '1'})) {{")
        out.append(f"            fputs({c_string(f'{case.file}:{case.line}: test failed: {fn.name}({argtext}) = ')}, stderr);")
        if len(checked) != 1:
            out.append('            fputs("(", stderr);')
        for j, (got, typ, _) in enumerate(checked):
            if j:
                out.append('            fputs(", ", stderr);')
            out.append("            " + self.tc_show(got, typ))
        if len(checked) != 1:
            out.append('            fputs(")", stderr);')
        out.append(f"            fputs({c_string(f', expected {exptext}')}, stderr);")
        out.append('            fputs("\\n", stderr);')
        out.append("            exit(1);")
        out.append("        }")
        out.append(f'        if (idtc_out) fprintf(idtc_out, "%s %d %lld %lld\\n", '
                   f'{c_string(fn.name)}, {idx}, idtc_t, idtc_m);')
        out.append("    }")
        return out

    def gen_test_main(self) -> str:
        """The harness entry point. Counts are written to the file named by
        argv[1] (one line per case), so a case's own printing cannot be mistaken
        for a measurement; failures go to stderr and stop the run."""
        body = []
        for fn in self.funcs.values():
            for idx, case in enumerate(fn.cases):
                body.extend(self.gen_test_case(fn, idx, case))
        protos = [line.split(" {")[0] + ";" for line in
                  (h.split("\n")[0] for h in self.tc_helpers.values())]
        return "\n".join(
            ["/* test harness (idc --tests) */", "static FILE* idtc_out = NULL;"]
            + protos + [""] + list(self.tc_helpers.values()) + [""]
            + ["int main(int argc, char** argv) {",
               "    if (argc > 1) idtc_out = fopen(argv[1], \"w\");"]
            + body
            + ["    if (idtc_out) fclose(idtc_out);", "    return 0;", "}"]) + "\n"


# ---------------------------------------------------------------- LLVM backend
#
# Emits textual LLVM IR for the *user* id functions only; the runtime (list,
# string, and I/O primitives) stays the existing C `RUNTIME` string, compiled
# and linked in by clang alongside the generated .ll. Every id value is either
# an i32 (int), a double (float), or an opaque `ptr` (string, or any list type
# -- lists are always the generic IdList* the runtime already implements, so
# no struct layout needs to be replicated here). Every mutable id variable
# (parameter or local) gets an `alloca` in the function's entry block and is
# read/written via plain load/store -- the same "no SSA/no phi" style clang
# itself emits at -O0, so no phi-node bookkeeping is needed for if/while.
# Real-time I/O and graphics builtins (put/flush/getkey/sleep_ms/ticks) and
# calls to functions not defined anywhere in the program are out of scope for
# this backend and are rejected with a clear error.

def ll_type(typ):
    if typ == "int":
        return "i32"
    if typ == "word":
        return "i64"
    if typ == "float":
        return "double"
    if typ == "void":
        return "void"
    return "ptr"   # string, or any list type


def unescape_id_string(raw: str) -> bytes:
    """The lexer accepts `\\.` (backslash + any char) inside a string literal
    and the C backend just copies `raw` verbatim into C source, relying on the
    C compiler to interpret the escapes. Backends that don't hand the literal
    to a C compiler must interpret them themselves; this covers the common
    escapes and otherwise keeps the escaped character literally."""
    assert raw[0] == '"' and raw[-1] == '"'
    s = raw[1:-1]
    out = bytearray()
    i = 0
    mapping = {"n": 10, "t": 9, "r": 13, "\\": 92, '"': 34, "0": 0}
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            out.append(mapping.get(s[i + 1], ord(s[i + 1])))
            i += 2
        else:
            out.extend(c.encode("utf-8"))
            i += 1
    return bytes(out)


def ll_string_const(bs: bytes):
    """A `c"..."` LLVM string-array literal (with a trailing NUL) for raw bytes
    `bs`, and its byte length (including the NUL)."""
    parts = []
    for b in bs:
        c = chr(b)
        if 32 <= b < 127 and c not in ('"', "\\"):
            parts.append(c)
        else:
            parts.append("\\%02X" % b)
    parts.append("\\00")
    return 'c"' + "".join(parts) + '"', len(bs) + 1


LLVM_RUNTIME_DECLARES = """\
declare ptr @id_list_new()
declare void @id_list_push(ptr, i64)
declare i64 @id_list_get(ptr, i32)
declare void @id_list_set(ptr, i32, i64)
declare i32 @id_list_len(ptr)
declare i64 @id_list_pop(ptr)
declare i64 @id_box_f(double)
declare double @id_unbox_f(i64)
declare i32 @id_to_int(ptr)
declare ptr @id_concat(ptr, ptr)
declare ptr @id_str_of_int(i32)
declare ptr @id_str_of_float(double)
declare void @id_print(ptr)
declare ptr @id_input()
declare ptr @id_read_all()
declare i32 @id_len(ptr)
declare i32 @id_charat(ptr, i32)
declare ptr @id_chr(i32)
declare i32 @strcmp(ptr, ptr)
declare i32 @id_idiv(i32, i32)
declare i32 @id_imod(i32, i32)
declare i64 @id_shl(i64, i64)
declare i64 @id_sar(i64, i64)
declare ptr @id_str_of_word(i64)
declare i64 @id_sdiv(i64, i64)
declare i64 @id_smod(i64, i64)
declare i64 @id_mem_alloc(i64)
declare i64 @id_mem_size()
declare i64 @id_peek8(i64)
declare i64 @id_peek16(i64)
declare i64 @id_peek32(i64)
declare i64 @id_peek64(i64)
declare void @id_poke8(i64, i64)
declare void @id_poke16(i64, i64)
declare void @id_poke32(i64, i64)
declare void @id_poke64(i64, i64)
declare i64 @id_udiv(i64, i64)
declare i64 @id_umod(i64, i64)
declare i64 @id_ult(i64, i64)
declare i64 @id_ushr(i64, i64)
declare ptr @id_str_of_mem(i64, i64)
declare i64 @id_mem_of_str(ptr)
"""

# Real-time terminal I/O is C-only on every target: put/flush/getkey/sleep_ms
# and ticks have no LLVM- or WASM-portable representation.
REALTIME_IO_BUILTINS = ("put", "flush", "getkey", "sleep_ms", "ticks")

UNSUPPORTED_BUILTINS_WASM = REALTIME_IO_BUILTINS

# The LLVM backend links the same C RUNTIME the C target does, so the flat
# store and word arithmetic are just calls to its helpers -- only real-time
# I/O stays out of scope.
UNSUPPORTED_BUILTINS_LLVM = REALTIME_IO_BUILTINS


def unsupported_builtin_msg(name) -> str:
    what = ("real-time I/O is C-only" if name in REALTIME_IO_BUILTINS
            else "the flat store and word arithmetic are C-only")
    return (f"builtin '{name}' is not supported for this --target ({what})")


def reject_word_type(funcs, target):
    """WASM's linear memory model doesn't yet have a mapping for `word` and
    the flat store, so a program using `word` there is rejected up front with
    a clear message rather than crashing somewhere inside instruction
    selection."""
    for fn in funcs:
        sites = [(fn.rettype, fn.file, fn.line)]
        sites += [(t, fn.file, fn.line) for t, _ in fn.params]
        sites += [(st.typ, st.file, st.line)
                  for st in walk_stmts(fn.body) if isinstance(st, DeclStmt)]
        for typ, file, line in sites:
            if typ.startswith("word"):
                raise CompileError(file, line,
                                   f"type 'word' is not supported for "
                                   f"--target {target} (it is C-only)")


class LLVMBackend:
    """Emits one LLVM IR module (as text) for a checked program. Shares the
    Compiler's checked tables (funcs/exported/var_owner) and re-derives typing
    the same way Compiler.gen_expr does, just producing IR instructions
    instead of C code; the remaining semantic checks (variable resolution,
    type compatibility) that Compiler's own codegen performs inline are
    therefore performed here too, via the same helper methods."""

    def __init__(self, compiler: Compiler):
        self.compiler = compiler
        self.str_table = {}   # bytes -> "@.strN"

    # -- string constants (module-wide, discovered while emitting bodies)

    def str_const(self, raw: str) -> str:
        bs = unescape_id_string(raw)
        name = self.str_table.get(bs)
        if name is None:
            name = f"@.str{len(self.str_table)}"
            self.str_table[bs] = name
        return name

    # -- per-function state

    def new_tmp(self) -> str:
        self.tmp_n += 1
        return f"%t{self.tmp_n}"

    def new_lbl_id(self) -> int:
        self.lbl_n += 1
        return self.lbl_n

    def emit(self, line: str):
        self.lines.append(line)

    def read_var(self, name, typ):
        t = self.new_tmp()
        if name in self.compiler.exported:
            self.emit(f"  {t} = load {ll_type(typ)}, ptr @g_{name}")
        else:
            self.emit(f"  {t} = load {ll_type(typ)}, ptr %v_{name}")
        return t

    def write_var(self, name, val, typ):
        if name in self.compiler.exported:
            self.emit(f"  store {ll_type(typ)} {val}, ptr @g_{name}")
        else:
            self.emit(f"  store {ll_type(typ)} {val}, ptr %v_{name}")

    def coerce(self, val, have, want):
        if have == want:
            return val
        if have == "int" and want == "word":
            t = self.new_tmp()
            self.emit(f"  {t} = sext i32 {val} to i64")
            return t
        if have == "int" and want == "float":
            t = self.new_tmp()
            self.emit(f"  {t} = sitofp i32 {val} to double")
            return t
        if have == "word" and want == "float":
            t = self.new_tmp()
            self.emit(f"  {t} = sitofp i64 {val} to double")
            return t
        return val

    def box(self, val, typ):
        if typ == "int":
            t = self.new_tmp()
            self.emit(f"  {t} = sext i32 {val} to i64")
            return t
        if typ == "word":
            return val
        if typ == "float":
            t = self.new_tmp()
            self.emit(f"  {t} = call i64 @id_box_f(double {val})")
            return t
        t = self.new_tmp()
        self.emit(f"  {t} = ptrtoint ptr {val} to i64")
        return t

    def unbox(self, val, typ):
        if typ == "int":
            t = self.new_tmp()
            self.emit(f"  {t} = trunc i64 {val} to i32")
            return t
        if typ == "word":
            return val
        if typ == "float":
            t = self.new_tmp()
            self.emit(f"  {t} = call double @id_unbox_f(i64 {val})")
            return t
        t = self.new_tmp()
        self.emit(f"  {t} = inttoptr i64 {val} to ptr")
        return t

    def to_i1(self, val, typ):
        t = self.new_tmp()
        if typ == "float":
            self.emit(f"  {t} = fcmp one double {val}, 0.0")
        elif typ == "int":
            self.emit(f"  {t} = icmp ne i32 {val}, 0")
        elif typ == "word":
            self.emit(f"  {t} = icmp ne i64 {val}, 0")
        else:
            self.emit(f"  {t} = icmp ne ptr {val}, null")
        return t

    def to_string(self, val, typ, e):
        if typ == "string":
            return val
        if typ == "int":
            t = self.new_tmp()
            self.emit(f"  {t} = call ptr @id_str_of_int(i32 {val})")
            return t
        if typ == "word":
            t = self.new_tmp()
            self.emit(f"  {t} = call ptr @id_str_of_word(i64 {val})")
            return t
        if typ == "float":
            t = self.new_tmp()
            self.emit(f"  {t} = call ptr @id_str_of_float(double {val})")
            return t
        raise CompileError(e.file, e.line, f"cannot convert {typ} to string")

    # -- function codegen

    def gen_function(self, fn: FuncDef) -> str:
        self.env = self.compiler.build_env(fn)
        self.lines = []
        self.tmp_n = 0
        self.lbl_n = 0
        params_sig = ", ".join(f"{ll_type(t)} %arg_{n}" for t, n in fn.params)
        header = f"define {ll_type(fn.rettype)} @id_{fn.name}({params_sig}) {{"
        self.emit("entry:")
        for name, typ in self.env.items():
            if name in self.compiler.exported:
                continue
            self.emit(f"  %v_{name} = alloca {ll_type(typ)}")
        for ptype, pname in fn.params:
            self.emit(f"  store {ll_type(ptype)} %arg_{pname}, ptr %v_{pname}")
        for stmt in fn.body:
            self.gen_stmt(stmt, fn)
        if fn.rettype == "void":
            self.emit("  ret void")
        else:
            val, typ = self.gen_expr(fn.retexpr, fn, fn.rettype)
            if not compatible(fn.rettype, typ):
                raise CompileError(fn.retexpr.file, fn.retexpr.line,
                                   f"function '{fn.name}' returns {fn.rettype} but "
                                   f"the expression has type {typ}")
            val = self.coerce(val, typ, fn.rettype)
            self.emit(f"  ret {ll_type(fn.rettype)} {val}")
        return header + "\n" + "\n".join(self.lines) + "\n}\n"

    def gen_stmt(self, stmt, fn):
        if isinstance(stmt, DeclStmt):
            val, typ = self.gen_expr(stmt.expr, fn, stmt.typ)
            if not compatible(stmt.typ, typ):
                raise CompileError(stmt.file, stmt.line,
                                   f"cannot initialize {stmt.typ} '{stmt.name}' "
                                   f"with a {typ} value")
            val = self.coerce(val, typ, stmt.typ)
            self.write_var(stmt.name, val, stmt.typ)
            return
        if isinstance(stmt, AssignStmt):
            if stmt.name not in self.env:
                self.compiler.explain_bad_var(stmt.name, fn, stmt.file, stmt.line)
            want = self.env[stmt.name]
            val, typ = self.gen_expr(stmt.expr, fn, want)
            if not compatible(want, typ):
                raise CompileError(stmt.file, stmt.line,
                                   f"cannot assign a {typ} value to {want} "
                                   f"'{stmt.name}'")
            val = self.coerce(val, typ, want)
            self.write_var(stmt.name, val, want)
            return
        if isinstance(stmt, IndexAssignStmt):
            base, btyp = self.gen_expr(stmt.base, fn)
            if not btyp.endswith("[]"):
                raise CompileError(stmt.file, stmt.line, f"cannot index a {btyp}")
            idx, ityp = self.gen_expr(stmt.index, fn)
            if ityp != "int":
                raise CompileError(stmt.file, stmt.line,
                                   f"list index must be int, got {ityp}")
            elem = btyp[:-2]
            val, typ = self.gen_expr(stmt.expr, fn, elem)
            if not compatible(elem, typ):
                raise CompileError(stmt.file, stmt.line,
                                   f"cannot store a {typ} into a {btyp}")
            val = self.coerce(val, typ, elem)
            boxed = self.box(val, elem)
            self.emit(f"  call void @id_list_set(ptr {base}, i32 {idx}, i64 {boxed})")
            return
        if isinstance(stmt, IfStmt):
            end_l = f"if.end{self.new_lbl_id()}"
            self.gen_if_chain(stmt, fn, end_l)
            self.emit(f"{end_l}:")
            return
        if isinstance(stmt, WhileStmt):
            n = self.new_lbl_id()
            cond_l, body_l, end_l = f"while.cond{n}", f"while.body{n}", f"while.end{n}"
            self.emit(f"  br label %{cond_l}")
            self.emit(f"{cond_l}:")
            cond, ctyp = self.gen_expr(stmt.cond, fn)
            if ctyp == "void":
                raise CompileError(stmt.file, stmt.line, "loop condition has type void")
            i1 = self.to_i1(cond, ctyp)
            self.emit(f"  br i1 {i1}, label %{body_l}, label %{end_l}")
            self.emit(f"{body_l}:")
            for s in stmt.body:
                self.gen_stmt(s, fn)
            self.emit(f"  br label %{cond_l}")
            self.emit(f"{end_l}:")
            return
        if isinstance(stmt, ExprStmt):
            self.gen_expr(stmt.expr, fn)
            return
        raise AssertionError(stmt)

    def gen_if_chain(self, stmt: IfStmt, fn, end_label):
        n = self.new_lbl_id()
        then_l = f"if.then{n}"
        cond, ctyp = self.gen_expr(stmt.cond, fn)
        if ctyp == "void":
            raise CompileError(stmt.file, stmt.line, "condition has type void")
        i1 = self.to_i1(cond, ctyp)
        if stmt.els is None:
            else_l = end_label
        else:
            else_l = f"if.else{n}"
        self.emit(f"  br i1 {i1}, label %{then_l}, label %{else_l}")
        self.emit(f"{then_l}:")
        for s in stmt.then:
            self.gen_stmt(s, fn)
        self.emit(f"  br label %{end_label}")
        if stmt.els is None:
            return
        self.emit(f"{else_l}:")
        if isinstance(stmt.els, IfStmt):
            self.gen_if_chain(stmt.els, fn, end_label)
        else:
            for s in stmt.els:
                self.gen_stmt(s, fn)
            self.emit(f"  br label %{end_label}")

    # -- expressions: returns (ir_value, id_type)

    def gen_expr(self, e, fn, expected=None):
        if isinstance(e, IntLit):
            # A literal too big for a 32-bit int is a word, not a silently
            # truncated int -- matching the C backend's reading of the same
            # literal (idc.py's Compiler.gen_expr).
            if int(e.value) > 0x7fffffff:
                return e.value, "word"
            return e.value, "int"
        if isinstance(e, FloatLit):
            return e.value, "float"
        if isinstance(e, StrLit):
            return self.str_const(e.raw), "string"
        if isinstance(e, VarRef):
            if e.name not in self.env:
                self.compiler.explain_bad_var(e.name, fn, e.file, e.line)
            typ = self.env[e.name]
            return self.read_var(e.name, typ), typ
        if isinstance(e, ImportRef):
            if e.name not in self.compiler.exported:
                if e.name in self.compiler.var_owner:
                    owner = self.compiler.var_owner[e.name][0]
                    raise CompileError(e.file, e.line,
                                       f"variable '{e.name}' (in function '{owner}') "
                                       f"is not exported")
                raise CompileError(e.file, e.line,
                                   f"no exported variable named '{e.name}'")
            typ = self.compiler.exported[e.name][0]
            return self.read_var(e.name, typ), typ
        if isinstance(e, IndexExpr):
            base, btyp = self.gen_expr(e.base, fn)
            if not btyp.endswith("[]"):
                raise CompileError(e.file, e.line, f"cannot index a {btyp}")
            idx, ityp = self.gen_expr(e.index, fn)
            if ityp != "int":
                raise CompileError(e.file, e.line, f"array index must be int, got {ityp}")
            elem = btyp[:-2]
            t = self.new_tmp()
            self.emit(f"  {t} = call i64 @id_list_get(ptr {base}, i32 {idx})")
            return self.unbox(t, elem), elem
        if isinstance(e, ArrayLit):
            if not e.elems:
                if expected is None or not expected.endswith("[]"):
                    raise CompileError(e.file, e.line,
                                       "an empty list literal needs a known list "
                                       "type here (e.g. on a typed declaration)")
                t = self.new_tmp()
                self.emit(f"  {t} = call ptr @id_list_new()")
                return t, expected
            raw, etyp = [], None
            for el in e.elems:
                val, typ = self.gen_expr(el, fn)
                if etyp is None:
                    etyp = typ
                elif not compatible(etyp, typ):
                    raise CompileError(el.file, el.line,
                                       f"list element has type {typ}, expected {etyp}")
                if is_numeric(etyp) and typ == "float":
                    etyp = "float"
                raw.append((val, typ))
            t = self.new_tmp()
            self.emit(f"  {t} = call ptr @id_list_new()")
            for val, typ in raw:
                val = self.coerce(val, typ, etyp)
                boxed = self.box(val, etyp)
                self.emit(f"  call void @id_list_push(ptr {t}, i64 {boxed})")
            return t, etyp + "[]"
        if isinstance(e, CallExpr):
            return self.gen_call(e, fn)
        if isinstance(e, UnOp):
            val, typ = self.gen_expr(e.operand, fn)
            if e.op == "-":
                if not is_numeric(typ):
                    raise CompileError(e.file, e.line, f"cannot negate a {typ}")
                t = self.new_tmp()
                if typ == "int":
                    self.emit(f"  {t} = sub i32 0, {val}")
                elif typ == "word":
                    self.emit(f"  {t} = sub i64 0, {val}")
                else:
                    self.emit(f"  {t} = fneg double {val}")
                return t, typ
            if e.op == "!":
                if not is_integral(typ):
                    raise CompileError(e.file, e.line, f"cannot apply '!' to a {typ}")
                width = "i64" if typ == "word" else "i32"
                t1 = self.new_tmp()
                self.emit(f"  {t1} = icmp eq {width} {val}, 0")
                t2 = self.new_tmp()
                self.emit(f"  {t2} = zext i1 {t1} to i32")
                return t2, "int"
            if e.op == "~":
                if not is_integral(typ):
                    raise CompileError(e.file, e.line, f"cannot apply '~' to a {typ}")
                width = "i64" if typ == "word" else "i32"
                t = self.new_tmp()
                self.emit(f"  {t} = xor {width} {val}, -1")
                return t, typ
            raise AssertionError(e.op)
        if isinstance(e, BinOp):
            return self.gen_binop(e, fn)
        raise AssertionError(e)

    def gen_binop(self, e: BinOp, fn):
        lc, lt = self.gen_expr(e.left, fn)
        rc, rt = self.gen_expr(e.right, fn)
        op = e.op
        if op == "+" and (lt == "string" or rt == "string"):
            ls = self.to_string(lc, lt, e.left)
            rs = self.to_string(rc, rt, e.right)
            t = self.new_tmp()
            self.emit(f"  {t} = call ptr @id_concat(ptr {ls}, ptr {rs})")
            return t, "string"
        if op in ("==", "!="):
            if lt == "string" and rt == "string":
                t1 = self.new_tmp()
                self.emit(f"  {t1} = call i32 @strcmp(ptr {lc}, ptr {rc})")
                cmp = "eq" if op == "==" else "ne"
                t2 = self.new_tmp()
                self.emit(f"  {t2} = icmp {cmp} i32 {t1}, 0")
                t3 = self.new_tmp()
                self.emit(f"  {t3} = zext i1 {t2} to i32")
                return t3, "int"
            if is_numeric(lt) and is_numeric(rt):
                common = arith_result(lt, rt)
                lc2 = self.coerce(lc, lt, common)
                rc2 = self.coerce(rc, rt, common)
                width = {"int": "i32", "word": "i64", "float": "double"}[common]
                t1 = self.new_tmp()
                if common == "float":
                    cmp = "oeq" if op == "==" else "one"
                    self.emit(f"  {t1} = fcmp {cmp} {width} {lc2}, {rc2}")
                else:
                    cmp = "eq" if op == "==" else "ne"
                    self.emit(f"  {t1} = icmp {cmp} {width} {lc2}, {rc2}")
                t2 = self.new_tmp()
                self.emit(f"  {t2} = zext i1 {t1} to i32")
                return t2, "int"
            raise CompileError(e.file, e.line, f"cannot compare {lt} with {rt}")
        if op in ("<", "<=", ">", ">="):
            if is_numeric(lt) and is_numeric(rt):
                common = arith_result(lt, rt)
                lc2 = self.coerce(lc, lt, common)
                rc2 = self.coerce(rc, rt, common)
                width = {"int": "i32", "word": "i64", "float": "double"}[common]
                imap = {"<": "slt", "<=": "sle", ">": "sgt", ">=": "sge"}
                fmap = {"<": "olt", "<=": "ole", ">": "ogt", ">=": "oge"}
                t1 = self.new_tmp()
                if common == "float":
                    self.emit(f"  {t1} = fcmp {fmap[op]} {width} {lc2}, {rc2}")
                else:
                    self.emit(f"  {t1} = icmp {imap[op]} {width} {lc2}, {rc2}")
                t2 = self.new_tmp()
                self.emit(f"  {t2} = zext i1 {t1} to i32")
                return t2, "int"
            raise CompileError(e.file, e.line, f"cannot order {lt} and {rt}")
        if op in ("&&", "||"):
            if is_integral(lt) and is_integral(rt):
                lb = self.to_i1(lc, lt)
                rb = self.to_i1(rc, rt)
                t1 = self.new_tmp()
                instr = "and" if op == "&&" else "or"
                self.emit(f"  {t1} = {instr} i1 {lb}, {rb}")
                t2 = self.new_tmp()
                self.emit(f"  {t2} = zext i1 {t1} to i32")
                return t2, "int"
            raise CompileError(e.file, e.line, f"'{op}' requires int operands")
        if op in ("+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"):
            if op in ("&", "|", "^", "<<", ">>") and not (is_integral(lt) and is_integral(rt)):
                raise CompileError(e.file, e.line,
                                   f"'{op}' requires int or word operands, got {lt} and {rt}")
            if is_numeric(lt) and is_numeric(rt):
                if op == "%" and (lt == "float" or rt == "float"):
                    raise CompileError(e.file, e.line, "'%' requires int operands")
                res = arith_result(lt, rt)
                lc2 = self.coerce(lc, lt, res)
                rc2 = self.coerce(rc, rt, res)
                t = self.new_tmp()
                if res in ("int", "word"):
                    # Division and shifts go through the same runtime helpers
                    # the C target uses, because a raw `sdiv` by zero is a
                    # SIGFPE and a raw `shl` by 32 is poison -- two behaviours
                    # docs/SPEC.md gives defined answers for. The helpers are
                    # in the C RUNTIME this target already links.
                    width = "i32" if res == "int" else "i64"
                    if op in ("/", "%"):
                        if res == "int":
                            helper = "id_idiv" if op == "/" else "id_imod"
                        else:
                            helper = "id_sdiv" if op == "/" else "id_smod"
                        self.emit(f"  {t} = call {width} @{helper}"
                                  f"({width} {lc2}, {width} {rc2})")
                        return t, res
                    if op in ("<<", ">>"):
                        helper = "id_shl" if op == "<<" else "id_sar"
                        if res == "int":
                            a64, n64, r64 = (self.new_tmp(), self.new_tmp(),
                                             self.new_tmp())
                            self.emit(f"  {a64} = sext i32 {lc2} to i64")
                            self.emit(f"  {n64} = sext i32 {rc2} to i64")
                            self.emit(f"  {r64} = call i64 @{helper}"
                                      f"(i64 {a64}, i64 {n64})")
                            self.emit(f"  {t} = trunc i64 {r64} to i32")
                        else:
                            self.emit(f"  {t} = call i64 @{helper}"
                                      f"(i64 {lc2}, i64 {rc2})")
                        return t, res
                    instr = {"+": "add", "-": "sub", "*": "mul",
                             "&": "and", "|": "or", "^": "xor"}[op]
                    self.emit(f"  {t} = {instr} {width} {lc2}, {rc2}")
                else:
                    instr = {"+": "fadd", "-": "fsub", "*": "fmul", "/": "fdiv"}[op]
                    self.emit(f"  {t} = {instr} double {lc2}, {rc2}")
                return t, res
            raise CompileError(e.file, e.line, f"cannot apply '{op}' to {lt} and {rt}")
        raise AssertionError(op)

    def gen_call(self, e: CallExpr, fn):
        name = e.name
        if name == "print":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "print takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn)
            s = self.to_string(val, typ, e)
            self.emit(f"  call void @id_print(ptr {s})")
            return "0", "void"
        if name == "input":
            if e.args:
                raise CompileError(e.file, e.line, "input takes no arguments")
            t = self.new_tmp()
            self.emit(f"  {t} = call ptr @id_input()")
            return t, "string"
        if name == "read_all":
            if e.args:
                raise CompileError(e.file, e.line, "read_all takes no arguments")
            t = self.new_tmp()
            self.emit(f"  {t} = call ptr @id_read_all()")
            return t, "string"
        if name == "len":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "len takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn)
            t = self.new_tmp()
            if typ == "string":
                self.emit(f"  {t} = call i32 @id_len(ptr {val})")
            elif typ.endswith("[]"):
                self.emit(f"  {t} = call i32 @id_list_len(ptr {val})")
            else:
                raise CompileError(e.file, e.line,
                                   f"len expects a string or list, got {typ}")
            return t, "int"
        if name == "push":
            if len(e.args) != 2:
                raise CompileError(e.file, e.line, "push takes exactly two arguments")
            lc, lt = self.gen_expr(e.args[0], fn)
            if not lt.endswith("[]"):
                raise CompileError(e.file, e.line, f"push expects a list, got {lt}")
            elem = lt[:-2]
            vc, vt = self.gen_expr(e.args[1], fn, elem)
            if not compatible(elem, vt):
                raise CompileError(e.file, e.line, f"cannot push a {vt} onto a {lt}")
            vc = self.coerce(vc, vt, elem)
            boxed = self.box(vc, elem)
            self.emit(f"  call void @id_list_push(ptr {lc}, i64 {boxed})")
            return "0", "void"
        if name == "pop":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "pop takes exactly one argument")
            lc, lt = self.gen_expr(e.args[0], fn)
            if not lt.endswith("[]"):
                raise CompileError(e.file, e.line, f"pop expects a list, got {lt}")
            elem = lt[:-2]
            t = self.new_tmp()
            self.emit(f"  {t} = call i64 @id_list_pop(ptr {lc})")
            return self.unbox(t, elem), elem
        if name == "to_int":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "to_int takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn)
            if typ != "string":
                raise CompileError(e.file, e.line, f"to_int expects a string, got {typ}")
            t = self.new_tmp()
            self.emit(f"  {t} = call i32 @id_to_int(ptr {val})")
            return t, "int"
        if name == "charat":
            if len(e.args) != 2:
                raise CompileError(e.file, e.line, "charat takes exactly two arguments")
            sc, st = self.gen_expr(e.args[0], fn)
            ic, it = self.gen_expr(e.args[1], fn)
            if st != "string":
                raise CompileError(e.file, e.line, f"charat expects a string, got {st}")
            if it != "int":
                raise CompileError(e.file, e.line, f"charat index must be int, got {it}")
            t = self.new_tmp()
            self.emit(f"  {t} = call i32 @id_charat(ptr {sc}, i32 {ic})")
            return t, "int"
        if name == "chr":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "chr takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn)
            if typ != "int":
                raise CompileError(e.file, e.line, f"chr expects an int, got {typ}")
            t = self.new_tmp()
            self.emit(f"  {t} = call ptr @id_chr(i32 {val})")
            return t, "string"
        if name in STORE_BUILTINS or name in WORD_BUILTINS:
            return self.gen_systems_call(e, fn)
        if name == "str_of_mem":
            if len(e.args) != 2:
                raise CompileError(e.file, e.line,
                                   "str_of_mem takes exactly two arguments")
            ac, at = self.gen_expr(e.args[0], fn)
            nc, nt = self.gen_expr(e.args[1], fn)
            if not is_integral(at) or not is_integral(nt):
                raise CompileError(e.file, e.line,
                                   "str_of_mem takes an address and a length")
            a64 = self.coerce(ac, at, "word")
            n64 = self.coerce(nc, nt, "word")
            t = self.new_tmp()
            self.emit(f"  {t} = call ptr @id_str_of_mem(i64 {a64}, i64 {n64})")
            return t, "string"
        if name == "mem_of_str":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line,
                                   "mem_of_str takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn)
            if typ != "string":
                raise CompileError(e.file, e.line,
                                   f"mem_of_str expects a string, got {typ}")
            t = self.new_tmp()
            self.emit(f"  {t} = call i64 @id_mem_of_str(ptr {val})")
            return t, "word"
        if name in UNSUPPORTED_BUILTINS_LLVM:
            raise CompileError(e.file, e.line, unsupported_builtin_msg(name))
        args = [self.gen_expr(a, fn) for a in e.args]
        callee = self.compiler.funcs.get(name)
        if callee is None:
            raise CompileError(e.file, e.line,
                               f"call to external function '{name}' is not "
                               f"supported for this --target (only functions "
                               f"defined in the program are supported)."
                               f"{builtin_hint(name)}")
        if len(args) != len(callee.params):
            raise CompileError(e.file, e.line,
                               f"function '{name}' takes {len(callee.params)} "
                               f"argument(s), got {len(args)}")
        argstrs = []
        for (ptype, pname), (val, typ), arg in zip(callee.params, args, e.args):
            if not compatible(ptype, typ):
                raise CompileError(arg.file, arg.line,
                                   f"argument '{pname}' of '{name}' expects "
                                   f"{ptype}, got {typ}")
            val = self.coerce(val, typ, ptype)
            argstrs.append(f"{ll_type(ptype)} {val}")
        if callee.rettype == "void":
            self.emit(f"  call void @id_{name}({', '.join(argstrs)})")
            return "0", "void"
        t = self.new_tmp()
        self.emit(f"  {t} = call {ll_type(callee.rettype)} @id_{name}({', '.join(argstrs)})")
        return t, callee.rettype

    def gen_systems_call(self, e: CallExpr, fn) -> Tuple[str, str]:
        """The flat-store and unsigned-word builtins. They all take and
        return machine words, so one shared shape covers every one of them --
        the same helpers the C target links, called with i64 arguments."""
        arity, helper, restype = (STORE_BUILTINS.get(e.name)
                                  or WORD_BUILTINS[e.name])
        if len(e.args) != arity:
            plural = "" if arity == 1 else "s"
            raise CompileError(e.file, e.line,
                               f"{e.name} takes exactly {arity} argument{plural}, "
                               f"got {len(e.args)}")
        argstrs = []
        for arg in e.args:
            val, typ = self.gen_expr(arg, fn)
            if not is_integral(typ):
                raise CompileError(arg.file, arg.line,
                                   f"{e.name} expects int or word arguments, "
                                   f"got {typ}")
            argstrs.append(f"i64 {self.coerce(val, typ, 'word')}")
        if restype == "void":
            self.emit(f"  call void @{helper}({', '.join(argstrs)})")
            return "0", "void"
        t = self.new_tmp()
        self.emit(f"  {t} = call i64 @{helper}({', '.join(argstrs)})")
        if restype == "int":
            t2 = self.new_tmp()
            self.emit(f"  {t2} = trunc i64 {t} to i32")
            return t2, "int"
        return t, restype

    # -- C-ABI entrypoint (marshals argv into an id string[] the same way the
    #    C backend's gen_entrypoint does, then calls id_main)

    def gen_entrypoint(self) -> str:
        m = self.compiler.funcs.get("main")
        if m is None:
            return ""
        ptypes = [t for t, _ in m.params]
        lines = ["define i32 @main(i32 %argc, ptr %argv) {", "entry:"]
        if ptypes == ["int", "string[]"]:
            lines += [
                "  %args = call ptr @id_list_new()",
                "  %i.addr = alloca i32",
                "  store i32 0, ptr %i.addr",
                "  br label %loop.cond",
                "loop.cond:",
                "  %i.val = load i32, ptr %i.addr",
                "  %cmp = icmp slt i32 %i.val, %argc",
                "  br i1 %cmp, label %loop.body, label %loop.end",
                "loop.body:",
                "  %idx64 = sext i32 %i.val to i64",
                "  %elemptr = getelementptr ptr, ptr %argv, i64 %idx64",
                "  %s = load ptr, ptr %elemptr",
                "  %sbox = ptrtoint ptr %s to i64",
                "  call void @id_list_push(ptr %args, i64 %sbox)",
                "  %i.next = add i32 %i.val, 1",
                "  store i32 %i.next, ptr %i.addr",
                "  br label %loop.cond",
                "loop.end:",
            ]
            call = "@id_main(i32 %argc, ptr %args)"
        elif ptypes == []:
            call = "@id_main()"
        else:
            raise CompileError(m.file, m.line,
                               "main must take (int, string[]) or no parameters")
        if m.rettype == "int":
            lines.append(f"  %r = call i32 {call}")
            lines.append("  ret i32 %r")
        else:
            lines.append(f"  call void {call}")
            lines.append("  ret i32 0")
        lines.append("}")
        return "\n".join(lines) + "\n"

    def emit_module(self) -> str:
        func_bodies = [self.gen_function(fn) for fn in self.compiler.funcs.values()]

        out = ['target triple = "x86_64-unknown-linux-gnu"', ""]
        out.append(LLVM_RUNTIME_DECLARES)

        if self.compiler.exported:
            out.append("; exported variables")
            for name, (typ, owner) in self.compiler.exported.items():
                zero = {"int": "0", "word": "0", "float": "0.0"}.get(typ, "null")
                out.append(f"@g_{name} = global {ll_type(typ)} {zero}  ; exported by {owner}()")
            out.append("")

        if self.str_table:
            out.append("; string constants")
            for bs, name in self.str_table.items():
                content, size = ll_string_const(bs)
                out.append(f"{name} = private unnamed_addr constant [{size} x i8] {content}")
            out.append("")

        out.extend(func_bodies)
        out.append(self.gen_entrypoint())
        return "\n".join(out) + "\n"


# ---------------------------------------------------------------- WASM backend
#
# Emits a self-contained WebAssembly module as WAT text, assembled with
# wat2wasm and run as a WASI "command" module under wasmtime. Unlike the LLVM
# backend, this does NOT reuse the C `RUNTIME` -- linking real libc into
# wasm32 needs a wasi-sysroot, which isn't available in this environment (only
# llvm/clang/lld/wabt/wasmtime are provided, no wasi-sysroot), so every runtime
# primitive (the growable list, string ops, and I/O) is hand-written here in
# WAT, using a single linear memory with a bump allocator (nothing is ever
# freed -- the same lifetime model the C RUNTIME already uses) and the
# `wasi_snapshot_preview1` imports directly (fd_write/fd_read/args_*/proc_exit)
# instead of libc. An id value is represented as: int -> i32, float -> f64,
# string / any list type -> i32 (an address in linear memory: a NUL-terminated
# byte string, or a 12-byte IdList header [len:i32][cap:i32][data-ptr:i32]).
# List cells are i64 (matching the C runtime's `long long` cells).
#
# WAT's structured `if`/`loop` line up with id's if/while directly, so (unlike
# the LLVM backend) no manual basic-block/label plumbing is needed for control
# flow; expressions are emitted as folded (fully nested) s-expressions, mirroring
# the C backend's approach of returning a single self-contained code string per
# expression.
#
# Real-time I/O/graphics builtins and calls to functions not defined anywhere
# in the program are out of scope (same as the LLVM backend). Converting a
# float to a string (print/concat) is also not implemented for this target.

# fixed low-memory scratch addresses (never touched by the bump allocator)
_IOV0_PTR, _IOV0_LEN, _IOV1_PTR, _IOV1_LEN = 0, 4, 8, 12
_NWRITTEN = 16
_NEWLINE_BYTE = 20
_ARGC_SCRATCH, _BUFSIZE_SCRATCH = 24, 28
_READ_IOV_PTR, _READ_IOV_LEN, _READ_NREAD, _READ_BYTE = 32, 36, 40, 44
_STROI_BUF = 64        # 32 bytes, for id_str_of_int's digit scratch
_INPUT_BUF = 128       # 1024 bytes, input()'s line buffer

# fixed fatal-error message bytes (mirroring the C RUNTIME's stderr messages)
# for the wasm target's own bounds/allocation traps -- laid out in the same
# never-touched-by-the-bump-allocator region as the scratch addresses above.
_MSG_IDX_PRE = b"id: index "
_MSG_IDX_MID = b" out of bounds (len "
_MSG_IDX_END = b")\n"
_MSG_POP = b"id: pop from empty list\n"
_MSG_OOM = b"id: out of memory\n"
_MSG_CAP = b"id: list capacity overflow\n"
# The four docs/SPEC.md §7 conditions arithmetic can raise. Without them a
# `/` by zero was an opaque engine trap (exit 134) where the C target prints
# a line and exits 1, and a shift past the width was silently count-masked.
_MSG_DIV0 = b"id: division by zero\n"
_MSG_MOD0 = b"id: remainder by zero\n"
_MSG_DIVOV = b"id: division overflow\n"
_MSG_SHNEG = b"id: shift by a negative amount\n"
_MSG_STORE_PRE = b"id: store address "
_MSG_STORE_MID = b" out of range (size "
_MSG_STORE_END = b")\n"
_MSG_NEGALLOC = b"id: negative allocation size\n"
_MSG_ALLOCOV = b"id: allocation size overflow\n"
_MSG_NEGLEN = b"id: negative length\n"

_MSG_IDX_PRE_ADDR = 1152
_MSG_IDX_MID_ADDR = _MSG_IDX_PRE_ADDR + len(_MSG_IDX_PRE)
_MSG_IDX_END_ADDR = _MSG_IDX_MID_ADDR + len(_MSG_IDX_MID)
_MSG_POP_ADDR = _MSG_IDX_END_ADDR + len(_MSG_IDX_END)
_MSG_OOM_ADDR = _MSG_POP_ADDR + len(_MSG_POP)
_MSG_CAP_ADDR = _MSG_OOM_ADDR + len(_MSG_OOM)
_MSG_DIV0_ADDR = _MSG_CAP_ADDR + len(_MSG_CAP)
_MSG_MOD0_ADDR = _MSG_DIV0_ADDR + len(_MSG_DIV0)
_MSG_DIVOV_ADDR = _MSG_MOD0_ADDR + len(_MSG_MOD0)
_MSG_SHNEG_ADDR = _MSG_DIVOV_ADDR + len(_MSG_DIVOV)
_MSG_STORE_PRE_ADDR = _MSG_SHNEG_ADDR + len(_MSG_SHNEG)
_MSG_STORE_MID_ADDR = _MSG_STORE_PRE_ADDR + len(_MSG_STORE_PRE)
_MSG_STORE_END_ADDR = _MSG_STORE_MID_ADDR + len(_MSG_STORE_MID)
_MSG_NEGALLOC_ADDR = _MSG_STORE_END_ADDR + len(_MSG_STORE_END)
_MSG_ALLOCOV_ADDR = _MSG_NEGALLOC_ADDR + len(_MSG_NEGALLOC)
_MSG_NEGLEN_ADDR = _MSG_ALLOCOV_ADDR + len(_MSG_ALLOCOV)

_RESERVED_END = 2048   # string constants (and then the heap) start here
assert _MSG_NEGLEN_ADDR + len(_MSG_NEGLEN) <= _RESERVED_END

_STORE_BASE = 1 << 20


def wat_bytes_literal(bs: bytes) -> str:
    """A WAT `(data ...)` string literal for raw bytes `bs`, NUL-terminated."""
    out = []
    for b in bs:
        c = chr(b)
        if b == 0x22:
            out.append('\\22')
        elif b == 0x5c:
            out.append('\\5c')
        elif 32 <= b < 127:
            out.append(c)
        else:
            out.append("\\%02x" % b)
    out.append("\\00")
    return "".join(out)


def wasm_runtime_funcs() -> str:
    return f"""\
  ;; ---- fatal errors: write a message to stderr (fd 2) and exit(1). Unlike a
  ;; bare `unreachable` (which the wasm engine reports as an opaque trap),
  ;; this gives the same clear "id: ..." message and exit code the C target
  ;; produces for the same conditions. The `unreachable` after `proc_exit`
  ;; is dead in practice (proc_exit terminates the instance) but keeps every
  ;; branch that calls these well-typed regardless of its result type.
  (func $id_write_all (param $fd i32) (param $ptr i32) (param $len i32)
    ;; fd_write (like POSIX writev) may perform a short write -- it can write
    ;; fewer bytes than asked and still return success, leaving the rest for a
    ;; follow-up call. Loop, advancing by whatever it actually wrote, until
    ;; every byte is out (or it stops making progress, e.g. on a real error).
    (local $got i32)
    (block $done
      (loop $again
        (br_if $done (i32.le_s (local.get $len) (i32.const 0)))
        (i32.store (i32.const {_IOV0_PTR}) (local.get $ptr))
        (i32.store (i32.const {_IOV0_LEN}) (local.get $len))
        (drop (call $fd_write (local.get $fd) (i32.const {_IOV0_PTR}) (i32.const 1)
                               (i32.const {_NWRITTEN})))
        (local.set $got (i32.load (i32.const {_NWRITTEN})))
        (br_if $done (i32.le_s (local.get $got) (i32.const 0)))
        (local.set $ptr (i32.add (local.get $ptr) (local.get $got)))
        (local.set $len (i32.sub (local.get $len) (local.get $got)))
        (br $again))))

  (func $id_die (param $ptr i32) (param $len i32)
    (call $id_write_all (i32.const 2) (local.get $ptr) (local.get $len))
    (call $proc_exit (i32.const 1))
    (unreachable))

  (func $id_index_error (param $idx i32) (param $len i32)
    (local $s i32)
    (call $id_write_all (i32.const 2) (i32.const {_MSG_IDX_PRE_ADDR})
                         (i32.const {len(_MSG_IDX_PRE)}))
    (local.set $s (call $id_str_of_int (local.get $idx)))
    (call $id_write_all (i32.const 2) (local.get $s) (call $id_strlen (local.get $s)))
    (call $id_write_all (i32.const 2) (i32.const {_MSG_IDX_MID_ADDR})
                         (i32.const {len(_MSG_IDX_MID)}))
    (local.set $s (call $id_str_of_int (local.get $len)))
    (call $id_write_all (i32.const 2) (local.get $s) (call $id_strlen (local.get $s)))
    (call $id_write_all (i32.const 2) (i32.const {_MSG_IDX_END_ADDR})
                         (i32.const {len(_MSG_IDX_END)}))
    (call $proc_exit (i32.const 1))
    (unreachable))

  ;; ---- arithmetic with defined answers (docs/SPEC.md 2.2, 2.3). The raw
  ;; wasm instructions are wrong twice over: i32.div_s by zero is an opaque
  ;; engine trap where the C target prints a line and exits 1, and i32.shl
  ;; masks the shift count to 5 bits, so `1 << 32` came out as 1 instead of 0.
  (func $id_idiv (param $a i32) (param $b i32) (result i32)
    (if (i32.eqz (local.get $b))
      (then (call $id_die (i32.const {_MSG_DIV0_ADDR})
                          (i32.const {len(_MSG_DIV0)}))))
    (if (i32.and (i32.eq (local.get $b) (i32.const -1))
                 (i32.eq (local.get $a) (i32.const -2147483648)))
      (then (call $id_die (i32.const {_MSG_DIVOV_ADDR})
                          (i32.const {len(_MSG_DIVOV)}))))
    (i32.div_s (local.get $a) (local.get $b)))

  ;; b == -1 would overflow for INT_MIN, and the answer is 0 either way.
  (func $id_imod (param $a i32) (param $b i32) (result i32)
    (if (i32.eqz (local.get $b))
      (then (call $id_die (i32.const {_MSG_MOD0_ADDR})
                          (i32.const {len(_MSG_MOD0)}))))
    (if (i32.eq (local.get $b) (i32.const -1))
      (then (return (i32.const 0))))
    (i32.rem_s (local.get $a) (local.get $b)))

  (func $id_shl (param $a i32) (param $n i32) (result i32)
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then (call $id_die (i32.const {_MSG_SHNEG_ADDR})
                          (i32.const {len(_MSG_SHNEG)}))))
    (if (i32.ge_s (local.get $n) (i32.const 32))
      (then (return (i32.const 0))))
    (i32.shl (local.get $a) (local.get $n)))

  ;; Past the width an arithmetic right shift is the sign bit repeated, which
  ;; is exactly what shifting by 31 produces.
  (func $id_sar (param $a i32) (param $n i32) (result i32)
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then (call $id_die (i32.const {_MSG_SHNEG_ADDR})
                          (i32.const {len(_MSG_SHNEG)}))))
    (if (i32.ge_s (local.get $n) (i32.const 32))
      (then (return (i32.shr_s (local.get $a) (i32.const 31)))))
    (i32.shr_s (local.get $a) (local.get $n)))

  (func $id_pop_error
    (call $id_die (i32.const {_MSG_POP_ADDR}) (i32.const {len(_MSG_POP)})))

  (func $id_oom_error
    (call $id_die (i32.const {_MSG_OOM_ADDR}) (i32.const {len(_MSG_OOM)})))

  (func $id_cap_overflow_error
    (call $id_die (i32.const {_MSG_CAP_ADDR}) (i32.const {len(_MSG_CAP)})))

  ;; Bump allocator over the wasm linear memory. Unlike the C target's
  ;; malloc/realloc, wasm memory can only grow (never shrink/free), but a
  ;; naive bump that never grows the memory would let later loads/stores walk
  ;; off the end of the allocated pages -- which the engine catches as an
  ;; opaque trap, but only *after* silently handing out a pointer into
  ;; unmapped space. Instead, check up front whether the requested block
  ;; still fits in the currently-allocated pages and, if not, grow memory to
  ;; cover it -- growth failure (address space exhausted) is reported the
  ;; same way as a C-side OOM.
  (func $id_alloc (param $n i32) (result i32)
    (local $p i32) (local $need i32) (local $have i32) (local $want i32) (local $grown i32)
    (local.set $p (global.get $heap))
    (local.set $need (i32.add (local.get $p) (local.get $n)))
    ;; The flat store is a fixed region at {_STORE_BASE} in this same linear
    ;; memory, and this bump allocator grows toward it. Reaching it must be a
    ;; clean abort: docs/SPEC.md 6 promises that the mistake which silently
    ;; corrupts memory in C is a trap here, and without this check a program
    ;; whose heap passed 1 MiB overwrote the store and read back garbage with
    ;; nothing reported.
    (if (i32.gt_u (local.get $need) (i32.const {_STORE_BASE}))
      (then (call $id_oom_error) (unreachable)))
    (local.set $have (i32.mul (memory.size) (i32.const 65536)))
    (if (i32.gt_u (local.get $need) (local.get $have))
      (then
        (local.set $want
          (i32.div_u (i32.add (i32.sub (local.get $need) (local.get $have)) (i32.const 65535))
                     (i32.const 65536)))
        (local.set $grown (memory.grow (local.get $want)))
        (if (i32.eq (local.get $grown) (i32.const -1))
          (then (call $id_oom_error) (unreachable)))))
    (global.set $heap (local.get $need))
    (local.get $p))

  (func $id_memcopy (param $dst i32) (param $src i32) (param $n i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $again
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (i32.store8 (i32.add (local.get $dst) (local.get $i))
                    (i32.load8_u (i32.add (local.get $src) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $again))))

  (func $id_list_new (result i32)
    (local $L i32)
    (local.set $L (call $id_alloc (i32.const 12)))
    (i32.store (local.get $L) (i32.const 0))
    (i32.store offset=4 (local.get $L) (i32.const 4))
    (i32.store offset=8 (local.get $L) (call $id_alloc (i32.const 32)))
    (local.get $L))

  (func $id_list_grow (param $L i32)
    (local $cap i32) (local $data i32) (local $ndata i32) (local $ncap i32)
    (local.set $cap (i32.load offset=4 (local.get $L)))
    (local.set $data (i32.load offset=8 (local.get $L)))
    ;; guard the same integer-overflow-in-sizing that the C runtime guards:
    ;; below this cap, `cap * 2` and `(cap * 2) * 8` both stay well under
    ;; 2^32, so neither the capacity doubling nor the byte-size computation
    ;; can wrap around.
    (if (i32.ge_u (local.get $cap) (i32.const 134217728))
      (then (call $id_cap_overflow_error) (unreachable)))
    (local.set $ncap (i32.mul (local.get $cap) (i32.const 2)))
    (local.set $ndata (call $id_alloc (i32.mul (local.get $ncap) (i32.const 8))))
    (call $id_memcopy (local.get $ndata) (local.get $data)
                       (i32.mul (local.get $cap) (i32.const 8)))
    (i32.store offset=8 (local.get $L) (local.get $ndata))
    (i32.store offset=4 (local.get $L) (local.get $ncap)))

  (func $id_list_push (param $L i32) (param $v i64)
    (local $len i32) (local $cap i32) (local $data i32)
    (local.set $len (i32.load (local.get $L)))
    (local.set $cap (i32.load offset=4 (local.get $L)))
    (if (i32.ge_s (local.get $len) (local.get $cap))
      (then (call $id_list_grow (local.get $L))))
    (local.set $data (i32.load offset=8 (local.get $L)))
    (i64.store (i32.add (local.get $data) (i32.mul (local.get $len) (i32.const 8)))
               (local.get $v))
    (i32.store (local.get $L) (i32.add (local.get $len) (i32.const 1))))

  (func $id_list_get (param $L i32) (param $idx i32) (result i64)
    (local $len i32) (local $data i32)
    (local.set $len (i32.load (local.get $L)))
    (if (i32.or (i32.lt_s (local.get $idx) (i32.const 0))
                (i32.ge_s (local.get $idx) (local.get $len)))
      (then (call $id_index_error (local.get $idx) (local.get $len)) (unreachable)))
    (local.set $data (i32.load offset=8 (local.get $L)))
    (i64.load (i32.add (local.get $data) (i32.mul (local.get $idx) (i32.const 8)))))

  (func $id_list_set (param $L i32) (param $idx i32) (param $v i64)
    (local $len i32) (local $data i32)
    (local.set $len (i32.load (local.get $L)))
    (if (i32.or (i32.lt_s (local.get $idx) (i32.const 0))
                (i32.ge_s (local.get $idx) (local.get $len)))
      (then (call $id_index_error (local.get $idx) (local.get $len)) (unreachable)))
    (local.set $data (i32.load offset=8 (local.get $L)))
    (i64.store (i32.add (local.get $data) (i32.mul (local.get $idx) (i32.const 8)))
               (local.get $v)))

  (func $id_list_len (param $L i32) (result i32)
    (i32.load (local.get $L)))

  (func $id_list_pop (param $L i32) (result i64)
    (local $len i32) (local $data i32)
    (local.set $len (i32.load (local.get $L)))
    (if (i32.le_s (local.get $len) (i32.const 0))
      (then (call $id_pop_error) (unreachable)))
    (local.set $len (i32.sub (local.get $len) (i32.const 1)))
    (i32.store (local.get $L) (local.get $len))
    (local.set $data (i32.load offset=8 (local.get $L)))
    (i64.load (i32.add (local.get $data) (i32.mul (local.get $len) (i32.const 8)))))

  (func $id_strlen (param $s i32) (result i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $again
        (br_if $done (i32.eqz (i32.load8_u (i32.add (local.get $s) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $again)))
    (local.get $i))

  (func $id_len (param $s i32) (result i32)
    (call $id_strlen (local.get $s)))

  (func $id_concat (param $a i32) (param $b i32) (result i32)
    (local $la i32) (local $lb i32) (local $r i32)
    (local.set $la (call $id_strlen (local.get $a)))
    (local.set $lb (call $id_strlen (local.get $b)))
    (local.set $r (call $id_alloc (i32.add (i32.add (local.get $la) (local.get $lb))
                                            (i32.const 1))))
    (call $id_memcopy (local.get $r) (local.get $a) (local.get $la))
    (call $id_memcopy (i32.add (local.get $r) (local.get $la)) (local.get $b) (local.get $lb))
    (i32.store8 (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $lb))
                (i32.const 0))
    (local.get $r))

  (func $id_strcmp (param $a i32) (param $b i32) (result i32)
    (local $i i32) (local $ca i32) (local $cb i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $again
        (local.set $ca (i32.load8_u (i32.add (local.get $a) (local.get $i))))
        (local.set $cb (i32.load8_u (i32.add (local.get $b) (local.get $i))))
        (br_if $done (i32.ne (local.get $ca) (local.get $cb)))
        (br_if $done (i32.eqz (local.get $ca)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $again)))
    (i32.sub (local.get $ca) (local.get $cb)))

  (func $id_str_of_int (param $x i32) (result i32)
    (local $n i32) (local $neg i32) (local $i i32) (local $r i32) (local $j i32) (local $d i32)
    ;; Fold into the NEGATIVE half of the range, not the positive one.
    ;; Negating a negative overflows for INT_MIN -- it stays negative, every
    ;; rem_s then yields a negative digit, and `d + 48` prints '0' - d, so
    ;; -2147483648 came out as "-./,),(-*,(". Negating a positive is always
    ;; representable, so the fold goes the other way and INT_MIN is never
    ;; negated at all.
    (local.set $n (local.get $x))
    (local.set $neg (i32.const 0))
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then (local.set $neg (i32.const 1))))
    (if (i32.gt_s (local.get $n) (i32.const 0))
      (then (local.set $n (i32.sub (i32.const 0) (local.get $n)))))
    (local.set $i (i32.const 0))
    (if (i32.eqz (local.get $n))
      (then
        (i32.store8 (i32.add (i32.const {_STROI_BUF}) (local.get $i)) (i32.const 48))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))))
    (block $digits_done
      (loop $digits
        (br_if $digits_done (i32.eqz (local.get $n)))
        ;; $n is <= 0 here, so rem_s gives the digit negated; flip it back.
        (local.set $d (i32.sub (i32.const 0)
                               (i32.rem_s (local.get $n) (i32.const 10))))
        (i32.store8 (i32.add (i32.const {_STROI_BUF}) (local.get $i))
                    (i32.add (local.get $d) (i32.const 48)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (local.set $n (i32.div_s (local.get $n) (i32.const 10)))
        (br $digits)))
    (if (local.get $neg)
      (then
        (i32.store8 (i32.add (i32.const {_STROI_BUF}) (local.get $i)) (i32.const 45))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))))
    (local.set $r (call $id_alloc (i32.add (local.get $i) (i32.const 1))))
    (local.set $j (i32.const 0))
    (block $rev_done
      (loop $rev
        (br_if $rev_done (i32.ge_s (local.get $j) (local.get $i)))
        (i32.store8 (i32.add (local.get $r) (local.get $j))
                    (i32.load8_u (i32.add (i32.const {_STROI_BUF})
                                          (i32.sub (i32.sub (local.get $i) (local.get $j))
                                                    (i32.const 1)))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $rev)))
    (i32.store8 (i32.add (local.get $r) (local.get $i)) (i32.const 0))
    (local.get $r))

  (func $id_to_int (param $s i32) (result i32)
    (local $i i32) (local $neg i32) (local $r i32) (local $c i32)
    (local.set $i (i32.const 0))
    (local.set $neg (i32.const 0))
    (local.set $r (i32.const 0))
    (block $skipws_done
      (loop $skipws
        (br_if $skipws_done (i32.ne (i32.load8_u (i32.add (local.get $s) (local.get $i)))
                                     (i32.const 32)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $skipws)))
    (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
    (if (i32.eq (local.get $c) (i32.const 45))
      (then (local.set $neg (i32.const 1)) (local.set $i (i32.add (local.get $i) (i32.const 1))))
      (else (if (i32.eq (local.get $c) (i32.const 43))
        (then (local.set $i (i32.add (local.get $i) (i32.const 1)))))))
    (block $digits_done
      (loop $digits
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $digits_done (i32.or (i32.lt_u (local.get $c) (i32.const 48))
                                     (i32.gt_u (local.get $c) (i32.const 57))))
        (local.set $r (i32.add (i32.mul (local.get $r) (i32.const 10))
                                (i32.sub (local.get $c) (i32.const 48))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $digits)))
    (if (local.get $neg) (then (local.set $r (i32.sub (i32.const 0) (local.get $r)))))
    (local.get $r))

  (func $id_charat (param $s i32) (param $idx i32) (result i32)
    (local $n i32)
    (local.set $n (call $id_strlen (local.get $s)))
    (if (i32.or (i32.lt_s (local.get $idx) (i32.const 0))
                (i32.ge_s (local.get $idx) (local.get $n)))
      (then (return (i32.const -1))))
    (i32.load8_u (i32.add (local.get $s) (local.get $idx))))

  (func $id_chr (param $c i32) (result i32)
    (local $r i32)
    (local.set $r (call $id_alloc (i32.const 2)))
    (i32.store8 (local.get $r) (local.get $c))
    (i32.store8 (i32.add (local.get $r) (i32.const 1)) (i32.const 0))
    (local.get $r))

  (func $id_print (param $s i32)
    (local $n i32)
    (local.set $n (call $id_strlen (local.get $s)))
    (call $id_write_all (i32.const 1) (local.get $s) (local.get $n))
    (call $id_write_all (i32.const 1) (i32.const {_NEWLINE_BYTE}) (i32.const 1)))

  (func $id_input (result i32)
    (local $n i32) (local $r i32) (local $got i32)
    (local.set $n (i32.const 0))
    (i32.store (i32.const {_READ_IOV_PTR}) (i32.const {_READ_BYTE}))
    (i32.store (i32.const {_READ_IOV_LEN}) (i32.const 1))
    (block $loop_done
      (loop $readloop
        (br_if $loop_done (i32.ge_s (local.get $n) (i32.const 1023)))
        (drop (call $fd_read (i32.const 0) (i32.const {_READ_IOV_PTR}) (i32.const 1)
                              (i32.const {_READ_NREAD})))
        (local.set $got (i32.load (i32.const {_READ_NREAD})))
        (br_if $loop_done (i32.eqz (local.get $got)))
        (br_if $loop_done (i32.eq (i32.load8_u (i32.const {_READ_BYTE})) (i32.const 10)))
        (i32.store8 (i32.add (i32.const {_INPUT_BUF}) (local.get $n))
                    (i32.load8_u (i32.const {_READ_BYTE})))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (br $readloop)))
    (local.set $r (call $id_alloc (i32.add (local.get $n) (i32.const 1))))
    (call $id_memcopy (local.get $r) (i32.const {_INPUT_BUF}) (local.get $n))
    (i32.store8 (i32.add (local.get $r) (local.get $n)) (i32.const 0))
    (local.get $r))

  (func $id_read_all (result i32)
    (local $cap i32) (local $n i32) (local $buf i32) (local $nbuf i32)
    (local $got i32) (local $r i32)
    (local.set $cap (i32.const 256))
    (local.set $n (i32.const 0))
    (local.set $buf (call $id_alloc (local.get $cap)))
    (i32.store (i32.const {_READ_IOV_PTR}) (i32.const {_READ_BYTE}))
    (i32.store (i32.const {_READ_IOV_LEN}) (i32.const 1))
    (block $loop_done
      (loop $readloop
        (drop (call $fd_read (i32.const 0) (i32.const {_READ_IOV_PTR}) (i32.const 1)
                              (i32.const {_READ_NREAD})))
        (local.set $got (i32.load (i32.const {_READ_NREAD})))
        (br_if $loop_done (i32.eqz (local.get $got)))
        (if (i32.ge_s (local.get $n) (local.get $cap))
          (then
            (local.set $nbuf (call $id_alloc (i32.mul (local.get $cap) (i32.const 2))))
            (call $id_memcopy (local.get $nbuf) (local.get $buf) (local.get $cap))
            (local.set $buf (local.get $nbuf))
            (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))))
        (i32.store8 (i32.add (local.get $buf) (local.get $n))
                    (i32.load8_u (i32.const {_READ_BYTE})))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (br $readloop)))
    (local.set $r (call $id_alloc (i32.add (local.get $n) (i32.const 1))))
    (call $id_memcopy (local.get $r) (local.get $buf) (local.get $n))
    (i32.store8 (i32.add (local.get $r) (local.get $n)) (i32.const 0))
    (local.get $r))

  (func $id_str_of_word (param $x i64) (result i32)
    (local $n i64) (local $neg i32) (local $i i32) (local $r i32) (local $j i32) (local $d i64)
    (local.set $n (local.get $x))
    (local.set $neg (i32.const 0))
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then (local.set $neg (i32.const 1))))
    (if (i64.gt_s (local.get $n) (i64.const 0))
      (then (local.set $n (i64.sub (i64.const 0) (local.get $n)))))
    (local.set $i (i32.const 0))
    (if (i64.eqz (local.get $n))
      (then
        (i32.store8 (i32.add (i32.const {_STROI_BUF}) (local.get $i)) (i32.const 48))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))))
    (block $digits_done
      (loop $digits
        (br_if $digits_done (i64.eqz (local.get $n)))
        (local.set $d (i64.sub (i64.const 0)
                               (i64.rem_s (local.get $n) (i64.const 10))))
        (i32.store8 (i32.add (i32.const {_STROI_BUF}) (local.get $i))
                    (i32.add (i32.wrap_i64 (local.get $d)) (i32.const 48)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (local.set $n (i64.div_s (local.get $n) (i64.const 10)))
        (br $digits)))
    (if (local.get $neg)
      (then
        (i32.store8 (i32.add (i32.const {_STROI_BUF}) (local.get $i)) (i32.const 45))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))))
    (local.set $r (call $id_alloc (i32.add (local.get $i) (i32.const 1))))
    (local.set $j (i32.const 0))
    (block $rev_done
      (loop $rev
        (br_if $rev_done (i32.ge_s (local.get $j) (local.get $i)))
        (i32.store8 (i32.add (local.get $r) (local.get $j))
                    (i32.load8_u (i32.add (i32.const {_STROI_BUF})
                                          (i32.sub (i32.sub (local.get $i) (local.get $j))
                                                    (i32.const 1)))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $rev)))
    (i32.store8 (i32.add (local.get $r) (local.get $i)) (i32.const 0))
    (local.get $r))

  (func $id_store_error (param $addr i64)
    (local $s i32)
    (call $id_write_all (i32.const 2) (i32.const {_MSG_STORE_PRE_ADDR})
                         (i32.const {len(_MSG_STORE_PRE)}))
    (local.set $s (call $id_str_of_word (local.get $addr)))
    (call $id_write_all (i32.const 2) (local.get $s) (call $id_strlen (local.get $s)))
    (call $id_write_all (i32.const 2) (i32.const {_MSG_STORE_MID_ADDR})
                         (i32.const {len(_MSG_STORE_MID)}))
    (local.set $s (call $id_str_of_word (global.get $store_used)))
    (call $id_write_all (i32.const 2) (local.get $s) (call $id_strlen (local.get $s)))
    (call $id_write_all (i32.const 2) (i32.const {_MSG_STORE_END_ADDR})
                         (i32.const {len(_MSG_STORE_END)}))
    (call $proc_exit (i32.const 1))
    (unreachable))

  (func $id_store_addr (param $addr i64) (param $width i32) (result i32)
    (if (i64.le_s (local.get $addr) (i64.const 0))
      (then (call $id_store_error (local.get $addr)) (unreachable)))
    (if (i64.gt_s (i64.add (local.get $addr) (i64.extend_i32_s (local.get $width)))
                  (global.get $store_used))
      (then (call $id_store_error (local.get $addr)) (unreachable)))
    (i32.add (i32.const {_STORE_BASE}) (i32.wrap_i64 (local.get $addr))))

  (func $id_mem_alloc (param $n i64) (result i64)
    (local $base i64) (local $end i64)
    (local $need i32) (local $have i32) (local $want i32) (local $grown i32)
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then (call $id_die (i32.const {_MSG_NEGALLOC_ADDR}) (i32.const {len(_MSG_NEGALLOC)}))))
    (local.set $base (i64.and (i64.add (global.get $store_used) (i64.const 7)) (i64.const -8)))
    (local.set $end (i64.add (local.get $base) (local.get $n)))
    (if (i64.lt_s (local.get $end) (local.get $base))
      (then (call $id_die (i32.const {_MSG_ALLOCOV_ADDR}) (i32.const {len(_MSG_ALLOCOV)}))))
    (local.set $need (i32.add (i32.const {_STORE_BASE}) (i32.wrap_i64 (local.get $end))))
    (local.set $have (i32.mul (memory.size) (i32.const 65536)))
    (if (i32.gt_u (local.get $need) (local.get $have))
      (then
        (local.set $want
          (i32.div_u (i32.add (i32.sub (local.get $need) (local.get $have)) (i32.const 65535))
                     (i32.const 65536)))
        (local.set $grown (memory.grow (local.get $want)))
        (if (i32.eq (local.get $grown) (i32.const -1))
          (then (call $id_oom_error) (unreachable)))))
    (global.set $store_used (local.get $end))
    (local.get $base))

  (func $id_mem_size (result i64)
    (global.get $store_used))

  (func $id_peek8 (param $addr i64) (result i64)
    (i64.extend_i32_u (i32.load8_u (call $id_store_addr (local.get $addr) (i32.const 1)))))

  (func $id_peek16 (param $addr i64) (result i64)
    (i64.extend_i32_u (i32.load16_u (call $id_store_addr (local.get $addr) (i32.const 2)))))

  (func $id_peek32 (param $addr i64) (result i64)
    (i64.extend_i32_u (i32.load (call $id_store_addr (local.get $addr) (i32.const 4)))))

  (func $id_peek64 (param $addr i64) (result i64)
    (i64.load (call $id_store_addr (local.get $addr) (i32.const 8))))

  (func $id_poke8 (param $addr i64) (param $v i64)
    (i32.store8 (call $id_store_addr (local.get $addr) (i32.const 1)) (i32.wrap_i64 (local.get $v))))

  (func $id_poke16 (param $addr i64) (param $v i64)
    (i32.store16 (call $id_store_addr (local.get $addr) (i32.const 2)) (i32.wrap_i64 (local.get $v))))

  (func $id_poke32 (param $addr i64) (param $v i64)
    (i32.store (call $id_store_addr (local.get $addr) (i32.const 4)) (i32.wrap_i64 (local.get $v))))

  (func $id_poke64 (param $addr i64) (param $v i64)
    (i64.store (call $id_store_addr (local.get $addr) (i32.const 8)) (local.get $v)))

  (func $id_str_of_mem (param $addr i64) (param $n i64) (result i32)
    (local $n32 i32) (local $real i32) (local $r i32)
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then (call $id_die (i32.const {_MSG_NEGLEN_ADDR}) (i32.const {len(_MSG_NEGLEN)}))))
    (local.set $n32 (i32.wrap_i64 (local.get $n)))
    (local.set $real (call $id_store_addr (local.get $addr) (local.get $n32)))
    (local.set $r (call $id_alloc (i32.add (local.get $n32) (i32.const 1))))
    (call $id_memcopy (local.get $r) (local.get $real) (local.get $n32))
    (i32.store8 (i32.add (local.get $r) (local.get $n32)) (i32.const 0))
    (local.get $r))

  (func $id_mem_of_str (param $s i32) (result i64)
    (local $n i32) (local $a i64) (local $real i32)
    (local.set $n (call $id_strlen (local.get $s)))
    (local.set $a (call $id_mem_alloc (i64.extend_i32_u (i32.add (local.get $n) (i32.const 1)))))
    (local.set $real (i32.add (i32.const {_STORE_BASE}) (i32.wrap_i64 (local.get $a))))
    (call $id_memcopy (local.get $real) (local.get $s) (i32.add (local.get $n) (i32.const 1)))
    (local.get $a))

  (func $id_udiv (param $a i64) (param $b i64) (result i64)
    (if (i64.eqz (local.get $b))
      (then (call $id_die (i32.const {_MSG_DIV0_ADDR}) (i32.const {len(_MSG_DIV0)}))))
    (i64.div_u (local.get $a) (local.get $b)))

  (func $id_umod (param $a i64) (param $b i64) (result i64)
    (if (i64.eqz (local.get $b))
      (then (call $id_die (i32.const {_MSG_MOD0_ADDR}) (i32.const {len(_MSG_MOD0)}))))
    (i64.rem_u (local.get $a) (local.get $b)))

  (func $id_ult (param $a i64) (param $b i64) (result i32)
    (i64.lt_u (local.get $a) (local.get $b)))

  (func $id_ushr (param $a i64) (param $b i64) (result i64)
    (if (i64.lt_s (local.get $b) (i64.const 0))
      (then (call $id_die (i32.const {_MSG_SHNEG_ADDR}) (i32.const {len(_MSG_SHNEG)}))))
    (if (i64.ge_s (local.get $b) (i64.const 64))
      (then (return (i64.const 0))))
    (i64.shr_u (local.get $a) (local.get $b)))

  (func $id_sdiv (param $a i64) (param $b i64) (result i64)
    (if (i64.eqz (local.get $b))
      (then (call $id_die (i32.const {_MSG_DIV0_ADDR}) (i32.const {len(_MSG_DIV0)}))))
    (if (i32.and (i64.eq (local.get $b) (i64.const -1))
                 (i64.eq (local.get $a) (i64.const -9223372036854775808)))
      (then (call $id_die (i32.const {_MSG_DIVOV_ADDR}) (i32.const {len(_MSG_DIVOV)}))))
    (i64.div_s (local.get $a) (local.get $b)))

  (func $id_smod (param $a i64) (param $b i64) (result i64)
    (if (i64.eqz (local.get $b))
      (then (call $id_die (i32.const {_MSG_MOD0_ADDR}) (i32.const {len(_MSG_MOD0)}))))
    (if (i64.eq (local.get $b) (i64.const -1))
      (then (return (i64.const 0))))
    (i64.rem_s (local.get $a) (local.get $b)))

  (func $id_shl64 (param $a i64) (param $n i64) (result i64)
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then (call $id_die (i32.const {_MSG_SHNEG_ADDR}) (i32.const {len(_MSG_SHNEG)}))))
    (if (i64.ge_s (local.get $n) (i64.const 64))
      (then (return (i64.const 0))))
    (i64.shl (local.get $a) (local.get $n)))

  (func $id_sar64 (param $a i64) (param $n i64) (result i64)
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then (call $id_die (i32.const {_MSG_SHNEG_ADDR}) (i32.const {len(_MSG_SHNEG)}))))
    (if (i64.ge_s (local.get $n) (i64.const 64))
      (then (return (i64.shr_s (local.get $a) (i64.const 63)))))
    (i64.shr_s (local.get $a) (local.get $n)))
"""


class WasmBackend:
    """Emits one WebAssembly text (WAT) module for a checked program. Shares
    the Compiler's checked tables the same way LLVMBackend does; see the
    module comment above for the value representation and scope."""

    def __init__(self, compiler: Compiler):
        self.compiler = compiler
        self.str_table = {}    # bytes -> address
        self.next_addr = _RESERVED_END

    def wtype(self, typ):
        if typ == "int":
            return "i32"
        if typ == "word":
            return "i64"
        if typ == "float":
            return "f64"
        return "i32"   # string, or any list type: an address

    def str_const(self, raw: str) -> int:
        bs = unescape_id_string(raw)
        addr = self.str_table.get(bs)
        if addr is None:
            addr = self.next_addr
            self.str_table[bs] = addr
            self.next_addr += len(bs) + 1
        return addr

    def new_temp_local(self, wt) -> str:
        self.tmp_local_n += 1
        name = f"$tmp{self.tmp_local_n}"
        self.pending_locals.append((name, wt))
        return name

    def new_lbl_id(self) -> int:
        self.lbl_n += 1
        return self.lbl_n

    def coerce(self, val, have, want):
        if have == want:
            return val
        if have == "int" and want == "word":
            return f"(i64.extend_i32_s {val})"
        if have == "int" and want == "float":
            return f"(f64.convert_i32_s {val})"
        if have == "word" and want == "float":
            return f"(f64.convert_i64_s {val})"
        return val

    def box(self, val, typ):
        if typ == "int":
            return f"(i64.extend_i32_s {val})"
        if typ == "word":
            return val
        if typ == "float":
            return f"(i64.reinterpret_f64 {val})"
        return f"(i64.extend_i32_u {val})"   # string/list address

    def unbox(self, val, typ):
        if typ == "int":
            return f"(i32.wrap_i64 {val})"
        if typ == "word":
            return val
        if typ == "float":
            return f"(f64.reinterpret_i64 {val})"
        return f"(i32.wrap_i64 {val})"

    def to_bool(self, val, typ):
        """A folded i32 expression that is nonzero iff `val` (of id type
        `typ`) is truthy -- used directly as an `if`/`br_if` condition (wasm's
        `if` pops an i32 and treats nonzero as true, so an int value can be
        used as-is)."""
        if typ == "int":
            return val
        if typ == "word":
            return f"(i64.ne {val} (i64.const 0))"
        if typ == "float":
            return f"(f64.ne {val} (f64.const 0))"
        return f"(i32.ne {val} (i32.const 0))"

    def to_string(self, val, typ, e):
        if typ == "string":
            return val
        if typ == "int":
            return f"(call $id_str_of_int {val})"
        if typ == "word":
            return f"(call $id_str_of_word {val})"
        raise CompileError(e.file, e.line,
                           f"cannot convert {typ} to string for --target wasm "
                           f"(float-to-string is not implemented for this target)")

    # -- statements: returns a list of indented WAT instruction lines

    def gen_stmt(self, stmt, fn, env, indent):
        ind = "  " * indent
        if isinstance(stmt, DeclStmt):
            val, typ = self.gen_expr(stmt.expr, fn, env, stmt.typ)
            if not compatible(stmt.typ, typ):
                raise CompileError(stmt.file, stmt.line,
                                   f"cannot initialize {stmt.typ} '{stmt.name}' "
                                   f"with a {typ} value")
            val = self.coerce(val, typ, stmt.typ)
            return [f"{ind}({self.setter(stmt.name)} {val})"]
        if isinstance(stmt, AssignStmt):
            if stmt.name not in env:
                self.compiler.explain_bad_var(stmt.name, fn, stmt.file, stmt.line)
            want = env[stmt.name]
            val, typ = self.gen_expr(stmt.expr, fn, env, want)
            if not compatible(want, typ):
                raise CompileError(stmt.file, stmt.line,
                                   f"cannot assign a {typ} value to {want} "
                                   f"'{stmt.name}'")
            val = self.coerce(val, typ, want)
            return [f"{ind}({self.setter(stmt.name)} {val})"]
        if isinstance(stmt, IndexAssignStmt):
            base, btyp = self.gen_expr(stmt.base, fn, env)
            if not btyp.endswith("[]"):
                raise CompileError(stmt.file, stmt.line, f"cannot index a {btyp}")
            idx, ityp = self.gen_expr(stmt.index, fn, env)
            if ityp != "int":
                raise CompileError(stmt.file, stmt.line,
                                   f"list index must be int, got {ityp}")
            elem = btyp[:-2]
            val, typ = self.gen_expr(stmt.expr, fn, env, elem)
            if not compatible(elem, typ):
                raise CompileError(stmt.file, stmt.line,
                                   f"cannot store a {typ} into a {btyp}")
            val = self.coerce(val, typ, elem)
            boxed = self.box(val, elem)
            return [f"{ind}(call $id_list_set {base} {idx} {boxed})"]
        if isinstance(stmt, IfStmt):
            cond, ctyp = self.gen_expr(stmt.cond, fn, env)
            if ctyp == "void":
                raise CompileError(stmt.file, stmt.line, "condition has type void")
            out = [f"{ind}(if {self.to_bool(cond, ctyp)}", f"{ind}  (then"]
            for s in stmt.then:
                out.extend(self.gen_stmt(s, fn, env, indent + 2))
            out.append(f"{ind}  )")
            if stmt.els is not None:
                out.append(f"{ind}  (else")
                if isinstance(stmt.els, IfStmt):
                    out.extend(self.gen_stmt(stmt.els, fn, env, indent + 2))
                else:
                    for s in stmt.els:
                        out.extend(self.gen_stmt(s, fn, env, indent + 2))
                out.append(f"{ind}  )")
            out.append(f"{ind})")
            return out
        if isinstance(stmt, WhileStmt):
            cond, ctyp = self.gen_expr(stmt.cond, fn, env)
            if ctyp == "void":
                raise CompileError(stmt.file, stmt.line, "loop condition has type void")
            n = self.new_lbl_id()
            out = [f"{ind}(block $break{n}", f"{ind}  (loop $continue{n}",
                   f"{ind}    (br_if $break{n} (i32.eqz {self.to_bool(cond, ctyp)}))"]
            for s in stmt.body:
                out.extend(self.gen_stmt(s, fn, env, indent + 2))
            out.append(f"{ind}    (br $continue{n})")
            out.append(f"{ind}  )")
            out.append(f"{ind})")
            return out
        if isinstance(stmt, ExprStmt):
            val, typ = self.gen_expr(stmt.expr, fn, env)
            if typ == "void":
                return [f"{ind}{val}"]
            return [f"{ind}(drop {val})"]
        raise AssertionError(stmt)

    def setter(self, name):
        if name in self.compiler.exported:
            return f"global.set $g_{name}"
        return f"local.set $v_{name}"

    # -- expressions: returns (wat_expr, id_type); `wat_expr` is always a
    #    single, complete, folded s-expression producing exactly one value
    #    (or none, for a void-typed call)

    def gen_expr(self, e, fn, env, expected=None):
        if isinstance(e, IntLit):
            if int(e.value) > 0x7fffffff:
                return f"(i64.const {e.value})", "word"
            return f"(i32.const {e.value})", "int"
        if isinstance(e, FloatLit):
            return f"(f64.const {e.value})", "float"
        if isinstance(e, StrLit):
            return f"(i32.const {self.str_const(e.raw)})", "string"
        if isinstance(e, VarRef):
            if e.name not in env:
                self.compiler.explain_bad_var(e.name, fn, e.file, e.line)
            typ = env[e.name]
            if e.name in self.compiler.exported:
                return f"(global.get $g_{e.name})", typ
            return f"(local.get $v_{e.name})", typ
        if isinstance(e, ImportRef):
            if e.name not in self.compiler.exported:
                if e.name in self.compiler.var_owner:
                    owner = self.compiler.var_owner[e.name][0]
                    raise CompileError(e.file, e.line,
                                       f"variable '{e.name}' (in function '{owner}') "
                                       f"is not exported")
                raise CompileError(e.file, e.line,
                                   f"no exported variable named '{e.name}'")
            typ = self.compiler.exported[e.name][0]
            return f"(global.get $g_{e.name})", typ
        if isinstance(e, IndexExpr):
            base, btyp = self.gen_expr(e.base, fn, env)
            if not btyp.endswith("[]"):
                raise CompileError(e.file, e.line, f"cannot index a {btyp}")
            idx, ityp = self.gen_expr(e.index, fn, env)
            if ityp != "int":
                raise CompileError(e.file, e.line, f"array index must be int, got {ityp}")
            elem = btyp[:-2]
            cell = f"(call $id_list_get {base} {idx})"
            return self.unbox(cell, elem), elem
        if isinstance(e, ArrayLit):
            if not e.elems:
                if expected is None or not expected.endswith("[]"):
                    raise CompileError(e.file, e.line,
                                       "an empty list literal needs a known list "
                                       "type here (e.g. on a typed declaration)")
                return "(call $id_list_new)", expected
            raw, etyp = [], None
            for el in e.elems:
                val, typ = self.gen_expr(el, fn, env)
                if etyp is None:
                    etyp = typ
                elif not compatible(etyp, typ):
                    raise CompileError(el.file, el.line,
                                       f"list element has type {typ}, expected {etyp}")
                if is_numeric(etyp) and typ == "float":
                    etyp = "float"
                raw.append((val, typ))
            t = self.new_temp_local("i32")
            lines = ["(block (result i32)", f"  (local.set {t} (call $id_list_new))"]
            for val, typ in raw:
                val = self.coerce(val, typ, etyp)
                boxed = self.box(val, etyp)
                lines.append(f"  (call $id_list_push (local.get {t}) {boxed})")
            lines.append(f"  (local.get {t}))")
            return "\n      ".join(lines), etyp + "[]"
        if isinstance(e, CallExpr):
            return self.gen_call(e, fn, env)
        if isinstance(e, UnOp):
            val, typ = self.gen_expr(e.operand, fn, env)
            if e.op == "-":
                if not is_numeric(typ):
                    raise CompileError(e.file, e.line, f"cannot negate a {typ}")
                if typ == "int":
                    return f"(i32.sub (i32.const 0) {val})", "int"
                if typ == "word":
                    return f"(i64.sub (i64.const 0) {val})", "word"
                return f"(f64.neg {val})", "float"
            if e.op == "!":
                if not is_integral(typ):
                    raise CompileError(e.file, e.line, f"cannot apply '!' to a {typ}")
                if typ == "word":
                    return f"(i64.eqz {val})", "int"
                return f"(i32.eqz {val})", "int"
            if e.op == "~":
                if not is_integral(typ):
                    raise CompileError(e.file, e.line, f"cannot apply '~' to a {typ}")
                if typ == "word":
                    return f"(i64.xor {val} (i64.const -1))", "word"
                return f"(i32.xor {val} (i32.const -1))", "int"
            raise AssertionError(e.op)
        if isinstance(e, BinOp):
            return self.gen_binop(e, fn, env)
        raise AssertionError(e)

    def gen_binop(self, e: BinOp, fn, env):
        lc, lt = self.gen_expr(e.left, fn, env)
        rc, rt = self.gen_expr(e.right, fn, env)
        op = e.op
        if op == "+" and (lt == "string" or rt == "string"):
            ls = self.to_string(lc, lt, e.left)
            rs = self.to_string(rc, rt, e.right)
            return f"(call $id_concat {ls} {rs})", "string"
        if op in ("==", "!="):
            if lt == "string" and rt == "string":
                inner = f"(call $id_strcmp {lc} {rc})"
                if op == "==":
                    return f"(i32.eqz {inner})", "int"
                return f"(i32.ne {inner} (i32.const 0))", "int"
            if is_numeric(lt) and is_numeric(rt):
                common = arith_result(lt, rt)
                lc2, rc2 = self.coerce(lc, lt, common), self.coerce(rc, rt, common)
                instr = {"int": {"==": "i32.eq", "!=": "i32.ne"},
                         "word": {"==": "i64.eq", "!=": "i64.ne"},
                         "float": {"==": "f64.eq", "!=": "f64.ne"}}[common][op]
                return f"({instr} {lc2} {rc2})", "int"
            raise CompileError(e.file, e.line, f"cannot compare {lt} with {rt}")
        if op in ("<", "<=", ">", ">="):
            if is_numeric(lt) and is_numeric(rt):
                common = arith_result(lt, rt)
                lc2, rc2 = self.coerce(lc, lt, common), self.coerce(rc, rt, common)
                imap = {"<": "i32.lt_s", "<=": "i32.le_s", ">": "i32.gt_s", ">=": "i32.ge_s"}
                wmap = {"<": "i64.lt_s", "<=": "i64.le_s", ">": "i64.gt_s", ">=": "i64.ge_s"}
                fmap = {"<": "f64.lt", "<=": "f64.le", ">": "f64.gt", ">=": "f64.ge"}
                instr = {"int": imap, "word": wmap, "float": fmap}[common][op]
                return f"({instr} {lc2} {rc2})", "int"
            raise CompileError(e.file, e.line, f"cannot order {lt} and {rt}")
        if op in ("&&", "||"):
            if is_integral(lt) and is_integral(rt):
                lb = (f"(i64.ne {lc} (i64.const 0))" if lt == "word"
                      else f"(i32.ne {lc} (i32.const 0))")
                rb = (f"(i64.ne {rc} (i64.const 0))" if rt == "word"
                      else f"(i32.ne {rc} (i32.const 0))")
                instr = "i32.and" if op == "&&" else "i32.or"
                return f"({instr} {lb} {rb})", "int"
            raise CompileError(e.file, e.line, f"'{op}' requires int or word operands")
        if op in ("+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"):
            if op in ("&", "|", "^", "<<", ">>") and not (is_integral(lt) and is_integral(rt)):
                raise CompileError(e.file, e.line,
                                   f"'{op}' requires int or word operands, got {lt} and {rt}")
            if is_numeric(lt) and is_numeric(rt):
                if op == "%" and (lt == "float" or rt == "float"):
                    raise CompileError(e.file, e.line, "'%' requires int operands")
                res = arith_result(lt, rt)
                lc2, rc2 = self.coerce(lc, lt, res), self.coerce(rc, rt, res)
                if res in ("int", "word"):
                    width = "i32" if res == "int" else "i64"
                    if op in ("/", "%"):
                        if res == "int":
                            helper = "id_idiv" if op == "/" else "id_imod"
                        else:
                            helper = "id_sdiv" if op == "/" else "id_smod"
                        return f"(call ${helper} {lc2} {rc2})", res
                    if op in ("<<", ">>"):
                        if res == "int":
                            helper = "id_shl" if op == "<<" else "id_sar"
                        else:
                            helper = "id_shl64" if op == "<<" else "id_sar64"
                        return f"(call ${helper} {lc2} {rc2})", res
                    instr = {"+": f"{width}.add", "-": f"{width}.sub", "*": f"{width}.mul",
                             "&": f"{width}.and", "|": f"{width}.or",
                             "^": f"{width}.xor"}[op]
                else:
                    instr = {"+": "f64.add", "-": "f64.sub", "*": "f64.mul",
                             "/": "f64.div"}[op]
                return f"({instr} {lc2} {rc2})", res
            raise CompileError(e.file, e.line, f"cannot apply '{op}' to {lt} and {rt}")
        raise AssertionError(op)

    def gen_call(self, e: CallExpr, fn, env):
        name = e.name
        if name == "print":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "print takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn, env)
            s = self.to_string(val, typ, e)
            return f"(call $id_print {s})", "void"
        if name == "input":
            if e.args:
                raise CompileError(e.file, e.line, "input takes no arguments")
            return "(call $id_input)", "string"
        if name == "read_all":
            if e.args:
                raise CompileError(e.file, e.line, "read_all takes no arguments")
            return "(call $id_read_all)", "string"
        if name == "len":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "len takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn, env)
            if typ == "string":
                return f"(call $id_len {val})", "int"
            if typ.endswith("[]"):
                return f"(call $id_list_len {val})", "int"
            raise CompileError(e.file, e.line, f"len expects a string or list, got {typ}")
        if name == "push":
            if len(e.args) != 2:
                raise CompileError(e.file, e.line, "push takes exactly two arguments")
            lc, lt = self.gen_expr(e.args[0], fn, env)
            if not lt.endswith("[]"):
                raise CompileError(e.file, e.line, f"push expects a list, got {lt}")
            elem = lt[:-2]
            vc, vt = self.gen_expr(e.args[1], fn, env, elem)
            if not compatible(elem, vt):
                raise CompileError(e.file, e.line, f"cannot push a {vt} onto a {lt}")
            vc = self.coerce(vc, vt, elem)
            boxed = self.box(vc, elem)
            return f"(call $id_list_push {lc} {boxed})", "void"
        if name == "pop":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "pop takes exactly one argument")
            lc, lt = self.gen_expr(e.args[0], fn, env)
            if not lt.endswith("[]"):
                raise CompileError(e.file, e.line, f"pop expects a list, got {lt}")
            elem = lt[:-2]
            return self.unbox(f"(call $id_list_pop {lc})", elem), elem
        if name == "to_int":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "to_int takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn, env)
            if typ != "string":
                raise CompileError(e.file, e.line, f"to_int expects a string, got {typ}")
            return f"(call $id_to_int {val})", "int"
        if name == "charat":
            if len(e.args) != 2:
                raise CompileError(e.file, e.line, "charat takes exactly two arguments")
            sc, st = self.gen_expr(e.args[0], fn, env)
            ic, it = self.gen_expr(e.args[1], fn, env)
            if st != "string":
                raise CompileError(e.file, e.line, f"charat expects a string, got {st}")
            if it != "int":
                raise CompileError(e.file, e.line, f"charat index must be int, got {it}")
            return f"(call $id_charat {sc} {ic})", "int"
        if name == "chr":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line, "chr takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn, env)
            if typ != "int":
                raise CompileError(e.file, e.line, f"chr expects an int, got {typ}")
            return f"(call $id_chr {val})", "string"
        if name in STORE_BUILTINS or name in WORD_BUILTINS:
            return self.gen_systems_call(e, fn, env)
        if name == "str_of_mem":
            if len(e.args) != 2:
                raise CompileError(e.file, e.line,
                                   "str_of_mem takes exactly two arguments")
            ac, at = self.gen_expr(e.args[0], fn, env)
            nc, nt = self.gen_expr(e.args[1], fn, env)
            if not is_integral(at) or not is_integral(nt):
                raise CompileError(e.file, e.line,
                                   "str_of_mem takes an address and a length")
            a64 = self.coerce(ac, at, "word")
            n64 = self.coerce(nc, nt, "word")
            return f"(call $id_str_of_mem {a64} {n64})", "string"
        if name == "mem_of_str":
            if len(e.args) != 1:
                raise CompileError(e.file, e.line,
                                   "mem_of_str takes exactly one argument")
            val, typ = self.gen_expr(e.args[0], fn, env)
            if typ != "string":
                raise CompileError(e.file, e.line,
                                   f"mem_of_str expects a string, got {typ}")
            return f"(call $id_mem_of_str {val})", "word"
        if name in UNSUPPORTED_BUILTINS_WASM:
            raise CompileError(e.file, e.line, unsupported_builtin_msg(name))
        args = [self.gen_expr(a, fn, env) for a in e.args]
        callee = self.compiler.funcs.get(name)
        if callee is None:
            raise CompileError(e.file, e.line,
                               f"call to external function '{name}' is not "
                               f"supported for this --target (only functions "
                               f"defined in the program are supported)."
                               f"{builtin_hint(name)}")
        if len(args) != len(callee.params):
            raise CompileError(e.file, e.line,
                               f"function '{name}' takes {len(callee.params)} "
                               f"argument(s), got {len(args)}")
        argstrs = []
        for (ptype, pname), (val, typ), arg in zip(callee.params, args, e.args):
            if not compatible(ptype, typ):
                raise CompileError(arg.file, arg.line,
                                   f"argument '{pname}' of '{name}' expects "
                                   f"{ptype}, got {typ}")
            argstrs.append(self.coerce(val, typ, ptype))
        rettype = callee.rettype
        return f"(call $id_{name} {' '.join(argstrs)})", rettype

    def gen_systems_call(self, e: CallExpr, fn, env) -> Tuple[str, str]:
        arity, helper, restype = (STORE_BUILTINS.get(e.name)
                                  or WORD_BUILTINS[e.name])
        if len(e.args) != arity:
            plural = "" if arity == 1 else "s"
            raise CompileError(e.file, e.line,
                               f"{e.name} takes exactly {arity} argument{plural}, "
                               f"got {len(e.args)}")
        argstrs = []
        for arg in e.args:
            val, typ = self.gen_expr(arg, fn, env)
            if not is_integral(typ):
                raise CompileError(arg.file, arg.line,
                                   f"{e.name} expects int or word arguments, "
                                   f"got {typ}")
            argstrs.append(self.coerce(val, typ, "word"))
        call = f"(call ${helper}{(' ' + ' '.join(argstrs)) if argstrs else ''})"
        return call, restype

    # -- function codegen

    def gen_function(self, fn: FuncDef) -> str:
        env = self.compiler.build_env(fn)
        param_names = {n for _, n in fn.params}
        self.pending_locals = []
        self.tmp_local_n = 0
        self.lbl_n = 0

        body_lines = []
        for stmt in fn.body:
            body_lines.extend(self.gen_stmt(stmt, fn, env, 2))
        tail = []
        if fn.rettype != "void":
            val, typ = self.gen_expr(fn.retexpr, fn, env)
            if not compatible(fn.rettype, typ):
                raise CompileError(fn.retexpr.file, fn.retexpr.line,
                                   f"function '{fn.name}' returns {fn.rettype} but "
                                   f"the expression has type {typ}")
            val = self.coerce(val, typ, fn.rettype)
            tail = [f"    (return {val})"]

        params = " ".join(f"(param $v_{n} {self.wtype(t)})" for t, n in fn.params)
        result = "" if fn.rettype == "void" else f" (result {self.wtype(fn.rettype)})"
        locals_decl = []
        for name, typ in env.items():
            if name in self.compiler.exported or name in param_names:
                continue
            locals_decl.append(f"    (local $v_{name} {self.wtype(typ)})")
        for name, wt in self.pending_locals:
            locals_decl.append(f"    (local {name} {wt})")

        lines = [f"  (func $id_{fn.name} {params}{result}"]
        lines.extend(locals_decl)
        lines.extend(body_lines)
        lines.extend(tail)
        lines.append("  )")
        return "\n".join(lines)

    def gen_entrypoint(self) -> str:
        m = self.compiler.funcs.get("main")
        if m is None:
            return ""
        ptypes = [t for t, _ in m.params]
        lines = ['  (func $_start (export "_start")']
        if ptypes == ["int", "string[]"]:
            lines += [
                "    (local $argc i32) (local $bufsize i32) (local $i i32)",
                "    (local $ptrs i32) (local $buf i32) (local $args i32)",
                f"    (drop (call $args_sizes_get (i32.const {_ARGC_SCRATCH}) "
                f"(i32.const {_BUFSIZE_SCRATCH})))",
                f"    (local.set $argc (i32.load (i32.const {_ARGC_SCRATCH})))",
                f"    (local.set $bufsize (i32.load (i32.const {_BUFSIZE_SCRATCH})))",
                "    (local.set $ptrs (call $id_alloc (i32.mul (local.get $argc) (i32.const 4))))",
                "    (local.set $buf (call $id_alloc (local.get $bufsize)))",
                "    (drop (call $args_get (local.get $ptrs) (local.get $buf)))",
                "    (local.set $args (call $id_list_new))",
                "    (local.set $i (i32.const 0))",
                "    (block $argdone",
                "      (loop $argloop",
                "        (br_if $argdone (i32.ge_s (local.get $i) (local.get $argc)))",
                "        (call $id_list_push (local.get $args)",
                "          (i64.extend_i32_u (i32.load (i32.add (local.get $ptrs)",
                "            (i32.mul (local.get $i) (i32.const 4))))))",
                "        (local.set $i (i32.add (local.get $i) (i32.const 1)))",
                "        (br $argloop)))",
            ]
            call_args = "(local.get $argc) (local.get $args)"
        elif ptypes == []:
            call_args = ""
        else:
            raise CompileError(m.file, m.line,
                               "main must take (int, string[]) or no parameters")
        if m.rettype == "int":
            lines.append(f"    (call $proc_exit (call $id_main {call_args}))")
        else:
            lines.append(f"    (call $id_main {call_args})")
        lines.append("  )")
        return "\n".join(lines)

    def emit_module(self) -> str:
        func_bodies = [self.gen_function(fn) for fn in self.compiler.funcs.values()]
        heap_base = ((self.next_addr + 15) // 16) * 16

        parts = ["(module"]
        parts.append('  (import "wasi_snapshot_preview1" "fd_write" '
                     '(func $fd_write (param i32 i32 i32 i32) (result i32)))')
        parts.append('  (import "wasi_snapshot_preview1" "fd_read" '
                     '(func $fd_read (param i32 i32 i32 i32) (result i32)))')
        parts.append('  (import "wasi_snapshot_preview1" "args_sizes_get" '
                     '(func $args_sizes_get (param i32 i32) (result i32)))')
        parts.append('  (import "wasi_snapshot_preview1" "args_get" '
                     '(func $args_get (param i32 i32) (result i32)))')
        parts.append('  (import "wasi_snapshot_preview1" "proc_exit" '
                     '(func $proc_exit (param i32)))')
        parts.append('  (memory (export "memory") 32)')
        parts.append(f'  (global $heap (mut i32) (i32.const {heap_base}))')
        parts.append('  (global $store_used (mut i64) (i64.const 1))')
        parts.append(f'  (data (i32.const {_NEWLINE_BYTE}) "\\0a")')
        parts.append(f'  (data (i32.const {_MSG_IDX_PRE_ADDR}) "{wat_bytes_literal(_MSG_IDX_PRE)}")')
        parts.append(f'  (data (i32.const {_MSG_IDX_MID_ADDR}) "{wat_bytes_literal(_MSG_IDX_MID)}")')
        parts.append(f'  (data (i32.const {_MSG_IDX_END_ADDR}) "{wat_bytes_literal(_MSG_IDX_END)}")')
        parts.append(f'  (data (i32.const {_MSG_POP_ADDR}) "{wat_bytes_literal(_MSG_POP)}")')
        parts.append(f'  (data (i32.const {_MSG_OOM_ADDR}) "{wat_bytes_literal(_MSG_OOM)}")')
        parts.append(f'  (data (i32.const {_MSG_CAP_ADDR}) "{wat_bytes_literal(_MSG_CAP)}")')
        parts.append(f'  (data (i32.const {_MSG_DIV0_ADDR}) "{wat_bytes_literal(_MSG_DIV0)}")')
        parts.append(f'  (data (i32.const {_MSG_MOD0_ADDR}) "{wat_bytes_literal(_MSG_MOD0)}")')
        parts.append(f'  (data (i32.const {_MSG_DIVOV_ADDR}) "{wat_bytes_literal(_MSG_DIVOV)}")')
        parts.append(f'  (data (i32.const {_MSG_SHNEG_ADDR}) "{wat_bytes_literal(_MSG_SHNEG)}")')
        parts.append(f'  (data (i32.const {_MSG_STORE_PRE_ADDR}) "{wat_bytes_literal(_MSG_STORE_PRE)}")')
        parts.append(f'  (data (i32.const {_MSG_STORE_MID_ADDR}) "{wat_bytes_literal(_MSG_STORE_MID)}")')
        parts.append(f'  (data (i32.const {_MSG_STORE_END_ADDR}) "{wat_bytes_literal(_MSG_STORE_END)}")')
        parts.append(f'  (data (i32.const {_MSG_NEGALLOC_ADDR}) "{wat_bytes_literal(_MSG_NEGALLOC)}")')
        parts.append(f'  (data (i32.const {_MSG_ALLOCOV_ADDR}) "{wat_bytes_literal(_MSG_ALLOCOV)}")')
        parts.append(f'  (data (i32.const {_MSG_NEGLEN_ADDR}) "{wat_bytes_literal(_MSG_NEGLEN)}")')
        for bs, addr in self.str_table.items():
            parts.append(f'  (data (i32.const {addr}) "{wat_bytes_literal(bs)}")')
        for gname, (typ, owner) in self.compiler.exported.items():
            wt = self.wtype(typ)
            zero = {"i32": "(i32.const 0)", "i64": "(i64.const 0)",
                    "f64": "(f64.const 0)"}[wt]
            parts.append(f'  (global $g_{gname} (mut {wt}) {zero})')
        parts.append(wasm_runtime_funcs())
        parts.extend(func_bodies)
        # Export every user-defined function so an embedder (e.g. a JS host
        # driving an idml UI) can call id logic directly, and id_alloc so the
        # host can place string/byte arguments into linear memory. These are
        # additive: the WASI `_start`/`memory` exports (command-style execution
        # under wasmtime) are unaffected, so a program with a `main` still runs
        # as before while also exposing its functions to an embedder.
        for name in self.compiler.funcs:
            parts.append(f'  (export "{name}" (func $id_{name}))')
        parts.append('  (export "id_alloc" (func $id_alloc))')
        entry = self.gen_entrypoint()
        if entry:
            parts.append(entry)
        parts.append(")")
        return "\n".join(parts) + "\n"


def walk_expr(e):
    """Yield an expression and every expression nested inside it."""
    if e is None:
        return
    yield e
    if isinstance(e, CallExpr):
        for a in e.args:
            yield from walk_expr(a)
    elif isinstance(e, BinOp):
        yield from walk_expr(e.left)
        yield from walk_expr(e.right)
    elif isinstance(e, UnOp):
        yield from walk_expr(e.operand)
    elif isinstance(e, IndexExpr):
        yield from walk_expr(e.base)
        yield from walk_expr(e.index)
    elif isinstance(e, ArrayLit):
        for x in e.elems:
            yield from walk_expr(x)


def walk_exprs_in(fn):
    """Yield every expression a function evaluates -- in its body, in its
    return clause, and nested inside either."""
    in_expr = walk_expr

    for s in walk_stmts(fn.body):
        if isinstance(s, DeclStmt):
            yield from in_expr(s.expr)
        elif isinstance(s, AssignStmt):
            yield from in_expr(s.expr)
        elif isinstance(s, IndexAssignStmt):
            yield from in_expr(s.base)
            yield from in_expr(s.index)
            yield from in_expr(s.expr)
        elif isinstance(s, ExprStmt):
            yield from in_expr(s.expr)
        elif isinstance(s, IfStmt):
            yield from in_expr(s.cond)
        elif isinstance(s, WhileStmt):
            yield from in_expr(s.cond)
    yield from in_expr(fn.retexpr)


def walk_stmts(body):
    """Yield every statement, including those nested in if/else blocks."""
    for s in body:
        yield s
        if isinstance(s, IfStmt):
            yield from walk_stmts(s.then)
            if isinstance(s.els, IfStmt):
                yield from walk_stmts([s.els])
            elif s.els:
                yield from walk_stmts(s.els)
        elif isinstance(s, WhileStmt):
            yield from walk_stmts(s.body)


# -- function uniqueness -------------------------------------------------------
# Two functions that are identical except for their name are duplicate
# functionality and a compile error. We fingerprint each function by its
# signature (parameter types + return type) and the structure of its body, with
# the function's own parameters and locals alpha-normalized (v0, v1, ...) so a
# mere renaming can't hide a duplicate. What stays verbatim carries real meaning:
# operators, literals, the names of called functions and builtins, imported and
# exported global names. A self-recursive call is normalized to `self`, so two
# identical recursive functions also collide.

def _canon_expr(e, cn, selfname):
    if isinstance(e, IntLit):
        return "I" + e.value
    if isinstance(e, FloatLit):
        return "F" + e.value
    if isinstance(e, StrLit):
        return "S" + e.raw
    if isinstance(e, VarRef):
        return "v" + cn(e.name)
    if isinstance(e, ImportRef):
        return "g(" + e.name + ")"
    if isinstance(e, CallExpr):
        callee = "self" if e.name == selfname else e.name
        return "c(" + callee + ":" + ",".join(_canon_expr(a, cn, selfname) for a in e.args) + ")"
    if isinstance(e, IndexExpr):
        return "ix(" + _canon_expr(e.base, cn, selfname) + "," + _canon_expr(e.index, cn, selfname) + ")"
    if isinstance(e, ArrayLit):
        return "ar(" + ",".join(_canon_expr(x, cn, selfname) for x in e.elems) + ")"
    if isinstance(e, BinOp):
        return "b" + e.op + "(" + _canon_expr(e.left, cn, selfname) + "," + _canon_expr(e.right, cn, selfname) + ")"
    if isinstance(e, UnOp):
        return "u" + e.op + "(" + _canon_expr(e.operand, cn, selfname) + ")"
    raise AssertionError(e)


def _canon_stmt(s, cn, selfname):
    if isinstance(s, DeclStmt):
        if s.exported:   # exported name is a reserved global -> keep it verbatim
            return "ed:" + s.typ + " " + s.name + "=" + _canon_expr(s.expr, cn, selfname)
        return "d:" + s.typ + " " + cn(s.name) + "=" + _canon_expr(s.expr, cn, selfname)
    if isinstance(s, AssignStmt):
        return "a:" + cn(s.name) + "=" + _canon_expr(s.expr, cn, selfname)
    if isinstance(s, IndexAssignStmt):
        return ("ia:" + _canon_expr(s.base, cn, selfname) + "[" +
                _canon_expr(s.index, cn, selfname) + "]=" + _canon_expr(s.expr, cn, selfname))
    if isinstance(s, IfStmt):
        out = "if(" + _canon_expr(s.cond, cn, selfname) + "){" + _canon_block(s.then, cn, selfname) + "}"
        if isinstance(s.els, IfStmt):
            out += "elif" + _canon_stmt(s.els, cn, selfname)
        elif s.els:
            out += "else{" + _canon_block(s.els, cn, selfname) + "}"
        return out
    if isinstance(s, WhileStmt):
        return "wh(" + _canon_expr(s.cond, cn, selfname) + "){" + _canon_block(s.body, cn, selfname) + "}"
    if isinstance(s, ExprStmt):
        return "e:" + _canon_expr(s.expr, cn, selfname)
    raise AssertionError(s)


def _canon_block(body, cn, selfname):
    return ";".join(_canon_stmt(s, cn, selfname) for s in body)


def canonical_function(fn):
    """A signature+logic fingerprint of a function, independent of its name and
    of how it spells its own parameters and locals."""
    names = {}

    def cn(n):
        if n not in names:
            names[n] = str(len(names))
        return names[n]

    params = ",".join(ptype + " " + cn(pname) for ptype, pname in fn.params)
    body = _canon_block(fn.body, cn, fn.name)
    ret = "void" if fn.retexpr is None else _canon_expr(fn.retexpr, cn, fn.name)
    return "(" + params + ")->" + fn.rettype + "{" + body + "}=>" + ret


# ---------------------------------------------------------------- driver

# A project is a directory tree. To keep it unified and uncluttered, every
# directory in it may hold at most 3 entries, counting .id files and
# subdirectories (other files, e.g. docs, are ignored and don't count). idc
# compiles all .id files in the tree, in a deterministic sorted-path order.
PROJECT_ENTRY_LIMIT = 3

# A project may declare its dependencies (native backends, other id-source
# directories) in a single manifest file at its root. It is NOT compiled as
# source and does NOT count toward a directory's entry limit -- it's metadata,
# the id-native replacement for the --backend flag. See parse_import_manifest.
IMPORT_MANIFEST = "conf.id"
# The name a project used before conf.id. A file still called this is refused
# rather than compiled as ordinary source, which is what would otherwise happen
# and would report a parse error in a dependency list.
LEGACY_MANIFEST = "import.id"

# A constant declaration in conf.id: the same `TYPE name = value;` a function
# body would write. Constants live here rather than in a function because a
# value assigned once and never changed does not need a function to exist --
# see the "assigned once" check in the semantic pass, which says so by name.
STRICT_CONST = False

CONST_DECL = re.compile(r'^(int|word|float|string)(\[\])?\s+[A-Za-z_]\w*\s*=.*;$')


def source_unit(path, roots):
    """Which compilation unit `path` belongs to: the index of its source root.

    A unit is one source root -- the program's own tree, or one imported
    dependency such as the standard library -- and it is the scope of the
    one-type-per-name rule (docs/IDSTD.md C4). A file's root is the LONGEST of
    `roots` that prefixes it, so a dependency nested inside the project belongs
    to the dependency; ties go to the earliest. bin/idc derives the unit the
    same way and passes it to the self-hosted compiler in the `#file` marker,
    and the two must agree or the same program draws different diagnostics from
    the two compilers."""
    best, unit = -1, 0
    for i, root in enumerate(roots):
        if len(root) > best and path.startswith(root):
            best, unit = len(root), i
    return unit


def collect_project(root):
    """Walk the project tree, enforce the per-directory entry limit, and return
    every .id file in deterministic (sorted full-path) order."""
    id_files = []
    for dirpath, dirnames, filenames in os.walk(root):
        # ignore hidden entries; they neither compile nor count
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        # the dependency manifest is metadata, not source: never compiled, never
        # counted toward the per-directory entry limit.
        ids = [n for n in filenames if n.endswith(".id") and n != IMPORT_MANIFEST]
        # A file still called import.id would otherwise be compiled as source,
        # and its `import "../lib"` lines would be reported as a syntax error in
        # a file the author thinks is configuration. Name the rename instead.
        if LEGACY_MANIFEST in filenames:
            raise CompileError(
                os.path.join(dirpath, LEGACY_MANIFEST), 1,
                f"'{LEGACY_MANIFEST}' is now called '{IMPORT_MANIFEST}' -- it "
                f"holds constants as well as dependencies. Rename it")
        # ...but only at a root, which is the only place one is read. A nested
        # one is neither compiled nor parsed as a manifest, so it vanishes --
        # and the only symptom is "no such function" at the caller, blaming a
        # file that is fine. Say what actually happened instead.
        if IMPORT_MANIFEST in filenames and os.path.abspath(dirpath) != os.path.abspath(root):
            raise CompileError(
                os.path.join(dirpath, IMPORT_MANIFEST), 1,
                f"'{IMPORT_MANIFEST}' is the dependency manifest and is only "
                f"read at the root of a project or a dependency. Here it is "
                f"neither compiled nor read, so anything it defines silently "
                f"does not exist; rename it")
        entries = len(ids) + len(dirnames)
        if entries > PROJECT_ENTRY_LIMIT:
            raise CompileError(
                dirpath, 1,
                f"a project directory may contain at most {PROJECT_ENTRY_LIMIT} "
                f"files and directories combined, but this one has {entries} "
                f"(.id files and subdirectories); split it into subdirectories")
        id_files.extend(os.path.join(dirpath, n) for n in ids)
    if not id_files:
        raise CompileError(root, 1, "no .id files in this project")
    id_files.sort()
    return id_files


def parse_import_manifest(root):
    """Read <root>/conf.id if present and return the dependency directories it
    names. Each non-blank, non-comment line is `import "<relative-dir>"`; the
    path is resolved relative to the manifest. This is the id-native way to
    attach dependencies (replacing --backend): a dependency that carries a
    backend.json is linked as a native backend, any other directory is merged in
    as additional id source. Returns [] when there is no manifest."""
    path = os.path.join(root, IMPORT_MANIFEST)
    if not os.path.isfile(path):
        return []
    deps = []
    seen_const = False
    with open(path) as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("//"):
                continue
            # Constants come after imports, so a reader sees where the code
            # comes from before what it is configured with. A constant is a
            # declaration exactly as it would be written in a function body.
            if CONST_DECL.match(line):
                seen_const = True
                continue
            if seen_const:
                raise CompileError(
                    path, lineno,
                    f'imports come before constants in {IMPORT_MANIFEST}; '
                    f'{raw.strip()!r} follows a constant declaration')
            m = re.match(r'^import\s+"([^"]+)"\s*$', line)
            if not m:
                raise CompileError(
                    path, lineno,
                    f'malformed conf.id line: {raw.rstrip()!r}; each dependency '
                    f'is a line of the form  import "relative/dir", and each '
                    f'constant a line of the form  int name = value;')
            dep = os.path.normpath(os.path.join(root, m.group(1)))
            if not os.path.isdir(dep):
                raise CompileError(
                    path, lineno,
                    f'import "{m.group(1)}" does not resolve to a directory '
                    f'(looked for {dep})')
            deps.append(dep)
    return deps


# --------------------------------------------------------------- the stdlib
#
# `idstd` is the standard library, and it is imported by DEFAULT: a program
# writes `print(fx_max(a, b))` with no conf.id line and no flag. That is the
# whole point of a standard library, and it is the one dependency a program
# does not declare.
#
# It is merged exactly like a source dependency named in an conf.id -- same
# entry-count rule, same transitive manifest walk -- so a stdlib module that
# needs a native backend (a framebuffer needs backends/gfx) declares it in the
# stdlib's own conf.id and every program gets it. That only works because
# imports are transitive (resolve_deps); it is why the two landed together.
#
# THREE things must be able to turn it off, and all three are real:
#   1. idstd itself, which cannot import itself.
#   2. The bootstrap stages, compiler/lex{,_parse}. They define their own
#      helpers (`lset`, and a local vocabulary); implicitly importing a library
#      that also defines them is a duplicate-logic error, and any change to
#      their emitted C breaks self-hosting and byte-parity. bin/idc bootstraps
#      them with --no-std for exactly this reason.
#   3. tests/invalid/, whose diagnostics must not shift because a library
#      appeared in the program.
STDLIB_DIR_NAME = "idstd"


def resolve_stdlib(explicit=None, no_std=False):
    """Locate the standard library, or return None when there is none.

    Order: --no-std / IDC_NO_STD wins over everything; then an explicit --std;
    then $IDSTD_HOME; then a sibling of this repository or of the one above. A
    checkout with no idstd beside it simply has no standard library -- that is
    not an error, because the compiler has to keep building the language's own
    bootstrap in a tree where the library does not exist yet."""
    if no_std or os.environ.get("IDC_NO_STD"):
        return None
    for src, path in (("--std", explicit),
                      ("$IDSTD_HOME", os.environ.get("IDSTD_HOME"))):
        if path:
            if not os.path.isdir(path):
                raise CompileError(path, 1,
                                   f"{src} does not name a directory")
            return os.path.abspath(path)
    here = os.path.dirname(os.path.abspath(__file__))
    ups = [os.pardir, os.path.join(os.pardir, os.pardir)]
    near = [os.path.normpath(os.path.join(here, u, STDLIB_DIR_NAME)) for u in ups]
    return next((p for p in near if os.path.isdir(p)), None)


def resolve_deps(root):
    """Resolve a project's dependency graph *transitively*, and return
    (source_dirs, backend_dirs).

    An imported directory's own `conf.id` is read too. Without that, a
    library cannot declare its own dependencies: the `gfx` library in a
    standard library could not say it needs `backends/gfx`, so every program
    that used one line of it had to name the backend itself -- which defeats
    the point of a library, and defeats "imported by default" entirely.

    Walked breadth-first from the project, so the order a project writes its
    manifest in is the order its dependencies are merged in. Every directory
    is visited once, keyed on its resolved path, which is also what makes a
    cycle (a <-> b, or the diamond a -> b, a -> c, b -> d, c -> d) terminate
    rather than recurse forever."""
    seen = {os.path.realpath(root)}
    queue = [root]
    sources, backends = [], []
    while queue:
        cur = queue.pop(0)
        for dep in parse_import_manifest(cur):
            key = os.path.realpath(dep)
            if key in seen:
                continue
            seen.add(key)
            if os.path.isfile(os.path.join(dep, "backend.json")):
                # A backend is a leaf: it is native source plus a manifest,
                # and it has no conf.id of its own to follow.
                backends.append(dep)
            else:
                sources.append(dep)
                queue.append(dep)
    return sources, backends


def dedupe_backends(dirs):
    """One backend named twice is still one backend.

    `--backend backends/fs` on a project whose conf.id already imports it --
    the two documented ways to attach the same dependency -- used to append the
    directory twice, compile its sources twice, and hand cc the same object
    file twice, which is a hard "multiple definition" error for every symbol
    the backend exports. Collapse by resolved path, keeping the first mention
    so the link order a project asked for is the link order it gets."""
    seen, out = set(), []
    for d in dirs:
        key = os.path.realpath(d)
        if key in seen:
            continue
        seen.add(key)
        out.append(d)
    return out


def platform_key():
    """Map sys.platform to a backend.json platform key."""
    if sys.platform == "darwin":
        return "darwin"
    if sys.platform.startswith("linux"):
        return "linux"
    return sys.platform


def backend_platforms(spec, target):
    """The platform table a backend offers for one *compiler* target.

    A backend describes itself twice. `abi` says which functions it provides
    and what their id-level signatures are -- that part is about `id`, not
    about C, and is the same however the program is compiled. `targets` says
    how to obtain those functions for a given code generator: the C target
    wants sources/cflags/link, an LLVM or wasm target or an interpreter will
    want something else, and each can be added under its own key without a
    single `.id` file changing.

    A manifest with no `targets` is a pre-`targets` one (gfx, gl): its bare
    `platforms` table is the C target's, and no other target is offered.

    Returns the {platform: impl} mapping, or None if this backend has nothing
    for this target."""
    targets = spec.get("targets")
    if targets is None:
        if target != "c":
            return None
        return spec.get("platforms") or {}
    entry = targets.get(target)
    if entry is None:
        return None
    return entry.get("platforms") or {}


def resolve_backend(dir_path, cc):
    """Read a backend dir's manifest, compile its sources for this platform, and
    return (objects, link_flags). Objects are temp .o files the caller links and
    then removes. Raises CompileError on a bad/unsupported backend."""
    manifest = os.path.join(dir_path, "backend.json")
    try:
        with open(manifest) as f:
            spec = json.load(f)
    except OSError:
        raise CompileError(dir_path, 0, f"backend has no backend.json: {manifest}")
    except ValueError as e:
        raise CompileError(manifest, 0, f"invalid backend.json: {e}")

    key = platform_key()
    name = spec.get("name", os.path.basename(dir_path.rstrip("/")))
    plats = backend_platforms(spec, "c")
    if plats is None:
        raise CompileError(manifest, 0,
                           f"backend '{name}' has no implementation for the C target "
                           f"(its manifest declares: "
                           f"{', '.join(sorted(spec.get('targets') or {})) or 'none'})")
    plat = plats.get(key)
    if plat is None:
        raise CompileError(manifest, 0,
                           f"backend '{name}' has no support for platform '{key}'")

    objects = []
    for src in plat.get("sources", []):
        src_path = os.path.join(dir_path, src)
        obj = os.path.splitext(src_path)[0] + ".gen.o"
        cmd = [cc, "-O2", "-c", src_path, "-o", obj] + list(plat.get("cflags", []))
        res = subprocess.run(cmd, stderr=subprocess.PIPE, text=True)
        if res.stderr:
            sys.stderr.write(res.stderr)
        if res.returncode != 0:
            for o in objects:
                if os.path.exists(o):
                    os.unlink(o)
            msg = f"backend compile failed (command: {' '.join(cmd)})"
            # A backend links native system libraries (OpenGL, X11, ...). On a
            # system where their dev headers/libs aren't on the compiler's
            # default search path -- notably NixOS -- the compile fails with a
            # missing-header/library error. Point the user at the dev-shell,
            # which provides them, rather than leaving a cryptic cc error.
            low = (res.stderr or "").lower()
            if ("no such file" in low or "not found" in low
                    or "fatal error" in low or os.path.exists("/etc/NIXOS")):
                bdir = dir_path.rstrip("/")
                msg += ("\n  hint: this backend links native dev libraries (OpenGL, "
                        "X11, ...) whose headers may not be on the compiler's default\n"
                        "        search path (e.g. on NixOS). Build inside the dev-shell, "
                        "which provides them:\n"
                        f"          tools/devshell.sh './idc.py YOUR_PROJECT "
                        f"--backend {bdir} -o OUT'")
            raise CompileError(src_path, 0, msg)
        objects.append(obj)
    return objects, list(plat.get("link", []))


def main(argv):
    ap = argparse.ArgumentParser(prog="idc", description="compiler for the id language")
    ap.add_argument("path",
                    help="a single .id file, or a project directory (its whole "
                         "tree of .id files is compiled together)")
    ap.add_argument("-o", "--output", help="output executable path")
    ap.add_argument("--target", choices=["c", "llvm", "wasm"], default="c",
                    help="codegen target (default: c)")
    ap.add_argument("--emit-c", metavar="FILE", help="write the generated C and stop")
    ap.add_argument("--emit-llvm", metavar="FILE",
                    help="write the generated LLVM IR (.ll) and stop (--target llvm)")
    ap.add_argument("--emit-wasm", metavar="FILE",
                    help="write the generated WebAssembly text (.wat) and stop "
                         "(--target wasm)")
    ap.add_argument("--keep-c", action="store_true",
                    help="keep the generated C next to the output")
    ap.add_argument("--cc", default="cc", help="C compiler to use (default: cc)")
    ap.add_argument("--no-std", action="store_true",
                    help="do not import the standard library. Needed by idstd "
                         "itself, by the bootstrap stages (which define their "
                         "own helpers), and by diagnostic fixtures")
    ap.add_argument("--std", metavar="DIR",
                    help="use DIR as the standard library (default: $IDSTD_HOME, "
                         "else an 'idstd' directory beside this repository)")
    ap.add_argument("--tests", action="store_true",
                    help="run every function's test cases (docs/TESTS.md) and "
                         "fail the build if one fails; nothing is written until "
                         "they pass, --emit-c included")
    ap.add_argument("--strict-const", action="store_true",
                    help="reject an exported value that is assigned once and "
                         "never changed; it belongs in conf.id")
    ap.add_argument("--require-tests", action="store_true",
                    help="additionally reject any function carrying fewer than "
                         "two cases (implies --tests)")
    ap.add_argument("--backend", action="append", default=[], metavar="DIR",
                    help="DEPRECATED: prefer an conf.id manifest in the project. "
                         "Link a native backend directory (reads its backend.json "
                         "for this platform's sources and link flags); repeatable")
    args = ap.parse_args(argv)
    if args.require_tests:
        args.tests = True
    # Off by default, and the reason is not caution: it is correct today and
    # every program fails it, because idstd's fx_sintab is a 91-entry literal
    # assigned once in a function that does nothing else -- exactly what the
    # check is for. It cannot be the default until conf.id constants are
    # EMITTED (they are parsed and ordered, not yet declared as globals) and
    # idstd has moved its own across. See docs/TODO.md.
    global STRICT_CONST
    STRICT_CONST = args.strict_const

    try:
        # Every source root, in the order they are added: the program's own
        # tree first, then each dependency, then the standard library and its
        # own. One root is one compilation unit -- see source_unit.
        roots = []
        if os.path.isdir(args.path):
            roots.append(args.path)
            source_files = collect_project(args.path)
            # Dependencies declared in the project's conf.id, and in the
            # conf.id of every directory it reaches: a backend dir is linked
            # (like --backend); any other dir is merged in as id source.
            dep_sources, dep_backends = resolve_deps(args.path)
            args.backend.extend(dep_backends)
            for dep in dep_sources:
                roots.append(dep)
                source_files.extend(collect_project(dep))
        elif os.path.isfile(args.path):
            roots.append(args.path)
            source_files = [args.path]
        else:
            print(f"idc: no such file or directory: '{args.path}'", file=sys.stderr)
            return 1

        # The standard library, merged in unless turned off. A single file gets
        # it too: `idc prog.id` is the tutorial path, and it is the one that
        # most needs fx_max to already exist.
        stdlib = resolve_stdlib(args.std, args.no_std)
        if stdlib is not None:
            roots.append(stdlib)
            source_files.extend(collect_project(stdlib))
            std_sources, std_backends = resolve_deps(stdlib)
            args.backend.extend(std_backends)
            for dep in std_sources:
                roots.append(dep)
                source_files.extend(collect_project(dep))
        source_files = sorted(set(source_files))
        units = {path: source_unit(path, roots) for path in source_files}
        args.backend = dedupe_backends(args.backend)

        funcs_by_file = {}
        for path in source_files:
            with open(path) as f:
                src = f.read()
            funcs_by_file[path] = Parser(lex(src, path)).parse_file()
        compiler = Compiler(funcs_by_file, has_backend=bool(args.backend),
                            units=units)
        if args.target == "c":
            code = compiler.compile()
        elif args.target == "llvm":
            compiler.validate()
            code = LLVMBackend(compiler).emit_module()
        else:
            compiler.validate()
            code = WasmBackend(compiler).emit_module()
        # The cases run before anything is written: a program whose cases fail
        # must not produce output of any kind (docs/TESTS.md).
        if args.tests and run_tests(funcs_by_file, compiler, args):
            return 1
    except CompileError as err:
        print(str(err), file=sys.stderr)
        return 1
    except OSError as err:
        print(f"idc: {err}", file=sys.stderr)
        return 1

    if args.target == "c" and args.emit_c:
        with open(args.emit_c, "w") as f:
            f.write(code)
        print(f"wrote {args.emit_c}")
        return 0
    if args.target == "llvm" and args.emit_llvm:
        with open(args.emit_llvm, "w") as f:
            f.write(code)
        print(f"wrote {args.emit_llvm}")
        return 0
    if args.target == "wasm" and args.emit_wasm:
        with open(args.emit_wasm, "w") as f:
            f.write(code)
        print(f"wrote {args.emit_wasm}")
        return 0

    have_main = "main" in compiler.funcs
    out = args.output
    if out is None:
        # default name: the project directory's name, or the file's stem
        first = os.path.normpath(args.path)
        base = os.path.basename(first if os.path.isdir(first)
                                else os.path.splitext(first)[0])
        out = os.path.join(BUILD_DIR, base + (".o" if not have_main else ""))
        os.makedirs(BUILD_DIR, exist_ok=True)

    out, note, err = choose_output_path(out, args.output is not None)
    if err is not None:
        print(f"idc: {err}", file=sys.stderr)
        return 1
    if note is not None:
        print(f"idc: {note}", file=sys.stderr)

    if args.target != "c" and args.backend:
        warn(args.path, 0,
             f"--backend ignored: native graphics/real-time backends are C-only "
             f"(--target {args.target} doesn't support them)")

    if args.target == "c":
        return build_c(compiler, code, args, out, have_main)
    if args.target == "llvm":
        return build_llvm(code, args, out, have_main)
    return build_wasm(code, args, out, have_main)


# A scaling claim is a comparison of two counts, and the smaller of the two
# carries whatever fixed setup the function does. Without slack that fixed cost
# reads as growth; 4x is enough to absorb it without hiding a change of order.
CONSTRAINT_SLACK = 4


def growth(bound, n) -> float:
    """What `bound` predicts at size `n`, up to a constant."""
    n = max(n, 1)
    if bound == "O(1)":
        return 1.0
    if bound == "O(log n)":
        return math.log2(max(n, 2))
    if bound == "O(n)":
        return float(n)
    if bound == "O(n log n)":
        return n * math.log2(max(n, 2))
    return float(n) * n          # O(n^2)


def case_size(case: TestCase) -> int:
    """`n` for a case: the largest size among its arguments."""
    return max((literal_size(a) for a in case.args), default=0)


def run_tests(funcs_by_file, compiler, args) -> bool:
    """Build the harness, run every case, and check every scaling claim.

    Returns True when the build must stop because a case failed (the harness
    has already said which). Anything the compiler decides for itself -- a
    function with too few cases, a claim that cannot be checked, a claim that
    does not hold -- is a CompileError."""
    if args.require_tests:
        for fn in compiler.funcs.values():
            if len(fn.cases) < 2:
                raise CompileError(fn.file, fn.line,
                                   f"function '{fn.name}' has {len(fn.cases)} "
                                   f"test case(s); --require-tests needs at "
                                   f"least 2 (see docs/TESTS.md)")
    tested = [fn for fn in compiler.funcs.values() if fn.cases]
    if not tested:
        return False

    harness = Compiler(funcs_by_file, has_backend=bool(args.backend),
                       instrument=True, units=compiler.units)
    code = harness.compile()
    with tempfile.TemporaryDirectory() as tmp:
        c_path = os.path.join(tmp, "tests.c")
        bin_path = os.path.join(tmp, "tests")
        counts_path = os.path.join(tmp, "counts")
        with open(c_path, "w") as f:
            f.write(code)
        cmd = [args.cc, "-std=c11", "-O0", c_path, "-o", bin_path]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"idc: the test harness did not build; this is a bug in idc "
                  f"unless the program needs a native backend (command: "
                  f"{' '.join(cmd)})", file=sys.stderr)
            sys.stderr.write(res.stderr)
            return True
        if subprocess.run([bin_path, counts_path],
                          stdin=subprocess.DEVNULL).returncode != 0:
            return True
        counts = read_counts(counts_path)
    check_constraints(tested, counts)
    return False


def read_counts(path) -> dict:
    """(function, case index) -> (time, mem), as the harness measured them."""
    counts = {}
    with open(path) as f:
        for line in f:
            name, idx, t, m = line.split()
            counts[(name, int(idx))] = (int(t), int(m))
    return counts


def check_constraints(tested, counts):
    for fn in tested:
        claims = []
        for case in fn.cases:
            for claim in case.constraints:
                if claim not in claims:
                    claims.append(claim)
        for kind, bound in claims:
            group = [(i, c) for i, c in enumerate(fn.cases)
                     if (kind, bound) in c.constraints]
            head = group[0][1]
            if len(group) < 2 or len({case_size(c) for _, c in group}) < 2:
                raise CompileError(head.file, head.line,
                                   f"[{kind}:{bound}] needs a second case with a "
                                   f"different input size to compare against")
            group.sort(key=lambda pair: case_size(pair[1]))
            (i1, small), (i2, big) = group[0], group[-1]
            n1, n2 = case_size(small), case_size(big)
            col = 0 if kind == "time" else 1
            c1 = counts.get((fn.name, i1), (0, 0))[col]
            c2 = counts.get((fn.name, i2), (0, 0))[col]
            allowed = (max(c1, 1) * growth(bound, n2) / growth(bound, n1)
                       * CONSTRAINT_SLACK)
            if c2 > allowed:
                raise CompileError(big.file, big.line,
                                   f"[{kind}:{bound}] does not hold for "
                                   f"'{fn.name}': {kind} is {c1} at n={n1} and "
                                   f"{c2} at n={n2}, where {bound} allows at most "
                                   f"{int(allowed)}")


BUILD_DIR = "build"


def choose_output_path(out, explicit):
    """Settle on a path the executable can actually be written to.

    Default output goes to build/, which is what keeps the compiler's own
    choice of name from colliding with the project directory it was named
    after. An explicit -o can still land on a directory, and cc would then
    fail with "cannot open output file: Is a directory" -- a message about
    the build that reads as a message about the source (and which bin/idc
    used to blame on its own codegen).

    Passing a project directory is the supported way to build one, so the
    compiler does not refuse it: when the colliding name is the *compiler's*
    choice, it picks another one and says so. An explicit -o is the user's
    choice, and is reported rather than silently changed.

    Returns (path, note, error); at most one of note/error is set."""
    if not os.path.isdir(out):
        return out, None, None
    if explicit:
        return out, None, f"-o '{out}' is a directory; choose a different output path"
    alt = out + ".out"
    if os.path.isdir(alt):
        return out, None, (f"'{out}' and '{alt}' are both directories; "
                           f"pass -o NAME to name the executable")
    return alt, (f"'{out}' is the project directory, so the executable cannot take "
                 f"its name; writing it to '{alt}' instead (pass -o NAME to choose)"), None


def build_c(compiler, c_code, args, out, have_main):
    # Native backends link only into a real executable; a library .o has nothing
    # to link them into, so skip (with a note) when there is no main.
    backend_objs, backend_link = [], []
    if args.backend and not have_main:
        warn(args.path, 0, "--backend ignored: this project has no main (builds "
                           "to a .o); link the backend into the final program")
    elif args.backend:
        try:
            for d in args.backend:
                objs, link = resolve_backend(d, args.cc)
                backend_objs += objs
                backend_link += link
        except CompileError as err:
            for o in backend_objs:
                if os.path.exists(o):
                    os.unlink(o)
            print(str(err), file=sys.stderr)
            return 1

    c_path = (os.path.splitext(out)[0] + ".c") if args.keep_c else out + ".gen.c"
    with open(c_path, "w") as f:
        f.write(c_code)

    cmd = [args.cc, "-std=c11", "-O2", c_path] + backend_objs + ["-o", out] + backend_link
    if not have_main:
        cmd.insert(1, "-c")  # no entrypoint: produce an object file to link later
    try:
        res = subprocess.run(cmd)
    finally:
        if not args.keep_c:
            os.unlink(c_path)
        for o in backend_objs:
            if os.path.exists(o):
                os.unlink(o)
    if res.returncode != 0:
        print(f"idc: C compilation failed (command: {' '.join(cmd)})", file=sys.stderr)
        return 1
    return 0


def build_llvm(ll_code, args, out, have_main):
    """Lower the emitted LLVM IR to a native binary with clang, reusing the
    existing C `RUNTIME` (compiled by clang alongside the .ll) for lists,
    strings, and the rest of the id builtins."""
    ll_path = out + ".gen.ll"
    rt_path = out + ".gen.rt.c"
    with open(ll_path, "w") as f:
        f.write(ll_code)
    with open(rt_path, "w") as f:
        # the C target's RUNTIME marks every helper `static` (internal linkage,
        # fine when it's spliced into the single generated C file); the .ll
        # here is a *separate* translation unit that calls these functions, so
        # this copy (used only for the llvm/wasm build step -- never for
        # --target c's emitted C, which stays byte-identical) drops `static`
        # to give them external linkage.
        f.write(re.sub(r"(?m)^static ", "", RUNTIME))
    if have_main:
        cmd = ["clang", "-O2", "-Wno-override-module", rt_path, ll_path, "-o", out]
    else:
        # no entrypoint: emit an object file (its id_* runtime references stay
        # unresolved, to be linked against a runtime later, like the C target)
        cmd = ["clang", "-O2", "-Wno-override-module", "-c", ll_path, "-o", out]
    try:
        res = subprocess.run(cmd)
    finally:
        os.unlink(ll_path)
        os.unlink(rt_path)
    if res.returncode != 0:
        print(f"idc: LLVM compilation failed (command: {' '.join(cmd)})", file=sys.stderr)
        return 1
    return 0


def build_wasm(wat_code, args, out, have_main):
    """Assemble the emitted WebAssembly text with wat2wasm into a runnable
    (wasmtime-runnable, WASI command-style) module."""
    wat_path = out + ".gen.wat"
    with open(wat_path, "w") as f:
        f.write(wat_code)
    cmd = ["wat2wasm", wat_path, "-o", out]
    try:
        res = subprocess.run(cmd)
    finally:
        os.unlink(wat_path)
    if res.returncode != 0:
        print(f"idc: wasm assembly failed (command: {' '.join(cmd)})", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
