#!/usr/bin/env python3
"""Rewrite `id` source to the expression-shape rules of docs/SPEC.md 7.1.

    tools/flatten.py FILE...        rewrite in place
    tools/flatten.py --check FILE   report, change nothing

Two rules, one idea: a value that takes a step to compute is given a name, and
the name is what the reader of the line sees.

    } return int lm_len(s2w(s));        ->   word s2w_v = s2w(s);
                                             int ret_i = lm_len(s2w_v);
                                        }    return int ret_i;

This tool exists because the rules arrived after about 1600 places in this
repository and in `idstd` had already been written the other way. It is a
migration, not a formatter: it makes the smallest edit that satisfies the
rules and leaves every comment, blank line and piece of spacing alone, because
the comments in this tree carry most of its reasoning.

WHAT IT DOES NOT DO. The action limit is 3 and this tool adds statements, so a
block that was already full becomes a block that is over. Splitting a function
needs a name for the new one and a decision about which statements move, and
neither is mechanical -- so those are left for a person, and the compiler
names every one of them.

NAMES. A returned value is `ret_<tag>`, tagged by type, because `id` gives a
name one type across a whole program and a single `ret` could therefore only
ever be one type. A hoisted call's value is `<callee>_v`, which is
type-consistent for free: a function has one return type, so every hoist of it
carries the same one.
"""
import re
import sys

TYPE = r'(?:int|word|float|string|void)(?:\[\])*'
TAG = {'int': 'i', 'word': 'w', 'float': 'f', 'string': 's'}

# The builtins, and the types they answer with. Derived from docs/SPEC.md
# rather than from either compiler: a hoisted call needs a declared type, and
# a builtin has no `} return T ...` line anywhere to read one from.
# Read off compiler/parse/mid/types/type_of/call/builtin/, which is where the
# primary compiler keeps the same table. `pop` is None because its type is its
# argument's element type, which is not a property of the name.
BUILTIN = {
    'input': 'string', 'read_all': 'string', 'chr': 'string',
    'str_of_mem': 'string', 'w2s': 'string',
    'to_int': 'int', 'len': 'int', 'charat': 'int', 'ult': 'int',
    'alloc': 'word', 'store_size': 'word', 'peek8': 'word', 'peek16': 'word',
    'peek32': 'word', 'peek64': 'word', 'udiv': 'word', 'umod': 'word',
    'ushr': 'word', 'mem_of_str': 'word', 'ticks': 'word', 's2w': 'word',
    'ld8': 'word', 'ld16': 'word', 'ld32': 'word', 'ld64': 'word',
    'int_of_float': 'int', 'float_of_int': 'float',
    'word_of_float': 'word', 'float_of_word': 'float',
    'pop': None,
}


def backend_abi(roots):
    """A native backend declares its functions in backend.json rather than in
    `id`, so their return types are not in any `} return T ...` line."""
    import json
    import os
    out = {}
    for r in roots:
        for base, dirs, fs in os.walk(r):
            if 'backend.json' not in fs:
                continue
            try:
                d = json.load(open(os.path.join(base, 'backend.json')))
            except (OSError, ValueError):
                continue
            for v in (d.values() if isinstance(d, dict) else []):
                for row in (v if isinstance(v, list) else []):
                    if isinstance(row, dict) and 'name' in row and 'returns' in row:
                        out[row['name']] = row['returns']
    return out
# Builtins that return nothing, so a call to one is a statement and never an
# operand -- listing them keeps a `print(...)` from being mistaken for a value.
VOID_BUILTIN = {'print', 'put', 'flush', 'push', 'lset', 'wset', 'sset',
                'poke8', 'poke16', 'poke32', 'poke64', 'st8', 'st16', 'st32',
                'st64', 'free'}

KEYWORDS = {'if', 'else', 'while', 'return', 'export', 'import', 'asm', 'const'}


# ------------------------------------------------------------------ tokens

class Tok:
    __slots__ = ('kind', 'text', 'a', 'b')

    def __init__(self, kind, text, a, b):
        self.kind, self.text, self.a, self.b = kind, text, a, b

    def __repr__(self):
        return f'{self.kind}:{self.text}'


NUM = re.compile(r'0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*\.[0-9_]+|[0-9][0-9_]*')
NAME = re.compile(r'[A-Za-z_][A-Za-z_0-9]*')
OPS = ['<<', '>>', '<=', '>=', '==', '!=', '&&', '||',
       '+', '-', '*', '/', '%', '<', '>', '=', '&', '|', '^', '!', '~',
       '(', ')', '[', ']', '{', '}', ',', ';', '.']


