#!/usr/bin/env bash
# `--target wasm`: the C target's own C, recompiled for wasm32-wasi and
# linked as a WASI reactor (docs/TODO.md 9b).
#
# Three things are checked, because "it links" is not "it works":
#
#   * the export list is exactly memory/_initialize/id_alloc plus the
#     program's own top-level functions -- not the fixture idstd's, even
#     though it is compiled in (--gc-sections plus the driver's own filter,
#     idc/bin/idc);
#   * an int function and a string-in/string-out function both give the
#     right answer, called from node the way lib/id-runtime.ts calls one;
#   * idstd is still reachable code (tfx_abs is called), it is just not
#     exported -- so this also stands in for "idstd compiles for wasm32",
#     which idc/runtime --runtime --triple wasm32-unknown-unknown cannot do
#     today (docs/GAPS.md).
#
# Uses tests/fixtures/idstd, the same as stdlib.sh, so this says the same
# thing on a checkout with no real idstd beside it.
#
# Run from anywhere: tests/wasm.sh   (needs the umbrella's `nix develop`
# shell for the wasm32-wasi toolchain, and node)
set -u
cd "$(dirname "$0")"
ROOT=".."
FIXTURE=$(cd fixtures/idstd && pwd)
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

for v in IDC_WASI_CLANG IDC_WASI_SYSROOT_INCLUDE IDC_WASI_LIBDIR IDC_WASI_COMPILER_RT; do
    if [ -z "${!v:-}" ]; then
        echo "SKIP: wasm tests (need \$$v -- run via 'nix develop', which flake.nix sets it in)"
        exit 0
    fi
done
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: wasm tests (need node on PATH)"
    exit 0
fi
if ! command -v wasm-objdump >/dev/null 2>&1; then
    echo "SKIP: wasm tests (need wasm-objdump on PATH)"
    exit 0
fi

unset IDSTD_HOME IDC_NO_STD

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/prog.id" <<'EOF'
greet(string who) {
  string g = "hi " + who;
} return string g;

sum3(int a, int b) {
  int t = tfx_abs(a);
  int s = t + b;
} return int s;
EOF

if ! "$ROOT/bin/idc" --std "$FIXTURE" --allow-untested "$TMP/prog.id" \
        --target wasm -o "$TMP/prog.wasm" >"$TMP/build.err" 2>&1; then
    bad "the program builds ($(head -1 "$TMP/build.err"))"
    echo; echo "$pass passed, $fail failed"; exit 1
fi
ok "the program builds"

exports=$(wasm-objdump -x -j Export "$TMP/prog.wasm" 2>/dev/null | grep -oE '"[a-zA-Z_0-9]+"' | tr -d '"' | sort)
want=$(printf '%s\n' memory id_alloc _initialize id_greet id_sum3 | sort)
if [ "$exports" = "$want" ]; then
    ok "exports are exactly memory/id_alloc/_initialize/id_greet/id_sum3 (no fixture idstd)"
else
    bad "export list (got: $(echo "$exports" | tr '\n' ' '))"
fi

cat > "$TMP/check.mjs" <<'EOF'
import fs from 'fs';
const path = process.argv[2];
const stub = {
  fd_write: () => 0, fd_read: () => 0, fd_close: () => 0, fd_seek: () => 0,
  fd_fdstat_get: () => 0, args_sizes_get: () => 0, args_get: () => 0,
  environ_sizes_get: () => 0, environ_get: () => 0, clock_time_get: () => 0,
  proc_exit: (c) => { throw new Error('exit ' + c); },
};
const { instance } = await WebAssembly.instantiate(
  fs.readFileSync(path),
  { wasi_snapshot_preview1: new Proxy(stub, { get: (t, n) => t[n] ?? (() => 0) }) }
);
const e = instance.exports;
e._initialize();
const enc = new TextEncoder(), dec = new TextDecoder();
const w = (s) => { const b = enc.encode(s); const p = e.id_alloc(b.length + 1); const m = new Uint8Array(e.memory.buffer); m.set(b, p); m[p + b.length] = 0; return p; };
const r = (p) => { const m = new Uint8Array(e.memory.buffer); let q = p; while (m[q]) q++; return dec.decode(m.subarray(p, q)); };
console.log(r(e.id_greet(w('web'))));
console.log(e.id_sum3(-4, 10));
EOF
got=$(node "$TMP/check.mjs" "$TMP/prog.wasm" 2>"$TMP/run.err")
want_out=$'hi web\n14'
if [ "$got" = "$want_out" ]; then
    ok "id_greet (string in/out) and id_sum3 (int, via idstd's tfx_abs) both run correctly under node"
else
    bad "node run (got '$got', want '$want_out'; stderr: $(head -1 "$TMP/run.err"))"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
