#!/usr/bin/env bash
# Self-hosted-driver tests: bin/idc (the id-written lexer+parser driven by a
# bash driver -- see bin/idc) must build several demos to binaries whose
# RUNTIME OUTPUT matches the idc.py-built binary exactly, and its --emit-c
# output must be byte-identical to idc.py's for programs the self-hosted
# compiler fully supports.
#
# There is no fallback: bin/idc drives the self-hosted stages and nothing
# else, so every check here is a check of them. tools/parity.sh and
# tests/run.sh's "codegen parity" section cover self-hosted/idc.py byte-parity
# on the emitted C; this suite covers the driver end to end.
#
# Run from anywhere: tests/self_host_build.sh
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

ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# build_pair NAME PROG -- builds PROG with both compilers into $TMP/NAME_py
# and $TMP/NAME_self; returns nonzero (and records a FAIL) if either fails.
build_pair() {
    local name="$1" prog="$2"
    if ! $IDC "$prog" -o "$TMP/${name}_py" >/dev/null 2>"$TMP/${name}.pyerr"; then
        bad "$name: idc.py build (see $(cat "$TMP/${name}.pyerr" | head -1))"
        return 1
    fi
    if ! $BIN_IDC "$prog" -o "$TMP/${name}_self" >/dev/null 2>"$TMP/${name}.selferr"; then
        bad "$name: bin/idc build (see $(cat "$TMP/${name}.selferr" | head -1))"
        return 1
    fi
    ok "$name: idc.py and bin/idc both build"
}

# check_output NAME [ARGS...] -- runs both binaries with the same args/stdin
# behavior and compares stdout+stderr.
check_output() {
    local name="$1"; shift
    local out_py out_self
    out_py=$("$TMP/${name}_py" "$@" 2>&1)
    out_self=$("$TMP/${name}_self" "$@" 2>&1)
    if [ "$out_py" = "$out_self" ]; then
        ok "$name: bin/idc binary output matches idc.py binary"
    else
        bad "$name: output mismatch (idc.py='$out_py' bin/idc='$out_self')"
    fi
}

