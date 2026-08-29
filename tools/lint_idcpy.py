#!/usr/bin/env python3
"""idc.py must obey a lightweight form of the rules it enforces.

    tools/lint_idcpy.py            report every violation
    tools/lint_idcpy.py --check    exit 1 if the count exceeds the budget

`id` refuses a program whose blocks are long, whose nesting is deep, or whose
functions repeat each other. `idc.py` is the compiler that enforces those rules
and obeys none of them, which is how it reached 5433 lines with a
128-statement function in it. A compiler whose own source is the shape it
rejects is not a good argument for the shape.

The rules are relaxed, deliberately -- Python is not `id`, and demanding three
actions per block would mean rewriting the file into a thousand functions for
no gain. They are set from the file's own distribution: the median function is
9 statements and nests 1 deep, so the limits below are generous to ordinary
code and catch only genuine bloat.

  id                            here                        why relaxed
  3 actions per block           32 statements per function  median is 9
  nesting depth 2               depth 4                     median is 1
  functions must be unique      identical up to renaming    same rule
  3 functions per file          (not checked)               one file, 159 fns

The last one is the interesting omission. It is the rule idc.py breaks worst
and the one that cannot be applied without splitting the file, which is
docs/BACKENDS.md's whole plan. The line ceiling in tests/run.sh covers the
same ground for now.

BUDGET is a ratchet, exactly like that ceiling: it may fall, never rise. The
violations left are named in it, so a NEW one fails even while the old ones
stand.
"""
import ast
import sys

MAX_STATEMENTS = 32
MAX_DEPTH = 4

# The functions that exceed a limit today, with the count that made them fail.
# Fixing one means deleting its line. Adding one is a test failure.
BUDGET = {
    ("parse_stmt", 566): 44,
    ("parse_primary", 730): 42,
    ("__init__", 1365): 35,
    ("gen_stmt", 1879): 58,
    ("gen_expr", 1961): 63,
    ("gen_call", 2035): 124,
    ("gen_binop", 2210): 39,
    ("gen_test_case", 2380): 43,
    ("gen_stmt", 2763): 57,
    ("gen_expr", 2856): 90,
    ("gen_binop", 2958): 96,
    ("gen_call", 3072): 128,
    ("gen_stmt", 4085): 65,
    ("gen_expr", 4169): 84,
    ("gen_binop", 4261): 61,
    ("gen_call", 4335): 103,
    ("emit_module", 4551): 44,
    ("resolve_backend", 5019): 35,
    ("main", 5078): 101,
}
DEPTH_BUDGET = {
    ("lex", 163): 7,
    ("parse_primary", 730): 5,
    ("gen_binop", 2958): 5,
    ("gen_binop", 4261): 5,
    ("walk_expr", 4611): 6,
    ("walk_exprs_in", 4632): 7,
    ("build_c", 5378): 5,
}

NESTERS = (ast.If, ast.For, ast.While, ast.With, ast.Try)


def nesting(node, d=0):
    best = d
    for ch in ast.iter_child_nodes(node):
        best = max(best, nesting(ch, d + 1 if isinstance(ch, NESTERS) else d))
    return best


def statements(fn):
    return sum(1 for n in ast.walk(fn) if isinstance(n, ast.stmt)) - 1


def structure(fn):
    """A function's body with every name and argument erased, so two functions
    that differ only in what they call things compare equal -- `id`'s rule."""
    class Scrub(ast.NodeTransformer):
        def visit_Name(self, n):
            return ast.copy_location(ast.Name(id="_", ctx=n.ctx), n)

        def visit_arg(self, n):
            return ast.copy_location(ast.arg(arg="_"), n)

    body = ast.parse(ast.unparse(ast.Module(body=fn.body, type_ignores=[])))
    return ast.dump(Scrub().visit(body))


def main(argv):
    check = "--check" in argv
    path = "idc.py"
    tree = ast.parse(open(path).read())
    fns = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]

    bad, seen = [], {}
    for fn in fns:
        key = (fn.name, fn.lineno)
        n = statements(fn)
        if n > MAX_STATEMENTS and BUDGET.get(key) != n:
            bad.append(f"{path}:{fn.lineno}: '{fn.name}' is {n} statements; "
                       f"the limit is {MAX_STATEMENTS}")
        d = nesting(fn)
        if d > MAX_DEPTH and DEPTH_BUDGET.get(key) != d:
            bad.append(f"{path}:{fn.lineno}: '{fn.name}' nests {d} deep; "
                       f"the limit is {MAX_DEPTH}")
        if statements(fn) >= 3:
            s = structure(fn)
            if s in seen:
                bad.append(f"{path}:{fn.lineno}: '{fn.name}' has the same "
                           f"logic as '{seen[s]}' up to renaming")
            else:
                seen[s] = fn.name

    # A budget entry whose function no longer violates -- or no longer exists --
    # is stale, and a stale budget is how a ratchet quietly stops ratcheting.
    live = {(f.name, f.lineno): (statements(f), nesting(f)) for f in fns}
    for key, want in sorted(BUDGET.items()):
        got = live.get(key)
        if got is None or got[0] != want:
            bad.append(f"budget: {key[0]} (line {key[1]}) no longer has {want} "
                       f"statements -- lower or remove its BUDGET entry")
    for key, want in sorted(DEPTH_BUDGET.items()):
        got = live.get(key)
        if got is None or got[1] != want:
            bad.append(f"budget: {key[0]} (line {key[1]}) no longer nests {want} "
                       f"deep -- lower or remove its DEPTH_BUDGET entry")

    for line in bad:
        print(line, file=sys.stderr)
    if not bad:
        print(f"lint_idcpy: {len(fns)} functions, "
              f"{len(BUDGET)} over the statement limit and "
              f"{len(DEPTH_BUDGET)} over the nesting limit, all budgeted")
    return 1 if (bad and check) else (1 if bad else 0)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
