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
# Run from anywhere: tests/invalid.sh
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

for f in invalid/*.id; do
    name=$(basename "$f" .id)
    expect=$(sed -n 's@^// EXPECT: @@p' "$f" | head -1)
    if [ -z "$expect" ]; then
        echo "FAIL: $name (no '// EXPECT:' line in $f)"; fail=$((fail+1)); continue
    fi
    check_one "$name" "$f" "$expect"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