# Every demo project, discovered rather than listed. A demo added to demos/
# is covered from the moment it exists, with no script to remember to edit --
# which is the failure this replaced: the list here named four demos while
# demos/ held eighteen.
#
# A demo that needs a --backend or a standard library cannot build here (this
# file is hermetic and passes no flags), so "both compilers refuse it" is a
# pass: what is being checked is that the two compilers AGREE, and agreeing to
# refuse is agreement. What would fail is one building and the other not.
for prog in ../../demos/*/; do
    name=$(basename "$prog")
    $IDC     "$prog" -o "$TMP/sweep_py"   >/dev/null 2>&1; py=$?
    $BIN_IDC "$prog" -o "$TMP/sweep_self" >/dev/null 2>&1; self=$?
    if [ "$py" -eq "$self" ]; then
        ok "sweep: $name (both compilers agree: rc=$py)"
    else
        bad "sweep: $name (idc.py rc=$py, bin/idc rc=$self)"
    fi
done

build_pair hello ../../demos/hello && check_output hello hi
build_pair calc ../../demos/calc && check_output calc
build_pair control ../../demos/control/flow.id && check_output control

if build_pair adventure ../../demos/adventure; then
    for choices in "1 1 1" "2 2 2" "2 1 2"; do
        out_py=$(printf '%s\n' $choices | "$TMP/adventure_py" | grep -o 'ENDING [0-9]')
        out_self=$(printf '%s\n' $choices | "$TMP/adventure_self" | grep -o 'ENDING [0-9]')
        if [ "$out_py" = "$out_self" ]; then
            ok "adventure ($choices): bin/idc matches idc.py"
        else
            bad "adventure ($choices): mismatch (idc.py='$out_py' bin/idc='$out_self')"
        fi
    done
fi

# --emit-c byte parity through the driver (a couple of programs the
# self-hosted compiler fully supports today -- see tools/parity.sh)
for prog in ../../demos/calc ../../demos/control/flow.id ../../demos/adventure; do
    $IDC "$prog" --emit-c "$TMP/ec_py.c" >/dev/null 2>&1
    $BIN_IDC "$prog" --emit-c "$TMP/ec_self.c" >/dev/null 2>&1
    if diff "$TMP/ec_py.c" "$TMP/ec_self.c" >/dev/null; then
        ok "emit-c byte parity via bin/idc ($prog)"
    else
        bad "emit-c byte parity via bin/idc ($prog)"
    fi
done

# a no-main project (a library) must build to a .o with bin/idc too
if env -u IDC_NO_STD $BIN_IDC ../../demos/engine -o "$TMP/engine_self.o" >/dev/null 2>&1 \
   && [ -f "$TMP/engine_self.o" ]; then
    ok "engine (no main -> .o) builds via bin/idc"
else
    bad "engine (no main -> .o) builds via bin/idc"
fi

# -- link-time-resolved calls (native backends) ------------------------------
# A call no input file defines is a typo when nothing could resolve it, and a
# link-time symbol when a backend is attached. Both halves are checked, since
# the same pass decides them and getting either wrong breaks the other.

# (a) no backend: the name is rejected, by name, with the builtin list --
#     NOT handed to cc as an implicit declaration.
cat > "$TMP/typo.id" <<'EOF'
main(int argc, string[] argv) {
  string s = to_flot("1");
  print(s);
} return int 0;
EOF
typo_out=$($BIN_IDC "$TMP/typo.id" -o "$TMP/typo.bin" 2>&1)
if printf '%s' "$typo_out" | grep -q "error: no such function 'to_flot'" \
   && printf '%s' "$typo_out" | grep -q "available builtins:" \
   && ! printf '%s' "$typo_out" | grep -q "internal error"; then
    ok "unresolved call with no backend is a 'no such function' error"
else
    bad "unresolved call with no backend is a 'no such function' error (got: $(printf '%s' "$typo_out" | head -1))"
fi

# (b) with a backend: its `native` declarations are merged as source, so the
#     emitted C carries a real prototype for each call into it and no
#     `extern int` block. This used to assert that block and byte parity with
#     idc.py; the parity is gone by design, since idc.py, which is being retired
#     and will not change, still emits the block. gfxdemo is a user program and
#     calls idstd's lset, so bin/idc builds it with the standard library, as
#     backends.sh does -- the old check passed without it only because the
#     missing lset became one more `extern int`.
for prog in ../../demos/gfxdemo; do
    be=../backends/gfx
    if ! $IDC "$prog" --backend "$be" --emit-c "$TMP/be_py.c" >/dev/null 2>&1; then
        bad "backend emit-c: idc.py failed on $prog"
        continue
    fi
    if ! env -u IDC_NO_STD $BIN_IDC "$prog" --backend "$be" --emit-c "$TMP/be_self.c" >/dev/null 2>&1; then
        bad "backend emit-c: bin/idc failed on $prog"
        continue
    fi
    if grep -qx 'int id_gfx_open(int w, int h, char\* title);' "$TMP/be_self.c" \
       && ! grep -q '^extern int id_' "$TMP/be_self.c"; then
        ok "backend calls are emitted as prototypes via bin/idc ($prog)"
    else
        bad "backend calls are emitted as prototypes via bin/idc ($prog)"
    fi
done

# -- the driver must agree with idc.py about what a project IS ---------------
# These are filesystem questions, answered in bash rather than in id, so they
# are the ones most likely to drift from idc.py. Each one did.

# (a) hidden directories are neither counted toward the 3-entry limit nor
#     descended into for source.
proj="$TMP/hid"
mkdir -p "$proj/.git" "$proj/a" "$proj/b"
cat > "$proj/m.id" <<'EOF'
main(int argc, string[] argv) { print(1); } return int 0;
EOF
cat > "$proj/.git/sneaky.id" <<'EOF'
sneaky_fn() { int q = 1; } return int q;
EOF
$IDC     "$proj" --emit-c "$TMP/hid_py.c"   >/dev/null 2>&1; py_rc=$?
$BIN_IDC "$proj" --emit-c "$TMP/hid_self.c" >/dev/null 2>&1; self_rc=$?
if [ "$py_rc" -eq 0 ] && [ "$self_rc" -eq 0 ] \
   && diff "$TMP/hid_py.c" "$TMP/hid_self.c" >/dev/null \
   && ! grep -q id_sneaky_fn "$TMP/hid_self.c"; then
    ok "hidden dirs: not counted, not compiled (matches idc.py)"
else
    bad "hidden dirs: not counted, not compiled (idc.py rc=$py_rc bin/idc rc=$self_rc)"
fi

# (a2) ...including a conf.id inside one. A hidden directory is outside the
#      project entirely, so its conf.id is not a NESTED manifest -- it is not a
#      manifest at all, and reporting it stops a project from being built for a
#      file it never reads. bin/idc excluded the root's own conf.id with
#      `find -mindepth 2`, which also stops `-prune` from firing at depth 1, so
#      every hidden directory directly under a root was walked into. idstd's
#      whole test suite lives in `.tests/` and could not be built.
mkdir -p "$proj/.git"
cat > "$proj/.git/conf.id" <<'EOF'
int sneaky_depth = 7;
EOF
$IDC     "$proj" --emit-c "$TMP/hidconf_py.c"   >/dev/null 2>&1; py_rc=$?
$BIN_IDC "$proj" --emit-c "$TMP/hidconf_self.c" >/dev/null 2>&1; self_rc=$?
if [ "$py_rc" -eq 0 ] && [ "$self_rc" -eq 0 ] \
   && diff "$TMP/hidconf_py.c" "$TMP/hidconf_self.c" >/dev/null; then
    ok "a conf.id inside a hidden dir is not a nested manifest (matches idc.py)"
else
    bad "a conf.id inside a hidden dir is not a nested manifest (idc.py rc=$py_rc bin/idc rc=$self_rc)"
fi

# (b) an absolute path in conf.id resolves, as it does under idc.py.
lib="$TMP/implib"; app="$TMP/impapp"
mkdir -p "$lib" "$app"
cat > "$lib/h.id" <<'EOF'
imp_helper() { int q = 5; } return int q;
EOF
cat > "$app/main.id" <<'EOF'
main(int argc, string[] argv) { int r = imp_helper(); print(r); } return int 0;
EOF
printf 'import "%s"\n' "$lib" > "$app/conf.id"
if $BIN_IDC "$app" -o "$TMP/imp.bin" >/dev/null 2>&1 \
   && [ "$("$TMP/imp.bin")" = "5" ]; then
    ok "conf.id: an absolute dependency path resolves"
else
    bad "conf.id: an absolute dependency path resolves"
fi

# (b2) a conf.id constant becomes a program global, initialised before main
#      runs rather than by a function nothing calls (docs/TODO.md item 4).
#      bin/idc only: idc.py never learned conf.id constants and is not going
#      to -- the compiler's own source declares none, so the bootstrap rule
#      says it does not need them.
proj="$TMP/consts"
mkdir -p "$proj"
cat > "$proj/conf.id" <<'EOF'
int max_depth = 7;
int fanout = 3;
EOF
cat > "$proj/main.id" <<'EOF'
main(int argc, string[] argv) {
  print((import max_depth) * (import fanout));
} return int 0;
EOF
if $BIN_IDC "$proj" -o "$TMP/consts.bin" >/dev/null 2>&1 \
   && [ "$("$TMP/consts.bin")" = "21" ]; then
    ok "conf.id: a constant is a global, initialised before main"
else
    bad "conf.id: a constant is a global, initialised before main"
fi

# and it is emitted at file scope with its initialiser attached, which is what
# makes "no function declares it" true rather than merely unreported.
if $BIN_IDC "$proj" --emit-c "$TMP/consts.c" >/dev/null 2>&1 \
   && grep -q '^int max_depth = 7;  /\* constant from conf.id \*/$' "$TMP/consts.c"; then
    ok "conf.id: a constant is emitted with a static initialiser"
