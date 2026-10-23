#!/usr/bin/env bash
# Conformance: does every code-generation target agree about what a program
# means?
#
# Comparing the *text* two compilers emit, which the tree used to do, is only
# a question that exists while both of them emit C. It cannot say anything about
# `--target llvm` or `--target wasm`, and it never will. This file asks the
# question that survives a second target: build the same program every way the
# toolchain can, run it, and require the same stdout, the same exit code and
# the same stderr from each.
#
# Every target is bin/idc. `llvm` is its own LLVM back end, which lowers to the
# SSA IR in compiler/parse/back/ir and prints it (docs/LLVM.md). `wasm` is the C
# target's C recompiled for wasm32-wasi as a WASI command, run by wasmtime --
# so it shares C's semantics but not its C compiler: clang, not gcc.
#
# Every case is one .id file under tests/conform/<area>/ with its answer beside
# it:
#
#   NN-name.id        the program
#   NN-name.expected  its exact stdout
#   NN-name.exit      its exit code, present only when nonzero
#   NN-name.stderr    its exact stderr, present only when it writes any
#   NN-name.stdin     the bytes fed to its stdin, present only when it reads
#                     any (without one, stdin is /dev/null)
#   NN-name.combined  stdout and stderr sent to one file, present only when the
#                     order the two streams interleave in is what is pinned
#   NN-name.env       NAME=VALUE words the program runs with, present only when
#                     the environment is what is under test (free/ sets
#                     ID_FREE_STATS so each target reports how many lists and
#                     strings it freed, which docs/MEMORY.md 2a requires to be
#                     equal)
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
# One more check is about speed, not answers: for every case with a loop, the C
# and the LLVM target must version the same loops (versioned_agree below). The
# answers are right whether or not a target versions a loop, so a target that
# silently stops doing it passes everything above.
#
# Run from anywhere: tests/conform.sh [AREA...]   (AREAs, e.g. trap, run only
# those directories under tests/conform/ -- the whole run is over the 60s budget;
# AREA:K/N runs the cases whose file number mod N is K mod N, so list:1/2 and
# list:2/2 are the two halves of list)
# Needs clang for --target llvm, and the WASI toolchain `nix develop` sets plus
# wasmtime for --target wasm;
# a missing toolchain skips that target with a message rather than passing.
set -u
cd "$(dirname "$0")"
BIN_IDC=../bin/idc
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
# than getting the answer wrong, so match on that wording.
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
known_apart() {
    case "$1:$2" in
    esac
    return 1
}

apart_why() {
    case "$1:$2" in
    esac
}

# run_bin TARGET BIN
# Runs a built case with its .stdin file on stdin and the NAME=VALUE words of its .env file, if it has them
# (runin and runenv, set by run_case). wasmtime hands the guest only what --env names.
run_bin() {
    local kv a=()
    if [ "$1" = wasm ]; then
        for kv in ${runenv[@]+"${runenv[@]}"}; do a+=(--env "$kv"); done
        wasmtime run ${a[@]+"${a[@]}"} "$2" <"${runin:-/dev/null}"
    else
        env ${runenv[@]+"${runenv[@]}"} "$2" <"${runin:-/dev/null}"
    fi
}

# run_case TARGET CASE_ID DIR BASE
# Builds and runs one case for one target and records PASS / GAP / FAIL.
run_case() {
    local target="$1" id="$2" dir="$3" base="$4"
    local src="$dir/$base.id"
    [ -d "$dir/$base" ] && src="$dir/$base"
    local want_out want_exit want_err got_out got_exit got_err bin
    # The case id names its area, so it contains a '/' that must not reach a
    # path under $TMP -- that directory does not exist and every build would
    # fail as if the compiler had.
    local slug="${id//\//-}"

    if known_apart "$target" "$(basename "$dir")"; then
        skip "$target  $id  -- known: $(apart_why "$target" "$(basename "$dir")")"
        return
    fi

    want_out=$(cat "$dir/$base.expected")
    want_exit=0
    [ -f "$dir/$base.exit" ] && want_exit=$(cat "$dir/$base.exit")

    # The conformance programs carry no test cases: what they pin is their
    # output on every target, so bin/idc builds them with --allow-untested.
    case "$target" in
        c)    bin="$TMP/$slug.c.bin"
              "$BIN_IDC" "$src" --allow-untested -o "$bin" >"$TMP/build.log" 2>&1 ;;
        llvm) bin="$TMP/$slug.llvm.bin"
              "$BIN_IDC" "$src" --allow-untested --target llvm -o "$bin" \
                  >"$TMP/build.log" 2>&1 ;;
        wasm) bin="$TMP/$slug.wasm"
              "$BIN_IDC" "$src" --allow-untested --target wasm -o "$bin" \
                  >"$TMP/build.log" 2>&1 ;;
    esac

    if [ ! -e "$bin" ]; then
        if is_enumerated_gap "$TMP/build.log" "$target"; then
            skip "$target  $id  -- $(head -1 "$TMP/build.log")"
        else
            bad "$target  $id  -- build failed: $(head -1 "$TMP/build.log")"
        fi
        return
    fi

    local -a runenv=()
    [ -f "$dir/$base.env" ] && read -r -a runenv < "$dir/$base.env"
    local runin=/dev/null
    [ -f "$dir/$base.stdin" ] && runin="$dir/$base.stdin"
    got_out=$(run_bin "$target" "$bin" 2>"$TMP/err.log"); got_exit=$?
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
    if [ -f "$dir/$base.combined" ]; then
        run_bin "$target" "$bin" >"$TMP/both.log" 2>&1
        if [ "$(cat "$TMP/both.log")" != "$(cat "$dir/$base.combined")" ]; then
            bad "$target  $id  -- stdout and stderr together: want [$(cat "$dir/$base.combined")] got [$(cat "$TMP/both.log")]"
            return
        fi
    fi
    ok
}

