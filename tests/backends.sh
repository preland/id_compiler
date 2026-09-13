#!/usr/bin/env bash
# Native-backend tests.
#
# The backends are C, so most of what can go wrong is a link question rather
# than a run question -- and link questions need no display. That is the point
# of this file: the checks that matter most (do both backends coexist, do the
# graphics demos still build, is a backend call checked) all run headless.
#
# The few checks that genuinely need a window get one from tools/headless.sh,
# a private Xvfb, so they never touch the developer's own display: a new window
# on a tiling compositor steals focus and drops whatever was fullscreen, which
# is intolerable in a suite that runs on every commit. They skip, loudly, when
# Xvfb is missing.
#
# Needs the X11/GL headers, so it runs under tools/devshell.sh on NixOS. If the
# headers are missing the whole file skips rather than failing -- a machine
# without them is not a machine this suite can say anything about.
#
# Run from anywhere: tests/backends.sh
set -u
# Hermetic: these checks assert on exact diagnostics, exact emitted C, or the
# compiler's own bootstrap, none of which may change because a standard library
# happens to exist beside this repository. stdlib.sh covers that path instead.
# Exception: the graphics demos (gfxdemo, gl3d, gl3dgame, fpsmaze, galaxy, flyover)
# are user programs and get idstd implicitly, so they are built with env -u IDC_NO_STD
# to test them the way a user would.
export IDC_NO_STD=1

cd "$(dirname "$0")"
ROOT=".."
ORG="../.."
ABS_ROOT=$(cd "$ROOT" && pwd)   # for the checks that build from another cwd
# bin/idc takes --allow-untested throughout: none of the programs built here has
# test cases, and what is under test is the backends. It is part of the word so
# the loops below run both compilers as before; idc.py has no such flag.
BIN_IDC="../bin/idc --allow-untested"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
skip() { echo "SKIP: $1"; }

# -- fs: files, and no system libraries at all -------------------------------
# Deliberately above the X11 gate below. This backend is stdio and stat, so it
# builds and runs on any machine with a C compiler, and the checks that used to
# be impossible without a display budget -- does a backend link, does the
# extern block resolve, do both compilers agree -- are all answerable here.
fsout="$TMP/fs"
if cc -O2 -c "$ROOT/backends/fs/fs_posix.c" -I"$ROOT/backends/fs" -o "$TMP/fs.o" 2>"$TMP/fs.err"; then
    ok "backends/fs/fs_posix.c compiles"
else
    bad "backends/fs/fs_posix.c compiles ($(head -1 "$TMP/fs.err"))"
fi

# The demo attaches the backend through its own conf.id, so no --backend
# flag: the id-native path is the one under test.
expected='wrote 44 bytes to fsdemo.txt (close 0)
read 44 bytes back (close 0):
the quick brown fox
jumps over
the lazy dog

removed fsdemo.txt (rc 0), exists now 0
reopening it gives -1, errno 2'
for c in "$BIN_IDC" "$ROOT/idc.py"; do
    name=$(basename "${c%% *}")
    if ! $c "$ORG/demos/fsdemo" -o "$fsout.$name" >"$TMP/fs.build" 2>&1; then
        bad "fsdemo builds with $name"; continue
    fi
    got=$(cd "$TMP" && "$fsout.$name" 2>&1)
    if [ "$got" = "$expected" ]; then
        ok "fsdemo writes, reads back and removes a file ($name)"
    else
        bad "fsdemo writes, reads back and removes a file ($name): got '$got'"
    fi
done

# Naming one backend twice -- --backend *and* conf.id, the two documented
# ways -- used to compile its sources twice and hand cc the same object file
# twice: "multiple definition" for every symbol it exports.
for c in "$BIN_IDC" "$ROOT/idc.py"; do
    name=$(basename "${c%% *}")
    if $c "$ORG/demos/fsdemo" --backend "$ROOT/backends/fs" -o "$fsout.dup.$name" \
         >"$TMP/fs.dup" 2>&1; then
        ok "a backend named by both --backend and conf.id links once ($name)"
    else
        bad "a backend named by both --backend and conf.id links once ($name): $(grep -m1 -i 'multiple definition\|error' "$TMP/fs.dup" | cut -c1-90)"
    fi
