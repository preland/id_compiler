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
[ "$which" = csv ] && unset IDC_NO_STD
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
    printf 'string[] lib_exports = ["apply", "twice"];\n' > "$TMP/hasfunc/conf.id"
    if build hasfunc "$TMP/hasfunc" --no-std --allow-untested; then bad "an exported function taking a function value is refused (built)"
    elif grep -q "has no C form" "$TMP/hasfunc.log" && grep -q "remove 'apply' from lib_exports" "$TMP/hasfunc.log"; then ok "an exported function taking a function value is refused, naming the type and the fix"
    else bad "an exported function taking a function value is refused ($(tail -1 "$TMP/hasfunc.log"))"; fi

    mkdir "$TMP/nolist"
    printf 'twice(int a) {\n  int b = a * 2;\n} return int b;\n(2):(4)\n(5):(10)\n' > "$TMP/nolist/twice.id"
    if build nolist "$TMP/nolist" --no-std; then bad "a library with no lib_exports list is refused (built)"
    elif grep -q 'string\[\] lib_exports = \[' "$TMP/nolist.log" && grep -q 'nolist/conf.id' "$TMP/nolist.log"; then ok "a library with no lib_exports list is refused, showing the line to add and where"
    else bad "a library with no lib_exports list is refused ($(tail -1 "$TMP/nolist.log"))"; fi

    mkdir "$TMP/emptylist"
    cp "$TMP/nolist/twice.id" "$TMP/emptylist/twice.id"
    printf 'string[] lib_exports = [];\n' > "$TMP/emptylist/conf.id"
    if build emptylist "$TMP/emptylist" --no-std; then bad "an empty lib_exports list is refused (built)"
    elif grep -q 'lists no function' "$TMP/emptylist.log"; then ok "an empty lib_exports list is refused, with an example entry"
    else bad "an empty lib_exports list is refused ($(tail -1 "$TMP/emptylist.log"))"; fi

    mkdir "$TMP/badname"
    cp "$TMP/nolist/twice.id" "$TMP/badname/twice.id"
    printf 'string[] lib_exports = ["twice", "twicce"];\n' > "$TMP/badname/conf.id"
    if build badname "$TMP/badname" --no-std; then bad "a lib_exports name that is not a function is refused (built)"
    elif grep -q "'twicce', which is not a function of this project" "$TMP/badname.log" && grep -q 'check the spelling' "$TMP/badname.log"; then ok "a lib_exports name that is not a function is refused, naming it and the fix"
    else bad "a lib_exports name that is not a function is refused ($(tail -1 "$TMP/badname.log"))"; fi

    mkdir "$TMP/dupname"
    cp "$TMP/nolist/twice.id" "$TMP/dupname/twice.id"
    printf 'string[] lib_exports = ["twice", "twice"];\n' > "$TMP/dupname/conf.id"
    if build dupname "$TMP/dupname" --no-std; then bad "a duplicate lib_exports entry is refused (built)"
    elif grep -q "lists 'twice' twice; remove one" "$TMP/dupname.log"; then ok "a duplicate lib_exports entry is refused, naming it and the fix"
    else bad "a duplicate lib_exports entry is refused ($(tail -1 "$TMP/dupname.log"))"; fi

    mkdir "$TMP/badtype"
    cp "$TMP/nolist/twice.id" "$TMP/badtype/twice.id"
    printf 'int lib_exports = 3;\n' > "$TMP/badtype/conf.id"
    if build badtype "$TMP/badtype" --no-std; then bad "a lib_exports that is not a string list is refused (built)"
    elif grep -q 'lib_exports must be a list of strings' "$TMP/badtype.log"; then ok "a lib_exports that is not a string list is refused, with the form to write"
    else bad "a lib_exports that is not a string list is refused ($(tail -1 "$TMP/badtype.log"))"; fi

    mkdir -p "$TMP/impb" "$TMP/impa"
    printf 'string[] lib_exports = ["inner_t"];\n' > "$TMP/impb/conf.id"
    printf 'inner_t(int a) {\n  int b = a * 3;\n} return int b;\n(2):(6)\n(5):(15)\n' > "$TMP/impb/t.id"
    printf 'import "../impb"\nstring[] lib_exports = ["outer_w"];\n' > "$TMP/impa/conf.id"
    printf 'outer_w(int a) {\n  int b = inner_t(a) + 1;\n} return int b;\n(2):(7)\n(5):(16)\n' > "$TMP/impa/w.id"
    if build impa "$TMP/impa" --no-std && [ "$(exports_of "$TMP/impa.d/libimpa.a" a | tr '\n' ' ')" = "impa_error impa_free impa_outer_w impa_shutdown impa_strs_free impa_table_free " ]; then
        ok "a library that imports another library exports only its own list (the dependency's lib_exports is not a clash)"
    else bad "a library that imports another library exports only its own list ($(tail -1 "$TMP/impa.log"))"; fi

    mkdir -p "$TMP/deep/inner"
    printf 'string[] lib_exports = ["inner_triple"];\n' > "$TMP/deep/conf.id"
    printf 'inner_triple(int a) {\n  int b = a * 3;\n} return int b;\n(2):(6)\n(5):(15)\n' > "$TMP/deep/inner/triple.id"
    printf 'outer_wrap(int a) {\n  int b = a * 5;\n} return int b;\n(1):(5)\n(4):(20)\n' > "$TMP/deep/outer.id"
    if build deep "$TMP/deep" --no-std && [ "$(exports_of "$TMP/deep.d/libdeep.a" a | tr '\n' ' ')" = "deep_error deep_free deep_inner_triple deep_shutdown deep_strs_free deep_table_free " ]; then
        ok "a listed function in a subdirectory is exported, and an unlisted root function is not"
    else bad "a listed function in a subdirectory is exported, and an unlisted root function is not ($(tail -1 "$TMP/deep.log"); $(exports_of "$TMP/deep.d/libdeep.a" a | tr '\n' ' '))"; fi

    mkdir -p "$TMP/failer"
    printf 'string[] lib_exports = ["must_pos"];\n' > "$TMP/failer/conf.id"
    printf 'must_pos(int a) {\n  if (a < 1) {\n    fail("must_pos: need a positive number, got " + a);\n  }\n} return int a;\n(3):(3)\n(9):(9)\n(0):() then traps:("must_pos: need a positive number, got 0")\n' > "$TMP/failer/m.id"
    printf '#include <stdio.h>\n#include <string.h>\n#include <stdint.h>\n#include "failer.h"\nint main(void) {\n  int32_t r = 0;\n  int a = failer_must_pos(4, &r) == 0 && r == 4;\n  int b = failer_must_pos(-3, &r) == 1 && strstr(failer_error(), "id: must_pos: need a positive number, got -3") != NULL;\n  int c = failer_must_pos(5, &r) == 0 && failer_error()[0] == 0;\n  printf("%%s: fail returns status 1 with its own message, and the next call works\\n", a && b && c ? "PASS" : "FAIL");\n  return 0;\n}\n' > "$TMP/failer_host.c"
    if build failer "$TMP/failer" --no-std; then
        for mode in static shared; do
            if host failer "$TMP/failer_host.c" "$mode" && grep -q '^PASS' "$TMP/failer.$mode.out"; then ok "fail: a --lib call returns status 1 and NAME_error() holds the message ($mode)"; else bad "fail: a --lib call returns status 1 and NAME_error() holds the message ($mode: $(head -1 "$TMP/failer.$mode.out"))"; fi
        done
    else bad "fail: a library that calls fail builds ($(tail -1 "$TMP/failer.log"))"; fi
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
    mkdir "$TMP/stdname"
    printf 'twice(int a) {\n  int b = a * 2;\n} return int b;\n(2):(4)\n(5):(10)\n' > "$TMP/stdname/twice.id"
    printf 'string[] lib_exports = ["twice", "lst_str_index"];\n' > "$TMP/stdname/conf.id"
    if build stdname "$TMP/stdname"; then bad "a lib_exports name that is an idstd function is refused (built)"
    elif grep -q "'lst_str_index', a function of the standard library" "$TMP/stdname.log" && grep -q 'define a function of your own that calls it' "$TMP/stdname.log"; then ok "a lib_exports name that is an idstd function is refused, naming it and the fix"
    else bad "a lib_exports name that is an idstd function is refused ($(tail -1 "$TMP/stdname.log"))"; fi
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
