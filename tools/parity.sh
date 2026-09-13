#!/usr/bin/env bash
# Differential test: does the id-written compiler emit the same C as idc.py?
#
#   tools/parity.sh prog.id        # a single .id file
#   tools/parity.sh demos/calc     # a project directory (its whole .id tree)
#
# Exit 0 if the emitted C is byte-identical, else 1 (and shows the diff).
#
# Not for a project that uses a native backend (demos/gfxdemo, demos/fsdemo,
# ...). The two compilers legitimately differ there: bin/idc reads the
# backend's `native` declarations and emits real prototypes, while idc.py
# emits an unprototyped `extern int` block. Those projects are checked by
# behaviour, with the backend attached, in tests/backends.sh.
set -u
cd "$(dirname "$0")/.."

IDC=./idc.py
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

target="${1:?usage: parity.sh <file-or-project-dir>}"

# build the id-written compiler (lexer + parser/codegen) once, with bin/idc.
# Always with the standard library, whatever IDC_NO_STD says about the program
# under test: the compiler's own source calls idstd's lset, so a bootstrap
# without it does not build at all. Not with idc.py: idstd may use `given` and
# `then`, which only bin/idc parses.
env -u IDC_NO_STD ./bin/idc compiler/lex   -o "$TMP/idlex"   2>/dev/null || { echo "lexer build failed"; exit 2; }
env -u IDC_NO_STD ./bin/idc compiler/parse -o "$TMP/idparse" 2>/dev/null || { echo "idparse build failed"; exit 2; }

# The program under test is compiled WITHOUT the standard library, by both
# sides. idc.py cannot read idstd once idstd holds a case written with `given`,
# so a comparison that merges it is not one idc.py can take part in. That
# rules out the compiler's own source, which needs lset: whether its emitted C
# changed is tools/regen_bootstrap.sh --check, which compares it with
# bootstrap/*.c and runs no idc.py.
export IDC_NO_STD=1

# C from idc.py
$IDC "$target" --emit-c "$TMP/py.c" >/dev/null 2>&1 || { echo "idc.py failed on input (a program that needs idstd cannot be compared here -- see the comment above)"; exit 2; }
# C from the id-written compiler, over the same source stream bin/idc feeds it:
# every .id file of the project AND of everything its conf.id reaches, with the
# #file markers in place. Concatenating the target's own tree is not the same
# stream once a project has a conf.id.
./bin/idc "$target" --emit-sources 2>/dev/null | "$TMP/idlex" | "$TMP/idparse" > "$TMP/id.c"

if diff "$TMP/py.c" "$TMP/id.c" >/dev/null; then
    echo "MATCH   $target"
    exit 0
else
    echo "DIFFER  $target"
    diff "$TMP/py.c" "$TMP/id.c" | head -40
    exit 1
fi