done

# fs_list: a directory's entries, sorted, directories marked, and a buffer too
# small still told what it would take. This is the call bin/idc has to have
# before it can be an `id` program rather than a shell script, so it is checked
# from `id` and not just from C.
lsexp='small 15
need 15
a.id
b.id
sub/'
for c in "$BIN_IDC" "$ROOT/idc.py"; do
    name=$(basename "${c%% *}")
    if ! $c "$ROOT/tests/fixtures/lsdemo" -o "$fsout.ls.$name" >"$TMP/ls.build" 2>&1; then
        bad "lsdemo builds with $name ($(head -1 "$TMP/ls.build"))"; continue
    fi
    got=$(cd "$TMP" && "$fsout.ls.$name" 2>&1)
    if [ "$got" = "$lsexp" ]; then
        ok "fs_list lists a directory, sorted, with directories marked ($name)"
    else
        bad "fs_list lists a directory, sorted, with directories marked ($name): got '$got'"
    fi
done

# What fs_list is for: driver/ is the tree walk bin/idc does with `find`, and
# it must agree with `find` byte for byte. The order files reach the compiler
# is the order the one-name-one-type rule reports collisions in, so a walk that
# ordered them differently would make the compiler disagree with itself about
# which file to blame.
if $BIN_IDC "$ROOT/driver" -o "$TMP/idsrc" >"$TMP/drv.build" 2>&1; then
    ok "driver/ builds"
    for tree in "$ROOT/compiler" "$ORG/editor"; do
        want=$(find "$tree" -mindepth 1 \( -type d -name '.*' -prune \) -o \
                    \( -name '*.id' ! -name 'conf.id' -print \) | LC_ALL=C sort)
        got=$("$TMP/idsrc" "$tree")
        if [ "$got" = "$want" ]; then
            ok "the id tree walk matches find|sort ($(basename "$tree"), $(printf '%s\n' "$want" | wc -l) files)"
        else
            bad "the id tree walk matches find|sort ($(basename "$tree")): $(diff <(printf '%s\n' "$got") <(printf '%s\n' "$want") | head -2 | tr '\n' ' ')"
        fi
    done
else
    bad "driver/ builds ($(head -1 "$TMP/drv.build"))"
fi

# fsdemo's emitted C is no longer compared with idc.py's: bin/idc emits the fs
# backend's `native` declarations as prototypes, and idc.py, which is being
# retired and will not change, emits `extern int` for the same calls. What both
# must agree on is the behaviour checked above.

# A call into a backend is checked like any other call. A typo used to pass
# the compiler and fail at the C linker, and a wrong argument count compiled
# and dumped core when run; both are now the diagnostics an `id` function gets.
chk="$TMP/chk"; mkdir -p "$chk"
printf 'import "%s"\n' "$(cd "$ROOT/backends/fs" && pwd)" > "$chk/conf.id"
printf 'main(int argc, string[] argv) {\n  int h = fs_opne("x", "r");\n  print(h);\n} return int 0;\n' > "$chk/main.id"
if $BIN_IDC "$chk" -o "$TMP/chk.bin" 2>&1 | grep -qF "no such function 'fs_opne'; available builtins:"; then
    ok "a typo'd backend call is 'no such function' (bin/idc)"
else
    bad "a typo'd backend call is 'no such function' (bin/idc)"
fi
printf 'main(int argc, string[] argv) {\n  int h = fs_open(1, 2, 3);\n  print(h);\n} return int 0;\n' > "$chk/main.id"
if $BIN_IDC "$chk" -o "$TMP/chk.bin" 2>&1 | grep -qF "function 'fs_open' takes 2 argument(s), got 3"; then
    ok "a backend call with the wrong argument count is rejected (bin/idc)"
else
    bad "a backend call with the wrong argument count is rejected (bin/idc)"
fi

