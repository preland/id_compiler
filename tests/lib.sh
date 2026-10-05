#!/usr/bin/env bash
# `--lib`: an id project built into a shared library, a static archive and a C
# header, and called from C (docs/INTEROP.md, "id as a library").
#
#   tests/lib.sh          the fixture libraries under tests/lib/ (kit: every
#                         type and the traps; tally: state), built with no
#                         standard library
#   tests/lib.sh csv      trials/csvlib, a real library over csvq's parser;
#                         needs the real idstd
#
# What is checked, and why each check can go red:
#
#   * the library exports exactly its own symbols -- a leaked runtime or
#     backend symbol, or a missing function, changes the list;
#   * a C host links the .a and another links the .so, and both run the same
#     checks (kit_host.c): every type in and out, a trap as status 1 with its
#     message, a NUL in a string as status 2, and resident memory flat over
#     600000 calls -- built with --lib-state the same host must FAIL that last
#     check, which is what shows the check can see a leak;
#   * a library whose cases fail is not built, and nothing is left behind;
#   * a library that keeps state is refused unless --lib-state says so;
#   * two id libraries link into one program.
#
# tools/libgen needs the real idstd to build, once; the libraries here do not.
#
# Run from anywhere: tests/lib.sh [csv]
set -u
cd "$(dirname "$0")"

unset IDSTD_HOME
which=${1:-fixtures}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

for tool in cc ar nm; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: lib tests (need $tool on PATH)"; exit 0; }
done
STD=""
for up in "../../idstd" "../../../idstd"; do
    [ -d "$up" ] && { STD=$(cd "$up" && pwd); break; }
done
[ -n "${IDSTD_HOME:-}" ] && STD="$IDSTD_HOME"
if [ -z "$STD" ]; then
    echo "SKIP: lib tests (tools/libgen builds with the standard library, and none was found beside this checkout)"
    exit 0
fi
export IDSTD_HOME="$STD"

build() { # name, project, flags... : builds into $TMP/NAME.d
    local name="$1" proj="$2"; shift 2
    mkdir -p "$TMP/$name.d"
    ../bin/idc "$proj" --lib -o "$TMP/$name.d/$name" "$@" >"$TMP/$name.log" 2>&1
}

exports_of() { # file kind -> sorted exported function symbols
    if [ "$2" = so ]; then nm -D --defined-only "$1" | awk '$2 == "T" {print $3}' | sort
    else nm --defined-only "$1" 2>/dev/null | awk '$2 == "T" {print $3}' | sort; fi
}

host() { # name, host.c, static|shared, extra libs... : compile, run, report
    local name="$1" src="$2" mode="$3"; shift 3
    local d="$TMP/$name.d" exe="$TMP/$name.$mode.exe"
    if [ "$mode" = static ]; then
        cc -O2 -o "$exe" "$src" -I"$d" "$@" "$d/lib$name.a" -pthread >"$TMP/$name.$mode.cc" 2>&1
    else
        cc -O2 -o "$exe" "$src" -I"$d" "$@" -L"$d" -l"$name" -Wl,-rpath,"$d" >"$TMP/$name.$mode.cc" 2>&1
    fi || { bad "$name: the C host compiles against the $mode library ($(head -1 "$TMP/$name.$mode.cc"))"; return 1; }
    "$exe" >"$TMP/$name.$mode.out" 2>&1
}

