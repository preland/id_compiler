#!/usr/bin/env bash
# `--target wasm` and JavaScript: the <name>.mjs and <name>.d.ts that bin/idc
# writes beside the wasm, the JS backends that answer a program's natives, and
# what a trap looks like from JS (docs/INTEROP.md, "id and JavaScript").
#
# The fixtures are in tests/wasm_js/: lib/ (a project with a backend of its own,
# jsx, implemented twice -- jsx.c for the cases the C target runs at build time,
# jsx.mjs for the wasm module), nobe/ (the same backend attached and never
# reached), cmd/ (a program with main) and nowasm/ (a backend with no wasm
# implementation, which must be refused at the call that reaches it). They are
# built without idstd (IDC_NO_STD) so the file runs in seconds and says the same
# thing on a checkout with no idstd beside it; `wasm_js_std` below builds
# against the real one for the fs and env backends.
#
# Needs the WASI toolchain nix develop sets (IDC_WASI_*) and node; skips
# loudly without either. Run from anywhere: tests/wasm_js.sh   [std]
set -u
cd "$(dirname "$0")"
BIN_IDC="../bin/idc"
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

for v in IDC_WASI_CLANG IDC_WASI_SYSROOT_INCLUDE IDC_WASI_LIBDIR IDC_WASI_COMPILER_RT; do
    if [ -z "${!v:-}" ]; then
        echo "SKIP: wasm_js tests (need \$$v -- run via 'nix develop', which flake.nix sets it in)"
        exit 0
    fi