# A native has no body, so its parameter names are not variables and reserve
# nothing. A program that exports `handle` and `buf` -- names fs's declarations
# use -- must build and run; this used to stop inside backends/fs with
# "'handle' is an exported global".
printf 'setup() {\n  export int handle = 1;\n  export int[] buf = [];\n} return void;\n\nmain(int argc, string[] argv) {\n  setup();\n  int ok = fs_exists("nope");\n  print(ok);\n} return int 0;\n' > "$chk/main.id"
if $BIN_IDC "$chk" -o "$TMP/chk.bin" >"$TMP/chk.err" 2>&1 && [ "$(cd "$TMP" && ./chk.bin)" = "0" ]; then
    ok "a program may export a name a backend's parameter uses (bin/idc)"
else
    bad "a program may export a name a backend's parameter uses (bin/idc): $(head -1 "$TMP/chk.err" | cut -c1-120)"
fi

# Two natives with one signature are two functions: a native has no logic to
# compare, so its name is part of its fingerprint. `n` is also a string in
# main, which one type per name would reject if a native's parameter counted.
cat > "$TMP/twin.id" <<'EOF'
native twin_a(int n) return int;
native twin_b(int n) return int;
main(int argc, string[] argv) {
  string n = "sum ";
  int r = twin_a(1) + twin_b(2);
  print(n + r);
} return int 0;
EOF
if $BIN_IDC "$TMP/twin.id" --emit-c "$TMP/twin.c" >/dev/null 2>&1 \
   && grep -qx "int id_twin_a(int n);" "$TMP/twin.c" && grep -qx "int id_twin_b(int n);" "$TMP/twin.c"; then
    ok "two natives with the same signature do not collide, and their parameters reserve no name (bin/idc)"
else
    bad "two natives with the same signature do not collide, and their parameters reserve no name (bin/idc)"
fi

# A manifest that offers no C implementation must say so, in both compilers,
# rather than reporting "no support for platform 'linux'" (which would be a
# lie: the platform is fine, the *target* is what is missing).
#
# bin/idc reads a backend's manifest only once one of its natives is reached,
# so its program calls one; idc.py reads every attached manifest up front and
# keeps building hello.
nocbe="$TMP/nocbe"; mkdir -p "$nocbe"
printf '{"name":"toy","abi":[],"targets":{"interp":{"module":"toy.py"}}}\n' > "$nocbe/backend.json"
printf 'native toy_ping() return int;\n' > "$nocbe/toy.id"
printf 'main(int argc, string[] argv) {\n  int r = toy_ping();\n  print(r);\n} return int 0;\n' > "$TMP/toy.id"
for c in "$BIN_IDC" "$ROOT/idc.py"; do
    name=$(basename "${c%% *}")
    prog="$ORG/demos/hello"
    [ "$name" = idc ] && prog="$TMP/toy.id"
    if $c "$prog" --backend "$nocbe" -o "$TMP/nocbe.bin" 2>&1 \
       | grep -q "no implementation for the C target"; then
        ok "a backend with no C target is diagnosed as such ($name)"
    else
        bad "a backend with no C target is diagnosed as such ($name)"
    fi
done

# -- the default output goes to build/ ---------------------------------------
# `idc PROJECT` names the executable after the project, so building from the
# directory beside it used to ask cc to write over a directory ("cannot open
# output file: Is a directory", reported by bin/idc as a bug in the self-hosted
# compiler). Defaulting into build/ makes that collision impossible, and keeps
# built binaries out of the source tree.
outdir="$TMP/outdir"; mkdir -p "$outdir"
cp -r "$ORG/demos/hello" "$outdir/proj"
for c in "$ABS_ROOT/bin/idc --allow-untested" "$ABS_ROOT/idc.py"; do
    name=$(basename "${c%% *}")
    out=$(cd "$outdir" && $c proj 2>&1)
    if [ -x "$outdir/build/proj" ] && [ ! -e "$outdir/proj.out" ]; then
        ok "a default build lands in build/ ($name)"
    else
        bad "a default build lands in build/ ($name): $out"
    fi
    rm -rf "$outdir/build"
    # An explicit -o is the user's choice and is reported, not second-guessed.
    if (cd "$outdir" && $c proj -o proj 2>&1) | grep -q "is a directory"; then
        ok "-o naming a directory is reported ($name)"
    else
        bad "-o naming a directory is reported ($name)"
    fi