else
    bad "conf.id: a constant is emitted with a static initialiser"
fi

# a constant is an exported name, so a function may not export it again.
cat > "$proj/main.id" <<'EOF'
main(int argc, string[] argv) {
  export int max_depth = 1;
  print((import max_depth));
} return int 0;
EOF
if $BIN_IDC "$proj" -o "$TMP/consts.bin" 2>&1 \
   | grep -q "'max_depth' is already an exported global"; then
    ok "conf.id: a constant reserves its name against a later export"
else
    bad "conf.id: a constant reserves its name against a later export"
fi

# and the same constants reach the LLVM target, where a global's initialiser
# must already be a value: a string is a pointer to bytes emitted beside it,
# and an integer written as an operator over literals is folded. The kernel
# builds only for LLVM, so this is the path its constants take.
if command -v clang >/dev/null 2>&1; then
    cat > "$proj/conf.id" <<'EOF'
int max_depth = 7 * 3;
int below = 0 - 2;
string banner = "id\tok";
EOF
    cat > "$proj/main.id" <<'EOF'
main(int argc, string[] argv) {
  print((import max_depth) + (import below));
  print((import banner));
} return int 0;
EOF
    if $BIN_IDC "$proj" --target llvm -o "$TMP/consts_ll.bin" >/dev/null 2>&1 \
       && [ "$("$TMP/consts_ll.bin")" = "$(printf '19\nid\tok')" ]; then
        ok "conf.id: string and folded constants build for --target llvm"
    else
        bad "conf.id: string and folded constants build for --target llvm"
    fi
