#!/usr/bin/env bash
# Negative tests for idc: every .id file under tests/invalid/ must fail to
# compile under bin/idc, AND its error must contain the string on its
# `// EXPECT:` line.
#
# Add a case by dropping a new .id file in tests/invalid/ with an EXPECT line.
#
# Some files also carry `// EXPECT-IDCPY: <text>` or `// IDCPY-ACCEPTS`: those
# described idc.py's own diagnostic (or its lack of the rule) from when this
# suite checked both compilers. idc.py is frozen (docs/HACKING.md) and no
# longer built against here; the markers are left in place rather than edited
# out of the 44 files that carry them, and are simply unused by this script.
#
# Run from anywhere: tests/invalid.sh [K N]
# K N runs shard K of N: the checks whose position in this file's order, counting
# from 1, is K mod N. run.sh calls it as invalid_1of4 .. invalid_4of4, so each
# stays under the minute.
set -u
# Hermetic: these checks assert on exact diagnostics, exact emitted C, or the
# compiler's own bootstrap, none of which may change because a standard library
# happens to exist beside this repository. stdlib.sh covers that path instead.
export IDC_NO_STD=1

cd "$(dirname "$0")"
BIN_IDC=../bin/idc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

# check_one LABEL FILE EXPECT -- must exit nonzero and print EXPECT. bin/idc
# is given --allow-untested: none of these programs has test cases, and the
# rule each one breaks is the one on its EXPECT line, not the two-case
# minimum.
check_one() {
    local label="$1" f="$2" expect="$3" out rc
    out=$("$BIN_IDC" "$f" --allow-untested -o "$TMP/out" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: $label (compiled successfully; expected error '$expect')"
        fail=$((fail+1)); return
    fi
    if printf '%s' "$out" | grep -qF "$expect"; then
        echo "PASS: $label"
        pass=$((pass+1))
    else
        echo "FAIL: $label (expected '$expect')"
        echo "      got: $(printf '%s' "$out" | head -1)"
        fail=$((fail+1))
    fi
}

shard=${1:-1} shards=${2:-1}
index=0
mine() {
    index=$((index+1))
    [ $(( index % shards )) -eq $(( shard % shards )) ]
}

for f in invalid/*.id; do
    mine || continue
    name=$(basename "$f" .id)
    expect=$(sed -n 's@^// EXPECT: @@p' "$f" | head -1)
    if [ -z "$expect" ]; then
        echo "FAIL: $name (no '// EXPECT:' line in $f)"; fail=$((fail+1)); continue
    fi
    check_one "$name" "$f" "$expect"
done

# A directory is a project: a struct is declared in a file of its own
# (docs/SPEC.md, structs), so a program that uses one is not a single file. Its
# `// EXPECT:` line is in whichever of its files carries it.
for d in invalid/*/; do
    [ -d "$d" ] || continue
    mine || continue
    name=$(basename "$d")
    expect=$(sed -n 's@^// EXPECT: @@p' "$d"*.id | head -1)
    if [ -z "$expect" ]; then
        echo "FAIL: $name (no '// EXPECT:' line in $d)"; fail=$((fail+1)); continue
    fi
    check_one "$name" "${d%/}" "$expect"
done

# A name used with two types across the program (E0303) must be the FIRST thing
# reported: the type checker reads the clashing declarations as one type and
# raises uncoded errors that blame the wrong line, so the precise diagnostic has
# to come before them or an author fixes the symptom.
if mine; then
first=$("$BIN_IDC" fixtures/type_clash --allow-untested -o "$TMP/clash" 2>&1 | head -1)
case "$first" in
    *"[E0303]") echo "PASS: type clash: the first diagnostic is E0303"; pass=$((pass+1)) ;;
    *)          echo "FAIL: type clash: the first diagnostic is E0303"; echo "      got: $first"; fail=$((fail+1)) ;;
esac
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