if [ "$which" = fixtures ]; then
    # --- kit: every type, the traps, the memory ------------------------------
    if build kit lib/kit --no-std; then ok "kit builds as a library"; else bad "kit builds as a library ($(grep -v '^idc:   ' "$TMP/kit.log" | tail -1))"; fi
    want_syms="kit_div kit_dot kit_error kit_free kit_grid kit_join kit_nth kit_scale kit_stash kit_shutdown kit_split kit_strs_free kit_table_free kit_wsum"
    for kind in so a; do
        file="$TMP/kit.d/libkit.$kind"
        got=$(exports_of "$file" "$kind" | tr '\n' ' ' | sed 's/ $//')
        want=$(echo "$want_syms" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
        if [ "$got" = "$want" ]; then ok "kit: libkit.$kind defines exactly the library's own functions"; else bad "kit: libkit.$kind defines exactly the library's own functions (got: $got)"; fi
    done
    for mode in static shared; do
        if host kit lib/kit_host.c "$mode"; then
            ok "kit: the C host passes against the $mode library ($(grep -c '^PASS' "$TMP/kit.$mode.out") checks)"
        else
            bad "kit: the C host passes against the $mode library ($(grep '^FAIL' "$TMP/kit.$mode.out" | head -2 | tr '\n' ';'))"
        fi
    done

    # The same host against a library that frees nothing per call: the memory
    # check has to fail, or it was never measuring anything.
    mkdir -p "$TMP/kitkeep.d"
    if ../bin/idc lib/kit --lib --lib-state --no-std -o "$TMP/kitkeep.d/kit" >"$TMP/kitkeep.log" 2>&1; then
        cc -O2 -o "$TMP/kitkeep.exe" lib/kit_host.c -I"$TMP/kitkeep.d" "$TMP/kitkeep.d/libkit.a" -pthread >"$TMP/kitkeep.cc" 2>&1
        "$TMP/kitkeep.exe" >"$TMP/kitkeep.out" 2>&1
        if grep -q '^FAIL: resident memory' "$TMP/kitkeep.out" && ! grep -q '^FAIL: [^r]' "$TMP/kitkeep.out"; then
            ok "kit: --lib-state grows memory, and only the memory check notices"
        else
            bad "kit: --lib-state grows memory, and only the memory check notices ($(grep '^FAIL' "$TMP/kitkeep.out" | head -2 | tr '\n' ';'))"
        fi
    else
        bad "kit builds with --lib-state ($(tail -1 "$TMP/kitkeep.log"))"
    fi

    # --- tally: state ---------------------------------------------------------
    if build tally lib/tally --no-std; then bad "tally: a library with state is refused without --lib-state"
    elif grep -q -- '--lib-state' "$TMP/tally.log"; then ok "tally: a library with state is refused without --lib-state, naming the flag"
    else bad "tally: refused, but the message does not name --lib-state ($(tail -1 "$TMP/tally.log"))"; fi
    if build tally lib/tally --no-std --lib-state && host tally lib/tally_host.c static; then
        ok "tally: --lib-state keeps a list made by one call for the next ($(grep -c '^PASS' "$TMP/tally.static.out") checks)"
    else
        bad "tally: --lib-state keeps a list made by one call for the next ($(grep '^FAIL' "$TMP/tally.static.out" 2>/dev/null | head -2 | tr '\n' ';'))"
    fi

    # --- two libraries in one program ----------------------------------------
    cat > "$TMP/both.c" <<'EOF'
#include <stdio.h>
#include "kit.h"
#include "tally.h"
int main(void) {
    int32_t q = 0, t = 0;
    if (kit_div(9, 3, &q) != 0 || tally_reset() != 0 || tally_add(q) != 0 || tally_total(&t) != 0) return 1;
    printf("%d\n", t);
    return t == 3 ? 0 : 2;
}
EOF
    if cc -o "$TMP/both.exe" "$TMP/both.c" -I"$TMP/kit.d" -I"$TMP/tally.d" "$TMP/kit.d/libkit.a" "$TMP/tally.d/libtally.a" -pthread >"$TMP/both.cc" 2>&1 && "$TMP/both.exe" >/dev/null; then
        ok "two id libraries link into one program and each keeps its own runtime"
    else
        bad "two id libraries link into one program ($(head -1 "$TMP/both.cc"))"
    fi

    # --- what stops a library --------------------------------------------------
    cp -R lib/kit "$TMP/badcase"
    sed -i 's/^(7, 2):(3)$/(7, 2):(4)/' "$TMP/badcase/fault.id"
    if build badcase "$TMP/badcase" --no-std; then bad "a library whose case fails is not built (built)"
    elif ls "$TMP/badcase.d" | grep -q 'libbadcase'; then bad "a library whose case fails leaves no library behind"
    elif grep -q 'test failed' "$TMP/badcase.log"; then ok "a library whose case fails is not built, and leaves nothing"
    else bad "a library whose case fails is not built ($(tail -1 "$TMP/badcase.log"))"; fi

    mkdir "$TMP/hasmain"
    printf 'main(int argc, string[] argv) {\n} return int 0;\n(1, ["x"]):(0)\n(2, ["x", "y"]):(0)\n' > "$TMP/hasmain/main.id"
    if build hasmain "$TMP/hasmain" --no-std; then bad "a project with a main is refused (built)"
    elif grep -q 'needs a project with no main' "$TMP/hasmain.log"; then ok "a project with a main is refused, with the fix"
    else bad "a project with a main is refused ($(tail -1 "$TMP/hasmain.log"))"; fi

    mkdir "$TMP/hasfunc"
    printf 'apply(func(int) return int fn, int v) {\n  int out_v = fn(v);\n} return int out_v;\n' > "$TMP/hasfunc/apply.id"
    printf 'twice(int a) {\n  int b = a * 2;\n} return int b;\n(2):(4)\n(5):(10)\n' > "$TMP/hasfunc/twice.id"
    if build hasfunc "$TMP/hasfunc" --no-std --allow-untested; then bad "an exported function taking a function value is refused (built)"
    elif grep -q "has no C form" "$TMP/hasfunc.log"; then ok "an exported function taking a function value is refused, naming the type and the fix"
    else bad "an exported function taking a function value is refused ($(tail -1 "$TMP/hasfunc.log"))"; fi
else
    # --- csvlib: a real library, over csvq's parser, with the real idstd -----
    if build csv ../../trials/csvlib; then ok "trials/csvlib builds as a library"; else bad "trials/csvlib builds as a library ($(tail -1 "$TMP/csv.log"))"; fi
    for kind in so a; do
        got=$(exports_of "$TMP/csv.d/libcsv.$kind" "$kind" | tr '\n' ' ' | sed 's/ $//')
        want="csv_cell csv_col csv_error csv_errors csv_free csv_line csv_rows csv_shutdown csv_strs_free csv_sum csv_table_free"
        if [ "$got" = "$want" ]; then ok "csv: libcsv.$kind defines exactly the library's own functions"; else bad "csv: libcsv.$kind defines exactly the library's own functions (got: $got)"; fi
    done
    if readelf -d "$TMP/csv.d/libcsv.so" 2>/dev/null | grep NEEDED | grep -qv 'libc.so\|ld-linux'; then
        bad "csv: libcsv.so depends only on libc ($(readelf -d "$TMP/csv.d/libcsv.so" | grep NEEDED | tr '\n' ' '))"
    else
        ok "csv: libcsv.so depends only on libc (unreached backends are not linked)"
    fi
    for mode in static shared; do
        if host csv lib/csv_host.c "$mode"; then
            ok "csv: the C host passes against the $mode library ($(grep -c '^PASS' "$TMP/csv.$mode.out") checks)"
        else
            bad "csv: the C host passes against the $mode library ($(grep '^FAIL' "$TMP/csv.$mode.out" | head -2 | tr '\n' ';'))"
        fi
    done
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