else
    echo "SKIP: conf.id constants on --target llvm (needs clang on PATH)"
fi

# (c) --triple reaches idparse, which is what selects among asm overloads.
cat > "$TMP/asm.id" <<'EOF'
main(int argc, string[] argv) {
  word r = dbl(21);
  print(r);
} return int 0;
asm "x86_64-unknown-linux-gnu" dbl(word a) {
  "mov %[a], %[ret]"
  "add %[ret], %[ret]"
} return word ret;
EOF
if $BIN_IDC "$TMP/asm.id" --triple x86_64-unknown-linux-gnu -o "$TMP/asm.bin" >/dev/null 2>&1 \
   && [ "$("$TMP/asm.bin")" = "42" ] \
   && $BIN_IDC "$TMP/asm.id" --triple aarch64-unknown-linux-gnu -o "$TMP/asm2.bin" 2>&1 \
      | grep -q "no 'asm' definition of 'dbl' for target 'aarch64-unknown-linux-gnu'"; then
    ok "--triple selects the asm overload, and reports a missing one"
else
    bad "--triple selects the asm overload, and reports a missing one"
fi

# (c2) ...and it is read wherever it appears, not only at argv[1]. The driver
# once put another flag ahead of --triple whenever a backend was attached, and
# the positional read this replaced then kept the default triple: the build
# below silently produced an x86_64 binary and reported success.
if $BIN_IDC "$TMP/asm.id" --backend ../backends/fs --triple aarch64-unknown-linux-gnu \
     -o "$TMP/asm3.bin" 2>&1 \
   | grep -q "no 'asm' definition of 'dbl' for target 'aarch64-unknown-linux-gnu'" \
   && [ ! -f "$TMP/asm3.bin" ]; then
    ok "--triple is honoured with a backend attached (not just at argv[1])"
else
    bad "--triple is honoured with a backend attached (not just at argv[1])"
fi

# (c3) The missing-overload diagnostic is a diagnostic, not a compiler bug.
# asm_error prints, and print shares its stream with the generated code, so
# without a failure flag the message landed inside the C and the build died as
# "internal error: the self-hosted compiler emitted C that does not compile".
# One line out, and nothing about reporting it.
asm_out=$($BIN_IDC "$TMP/asm.id" --triple aarch64-unknown-linux-gnu -o "$TMP/asm4.bin" 2>&1)
if [ "$(printf '%s\n' "$asm_out" | wc -l)" -eq 1 ] \
   && ! printf '%s\n' "$asm_out" | grep -q "internal error"; then
    ok "a missing asm overload is reported, not raised as a compiler bug"
else
    bad "a missing asm overload is reported, not raised as a compiler bug"
fi

# (c4) A triple naming a platform the host cc cannot target is refused. It used
# to build: the triple picked the backend's darwin sources and the host cc
# compiled them anyway, so `--triple aarch64-apple-darwin` on Linux produced a
# Linux ELF wearing another platform's name.
if $BIN_IDC ../../demos/hello --triple aarch64-apple-darwin -o "$TMP/cross.bin" 2>&1 \
   | grep -q "cannot build for 'aarch64-apple-darwin' here" \
   && [ ! -f "$TMP/cross.bin" ]; then
    ok "a non-host platform triple is refused rather than built for the host"
else
    bad "a non-host platform triple is refused rather than built for the host"
fi