done

# -- a backend is linked only when one of its natives is reached -------------
# Attaching a backend used to mean compiling its sources and linking its flags
# into every build, so a standard library that named gfx made hello-world link
# X11. Now the compiler lists the natives reachable from main (and, for the
# harness, from the cases), and only the backends declaring one of them are
# compiled or linked. None of this needs X11: an unreached backend is never
# compiled, which is what is being checked. cclog records every cc invocation.
be_abs() { (cd "$ROOT/backends/$1" && pwd); }
cclog="$TMP/cclog"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec cc "$@"\n' "$TMP/cc.log" > "$cclog"
chmod +x "$cclog"
needs_lib() { readelf -d "$1" 2>/dev/null | grep -q "NEEDED.*$2"; }

c7none="$TMP/c7none"; mkdir -p "$c7none"
printf 'import "%s"\nimport "%s"\nimport "%s"\n' "$(be_abs gfx)" "$(be_abs gl)" "$(be_abs fs)" > "$c7none/conf.id"
printf 'main(int argc, string[] argv) {\n  print(7);\n} return int 0;\n' > "$c7none/main.id"
: > "$TMP/cc.log"
if $BIN_IDC "$c7none" --cc "$cclog" -o "$TMP/c7none.bin" >"$TMP/c7none.err" 2>&1 \
   && [ "$("$TMP/c7none.bin")" = "7" ] \
   && ! grep -qE 'gfx_linux|gl_linux|fs_posix|-lX11|-lGL' "$TMP/cc.log" \
   && ! needs_lib "$TMP/c7none.bin" libX11 && ! needs_lib "$TMP/c7none.bin" libGL; then
    ok "three attached backends that nothing calls are neither compiled nor linked"
else
    bad "three attached backends that nothing calls are neither compiled nor linked: $(grep -m1 -E 'gfx_linux|gl_linux|fs_posix|-lX11' "$TMP/cc.log" | cut -c1-120)$(head -1 "$TMP/c7none.err")"
fi

# The same through a standard library whose conf.id names every backend --
# the arrangement this exists for.
c7std="$TMP/c7std"; mkdir -p "$c7std/win" "$TMP/c7hello" "$TMP/c7win"
cp "$c7none/conf.id" "$c7std/conf.id"
printf 'c7_width() {\n  int cw = gfx_width();\n} return int cw;\n' > "$c7std/win/w.id"
printf 'main(int argc, string[] argv) {\n  print("hi");\n} return int 0;\n' > "$TMP/c7hello/main.id"
: > "$TMP/cc.log"
if env -u IDC_NO_STD $BIN_IDC "$TMP/c7hello" --std "$c7std" --cc "$cclog" -o "$TMP/c7hello.bin" >"$TMP/c7hello.err" 2>&1 \
   && [ "$("$TMP/c7hello.bin")" = "hi" ] \
   && ! grep -qE 'gfx_linux|gl_linux|fs_posix|-lX11|-lGL' "$TMP/cc.log" \
   && ! needs_lib "$TMP/c7hello.bin" libX11; then
    ok "a standard library naming gfx, gl and fs costs hello-world no link line"
else
    bad "a standard library naming gfx, gl and fs costs hello-world no link line: $(grep -m1 -E 'gfx_linux|gl_linux|-lX11' "$TMP/cc.log" | cut -c1-120)$(head -1 "$TMP/c7hello.err")"
fi

# A reached native no attached backend implements is a diagnostic at the call
# that reaches it, never a linker error about id_twin_a.
out=$($BIN_IDC "$TMP/twin.id" -o "$TMP/twin.bin" 2>&1)
if printf '%s\n' "$out" | grep -qF "twin.id:5: error: native 'twin_a', reached from main by this call, has no implementation for platform" \
   && ! printf '%s\n' "$out" | grep -q "undefined reference"; then
    ok "a reached native in no backend is diagnosed at its call, not by the linker"