have() { command -v "$1" >/dev/null 2>&1; }

# versioned_agree SRC ID
# Loop versioning (docs/PERFORMANCE.md) is one analysis with two printers: the C
# target prints the guard of every loop it versions as a C condition, the LLVM
# target builds the same guard as IR. A guard of N clauses is N-1 `&&` in the C
# and N-1 `and i1` in the IR, so the two counts must agree for a program; a
# token the analysis writes that the LLVM lowering stops understanding leaves
# its loops unversioned there, and the answers stay right while this count
# falls. (The agreement is of the whole program, not loop by loop.)
versioned_agree() {
    local src="$1" id="$2" cn ln
    if ! "$BIN_IDC" "$src" --allow-untested --emit-c "$TMP/ver.c" >"$TMP/ver.log" 2>&1 \
       || ! "$BIN_IDC" "$src" --allow-untested --target llvm --emit-llvm "$TMP/ver.ll" >>"$TMP/ver.log" 2>&1; then
        bad "versioning  $id  -- emitting C and IR failed: $(head -1 "$TMP/ver.log")"
        return
    fi
    cn=$(grep -E '^ *if \(\(.*\) != NULL && ' "$TMP/ver.c" | grep -o ' && ' | wc -l)
    ln=$(grep -c ' and i1 ' "$TMP/ver.ll")
    if [ "$cn" -eq "$ln" ]; then ok; else bad "versioning  $id  -- the C guards join $cn clauses, the LLVM guards $ln"; fi
}

TARGETS="c"
if have clang; then TARGETS="$TARGETS llvm"
else echo "SKIP: --target llvm (needs clang on PATH)"; fi
if [ -n "${IDC_WASI_CLANG:-}" ] && have wasmtime; then TARGETS="$TARGETS wasm"
else echo "SKIP: --target wasm (needs the WASI toolchain nix develop sets, and wasmtime on PATH)"; fi

cases=0
areas=("$@"); [ "${#areas[@]}" -eq 0 ] && areas=("*")
for spec in "${areas[@]}"; do
area=${spec%%:*}
part=1 parts=1
case "$spec" in *:*/*) part=${spec#*:}; parts=${part#*/}; part=${part%/*} ;; esac
for src in conform/$area/*.id conform/$area/*/; do
    [ -e "$src" ] || continue
    src=${src%/}
    dir=$(dirname "$src")
    base=$(basename "$src" .id)
    number=${base%%-*}
    [[ "$number" =~ ^[0-9]+$ ]] || number=0
    [ $(( 10#$number % parts )) -eq $(( part % parts )) ] || continue
    id="$(basename "$dir")/$base"
    if [ ! -f "$dir/$base.expected" ]; then
        bad "c  $id  -- no .expected file beside it"
        continue
    fi
    cases=$((cases+1))
    for target in $TARGETS; do
        run_case "$target" "$id" "$dir" "$base"
    done
    if [ -f "$src" ] && [[ " $TARGETS " == *" llvm "* ]] && ! known_apart llvm "$(basename "$dir")" && grep -q 'while' "$src"; then
        versioned_agree "$src" "$id"
    fi
done
done

[ "$cases" -gt 0 ] || { echo "no conformance cases found under tests/conform/$*"; exit 1; }

echo
echo "conformance: $cases cases x targets [$(echo $TARGETS | tr ' ' ',')]"
echo "$pass passed, $fail failed, $gap gaps"

if [ "$gap" -gt 0 ]; then
    echo
    echo "--- gaps: a target that refuses a program by name ---"
    printf '%s' "$GAPS"
fi

[ "$fail" -eq 0 ]