# (c5) ...and --cc means the user has one, so it is trusted.
if $BIN_IDC ../../demos/hello --triple aarch64-apple-darwin --cc cc -o "$TMP/cross2.bin" \
     >/dev/null 2>&1 && [ -f "$TMP/cross2.bin" ]; then
    ok "--cc overrides the host-platform refusal"
else
    bad "--cc overrides the host-platform refusal"
fi

# bootstrap caching: a second invocation must not rebuild idlex/idparse
cache_before=$(stat -c %Y ../.idc-cache/idlex 2>/dev/null || stat -f %m ../.idc-cache/idlex 2>/dev/null)
$BIN_IDC ../../demos/calc -o "$TMP/calc_self2" >/dev/null 2>"$TMP/cache.err"
cache_after=$(stat -c %Y ../.idc-cache/idlex 2>/dev/null || stat -f %m ../.idc-cache/idlex 2>/dev/null)
if [ "$cache_before" = "$cache_after" ] && ! grep -q "bootstrapping" "$TMP/cache.err"; then
    ok "bin/idc caches idlex/idparse across runs (no rebuild)"
else
    bad "bin/idc caches idlex/idparse across runs (no rebuild)"
fi

# A nested conf.id is a source file that silently does not exist: it is
# filtered out as metadata and only a ROOT's is read as a manifest, so anything
# it defines vanishes and the caller is blamed with "no such function". Both
# compilers must say what actually happened. Found by a rename that happened to
# choose the name.
mkdir -p "$TMP/nested/sub"
cat > "$TMP/nested/main.id" <<'EOF'
main(int argc, string[] argv) {
  int r = helper();
  print(r);
} return int 0;
EOF
cat > "$TMP/nested/sub/conf.id" <<'EOF'
helper() {
  int r = 42;
} return int r;
EOF
nested_msg="is the dependency manifest and is only read at the root"
if $BIN_IDC "$TMP/nested" -o "$TMP/nested.bin" 2>&1 | grep -q "$nested_msg" \
   && $IDC "$TMP/nested" -o "$TMP/nested.bin" 2>&1 | grep -q "$nested_msg"; then
    ok "a nested conf.id is reported, by both compilers"
else
    bad "a nested conf.id is reported, by both compilers"
fi

# An over-full directory must not swallow a real semantic error elsewhere in
# the same project: check_entry_limit used to exit before idlex/idparse ever
# ran, so a project mixing the two reported only the directory violation and
# hid everything idparse had to say about the rest -- this is exactly how
# idem/engine's 1,115 real errors were once read as "1 error". bin/idc only:
# idc.py still stops at the first CompileError it raises.
mkdir -p "$TMP/mixed"
for n in 1 2 3 4; do printf 'mx%d() {\n} return int %d;\n' "$n" "$n" > "$TMP/mixed/f$n.id"; done
cat > "$TMP/mixed/main.id" <<'EOF'
main(int argc, string[] argv) {
  int r = no_such_function();
  print(r);
} return int 0;
EOF
mixed_out=$($BIN_IDC "$TMP/mixed" -o "$TMP/mixed.bin" 2>&1)
mixed_rc=$?
if [ "$mixed_rc" -ne 0 ] \
   && printf '%s\n' "$mixed_out" | grep -q "at most 3 files and directories" \
   && printf '%s\n' "$mixed_out" | grep -q "no such function 'no_such_function'"; then
    ok "an over-full directory does not hide a real semantic error"
else
    bad "an over-full directory does not hide a real semantic error"
fi

# Test clauses (docs/TESTS.md) are part of a declaration, so BOTH compilers
# must accept them and both must ignore them in codegen. When only idc.py knew
# the syntax, a program carrying cases was a syntax error in the primary
# compiler -- two dialects, not one language. Byte parity is the assertion that
# matters: the cases must leave no trace in the emitted C. bin/idc runs the
# cases on every build, so they have to pass, and a scaling claim has to be on
# two cases of different sizes.
cat > "$TMP/cases.id" <<'EOF'
add(int a, int b) {
  int sum = a + b;
} return int sum;
(1, 2):(3)[time:O(1)]
(0, 0):(0)[time:O(1)]