else
    bad "a reached native in no backend is diagnosed at its call, not by the linker: $(printf '%s\n' "$out" | head -2 | tr '\n' ' ' | cut -c1-160)"
fi

# A platform a reached backend does not support names the native, the call and
# the triple. The same backend attached but unreached is not asked at all, so
# the build goes on to the next question -- here, that cc cannot target darwin.
c7gl="$TMP/c7gl"; mkdir -p "$c7gl"
printf 'import "%s"\n' "$(be_abs gl)" > "$c7gl/conf.id"
printf 'main(int argc, string[] argv) {\n  int gw = gl_width();\n  print(gw);\n} return int 0;\n' > "$c7gl/main.id"
out=$($BIN_IDC "$c7gl" --triple aarch64-apple-darwin -o "$TMP/c7gl.bin" 2>&1)
if printf '%s\n' "$out" | grep -qF "c7gl/main.id:2: error: native 'gl_width', reached from main by this call, is implemented by backend 'gl', which has no support for platform 'darwin' (building for 'aarch64-apple-darwin'); it is implemented for: linux"; then
    ok "an unsupported platform names the reached native, its call and the triple"
else
    bad "an unsupported platform names the reached native, its call and the triple: $(printf '%s\n' "$out" | head -2 | tr '\n' ' ' | cut -c1-200)"
fi
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$c7gl/main.id"
out=$($BIN_IDC "$c7gl" --triple aarch64-apple-darwin -o "$TMP/c7gl.bin" 2>&1)
if printf '%s\n' "$out" | grep -q "cannot build for 'aarch64-apple-darwin' here" \
   && ! printf '%s\n' "$out" | grep -q "has no support for platform"; then
    ok "an unreached backend's platforms are not a question the build asks"
else
    bad "an unreached backend's platforms are not a question the build asks: $(printf '%s\n' "$out" | head -1 | cut -c1-160)"
fi

if ! cc -fsyntax-only "$ROOT/backends/gfx/gfx_linux.c" -I"$ROOT/backends/gfx" 2>/dev/null; then
    # Only the windowed half of this file needs them; the fs and output-path
    # checks above ran and their tally still counts.
    skip "gfx/gl checks: no X11 headers (run under tools/devshell.sh)"
    echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]; exit
fi

# -- the backends a build links are the ones its natives reach ---------------
# Through the library above: calling the one function that reaches gfx links
# gfx, and gl -- attached by the same conf.id -- stays out.
printf 'main(int argc, string[] argv) {\n  int cw = c7_width();\n  print(cw);\n} return int 0;\n' > "$TMP/c7win/main.id"
: > "$TMP/cc.log"
if env -u IDC_NO_STD $BIN_IDC "$TMP/c7win" --std "$c7std" --cc "$cclog" -o "$TMP/c7win.bin" >"$TMP/c7win.err" 2>&1 \
   && grep -q 'gfx_linux\.c' "$TMP/cc.log" && ! grep -qE 'gl_linux|fs_posix|-lGL' "$TMP/cc.log" \
   && needs_lib "$TMP/c7win.bin" libX11 && ! needs_lib "$TMP/c7win.bin" libGL; then
    ok "a program reaching a gfx native through the library links gfx and nothing else"
else
    bad "a program reaching a gfx native through the library links gfx and nothing else: $(grep -m1 -E 'gl_linux|fs_posix|-lGL' "$TMP/cc.log" | cut -c1-120)$(head -1 "$TMP/c7win.err")"
fi

# The harness links what the cases reach, not what main does: probe's cases
# reach fs, main reaches fs and gfx.
c7h="$TMP/c7harn"; mkdir -p "$c7h"
printf 'import "%s"\nimport "%s"\n' "$(be_abs fs)" "$(be_abs gfx)" > "$c7h/conf.id"
cat > "$c7h/main.id" <<'EOF'
main(int argc, string[] argv) {
  int w = gfx_width();
  int p = probe("/nonexistent-c7");
  print(p + w);
} return int 0;

