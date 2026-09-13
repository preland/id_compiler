#!/usr/bin/env bash
# idtest.sh -- run the inline test cases of one module, in isolation.
#
#   tools/idtest.sh ../editor/app/view/draw/fb/win/scale/w
#   tools/idtest.sh DIR [DIR]
#
# Why this exists: bin/idc runs every case on every build (docs/TESTS.md, "How
# it runs"), but only as part of building the whole project, and a project such
# as the editor needs its native backends and its whole tree to build at all.
# Checking one module's cases while working on it should not need either.
#
# So this copies the named modules out into a throwaway project that needs no
# backend, gives it a main, and builds that with bin/idc: a failing case fails
# the build, and the exit status says so. The named directories must between
# them define everything they call, apart from idstd -- a module that calls into
# the rest of its project, as the editor's app/view/txt/edit does, reports
# those calls as missing functions instead. It used to call idc.py, back when
# only idc.py ran cases; idc.py cannot build anything that merges an idstd
# holding a `given` case.
#
# Exit 0 means every case in every named directory passed.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
BIN_IDC=$ROOT/bin/idc

[ $# -gt 0 ] || { sed -n '2,8p' "$0"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/p"

# One entry per module, plus main.id, and a project directory holds at most 3.
n=0
for d in "$@"; do
    [ -d "$d" ] || { echo "idtest: not a directory: $d" >&2; exit 2; }
    cp -r "$d" "$TMP/p/m$n" || exit 2
    n=$((n + 1))
done
if [ "$n" -gt 2 ]; then
    echo "idtest: at most 2 modules at a time -- a directory holds 3 entries and" >&2
    echo "        one of them is main.id" >&2
    exit 2
fi

# A main that does nothing: the harness generates its own entry point per case,
# and a project still has to have one function called main to be a program.
cat > "$TMP/p/main.id" <<'EOF'
main(int argc, string[] argv) {
} return int 0;
EOF

out=$("$BIN_IDC" "$TMP/p" -o "$TMP/bin" 2>&1)
rc=$?
# Rewrite the temp path back to the real one, so a failure names a file the
# reader can open.
n=0
for d in "$@"; do
    out=${out//$TMP\/p\/m$n/$d}
    n=$((n + 1))
done
[ -n "$out" ] && printf '%s\n' "$out"
if [ "$rc" -eq 0 ]; then
    echo "idtest: every case passed ($*)"
fi
exit "$rc"