main(int argc, string[] argv) {
  int r = add(2, 3);
  print(r);
} return int 0;
EOF
$IDC "$TMP/cases.id" --emit-c "$TMP/cases_py.c" >/dev/null 2>&1
$BIN_IDC "$TMP/cases.id" --emit-c "$TMP/cases_self.c" >/dev/null 2>&1
if [ -s "$TMP/cases_self.c" ] && cmp -s "$TMP/cases_py.c" "$TMP/cases_self.c"; then
    ok "a program with test cases builds identically under both compilers"
else
    bad "a program with test cases builds identically under both compilers"
fi

# -- stage 0 is C, and nothing here runs idc.py ------------------------------
#
# bootstrap/*.c is the compiler as C (bootstrap/README.md). Two things have to
# hold, and they fail in different ways: the snapshot has to still BE the
# compiler, and the driver has to still not need Python to get one.

# The gate. A cold cache, against a ROOT whose idc.py is a DIRECTORY -- which
# no shebang can execute -- so anything that still shells out to it fails here
# rather than passing on a file that merely happens to be present. The root is
# symlinks rather than a copy because the tree is 30 MB and only its names
# matter: bin/idc derives ROOT from its own path, so a linked bin/idc under
# $BOOTROOT sees $BOOTROOT as the repository.
#
# --std is passed explicitly: the bootstrap needs the library (both stages call
# lset) and deliberately ignores IDC_NO_STD, and $BOOTROOT has no sibling to
# find one beside.
REAL_ROOT=$(cd .. && pwd)
STD_REAL=""
for cand in "${IDSTD_HOME:-}" "$REAL_ROOT/../idstd" "$REAL_ROOT/../../idstd"; do
    [ -n "$cand" ] && [ -d "$cand" ] && { STD_REAL=$(cd "$cand" && pwd); break; }
done
if [ -z "$STD_REAL" ]; then
    echo "SKIP: bootstrap/*.c currency (no idstd checkout to build the compiler against)"
elif IDSTD_HOME="$STD_REAL" ../tools/regen_bootstrap.sh --check >"$TMP/regen.out" 2>&1; then
    ok "bootstrap/*.c is what compiler/{lex,parse} emits"
else
    bad "bootstrap/*.c is stale (run tools/regen_bootstrap.sh): $(head -1 "$TMP/regen.out")"
fi

