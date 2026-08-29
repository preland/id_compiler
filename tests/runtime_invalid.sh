#!/usr/bin/env bash
# Runtime-safety negative tests for idc: every .id file under
# tests/runtime_invalid/ must COMPILE successfully (unlike tests/invalid/,
# these are not compile-time errors) but then ABORT when run, printing the
# string on its `// EXPECT:` line to stderr and exiting nonzero. These prove
# the memory-safety guarantees (bounds-checked list access, pop-on-empty)
# actually hold at runtime instead of silently corrupting memory.
#
# Add a case by dropping a new .id file in tests/runtime_invalid/ with an
# EXPECT line.
#
# Every case is run against BOTH compilers, for the same reason
# tests/invalid.sh is: a guarantee that only one of them provides is a
# guarantee the primary compiler may not have.
#
# Run from anywhere: tests/runtime_invalid.sh
set -u
# Hermetic: these checks assert on exact diagnostics, exact emitted C, or the
# compiler's own bootstrap, none of which may change because a standard library
# happens to exist beside this repository. stdlib.sh covers that path instead.
export IDC_NO_STD=1

cd "$(dirname "$0")"
IDC=../idc.py
BIN_IDC=../bin/idc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

for f in runtime_invalid/*.id; do
    name=$(basename "$f" .id)
    expect=$(sed -n 's@^// EXPECT: @@p' "$f" | head -1)
    if [ -z "$expect" ]; then
        echo "FAIL: $name (no '// EXPECT:' line in $f)"; fail=$((fail+1)); continue
    fi

    for cc_pair in "idc.py|$IDC" "bin/idc|$BIN_IDC"; do
        label="$name [${cc_pair%%|*}]"; cc="${cc_pair#*|}"
        if ! "$cc" "$f" -o "$TMP/$name" 2>"$TMP/$name.compile_err"; then
            echo "FAIL: $label (failed to compile; expected it to compile and abort at run time)"
            echo "      compiler said: $(head -1 "$TMP/$name.compile_err")"
            fail=$((fail+1)); continue
        fi

        out=$("$TMP/$name" 2>&1 1>/dev/null)
        rc=$?

        if [ "$rc" -eq 0 ]; then
            echo "FAIL: $label (ran successfully; expected a nonzero-exit abort with '$expect')"
            fail=$((fail+1)); continue
        fi
        if printf '%s' "$out" | grep -qF "$expect"; then
            echo "PASS: $label"
            pass=$((pass+1))
        else
            echo "FAIL: $label (expected stderr to contain '$expect')"
            echo "      got: $(printf '%s' "$out" | head -1)"
            fail=$((fail+1))
        fi
    done
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