def lex(src):
    """Tokens with source spans. Comments and whitespace are dropped here and
    survive in the output only because every edit is a splice by span."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            i += 1
            continue
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            j = min(j + 1, n)
            out.append(Tok('str', src[i:j], i, j))
            i = j
            continue
        m = NUM.match(src, i)
        if m and (c.isdigit()):
            out.append(Tok('num', m.group(0), i, m.end()))
            i = m.end()
            continue
        m = NAME.match(src, i)
        if m:
            t = m.group(0)
            out.append(Tok('kw' if t in KEYWORDS else 'name', t, i, m.end()))
            i = m.end()
            continue
        for op in OPS:
            if src.startswith(op, i):
                out.append(Tok('op', op, i, i + len(op)))
                i += len(op)
                break
        else:
            i += 1
    out.append(Tok('eof', '', n, n))
    return out


# ------------------------------------------------------------------ parse
#
# Just enough of the expression grammar to know where a call is and how far it
# reaches. Precedence is not modelled: nothing here reorders anything, so a
# flat left-to-right chain of binaries carries the same spans a precedence
# ladder would.

class Node:
    __slots__ = ('kind', 'name', 'kids', 'a', 'b')

    def __init__(self, kind, name, kids, a, b):
        self.kind, self.name, self.kids, self.a, self.b = kind, name, kids, a, b

    def calls(self):
        """Every call node in this subtree, innermost first."""
        out = []
        for k in self.kids:
            out += k.calls()
        if self.kind == 'call':
            out.append(self)
        return out

    def guarded(self):
        """Calls that && or || may skip. Hoisting one of these would compute
        it unconditionally, which is a different program -- `charat` past the
        end is a value, but a divide or a list index is a trap."""
        out = []
        for i, k in enumerate(self.kids):
            out += k.guarded()
            if self.kind == 'bin' and self.name in ('&&', '||') and i == 1:
                out += k.calls()
        return out


class P:
    def __init__(self, toks):
        self.t, self.i = toks, 0

    def cur(self):
        return self.t[self.i]

    def eat(self, text=None):
        t = self.t[self.i]
        self.i += 1
        return t

    def at(self, text):
        return self.t[self.i].text == text

    def expr(self):
        e = self.unary()
        while self.cur().kind == 'op' and self.cur().text in (
                '+', '-', '*', '/', '%', '<', '>', '=', '&', '|', '^',
                '<<', '>>', '<=', '>=', '==', '!=', '&&', '||'):
            op = self.eat()
            r = self.unary()
            e = Node('bin', op.text, [e, r], e.a, r.b)
        return e

    def unary(self):
        if self.cur().kind == 'op' and self.cur().text in ('-', '!', '~'):
            t = self.eat()
            k = self.unary()
            return Node('un', t.text, [k], t.a, k.b)
        return self.postfix()

    def postfix(self):
        e = self.atom()
        while self.at('['):
            self.eat()
            ix = self.expr()
            end = self.cur().b
            if self.at(']'):
                self.eat()
            e = Node('index', '', [e, ix], e.a, end)
        return e

    def atom(self):
        t = self.cur()
        if t.text == '(':
            self.eat()
            if self.cur().text == 'import':
                self.eat()
                nm = self.eat()
                end = self.cur().b
                if self.at(')'):
                    self.eat()
                return Node('import', nm.text, [], t.a, end)
            e = self.expr()
            end = self.cur().b
            if self.at(')'):
                self.eat()
            return Node('paren', '', [e], t.a, end)
        if t.text == '[':
            self.eat()
            kids = []
            while not self.at(']') and self.cur().kind != 'eof':
                kids.append(self.expr())
                if self.at(','):
                    self.eat()
            end = self.cur().b
            if self.at(']'):
                self.eat()
            return Node('arr', '', kids, t.a, end)
        if t.kind in ('num', 'str'):
            self.eat()
            return Node('lit', t.text, [], t.a, t.b)
        if t.kind == 'name':
            self.eat()
            if self.at('('):
                self.eat()
                kids = []
                while not self.at(')') and self.cur().kind != 'eof':
                    kids.append(self.expr())
                    if self.at(','):
                        self.eat()
                end = self.cur().b
                if self.at(')'):
                    self.eat()
                return Node('call', t.text, kids, t.a, end)
            return Node('var', t.text, [], t.a, t.b)
        self.eat()
        return Node('bad', t.text, [], t.a, t.b)


def parse_expr(src, a, b):
    toks = [t for t in lex(src[a:b])]
    for t in toks:
        t.a += a
        t.b += a
    p = P(toks)
    return p.expr()


# ------------------------------------------------------------------ shape

FUNC_HEAD = re.compile(r'^(?:asm\s+"[^"]*"\s+)?([a-z_][a-z_0-9]*)\s*\(')
RET_LINE = re.compile(r'^\}\s*return\s+(' + TYPE + r')\s*(.*?);\s*$')
RET_VOID = re.compile(r'^\}\s*return\s+void\s*;?\s*$')


def is_plain(src, expr_text):
    """A name, an imported name, or a literal written where it is read."""
    s = expr_text.strip()
    if NAME.fullmatch(s) and s not in KEYWORDS:
        return True
    if NUM.fullmatch(s):
        return True
    if s.startswith('-') and NUM.fullmatch(s[1:].strip()):
        return True
    if s.startswith('"') and s.endswith('"') and s.count('"') == 2:
        return True
    if re.fullmatch(r'\(\s*import\s+[a-z_][a-z_0-9]*\s*\)', s):
        return True
    return False


def ret_name(ty):
    base = ty.replace('[]', '')
    tag = TAG.get(base, 'x')
    return 'ret_' + ('l' + tag if ty.endswith('[]') else tag)


def scan_rettypes(paths):
    """name -> declared return type, read from every `} return T ...;` in the
    files given. A hoisted call needs a type to declare, and this is where the
    language writes one down."""
    out = dict(BUILTIN)
    for p in paths:
        try:
            src = open(p, errors='replace').read()
        except OSError:
            continue
        cur = None
        for line in src.split('\n'):
            m = FUNC_HEAD.match(line)
            if m:
                cur = m.group(1)
                continue
            m = RET_LINE.match(line)
            if m and cur:
                out[cur] = m.group(1)
                cur = None
            elif RET_VOID.match(line) and cur:
                out[cur] = None
                cur = None
    return out


# ------------------------------------------------------------------ rewrite

class Fn:
    """One function: the head line, the body lines, and the return clause."""

    def __init__(self, head, lines, ret, name):
        self.head, self.lines, self.ret, self.name = head, lines, ret, name
        self.used = set(re.findall(r'[a-z_][a-z_0-9]*', head))
        for ln in lines:
            self.used |= set(re.findall(r'[a-z_][a-z_0-9]*', ln))

    def fresh(self, base):
        n, k = base, 2
        while n in self.used:
            n, k = f'{base}{k}', k + 1
        self.used.add(n)
        return n


def split_funcs(src):
    """The file as an alternating list of raw text and Fn objects. Anything
    that is not inside a function -- comments, blank lines, the `(a):(b)` test
    cases that follow one -- travels as raw text and is never touched."""
    out, lines, i = [], src.split('\n'), 0
    raw = []
    while i < len(lines):
        m = FUNC_HEAD.match(lines[i])
        if not m:
            raw.append(lines[i])
            i += 1
            continue
        head_start = i
        while i < len(lines) and not (lines[i].startswith('}') and 'return' in lines[i]):
            i += 1
        if i >= len(lines):
            raw += lines[head_start:]
            break
        head = lines[head_start]
        body = lines[head_start + 1:i]
        out.append('\n'.join(raw))
        raw = []
        out.append(Fn(head, body, lines[i], m.group(1)))
        i += 1
    out.append('\n'.join(raw))
    return out


def render(parts):
    return '\n'.join(p if isinstance(p, str)
                     else '\n'.join([p.head] + p.lines + [p.ret])
                     for p in parts)


def stmt_regions(line):
    """The part of a line that holds an expression, as (start, end).

    A condition is returned too, but flagged, because a value hoisted out of a
    `while` would be computed once where the loop computes it every time."""
    s = line
    m = re.match(r'^(\s*)(if|while)\s*\(', s)
    if m:
        a = m.end() - 1
        d, i = 0, a
        while i < len(s):
            if s[i] == '(':
                d += 1
            elif s[i] == ')':
                d -= 1
                if d == 0:
                    return (a + 1, i, m.group(2))
            i += 1
        return None
    m = re.match(r'^(\s*)\}\s*else\s+if\s*\(', s)
    if m:
        a = m.end() - 1
        d, i = 0, a
        while i < len(s):
            if s[i] == '(':
                d += 1
            elif s[i] == ')':
                d -= 1
                if d == 0:
                    return (a + 1, i, 'elif')
            i += 1
        return None
    m = re.match(r'^\s*(?:export\s+)?(?:' + TYPE + r'\s+)?[a-z_][a-z_0-9]*(?:\[[^\]]*\])?\s*=\s*(.*);\s*$', s)
    if m:
        return (m.start(1), m.end(1), 'stmt')
    m = re.match(r'^\s*([a-z_][a-z_0-9]*\s*\(.*\))\s*;\s*$', s)
    if m:
        return (m.start(1), m.end(1), 'call')
    return None


def hoistable(line, rettypes):
    """The innermost call sitting inside another call's argument, or None."""
    reg = stmt_regions(line)
    if not reg:
        return None
    a, b, kind = reg
    try:
        root = parse_expr(line, a, b)
    except Exception:
        return None
    skip = {id(g) for g in root.guarded()}
    inner = set()
    for c in root.calls():
        for arg in c.kids:
            for d in arg.calls():
                if id(d) not in skip:
                    inner.add(id(d))
    for c in root.calls():
        if id(c) in inner and not any(id(d) in inner for k in c.kids for d in k.calls()):
            return (c, kind)
    for c in root.calls():
        for arg in c.kids:
            for d in arg.calls():
                if id(d) in skip:
                    return (d, 'guarded')
    return None