BOOTROOT="$TMP/bootroot"
mkdir -p "$BOOTROOT"
for e in "$REAL_ROOT"/*; do
    [ "$(basename "$e")" = "idc.py" ] && continue
    ln -s "$e" "$BOOTROOT/$(basename "$e")"
done
mkdir -p "$BOOTROOT/idc.py"
printf 'main(int argc, string[] argv) {\n  print("bootstrapped");\n} return int 0;\n' \
    > "$TMP/hello_boot.id"
if [ -z "$STD_REAL" ]; then
    echo "SKIP: cold bootstrap (no idstd checkout to build the compiler against)"
elif IDC_CACHE_DIR="$TMP/bootcache" "$BOOTROOT/bin/idc" --std "$STD_REAL" \
         "$TMP/hello_boot.id" -o "$TMP/hello_boot" >"$TMP/boot.err" 2>&1 \
     && [ "$("$TMP/hello_boot")" = "bootstrapped" ]; then
    ok "a cold cache bootstraps from bootstrap/*.c with idc.py unreachable"
else
    bad "a cold cache bootstraps from bootstrap/*.c with idc.py unreachable: $(head -2 "$TMP/boot.err" | tr '\n' ' ')"
fi

# -- expression compilation is linear, not exponential ----------------------
# A left-leaning `+` chain used to double the work at every level of the
# tree: type_of and emit_bin each answered "is this concat/strcmp/a helper
# op" by recomputing both operands' types or C text from scratch instead of
# reusing what the level below had already worked out, which is exponential
# in the chain's depth. A 250-term chain drove this compiler to tens of GB;
# it must now build in a couple of seconds under a tight cap. See the fix in
# mid/types/type_of/ (a per-node type cache) and back/tgt/c/emit/.../binop/
# and .../op/helper/ (if/else in place of compute-then-override).
int_chain="1"
str_chain='"a1"'
i=2
while [ "$i" -le 250 ]; do
    int_chain="$int_chain + $i"
    str_chain="$str_chain + \"a$i\""
    i=$((i + 1))
done
printf 'main(int argc, string[] argv) {\n  int x = %s;\n  print(x);\n} return int 0;\n' \
    "$int_chain" > "$TMP/chain_int.id"
printf 'main(int argc, string[] argv) {\n  string x = %s;\n  print(x);\n} return int 0;\n' \
    "$str_chain" > "$TMP/chain_str.id"

if (ulimit -v 2000000; timeout 5 "$BIN_IDC" "$TMP/chain_int.id" -o "$TMP/chain_int_bin") \
        >"$TMP/chain_int.err" 2>&1; then
    ok "250-term int + chain compiles in linear time under a 2 GB cap"
else
    bad "250-term int + chain compiles in linear time under a 2 GB cap: $(head -1 "$TMP/chain_int.err")"
fi

if (ulimit -v 2000000; timeout 5 "$BIN_IDC" "$TMP/chain_str.id" -o "$TMP/chain_str_bin") \
        >"$TMP/chain_str.err" 2>&1; then
    ok "250-term string + chain compiles in linear time under a 2 GB cap"
else
    bad "250-term string + chain compiles in linear time under a 2 GB cap: $(head -1 "$TMP/chain_str.err")"
fi

# IDC_MEM_LIMIT: a deliberately tiny ceiling, against a fresh cache so the
# bootstrap rebuild actually exercises it, must be reported as a memory
# failure naming the stage and the ceiling -- not the generic "bug in the
# self-hosted compiler" block, because the compiler was refused memory, not
# necessarily wrong.
mem_out=$(IDC_CACHE_DIR="$TMP/memcache" IDC_MEM_LIMIT=100 $BIN_IDC ../../demos/hello -o "$TMP/mem.bin" 2>&1)
mem_rc=$?
if [ "$mem_rc" -ne 0 ] \
   && printf '%s\n' "$mem_out" | grep -q "exceeded the memory ceiling (100 MB)" \
   && ! printf '%s\n' "$mem_out" | grep -q "this is a bug in the self-hosted compiler"; then
    ok "a tiny IDC_MEM_LIMIT is reported as a memory failure, not a compiler bug"
else
    bad "a tiny IDC_MEM_LIMIT is reported as a memory failure, not a compiler bug"
fi

# IDC_MEM_LIMIT=0 disables the ceiling entirely -- the same build with a
# normal cache must still succeed.
if IDC_MEM_LIMIT=0 $BIN_IDC ../../demos/hello -o "$TMP/mem0.bin" >/dev/null 2>&1 \
   && [ -x "$TMP/mem0.bin" ]; then
    ok "IDC_MEM_LIMIT=0 disables the memory ceiling"
else
    bad "IDC_MEM_LIMIT=0 disables the memory ceiling"
fi

# A caller's own tighter ulimit -v is kept, not fought: the driver used to try
# raising it to IDC_MEM_LIMIT for every stage and printed "cannot modify limit"
# each time.
tight_out=$( (ulimit -v 3500000 2>/dev/null; $BIN_IDC ../../demos/hello -o "$TMP/tight.bin") 2>&1)
if [ -x "$TMP/tight.bin" ] && ! printf '%s\n' "$tight_out" | grep -q "cannot modify limit"; then
    ok "a caller's tighter memory limit is kept without complaint"
else
    bad "a caller's tighter memory limit is kept without complaint: $(printf '%s\n' "$tight_out" | head -1)"
fi

# When it is the caller's limit that a stage runs into, the message says so:
# IDC_MEM_LIMIT cannot raise it, so telling the user to raise IDC_MEM_LIMIT
# would be wrong.
inh_out=$( (ulimit -v 150000; IDC_CACHE_DIR="$TMP/inhcache" $BIN_IDC ../../demos/hello -o "$TMP/inh.bin") 2>&1)
if printf '%s\n' "$inh_out" | grep -q "exceeded the memory limit idc was started under" \
   && ! printf '%s\n' "$inh_out" | grep -q "this is a bug in the self-hosted compiler"; then
    ok "an inherited memory limit is reported as the caller's, not as IDC_MEM_LIMIT"
else
    bad "an inherited memory limit is reported as the caller's, not as IDC_MEM_LIMIT: $(printf '%s\n' "$inh_out" | head -1)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
