#!/usr/bin/env bash
# idtest.sh -- run the inline test cases of one module, in isolation.
#
#   tools/idtest.sh ../editor/app/edit
#   tools/idtest.sh ../editor/app/edit ../editor/app/view/scale
#
# Why this exists: `--tests` builds a second program out of the project and runs
# every case in it, and that program is linked without the native backends. So
# a project whose conf.id names one -- the editor names two -- cannot run a
# single case, and says so:
#
#   idc: the test harness did not build; this is a bug in idc unless the
#   program needs a native backend
#
# The way round it is the one tests/editor_*.sh already take: copy the module
# out into a throwaway project that needs no backend, give it a main, and test
# that. This is that, as a command, so a module's cases are one line to run
# rather than a shell incantation to remember.
#
# This used to call idc.py, because only idc.py ran cases. bin/idc now runs
# every case on every build (docs/TESTS.md, "How it runs"), and idc.py cannot
# build anything that merges an idstd holding a `given` case, so this is an
# ordinary bin/idc build of the throwaway project: a failing case fails it.
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