def rewrite(src, rettypes, path, problems):
    parts = split_funcs(src)
    for fn in parts:
        if isinstance(fn, str):
            continue
        flatten_return(fn, problems, path)
        flatten_calls(fn, rettypes, problems, path)
    return render(parts)


def flatten_return(fn, problems, path):
    m = RET_LINE.match(fn.ret)
    if not m:
        return
    ty, expr = m.group(1), m.group(2).strip()
    if ty == 'void' or not expr or is_plain(fn.ret, expr):
        return
    name = fn.fresh(ret_name(ty))
    fn.lines.append(f'  {ty} {name} = {expr};')
    fn.ret = f'}} return {ty} {name};'


def flatten_calls(fn, rettypes, problems, path):
    i = 0
    while i < len(fn.lines):
        for _ in range(12):
            got = hoistable(fn.lines[i], rettypes)
            if not got:
                break
            call, kind = got
            ty = rettypes.get(call.name, 'MISSING')
            if kind == 'elif':
                problems.append(f'{path}: `else if` condition holds a nested '
                                f'call ({call.name}); a name for it has nowhere '
                                f'to go -- the line before it is inside the '
                                f'previous branch, and before the whole chain '
                                f'would compute it even when an earlier branch '
                                f'wins')
                break
            if kind == 'guarded':
                problems.append(f'{path}: {call.name}() sits to the right of an '
                                f'&& or || inside a call; naming it would compute '
                                f'it even when the operator skips it')
                break
            if kind == 'while':
                problems.append(f'{path}: `while` condition holds a nested call '
                                f'({call.name}); a name for it would be computed '
                                f'once where the loop needs it every time')
                break
            if ty is None or ty == 'MISSING' or call.name in VOID_BUILTIN:
                problems.append(f'{path}: no return type known for {call.name}(), '
                                f'so its value cannot be declared')
                break
            line = fn.lines[i]
            ind = re.match(r'^(\s*)', line).group(1)
            text = line[call.a:call.b]
            # The same call written twice is two calls. There was a version of
            # this that reused the first binding for the second spelling, on
            # the theory that a repeated call is a repeated value. It is not:
            # `bump(c) + bump(c)` increments twice, and collapsing it silently
            # turned tests/conform/order/01 from `a=1 b=2` into `a=1 b=1`.
            # `id` has no way to say a function is free of effects, so nothing
            # here may assume one is.
            name = fn.fresh(call.name + '_v')
            fn.lines[i] = line[:call.a] + name + line[call.b:]
            fn.lines.insert(i, f'{ind}{ty} {name} = {text};')
            i += 1
        i += 1


def world(roots):
    """Every .id file under these roots. A hoisted call's type is declared
    wherever that function happens to live, which is routinely a tree that is
    not the one being rewritten -- `idstd` most of all."""
    import os
    out = []
    for r in roots:
        for base, dirs, fs in os.walk(r):
            if '/.git' in base:
                continue
            out += [os.path.join(base, f) for f in fs if f.endswith('.id')]
    return out


def main(argv):
    check = '--check' in argv
    roots = [a[len('--types='):] for a in argv if a.startswith('--types=')]
    paths = [a for a in argv if not a.startswith('--')]
    rettypes = scan_rettypes(world(roots) if roots else paths)
    rettypes.update(backend_abi(roots or ['.']))
    problems, changed = [], 0
    for p in paths:
        src = open(p, errors='replace').read()
        out = rewrite(src, rettypes, p, problems)
        if out != src:
            changed += 1
            if not check:
                open(p, 'w').write(out)
    for line in problems:
        print(line, file=sys.stderr)
    print(f'flatten: {changed} of {len(paths)} files '
          f'{"would change" if check else "changed"}, {len(problems)} left for a person')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
