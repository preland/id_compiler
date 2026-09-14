#!/usr/bin/env bash
# bin/idc --check and --fix.
#
# Each directory under tests/fix/ is one case:
#   before/  a project with violations
#   expect/  exactly what --fix makes of it
#   hand/    (optional) the same program repaired by hand, independently of
#            what --fix does: both must build and print the same thing, which
#            is what shows a fix kept the program's behaviour
#   want     (optional) lines that must appear in --fix's output
#
# For every case: --fix turns before/ into expect/; a second --fix on the result
# makes no edit; and --check prints what a build of before/ prints before it
# emits anything, with the same exit status.
#
# Hermetic, as tests_feature.sh is: no standard library, so nothing but the
# case is compiled.
#
# Run from anywhere: tests/fix.sh    FIX_IDC=/other/bin/idc tests/fix.sh
set -u
cd "$(dirname "$0")"
unset IDSTD_HOME
export IDC_NO_STD=1 IDC_NO_PROGRESS=1

IDC="${FIX_IDC:-../bin/idc}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

for case_dir in fix/*/; do
    name=$(basename "$case_dir")
    work="$TMP/$name"
    mkdir -p "$work"
    cp -r "$case_dir/before" "$work/tree"

    "$IDC" "$work/tree" --fix --allow-untested >"$work/fix.out" 2>"$work/fix.err"
    if diff -r "$case_dir/expect" "$work/tree" >"$work/tree.diff" 2>&1; then
        ok "$name: --fix gives expect/"
    else
        bad "$name: --fix gives expect/ ($(head -3 "$work/tree.diff" | tr '\n' ' '))"
    fi

    if [ -f "$case_dir/want" ]; then
        while IFS= read -r line; do
            grep -qF -- "$line" "$work/fix.out" "$work/fix.err" \
                && ok "$name: says '$line'" \
                || bad "$name: says '$line' ($(head -2 "$work/fix.err" | tr '\n' ' '))"
        done < "$case_dir/want"
    fi

    "$IDC" "$work/tree" --fix --allow-untested >"$work/fix2.out" 2>&1
    if grep -q '^idc --fix: 0 edit(s) in 0 files' "$work/fix2.out" && diff -r "$case_dir/expect" "$work/tree" >/dev/null 2>&1; then
        ok "$name: a second --fix makes no edit"
    else
        bad "$name: a second --fix makes no edit ($(grep '^idc --fix' "$work/fix2.out"))"
    fi

    "$IDC" "$case_dir/before" --check --allow-untested >"$work/check.out" 2>"$work/check.err"; crc=$?
    "$IDC" "$case_dir/before" --allow-untested -o "$work/bin" >"$work/build.out" 2>"$work/build.err"; brc=$?
    if [ "$crc" -ne 0 ] && [ "$brc" -ne 0 ] && cmp -s "$work/check.err" "$work/build.err" && [ ! -s "$work/check.out" ]; then
        ok "$name: --check of before/ says what its build says, and fails"
    else
        bad "$name: --check of before/ says what its build says, and fails (check $crc, build $brc)"
    fi

    [ -d "$case_dir/hand" ] || continue
    "$IDC" "$work/tree" --check --allow-untested >"$work/check2.out" 2>"$work/check2.err"; crc=$?
    if [ "$crc" -eq 0 ] && [ ! -s "$work/check2.out" ] && ! grep -qv '^idc: warning: --allow-untested' "$work/check2.err"; then
        ok "$name: --check passes the fixed tree"
    else
        bad "$name: --check passes the fixed tree ($(head -2 "$work/check2.err" | tr '\n' ' '))"
    fi
    if "$IDC" "$work/tree" --allow-untested -o "$work/fixed" >/dev/null 2>&1 \
       && "$IDC" "$case_dir/hand" --allow-untested -o "$work/hand" >/dev/null 2>&1; then
        "$work/fixed" >"$work/fixed.stdout" 2>&1
        "$work/hand" >"$work/hand.stdout" 2>&1
        if cmp -s "$work/fixed.stdout" "$work/hand.stdout" && [ -s "$work/hand.stdout" ]; then
            ok "$name: the fixed program prints what the hand-fixed one does"
        else
            bad "$name: the fixed program prints what the hand-fixed one does ($(tr '\n' '|' < "$work/fixed.stdout") vs $(tr '\n' '|' < "$work/hand.stdout"))"
        fi
    else
        bad "$name: the fixed program and the hand-fixed one both build"
    fi
done

# --check on a tree with no violation says nothing a build would not, and passes.
"$IDC" fix/order/hand --check --allow-untested >"$TMP/c.out" 2>"$TMP/c.err"; crc=$?
"$IDC" fix/order/hand --allow-untested -o "$TMP/h" >"$TMP/b.out" 2>"$TMP/b.err"; brc=$?
if [ "$crc" -eq 0 ] && [ "$brc" -eq 0 ] && cmp -s "$TMP/c.err" "$TMP/b.err"; then
    ok "--check of a legal program passes and says what its build says"
else
    bad "--check of a legal program passes and says what its build says (check $crc, build $brc)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
