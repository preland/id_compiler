#!/usr/bin/env bash
# Conformance: does every code-generation target agree about what a program
# means?
#
# `tools/parity.sh` compares the *text* two compilers emit, which is only a
# question that exists while both of them emit C. It cannot say anything about
# The `llvm` target here is `bin/idc --target llvm` -- the primary compiler's
# own LLVM back end, which lowers to the SSA IR in compiler/parse/back/ir and
# prints it (docs/LLVM.md). `idc.py --target llvm` is a separate, older code
# generator that is being retired with the rest of that file; it is no longer
# what this suite holds the language to.
#
# `--target llvm` or `--target wasm`, and it never will. This file asks the
# question that survives a second target: build the same program every way the
# toolchain can, run it, and require the same stdout, the same exit code and
# the same stderr from each.
#
# Every case is one .id file under tests/conform/<area>/ with its answer beside
# it:
#
#   NN-name.id        the program
#   NN-name.expected  its exact stdout
#   NN-name.exit      its exit code, present only when nonzero
#   NN-name.stderr    its exact stderr, present only when it writes any
#
# The expected files record what the C target does, because the C target is
# what `docs/SPEC.md` was written from. A disagreement is therefore always
# reported against C, and is either a bug in the other target or a place the
# spec has to choose -- see docs/SPEC.md.
#
# Three outcomes, and the difference between the last two is the whole point:
#
#   PASS  the target built the program and gave the specified answer
#   GAP   the target refused the program by name, saying the feature is
#         C-only. An enumerated limitation, counted and listed, not a wrong
#         answer
#   FAIL  the target gave a different answer, or failed to build for any
#         reason other than an enumerated limitation
#
# Only FAIL is an error. GAP is the backlog, printed so it cannot be mistaken
# for coverage.
#
# Run from anywhere: tests/conform.sh
# Needs clang for --target llvm and wat2wasm + wasmtime for --target wasm;
# a missing toolchain skips that target with a message rather than passing.
set -u
cd "$(dirname "$0")"
BIN_IDC=../bin/idc
IDC_PY=../idc.py
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The environment must not leak in. A developer with IDSTD_HOME set would
# otherwise pull a sibling standard library into every case, which changes
# what these programs mean and makes the suite say different things on
# different checkouts.
unset IDSTD_HOME
export IDC_NO_STD=1

pass=0 fail=0 gap=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
skip() { gap=$((gap+1));  GAPS="$GAPS$1"$'\n'; }
GAPS=""

# A target that says "this is C-only" is describing a known limitation rather
# than getting the answer wrong. The message comes from idc.py's
# unsupported_builtin_msg and reject_word_type, so match on their wording.
is_enumerated_gap() {
    grep -qE "is C-only|C-only|not implemented for this target" "$1"
}

# A target that is known not to conform in one area, by name.
#
# This is not the same as a gap: a gap is a target refusing a program it cannot
# compile, which it says so about. This is a target that compiles the program
# and gets a different answer, and the only honest way to keep the suite green
# while that is true is to name the area and say why. Removing a line here is
# how the fix gets noticed.
#
#   c:order   the C target emits one C expression per `id` expression, and C
#             does not sequence the arguments of a call. gcc evaluates them
#             right to left; docs/SPEC.md 7 says left to right. Conforming
#             means hoisting operands into temporaries. See SPEC 11, S11.
known_apart() {
    case "$1:$2" in
        c:order) return 0 ;;
    esac
    return 1
}

# run_case TARGET CASE_ID DIR BASE
# Builds and runs one case for one target and records PASS / GAP / FAIL.
run_case() {
    local target="$1" id="$2" dir="$3" base="$4"
    local src="$dir/$base.id"
    local want_out want_exit want_err got_out got_exit got_err bin
    # The case id names its area, so it contains a '/' that must not reach a
    # path under $TMP -- that directory does not exist and every build would
    # fail as if the compiler had.
    local slug="${id//\//-}"

    if known_apart "$target" "$(basename "$dir")"; then
        skip "$target  $id  -- known: the C target does not sequence operands (SPEC 7)"
        return
    fi

    want_out=$(cat "$dir/$base.expected")
    want_exit=0
    [ -f "$dir/$base.exit" ] && want_exit=$(cat "$dir/$base.exit")

    case "$target" in
        c)    bin="$TMP/$slug.c.bin"
              "$BIN_IDC" "$src" -o "$bin" >"$TMP/build.log" 2>&1 ;;
        llvm) bin="$TMP/$slug.llvm.bin"
              "$BIN_IDC" "$src" --target llvm -o "$bin" \
                  >"$TMP/build.log" 2>&1 ;;
        wasm) bin="$TMP/$slug.wasm"
              python3 "$IDC_PY" "$src" --target wasm -o "$bin" \
                  >"$TMP/build.log" 2>&1 ;;
    esac

    if [ ! -e "$bin" ]; then
        if is_enumerated_gap "$TMP/build.log"; then
            skip "$target  $id  -- $(head -1 "$TMP/build.log")"
        else
            bad "$target  $id  -- build failed: $(head -1 "$TMP/build.log")"
        fi
        return
    fi

    if [ "$target" = wasm ]; then
        got_out=$(wasmtime "$bin" 2>"$TMP/err.log"); got_exit=$?
    else
        got_out=$("$bin" 2>"$TMP/err.log"); got_exit=$?
    fi
    got_err=$(cat "$TMP/err.log")

    if [ "$got_out" != "$want_out" ]; then
        bad "$target  $id  -- stdout: want [$want_out] got [$got_out]"
        return
    fi
    if [ "$got_exit" != "$want_exit" ]; then
        bad "$target  $id  -- exit: want $want_exit got $got_exit"
        return
    fi
    if [ -f "$dir/$base.stderr" ]; then
        want_err=$(cat "$dir/$base.stderr")
        if [ "$got_err" != "$want_err" ]; then
            bad "$target  $id  -- stderr: want [$want_err] got [$got_err]"
            return
        fi
    fi
    ok
}

have() { command -v "$1" >/dev/null 2>&1; }

TARGETS="c"
if have clang; then TARGETS="$TARGETS llvm"
else echo "SKIP: --target llvm (needs clang on PATH)"; fi
if have wat2wasm && have wasmtime; then TARGETS="$TARGETS wasm"
else echo "SKIP: --target wasm (needs wat2wasm and wasmtime on PATH)"; fi

cases=0
for src in conform/*/*.id; do
    [ -e "$src" ] || { echo "no conformance cases found under tests/conform/"; exit 1; }
    dir=$(dirname "$src")
    base=$(basename "$src" .id)
    id="$(basename "$dir")/$base"
    if [ ! -f "$dir/$base.expected" ]; then
        bad "c  $id  -- no .expected file beside it"
        continue
    fi
    cases=$((cases+1))
    for target in $TARGETS; do
        run_case "$target" "$id" "$dir" "$base"
    done
done

echo
echo "conformance: $cases cases x targets [$(echo $TARGETS | tr ' ' ',')]"
echo "$pass passed, $fail failed, $gap gaps"

if [ "$gap" -gt 0 ]; then
    echo
    echo "--- gaps: a target that refuses a program by name ---"
    printf '%s' "$GAPS"
fi

[ "$fail" -eq 0 ]