done
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: wasm_js tests (need node on PATH)"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ "${1:-}" = std ]; then
    STD="${IDSTD_HOME:-}"
    [ -z "$STD" ] && [ -d ../../../idstd ] && STD=$(cd ../../../idstd && pwd)
    if [ -z "$STD" ] || [ ! -d "$STD/sys/io/fs" ]; then
        echo "SKIP: wasm_js std tests (no idstd found; set IDSTD_HOME)"
        exit 0
    fi
    export IDSTD_HOME="$STD"
    unset IDC_NO_STD
    mkdir -p "$TMP/std"
    cp wasm_js/std/*.id "$TMP/std/"
    if ! $BIN_IDC "$TMP/std" --target wasm -o "$TMP/std.wasm" >"$TMP/std.err" 2>&1; then
        bad "the idstd fs/env program builds ($(head -3 "$TMP/std.err" | tr '\n' ' '))"
        echo; echo "$pass passed, $fail failed"; exit 1
    fi
    ok "the idstd fs/env program builds for wasm"
    imports=$(wasm-objdump -x -j Import "$TMP/std.wasm" 2>/dev/null | grep -o 'env\.id_[a-z_]*' | sort | tr '\n' ' ')
    case "$imports" in
        *id_fs_open*id_fs_size*|*id_fs_size*id_fs_open*) ok "the fs natives the program reaches are imports ($imports)" ;;
        *) bad "fs natives are imports (got: $imports)" ;;
    esac
    mkdir "$TMP/stdname"
    printf 'twice(int a) {\n  int b = a * 2;\n} return int b;\n(2):(4)\n(5):(10)\n' > "$TMP/stdname/twice.id"
    printf 'string[] lib_exports = ["twice", "lst_str_index"];\n' > "$TMP/stdname/conf.id"
    if $BIN_IDC "$TMP/stdname" --target wasm -o "$TMP/stdname.wasm" >"$TMP/stdname.err" 2>&1; then
        bad "a lib_exports name that is an idstd function is refused (built)"
    elif grep -q "'lst_str_index', a function of the standard library" "$TMP/stdname.err" && grep -q 'define a function of your own that calls it' "$TMP/stdname.err"; then
        ok "a lib_exports name that is an idstd function is refused, naming it and the fix"
    else
        bad "a lib_exports name that is an idstd function is refused ($(head -2 "$TMP/stdname.err" | tr '\n' ' '))"
    fi
    if node wasm_js/std_check.mjs "$TMP" > "$TMP/std.out" 2>&1; then
        cat "$TMP/std.out"
        pass=$((pass + $(grep -c '^PASS' "$TMP/std.out")))
    else
        cat "$TMP/std.out"
        fail=$((fail + $(grep -c '^FAIL' "$TMP/std.out") + 0))
        [ "$(grep -c '^FAIL' "$TMP/std.out")" -eq 0 ] && bad "std_check.mjs exited non-zero with no FAIL line"
    fi
    echo; echo "$pass passed, $fail failed"
    [ "$fail" -eq 0 ]
    exit
fi

export IDC_NO_STD=1
unset IDSTD_HOME

build() { # build NAME DIR [FLAGS...]
    local name="$1" dir="$2"
    shift 2
    $BIN_IDC "$dir" --allow-untested --target wasm -o "$TMP/$name.wasm" "$@" >"$TMP/$name.err" 2>&1
}

build lib wasm_js/lib       || { bad "lib builds ($(head -2 "$TMP/lib.err" | tr '\n' ' '))"; echo "$pass passed, $fail failed"; exit 1; }
build liball wasm_js/lib --exports all || { bad "lib builds with --exports all ($(head -2 "$TMP/liball.err" | tr '\n' ' '))"; echo "$pass passed, $fail failed"; exit 1; }
build nobe wasm_js/nobe --backend wasm_js/lib/jsx || { bad "nobe builds ($(head -2 "$TMP/nobe.err" | tr '\n' ' '))"; echo "$pass passed, $fail failed"; exit 1; }
build cmd wasm_js/cmd       || { bad "cmd builds ($(head -2 "$TMP/cmd.err" | tr '\n' ' '))"; echo "$pass passed, $fail failed"; exit 1; }
ok "the four fixtures build to .wasm, .mjs and .d.ts"

for f in lib.mjs lib.d.ts liball.mjs nobe.mjs cmd.mjs; do
    [ -s "$TMP/$f" ] || bad "$f was written"
done

exports=$(wasm-objdump -x -j Export "$TMP/lib.wasm" 2>/dev/null | grep -oE '"[a-zA-Z_0-9]+"' | tr -d '"' | grep '^id_' | sort | tr '\n' ' ')
want="id_alloc id_measure id_shout id_squares id_str_of_cstr id_twice "
if [ "$exports" = "$want" ]; then
    ok "the export rule is exactly conf.id's lib_exports (a function of sub/ included, the other sub/ functions not)"
else
    bad "the default export rule (got: $exports)"
fi

if [ "$(grep -c 'idw_be_jsx' "$TMP/lib.mjs")" -ge 2 ] && ! grep -q 'idw_be_jsx' "$TMP/nobe.mjs"; then
    ok "a backend is bundled when a native of it is reached, and not when it only is attached"
else
    bad "backend bundling follows reachability"
fi

if node wasm_js/check.mjs "$TMP" > "$TMP/check.out" 2>&1; then
    cat "$TMP/check.out"
    pass=$((pass + $(grep -c '^PASS' "$TMP/check.out")))
else
    cat "$TMP/check.out"
    pass=$((pass + $(grep -c '^PASS' "$TMP/check.out")))
    fail=$((fail + $(grep -c '^FAIL' "$TMP/check.out")))
    [ "$(grep -c '^FAIL' "$TMP/check.out")" -eq 0 ] && bad "check.mjs exited non-zero with no FAIL line ($(tail -3 "$TMP/check.out" | tr '\n' ' '))"
fi

if build nowasm wasm_js/nowasm; then
    bad "a native whose backend has no wasm implementation is refused"
else
    if grep -q "native 'nw_one'" "$TMP/nowasm.err" && grep -q 'wasm_js' "$TMP/nowasm.err" && grep -q 'nowasm/api.id:2' "$TMP/nowasm.err"; then
        ok "a native whose backend has no wasm implementation is refused at its call, naming wasm_js as the fix"
    else
        bad "the refusal names the native, its call and the fix ($(head -3 "$TMP/nowasm.err" | tr '\n' ' '))"
    fi
fi

TW='twice(int a) {\n  int b = a * 2;\n} return int b;\n(2):(4)\n(5):(10)\n'
refuse() { # refuse NAME CONF-OR-EMPTY WHAT PATTERN... : a project that must not build, and the words its error must hold
    local name="$1" conf="$2" what="$3"; shift 3
    mkdir -p "$TMP/$name"
    printf "$TW" > "$TMP/$name/twice.id"
    [ -n "$conf" ] && printf '%s\n' "$conf" > "$TMP/$name/conf.id"
    if build "$name" "$TMP/$name"; then bad "$what (built)"; return; fi
    local p
    for p in "$@"; do
        grep -qF -- "$p" "$TMP/$name.err" || { bad "$what (the error lacks '$p': $(head -2 "$TMP/$name.err" | tr '\n' ' '))"; return; }
    done
    ok "$what"
}
refuse wnolist "" "a wasm library with no lib_exports list is refused, showing the line to add" 'lib_exports = [' 'wnolist/conf.id'
refuse wbadname 'string[] lib_exports = ["twice", "twicce"];' "a lib_exports name that is not a function is refused, naming it and the fix" "'twicce', which is not a function of this project" 'check the spelling'
refuse wdupname 'string[] lib_exports = ["twice", "twice"];' "a duplicate lib_exports entry is refused, naming it and the fix" "lists 'twice' twice; remove one"
refuse wmainname 'string[] lib_exports = ["twice", "main"];' "listing main is refused, naming the fix" "lists 'main', which cannot be exported"
mkdir -p "$TMP/wnomarsh"
printf 'grid(int[][] gx) {\n  int gn = len(gx);\n} return int gn;\n([[1]]):(1)\n([[1], [2]]):(2)\n' > "$TMP/wnomarsh/grid.id"
printf 'string[] lib_exports = ["grid"];\n' > "$TMP/wnomarsh/conf.id"
if build wnomarsh "$TMP/wnomarsh"; then bad "an unmarshallable listed function is refused (built)"
elif grep -q "lists 'grid'" "$TMP/wnomarsh.err" && grep -q 'does not cross the boundary' "$TMP/wnomarsh.err" && grep -q 'remove the entry' "$TMP/wnomarsh.err"; then ok "an unmarshallable listed function is refused, naming it and the fix"
else bad "an unmarshallable listed function is refused ($(head -2 "$TMP/wnomarsh.err" | tr '\n' ' '))"; fi

mkdir -p "$TMP/wunreached"
cp wasm_js/cmd/main.id "$TMP/wunreached/main.id"
printf "$TW" > "$TMP/wunreached/twice.id"
printf 'string[] lib_exports = ["twice"];\n' > "$TMP/wunreached/conf.id"
if build wunreached "$TMP/wunreached"; then bad "a listed function a program's main never reaches is refused (built)"
elif grep -q "'twice', which the module does not contain" "$TMP/wunreached.err" && grep -q 'call it from main' "$TMP/wunreached.err"; then ok "a listed function a program's main never reaches is refused, naming the fix"
else bad "a listed function a program's main never reaches is refused ($(head -2 "$TMP/wunreached.err" | tr '\n' ' '))"; fi

if $BIN_IDC wasm_js/lib --allow-untested --target wasm --no-js -o "$TMP/nojs.wasm" >/dev/null 2>&1 && [ -s "$TMP/nojs.wasm" ] && [ ! -e "$TMP/nojs.mjs" ]; then
    ok "--no-js writes the .wasm alone"
else
    bad "--no-js writes the .wasm alone"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
