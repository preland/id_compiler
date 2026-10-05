#!/usr/bin/env bash
# `-O LEVEL` (docs/BACKENDS.md, "Optimisation levels"): what each level does to
# the program it builds, shown on one tiny project whose three files each become
# a compilation unit (IDC_UNIT_FILES=1), so a call from main to `bump` crosses
# units and only whole-program inlining can remove it.
#
# What is checked, and what would turn each check red:
#
#   * every level builds and the program means the same thing at each: the same
#     stdout, and the same trap message and exit status (an inlined list access
#     must still say "index 4 out of bounds (len 3)", and exit 1);
#   * `bump` is a real function in the binary at -O0 and -O1 (nothing links the
#     units across) and is gone at -O2, -O3 and -Os -- if whole-program inlining
#     stopped (say, -flto dropped from the compile or the link) it would stay
#     and these fail;
#   * the C a build compiles (--keep-c) has the runtime's accessors `static inline`, while --emit-c stays the raw output
#     (the keyword every build path used to get from a different place);
#   * a level that is not one is refused, naming the ones that are;
#   * --target llvm builds and agrees with the C target, with the same level
#     (skipped without clang and llvm-as).
#
# Builds use no standard library, so this says the same on a checkout without one.
# Run from anywhere: tests/opt.sh
set -u
cd "$(dirname "$0")"
unset IDSTD_HOME
export IDC_NO_STD=1
BIN_IDC="${BIN_IDC:-../bin/idc}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

for tool in cc nm; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: opt tests (need $tool on PATH)"; exit 0; }
done

P="$TMP/proj"
mkdir "$P"
printf 'main(int argc, string[] argv) {\n  int ov = bump(argc) + step(argc);\n  int ow = pick(argc);\n  print("v=" + ov + "," + ow);\n} return int 0;\n(1, ["x"]):(0)\n(2, ["x", "z"]):(0)\n' > "$P/main.id"
printf 'bump(int bn) {\n  int bv = bn + 1;\n} return int bv;\n(1):(2)\n(4):(5)\n' > "$P/bump.id"
printf 'step(int sn) {\n  int sv = sn * 3;\n} return int sv;\n(1):(3)\n(2):(6)\n\npick(int pn) {\n  int[] px = [1, 2, 3];\n  int pv = px[pn - 1];\n} return int pv;\n(1):(1)\n(3):(3)\n' > "$P/step.id"

want_out="v=5,1"
want_trap="id: index 4 out of bounds (len 3)"

for L in 0 1 2 3 s; do
    exe="$TMP/p$L"
    if ! IDC_UNIT_FILES=1 "$BIN_IDC" "$P" -O"$L" -o "$exe" >"$TMP/b$L.log" 2>&1; then
        bad "-O$L builds ($(tail -1 "$TMP/b$L.log"))"
        continue
    fi
    got=$("$exe" 2>/dev/null); rc=$?
    trap_msg=$("$exe" a b c d 2>&1 >/dev/null); trc=$?
    if [ "$got" = "$want_out" ] && [ "$rc" -eq 0 ] && [ "$trap_msg" = "$want_trap" ] && [ "$trc" -eq 1 ]; then
        ok "-O$L builds, prints '$want_out', and traps with its message and exit status 1"
    else
        bad "-O$L: got '$got' (rc $rc), trap '$trap_msg' (rc $trc)"
    fi
    case "$L" in
        0|1) want_sym=1 ;;
        *)   want_sym=0 ;;
    esac
    if nm "$exe" 2>/dev/null | grep -q ' id_bump'; then have_sym=1; else have_sym=0; fi
    if [ "$have_sym" -eq "$want_sym" ]; then
        ok "-O$L: bump is $([ "$want_sym" -eq 1 ] && echo 'still a function in the binary' || echo 'inlined away across units')"
    else
        bad "-O$L: bump should $([ "$want_sym" -eq 1 ] && echo 'be' || echo 'not be') a symbol of the binary"
    fi
done

"$BIN_IDC" "$P" --keep-c -O0 -o "$TMP/keep.exe" >"$TMP/keep.log" 2>&1
if grep -q '^static inline long long id_list_get(' "$TMP/keep.c" && ! grep -q '^static long long id_list_get(' "$TMP/keep.c"; then
    ok "the C a build compiles has the runtime's accessors as static inline"
else
    bad "the C a build compiles has the runtime's accessors as static inline ($(tail -1 "$TMP/keep.log"))"
fi
"$BIN_IDC" "$P" --emit-c "$TMP/out.c" >"$TMP/emit.log" 2>&1
if grep -q '^static long long id_list_get(' "$TMP/out.c"; then
    ok "--emit-c stays the compiler's raw output (the bootstrap check compares it)"
else
    bad "--emit-c stays the compiler's raw output ($(tail -1 "$TMP/emit.log"))"
fi

if "$BIN_IDC" "$P" -O 7 -o "$TMP/bad" >"$TMP/o7.log" 2>&1; then
    bad "-O 7 is refused (built)"
elif grep -q "takes 0, 1, 2, 3 or s" "$TMP/o7.log"; then
    ok "-O 7 is refused, naming the levels"
else
    bad "-O 7 is refused, naming the levels ($(tail -1 "$TMP/o7.log"))"
fi

if command -v clang >/dev/null 2>&1 && command -v llvm-as >/dev/null 2>&1; then
    exe="$TMP/pll"
    if "$BIN_IDC" "$P" --target llvm -O2 -o "$exe" >"$TMP/bll.log" 2>&1; then
        got=$("$exe" 2>/dev/null); trap_msg=$("$exe" a b c d 2>&1 >/dev/null); trc=$?
        if [ "$got" = "$want_out" ] && [ "$trap_msg" = "$want_trap" ] && [ "$trc" -eq 1 ]; then
            ok "--target llvm -O2 agrees with the C target: same output, same trap, same status"
        else
            bad "--target llvm -O2 agrees with the C target (got '$got', trap '$trap_msg' rc $trc)"
        fi
    else
        bad "--target llvm -O2 builds ($(tail -1 "$TMP/bll.log"))"
    fi
else
    echo "SKIP: --target llvm check (needs clang and llvm-as)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