probe(string path) {
  int found = fs_exists(path);
} return int found;
("/nonexistent-c7-a"):(0)
("/nonexistent-c7-b"):(0)
EOF
: > "$TMP/cc.log"
if $BIN_IDC "$c7h" --cc "$cclog" -o "$TMP/c7harn.bin" >"$TMP/c7harn.err" 2>&1 \
   && grep 'harness\.c' "$TMP/cc.log" | grep -q 'fs_posix\.gen\.o' \
   && ! grep 'harness\.c' "$TMP/cc.log" | grep -qE 'gfx_linux|-lX11' \
   && grep 'final\.c' "$TMP/cc.log" | grep 'fs_posix\.gen\.o' | grep 'gfx_linux\.gen\.o' | grep -q -- '-lX11'; then
    ok "the test harness links the backends its cases reach, the program those main reaches"
else
    bad "the test harness links the backends its cases reach, the program those main reaches: $(grep 'harness\.c' "$TMP/cc.log" | cut -c1-160)$(head -1 "$TMP/c7harn.err")"
fi

# -- the backends themselves compile ----------------------------------------
for be in gfx/gfx_linux gl/gl_linux; do
    if cc -O2 -c "$ROOT/backends/$be.c" -I"$ROOT/backends/$(dirname "$be")" \
         -o "$TMP/$(basename "$be").o" 2>"$TMP/cc.err"; then
        ok "backends/$be.c compiles"
    else
        bad "backends/$be.c compiles ($(head -1 "$TMP/cc.err"))"
    fi
done

# -- both backends in one binary --------------------------------------------
# They both used to define id_gfx_open/poll/close, so linking them together was
# a hard "multiple definition" error and an engine could have a software window
# or a GPU window but never both. The GL backend's three window entry points
# are now glwin_*, and this is the proof.
dual="$TMP/dual"
mkdir -p "$dual/loop"
printf 'import "%s"\nimport "%s"\n' \
    "$(cd "$ROOT/backends/gfx" && pwd)" "$(cd "$ROOT/backends/gl" && pwd)" > "$dual/conf.id"
cat > "$dual/main.id" <<'EOF'
main(int argc, string[] argv) {
  int sw = gfx_open(64, 48, "dual soft");
  int hw = glwin_open(64, 48, "dual gpu");
  boot(sw, hw);
} return int 0;

boot(int sw, int hw) {
  export int[] fb = [];
  fill(64 * 48);
  spin(0);
} return void;

fill(int n) {
  int i = 0;
  while(i < n) {
    push((import fb), 3355443);
    i = i + 1;
  }
} return void;
EOF
cat > "$dual/loop/loop.id" <<'EOF'
spin(int t) {
  while(t < 2) {
    t = one(t);
  }
} return void;

one(int t) {
  render();
  int next = t + 1;
} return int next;

finish() {
  gl_end_frame();
  string msg = "soft " + gfx_width() + " gpu " + gl_width();
  print(msg);
} return void;
EOF
cat > "$dual/loop/more.id" <<'EOF'
render() {
  gfx_present((import fb));
  gl_begin_frame(200, 30, 30);
  finish();
} return void;
EOF
if $BIN_IDC "$dual" -o "$TMP/dual.bin" >"$TMP/dual.err" 2>&1; then
    ok "both backends link into one binary"
else
    bad "both backends link into one binary ($(grep -m1 -i 'error\|multiple' "$TMP/dual.err" | cut -c1-90))"
fi

# -- the graphics demos still build with bin/idc -----------------------------
# Their C is no longer compared with idc.py's. bin/idc reads each backend's
# `native` declarations and emits them as real prototypes; idc.py, which is
# being retired and will not change, emits an unprototyped `extern int` block
# for the same calls, so the two differ by design.
#
# idc.py no longer builds them here either. They are user programs and merge
# idstd, and idc.py cannot parse an idstd that holds a `given` case, so a check
# that idc.py builds them would fail on the library rather than on the demo.
for spec in gfxdemo:gfx gl3d:gl gl3dgame:gl fpsmaze:gl galaxy:gl flyover:gl; do
    d="${spec%%:*}"; be="$ROOT/backends/${spec##*:}"
    if env -u IDC_NO_STD $BIN_IDC "$ORG/demos/$d" --backend "$be" --emit-c "$TMP/self.c" >/dev/null 2>&1; then
        ok "$d: backend build (bin/idc)"
    else
        bad "$d: backend build (bin/idc)"
    fi
