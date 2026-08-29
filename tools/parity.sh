#!/usr/bin/env bash
# Differential test: does the id-written compiler emit the same C as idc.py?
#
#   tools/parity.sh prog.id        # a single .id file
#   tools/parity.sh demos/calc     # a project directory (its whole .id tree)
#
# Exit 0 if the emitted C is byte-identical, else 1 (and shows the diff).
#
# Not for a project that uses a native backend (demos/gfxdemo, demos/fsdemo,
# ...). Neither side of the comparison is told a backend is coming, so the
# calls it provides look like calls to nothing: idc.py stops, and idparse --
# run here without the --extern-ok that bin/idc passes it -- reports them
# instead of emitting the extern block. Those projects are checked the same
# way, with the backend attached, by tests/backends.sh.
set -u
cd "$(dirname "$0")/.."

IDC=./idc.py
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

target="${1:?usage: parity.sh <file-or-project-dir>}"

# build the two compilers (lexer + parser/codegen) once. Always with the
# standard library, whatever IDC_NO_STD says about the program under test: the
# compiler's own source calls idstd's lset, so a bootstrap without it does not
# build at all.
env -u IDC_NO_STD $IDC compiler/lex   -o "$TMP/idlex"   2>/dev/null || { echo "lexer build failed"; exit 2; }
env -u IDC_NO_STD $IDC compiler/parse -o "$TMP/idparse" 2>/dev/null || { echo "idparse build failed"; exit 2; }

# C from idc.py
$IDC "$target" --emit-c "$TMP/py.c" >/dev/null 2>&1 || { echo "idc.py failed on input"; exit 2; }
# C from the id-written compiler, over the same source stream bin/idc feeds it:
# every .id file of the project AND of everything its conf.id reaches,
# including the implicit standard library, with the #file markers in place.
# Concatenating the target's own tree is not the same stream and has not been
# since the compiler started calling idstd's lset.
./bin/idc "$target" --emit-sources 2>/dev/null | "$TMP/idlex" | "$TMP/idparse" > "$TMP/id.c"

if diff "$TMP/py.c" "$TMP/id.c" >/dev/null; then
    echo "MATCH   $target"
    exit 0
else
    echo "DIFFER  $target"
    diff "$TMP/py.c" "$TMP/id.c" | head -40
    exit 1
fi