done

# -- no windowed demo may hang when there is no display ----------------------
# Every one of them used to: `int ok = gfx_open(...)` was assigned and then
# ignored, and with no display gfx_poll returns -1 forever. Running with
# DISPLAY unset is the test, and it needs no display by construction.
for spec in gfxdemo:gfx gl3d:gl gl3dgame:gl fpsmaze:gl galaxy:gl flyover:gl; do
    d="${spec%%:*}"; be="$ROOT/backends/${spec##*:}"
    if ! env -u IDC_NO_STD $BIN_IDC "$ORG/demos/$d" --backend "$be" -o "$TMP/$d.bin" >/dev/null 2>&1; then
        bad "$d: builds for the no-display check"; continue
    fi
    DISPLAY= timeout 5 "$TMP/$d.bin" >/dev/null 2>&1
    if [ $? -eq 124 ]; then
        bad "$d: hangs with no display (gfx_open's result is being ignored)"
    else
        ok "$d: exits rather than hanging with no display"
    fi
done

# -- the parts that need a window -------------------------------------------
#
# These run under tools/headless.sh (a private Xvfb) rather than on whatever
# display the developer is using. On a tiling compositor a new window steals
# focus, warps the pointer and drops whatever was fullscreen -- correct for an
# application, hostile for a test that runs on every commit. The window is
# real, the GLX context is real, the frames are real; the compositor just
# never learns it exists.
#
# It also means these checks no longer need a session at all, so the `no
# DISPLAY` skip below now only fires when Xvfb itself is missing.
HEADLESS=../tools/headless.sh
if ! command -v Xvfb >/dev/null 2>&1; then
    skip "windowed checks (no Xvfb -- run via tools/devshell.sh)"
else
    for spec in gfxdemo:gfx gl3d:gl; do
        d="${spec%%:*}"
        if GFX_MAX_FRAMES=3 timeout 30 $HEADLESS "$TMP/$d.bin" >/dev/null 2>&1; then
            ok "$d: renders 3 frames and exits 0"
        else
            bad "$d: renders 3 frames and exits 0"
        fi
    done

    # GPU readback: render a known clear colour and read it back from `id`.
    # Until gl_read_pixels existed there was no way to check GPU output
    # without an external window grabber.
    shot="$TMP/glshot"; mkdir -p "$shot/px"
    printf 'import "%s"\n' "$(cd "$ROOT/backends/gl" && pwd)" > "$shot/conf.id"
    cat > "$shot/main.id" <<'EOF'
main(int argc, string[] argv) {
  int ok = glwin_open(32, 24, "glshot");
  export int[] px = [];
  boot();
} return int 0;

boot() {
  fill(32 * 24);
  frame();
} return void;

fill(int n) {
  int i = 0;
  while(i < n) {
    push((import px), 0);
    i = i + 1;
  }
} return void;
EOF
    cat > "$shot/px/p.id" <<'EOF'
frame() {
  gl_begin_frame(255, 0, 128);
  int n = gl_read_pixels((import px));
  done(n);
} return void;

done(int n) {
  gl_end_frame();
  print("" + n + " " + (import px)[0]);
} return void;
EOF
    if $BIN_IDC "$shot" -o "$TMP/glshot.bin" >/dev/null 2>&1; then
        out=$(GFX_MAX_FRAMES=2 timeout 30 $HEADLESS "$TMP/glshot.bin" 2>/dev/null)
        # 32*24 = 768 pixels, each 0xFF0080 = 16711808. The channel values are
        # chosen to be exact in any framebuffer format: a small green like 40
        # came back as 38 on this machine's GLX visual, which is a precision
        # property of the drawable, not a readback bug.
        if [ "$out" = "768 16711808" ]; then
            ok "gl_read_pixels returns the rendered frame to id"
        else
            bad "gl_read_pixels returns the rendered frame to id (got '$out')"
        fi
    else
        bad "gl_read_pixels test builds"
    fi
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
