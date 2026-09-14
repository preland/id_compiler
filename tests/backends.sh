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
# The native backends live in the standard library, inside the modules that
# wrap them, so the checks of the real ones find it the way the compilers do.
STD="${IDSTD_HOME:-}"
if [ -z "$STD" ]; then
    for up in "$ABS_ROOT/../idstd" "$ABS_ROOT/../../idstd"; do
        [ -d "$up" ] && { STD="$up"; break; }
    done
fi
if [ -n "$STD" ] && [ -d "$STD" ]; then STD=$(cd "$STD" && pwd -P); else STD=""; fi
if [ -z "$STD" ]; then
    echo "SKIP: backends.sh (the backends are idstd's, and no idstd was found; set IDSTD_HOME)"
    exit 0
fi
# be_abs NAME -- the directory of one of idstd's backends.
be_abs() {
    case "$1" in
        fs)     printf '%s' "$STD/sys/io/fs" ;;
        proc|sock) printf '%s' "$STD/sys/io/ipc/$1" ;;
        gfx|gl) printf '%s' "$STD/sys/win/$1" ;;
    esac
}
# bin/idc takes --allow-untested throughout: none of the programs built here has
# test cases, and what is under test is the backends.
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
if cc -O2 -c "$(be_abs fs)/fs_posix.c" -I"$(be_abs fs)" -o "$TMP/fs.o" 2>"$TMP/fs.err"; then
    ok "sys/io/fs/fs_posix.c compiles"
else
    bad "sys/io/fs/fs_posix.c compiles ($(head -1 "$TMP/fs.err"))"
fi

# The demo names no backend: fs is the standard library's, so the demo is built
# the way a user builds it, with idstd and no --backend flag or conf.id line.
#
# idc.py no longer builds a backend here, nor in the two checks after this one.
# It reads backend.json, which backend.id replaced, and idc.py is frozen
# and will not change: it cannot parse the standard library, and it counts a
# backend.id toward the 3-entries rule, which bin/idc exempts it from.
expected='wrote 44 bytes to fsdemo.txt (close 0)
read 44 bytes back (close 0):
the quick brown fox
jumps over
the lazy dog

removed fsdemo.txt (rc 0), exists now 0
reopening it gives -1, errno 2'
for c in "$BIN_IDC"; do
    name=$(basename "${c%% *}")
    if ! env -u IDC_NO_STD $c "$ORG/demos/fsdemo" -o "$fsout.$name" >"$TMP/fs.build" 2>&1; then
        bad "fsdemo builds with $name"; continue
    fi
    got=$(cd "$TMP" && "$fsout.$name" 2>&1)
    if [ "$got" = "$expected" ]; then
        ok "fsdemo writes, reads back and removes a file ($name)"
    else
        bad "fsdemo writes, reads back and removes a file ($name): got '$got'"
    fi
done

# Reaching one backend twice -- found in the library *and* named by --backend
# -- used to compile its sources twice and hand cc the same object file twice:
# "multiple definition" for every symbol it exports.
for c in "$BIN_IDC"; do
    name=$(basename "${c%% *}")
    if env -u IDC_NO_STD $c "$ORG/demos/fsdemo" --backend "$(be_abs fs)" -o "$fsout.dup.$name" \
         >"$TMP/fs.dup" 2>&1; then
        ok "a backend found in the library and named by --backend links once ($name)"
    else
        bad "a backend found in the library and named by --backend links once ($name): $(grep -m1 -i 'multiple definition\|error' "$TMP/fs.dup" | cut -c1-90)"
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
for c in "$BIN_IDC"; do
    name=$(basename "${c%% *}")
    if ! env -u IDC_NO_STD $c "$ROOT/tests/fixtures/lsdemo" -o "$fsout.ls.$name" >"$TMP/ls.build" 2>&1; then
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
if env -u IDC_NO_STD $BIN_IDC "$ROOT/driver" -o "$TMP/idsrc" >"$TMP/drv.build" 2>&1; then
    ok "driver/ builds"
    for tree in "$ROOT/compiler" "$ORG/editor"; do
        want=$(find "$tree" -mindepth 1 \( -type d -name '.*' -prune \) -o \
                    \( -name '*.id' ! -name 'conf.id' ! -name 'backend.id' -print \) | LC_ALL=C sort)
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
# backend's `native` declarations as prototypes, and idc.py, which is frozen
# (docs/HACKING.md) and will not change, emits `extern int` for the same
# calls. What both must agree on is the behaviour checked above.

# -- proc: a child process id can start, read from, wait for and kill ------
# Deliberately above the X11 gate below, like fs: this is fork/pipe/waitpid,
# so it needs nothing but a shell. This is the seam tools/qmon is written
# against (idstd's sys/io/ipc/proc/README.md).
procdir="$TMP/proc"; mkdir -p "$procdir/out"
printf 'import "%s"\n' "$(be_abs proc)" > "$procdir/conf.id"
cat > "$procdir/main.id" <<'EOF'
main(int argc, string[] argv) {
  int h = proc_spawn("sh\n-c\necho hi");
  int[] buf = mkbuf(64);
  run_echo(h, buf);
} return int 0;

run_echo(int h, int[] buf) {
  int got = proc_read(h, buf, 64, 2000);
  show(buf, got);
  finish(h);
} return void;
EOF
cat > "$procdir/out/buf.id" <<'EOF'
mkbuf(int n) {
  int[] out = [];
  fill(out, n);
} return int[] out;

fill(int[] out, int n) {
  int i = 0;
  while(i < n) {
    push(out, 0);
    i = i + 1;
  }
} return void;
EOF
cat > "$procdir/out/show.id" <<'EOF'
show(int[] buf, int n) {
  string s = tostr(buf, n);
  print(s);
} return void;

tostr(int[] buf, int n) {
  string s = "";
  int i = 0;
  while(i < n) {
    s = s + chr(buf[i]);
    i = i + 1;
  }
} return string s;
EOF
cat > "$procdir/out/finish.id" <<'EOF'
finish(int h) {
  int rc = proc_wait(h, 2000);
  print(rc);
  proc_close(h);
} return void;
EOF
procexp='hi

0'
if $BIN_IDC "$procdir" -o "$TMP/proc.bin" >"$TMP/proc.build" 2>&1; then
    got=$(timeout 10 "$TMP/proc.bin" 2>&1)
    if [ "$got" = "$procexp" ]; then
        ok "proc_spawn starts a child and proc_read reads its stdout back"
    else
        bad "proc_spawn starts a child and proc_read reads its stdout back: got '$got'"
    fi
else
    bad "proc backend demo builds ($(head -1 "$TMP/proc.build"))"
fi

# proc_kill: a still-running child times proc_wait out (-1, ETIMEDOUT is
# errno 110 on Linux), kill succeeds, and the second proc_wait reports it
# killed by SIGKILL (128 + 9 = 137) rather than hanging until the sleep itself
# would have finished.
killdir="$TMP/prockill"; mkdir -p "$killdir"
printf 'import "%s"\n' "$(be_abs proc)" > "$killdir/conf.id"
cat > "$killdir/main.id" <<'EOF'
main(int argc, string[] argv) {
  int h = proc_spawn("sleep\n5");
  run(h);
} return int 0;

run(int h) {
  int before = proc_wait(h, 100);
  mid(h, before);
} return void;
EOF
cat > "$killdir/ctrl.id" <<'EOF'
mid(int h, int before) {
  int k = proc_kill(h);
  after(h, before, k);
} return void;

after(int h, int before, int k) {
  int rc = proc_wait(h, 2000);
  string s = "" + before + " " + k + " " + rc;
  print(s);
} return void;
EOF
if $BIN_IDC "$killdir" -o "$TMP/prockill.bin" >"$TMP/prockill.build" 2>&1; then
    got=$(timeout 10 "$TMP/prockill.bin" 2>&1)
    if [ "$got" = "-1 0 137" ]; then
        ok "proc_kill ends a running child, and proc_wait reports it killed"
    else
        bad "proc_kill ends a running child, and proc_wait reports it killed: got '$got'"
    fi
else
    bad "proc kill demo builds ($(head -1 "$TMP/prockill.build"))"
fi

# -- sock: a Unix-domain socket id can connect to, and talk over -----------
# Served by socat when the dev shell has it, a small C helper otherwise --
# either way, one accept, one echo, one exit. sock_connect's retry loop is
# exercised for real: the id binary starts trying to connect before the
# server is necessarily listening yet.
sockpath="$TMP/echo.sock"
sockdir="$TMP/sock"; mkdir -p "$sockdir/out"
printf 'import "%s"\n' "$(be_abs sock)" > "$sockdir/conf.id"
cat > "$sockdir/main.id" <<EOF
main(int argc, string[] argv) {
  int h = sock_connect("$sockpath", 3000);
  go(h);
} return int 0;

go(int h) {
  int[] out = mkmsg();
  int n = len(out);
  sendit(h, out, n);
} return void;

sendit(int h, int[] out, int n) {
  int sent = sock_send(h, out, n);
  print(sent);
  recvit(h);
} return void;
EOF
cat > "$sockdir/out/msg.id" <<'EOF'
mkmsg() {
  int[] out = [];
  fill(out);
} return int[] out;

fill(int[] out) {
  push(out, 104);
  push(out, 105);
} return void;
EOF
cat > "$sockdir/out/recv.id" <<'EOF'
recvit(int h) {
  int[] buf = mkbuf(64);
  show(h, buf);
} return void;

mkbuf(int n) {
  int[] out = [];
  filln(out, n);
} return int[] out;

filln(int[] out, int n) {
  int i = 0;
  while(i < n) {
    push(out, 0);
    i = i + 1;
  }
} return void;
EOF
cat > "$sockdir/out/show.id" <<'EOF'
show(int h, int[] buf) {
  int got = sock_recv(h, buf, 64, 2000);
  tell(buf, got);
} return void;

tell(int[] buf, int n) {
  string s = tostr(buf, n);
  print(s);
} return void;

tostr(int[] buf, int n) {
  string s = "";
  int i = 0;
  while(i < n) {
    s = s + chr(buf[i]);
    i = i + 1;
  }
} return string s;
EOF
sock_via=""
if command -v socat >/dev/null 2>&1; then
    rm -f "$sockpath"
    (socat -T3 UNIX-LISTEN:"$sockpath",fork EXEC:cat >/dev/null 2>&1 &)
    sock_via="socat"
else
    cat > "$TMP/sockecho.c" <<'EOF'
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
int main(int argc, char** argv) {
    struct sockaddr_un addr;
    int s, c, n;
    char buf[256];
    if (argc < 2) return 1;
    unlink(argv[1]);
    s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return 1;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, argv[1], sizeof(addr.sun_path) - 1);
    if (bind(s, (struct sockaddr*)&addr, sizeof addr) != 0) return 1;
    if (listen(s, 1) != 0) return 1;
    c = accept(s, 0, 0);
    if (c < 0) return 1;
    n = (int)read(c, buf, sizeof buf);
    if (n > 0) write(c, buf, (size_t)n);
    close(c); close(s); unlink(argv[1]);
    return 0;
}
EOF
    if cc -O2 "$TMP/sockecho.c" -o "$TMP/sockecho" 2>"$TMP/sockecho.err"; then
        rm -f "$sockpath"
        "$TMP/sockecho" "$sockpath" &
        sock_via="a C helper"
    else
        skip "sock: connect/send/recv over a Unix socket (no socat, and the C helper failed to compile: $(head -1 "$TMP/sockecho.err"))"
    fi
fi
if [ -n "$sock_via" ]; then
    if $BIN_IDC "$sockdir" -o "$TMP/sock.bin" >"$TMP/sock.build" 2>&1; then
        got=$(timeout 10 "$TMP/sock.bin" 2>&1)
        want='2
hi'
        if [ "$got" = "$want" ]; then
            ok "sock_connect, sock_send and sock_recv talk to a Unix socket ($sock_via)"
        else
            bad "sock_connect, sock_send and sock_recv talk to a Unix socket ($sock_via): got '$got'"
        fi
    else
        bad "sock backend demo builds ($sock_via, $(head -1 "$TMP/sock.build"))"
    fi
fi
wait 2>/dev/null

# A call into a backend is checked like any other call. A typo used to pass
# the compiler and fail at the C linker, and a wrong argument count compiled
# and dumped core when run; both are now the diagnostics an `id` function gets.
chk="$TMP/chk"; mkdir -p "$chk"
printf 'import "%s"\n' "$(be_abs fs)" > "$chk/conf.id"
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

# Declarations that offer no C implementation must say so rather than
# reporting "no support for platform 'linux'" (which would be a lie: the
# platform is fine, the *target* is what is missing).
#
# bin/idc reads a backend's declarations only once one of its natives is
# reached, so the program calls one. idc.py was checked here too, and is not
# now: it reads backend.json, which no longer exists.
nocbe="$TMP/nocbe"; mkdir -p "$nocbe"
printf 'string name = "toy";\nstring interp_module = "toy.py";\n' > "$nocbe/backend.id"
printf 'native toy_ping() return int;\n' > "$nocbe/toy.id"
printf 'main(int argc, string[] argv) {\n  int r = toy_ping();\n  print(r);\n} return int 0;\n' > "$TMP/toy.id"
if $BIN_IDC "$TMP/toy.id" --backend "$nocbe" -o "$TMP/nocbe.bin" 2>&1 \
   | grep -qF "toy.id:2: error: native 'toy_ping', reached from main by this call, is implemented by backend 'toy', which has no implementation for the C target (its manifest declares: interp)"; then
    ok "a backend with no C target is diagnosed as such (idc)"
else
    bad "a backend with no C target is diagnosed as such (idc)"
fi

# -- the default output goes to build/ ---------------------------------------
# `idc PROJECT` names the executable after the project, so building from the
# directory beside it used to ask cc to write over a directory ("cannot open
# output file: Is a directory", reported by bin/idc as a bug in the self-hosted
# compiler). Defaulting into build/ makes that collision impossible, and keeps
# built binaries out of the source tree.
outdir="$TMP/outdir"; mkdir -p "$outdir"
cp -r "$ORG/demos/hello" "$outdir/proj"
c="$ABS_ROOT/bin/idc --allow-untested"
out=$(cd "$outdir" && $c proj 2>&1)
if [ -x "$outdir/build/proj" ] && [ ! -e "$outdir/proj.out" ]; then
    ok "a default build lands in build/"
else
    bad "a default build lands in build/: $out"
fi
rm -rf "$outdir/build"
# An explicit -o is the user's choice and is reported, not second-guessed.
if (cd "$outdir" && $c proj -o proj 2>&1) | grep -q "is a directory"; then
    ok "-o naming a directory is reported"
else
    bad "-o naming a directory is reported"
fi

# -- a backend is linked only when one of its natives is reached -------------
# Attaching a backend used to mean compiling its sources and linking its flags
# into every build, so a standard library that named gfx made hello-world link
# X11. Now the compiler lists the natives reachable from main (and, for the
# harness, from the cases), and only the backends declaring one of them are
# compiled or linked. None of this needs X11: an unreached backend is never
# compiled, which is what is being checked. cclog records every cc invocation.
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

# The same through a library whose conf.id imports every backend.
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

# -- a backend is attached by its backend.id, wherever a collected tree has it -
# A standard library carries its backends inside the modules that wrap them and
# names none of them in a conf.id: collecting a tree finds every backend.id in
# it. dstd is such a library -- io/tick is a backend, io/now.id library code
# calling its native. A program that never reaches tick_now compiles and links
# nothing of it; one that does gets the sources for its triple's platform.
dstd="$TMP/dstd"; mkdir -p "$dstd/io/tick" "$TMP/dhello" "$TMP/dcall"
printf 'string name = "tick";\nstring[] c_linux_sources = ["lin.c"];\nstring[] c_darwin_sources = ["mac.c"];\n' > "$dstd/io/tick/backend.id"
printf 'int id_tick_now(void) { return 41; }\n' > "$dstd/io/tick/lin.c"
printf 'int id_tick_now(void) { return 42; }\n' > "$dstd/io/tick/mac.c"
printf 'native tick_now() return int;\n' > "$dstd/io/tick/tick.id"
printf 'dstd_now() {\n  int t = tick_now();\n} return int t;\n' > "$dstd/io/now.id"
dstd=$(cd "$dstd" && pwd -P)
printf 'main(int argc, string[] argv) {\n  print("hi");\n} return int 0;\n' > "$TMP/dhello/main.id"
printf 'main(int argc, string[] argv) {\n  int t = dstd_now();\n  print(t);\n} return int 0;\n' > "$TMP/dcall/main.id"
: > "$TMP/cc.log"
if env -u IDC_NO_STD $BIN_IDC "$TMP/dhello" --std "$dstd" --cc "$cclog" -o "$TMP/dhello.bin" >"$TMP/dhello.err" 2>&1 \
   && [ "$("$TMP/dhello.bin")" = "hi" ] && ! grep -qE 'lin\.c|mac\.c' "$TMP/cc.log"; then
    : > "$TMP/cc.log"
    if env -u IDC_NO_STD $BIN_IDC "$TMP/dcall" --std "$dstd" --cc "$cclog" -o "$TMP/dcall.bin" >"$TMP/dcall.err" 2>&1 \
       && [ "$("$TMP/dcall.bin")" = "41" ] && grep -q 'io/tick/lin\.c' "$TMP/cc.log" && ! grep -q 'mac\.c' "$TMP/cc.log"; then
        ok "a backend.id inside a library attaches its backend with no conf.id, linked only where its native is reached"
    else
        bad "a backend.id inside a library attaches its backend with no conf.id, linked only where its native is reached: $(grep -v warning "$TMP/dcall.err" | head -1 | cut -c1-200)"
    fi
else
    bad "a backend.id inside a library attaches its backend with no conf.id, linked only where its native is reached: hello $(grep -v warning "$TMP/dhello.err" | head -1 | cut -c1-160)"
fi

# The platform key the triple names picks the sources: mac.c for darwin. --cc
# says the compiler is the user's, so the build goes ahead on this machine.
: > "$TMP/cc.log"
if env -u IDC_NO_STD $BIN_IDC "$TMP/dcall" --std "$dstd" --triple x86_64-apple-darwin --cc "$cclog" -o "$TMP/dmac.bin" >"$TMP/dmac.err" 2>&1 \
   && grep -q 'io/tick/mac\.c' "$TMP/cc.log" && ! grep -q 'lin\.c' "$TMP/cc.log" && [ "$("$TMP/dmac.bin")" = "42" ]; then
    ok "the triple's platform picks which sources of a library's backend are compiled"
else
    bad "the triple's platform picks which sources of a library's backend are compiled: $(grep -v warning "$TMP/dmac.err" | head -1 | cut -c1-200)"
fi

# A platform the backend has no sources for stops the build at the call that
# reaches the native -- here inside the library -- in the wording it has always
# had.
out=$(env -u IDC_NO_STD $BIN_IDC "$TMP/dcall" --std "$dstd" --triple x86_64-unknown-freebsd -o "$TMP/dbsd.bin" 2>&1)
if printf '%s\n' "$out" | grep -qxF "$dstd/io/now.id:2: error: native 'tick_now', reached from main by this call, is implemented by backend 'tick', which has no support for platform 'freebsd' (building for 'x86_64-unknown-freebsd'); it is implemented for: darwin, linux"; then
    ok "a library backend with no sources for the platform is diagnosed at the reaching call"
else
    bad "a library backend with no sources for the platform is diagnosed at the reaching call: $(printf '%s\n' "$out" | grep -v warning | head -1 | cut -c1-200)"
fi

# --backend is the override, not the way in. A directory holding only a
# backend.id and its sources, whose name is that of an attached backend,
# replaces how that backend is linked for this build; the declarations the
# calls were checked against stay where they are. Two such directories for one
# backend is a choice the build cannot make for you.
tickp="$TMP/tickp"; cp -r "$dstd/io/tick" "$tickp"
alt="$TMP/tickalt"; mkdir -p "$alt" "$TMP/tickalt2" "$TMP/ovr"
printf 'string name = "tick";\nstring[] c_linux_sources = ["alt.c"];\nstring[] c_darwin_sources = ["alt.c"];\n' > "$alt/backend.id"
printf 'int id_tick_now(void) { return 7; }\n' > "$alt/alt.c"
cp "$alt/backend.id" "$alt/alt.c" "$TMP/tickalt2/"
printf 'import "%s"\n' "$tickp" > "$TMP/ovr/conf.id"
printf 'main(int argc, string[] argv) {\n  int t = tick_now();\n  print(t);\n} return int 0;\n' > "$TMP/ovr/main.id"
: > "$TMP/cc.log"
if $BIN_IDC "$TMP/ovr" --backend "$alt" --cc "$cclog" -o "$TMP/ovr.bin" >"$TMP/ovr.err" 2>&1 \
   && [ "$("$TMP/ovr.bin")" = "7" ] && grep -q 'tickalt/alt\.c' "$TMP/cc.log" && ! grep -q 'tickp/lin\.c' "$TMP/cc.log"; then
    ok "--backend naming an attached backend replaces how that backend is linked"
else
    bad "--backend naming an attached backend replaces how that backend is linked: $(grep -v warning "$TMP/ovr.err" | head -1 | cut -c1-160) got '$("$TMP/ovr.bin" 2>/dev/null)'"
fi
out=$($BIN_IDC "$TMP/ovr" --backend "$alt" --backend "$TMP/tickalt2" -o "$TMP/ovr2.bin" 2>&1)
if printf '%s\n' "$out" | grep -qF "both implement backend 'tick'" && [ ! -e "$TMP/ovr2.bin" ]; then
    ok "two --backend overrides of one backend are refused"
else
    bad "two --backend overrides of one backend are refused: $(printf '%s\n' "$out" | grep -v warning | head -1 | cut -c1-160)"
fi

# The real library: it carries fs, gfx and gl, so a program with no conf.id
# reaches fs_exists and links fs alone, and hello-world links none of them.
# The platform diagnostic is given before the refusal to build another
# triple's test cases here, since the library always has cases and that
# refusal would otherwise be the only thing a cross build ever says.
rs="$TMP/rstd"; mkdir -p "$rs/hello" "$rs/call" "$rs/gl"
printf 'main(int argc, string[] argv) {\n  print("hi");\n} return int 0;\n' > "$rs/hello/main.id"
printf 'main(int argc, string[] argv) {\n  int e = fs_exists("/nonexistent-bkstd");\n  print(e);\n} return int 0;\n' > "$rs/call/main.id"
printf 'main(int argc, string[] argv) {\n  int gw = gl_width();\n  print(gw);\n} return int 0;\n' > "$rs/gl/main.id"
: > "$TMP/cc.log"
if env -u IDC_NO_STD $BIN_IDC "$rs/hello" --std "$STD" --cc "$cclog" -o "$TMP/rhello.bin" >"$TMP/rhello.err" 2>&1 \
   && [ "$("$TMP/rhello.bin")" = "hi" ] && ! grep -qE 'fs_posix|gfx_linux|gl_linux|-lX11|-lGL' "$TMP/cc.log" \
   && ! needs_lib "$TMP/rhello.bin" libX11 && ! needs_lib "$TMP/rhello.bin" libGL; then
    : > "$TMP/cc.log"
    if env -u IDC_NO_STD $BIN_IDC "$rs/call" --std "$STD" --cc "$cclog" -o "$TMP/rcall.bin" >"$TMP/rcall.err" 2>&1 \
       && [ "$("$TMP/rcall.bin")" = "0" ] && grep -q 'sys/io/fs/fs_posix\.c' "$TMP/cc.log" \
       && ! grep -qE 'gfx_linux|gl_linux|-lX11|-lGL' "$TMP/cc.log"; then
        ok "idstd carries fs: a program calling fs_exists links fs alone, and hello-world links no backend"
    else
        bad "idstd carries fs: a program calling fs_exists links fs alone, and hello-world links no backend: $(grep -v warning "$TMP/rcall.err" | head -1 | cut -c1-160)"
    fi
else
    bad "idstd carries fs: a program calling fs_exists links fs alone, and hello-world links no backend: hello $(grep -v warning "$TMP/rhello.err" | head -1 | cut -c1-160)"
fi
out=$(env -u IDC_NO_STD $BIN_IDC "$rs/gl" --std "$STD" --triple aarch64-apple-darwin -o "$TMP/rgl.bin" 2>&1)
if printf '%s\n' "$out" | grep -qF "rstd/gl/main.id:2: error: native 'gl_width', reached from main by this call, is implemented by backend 'gl', which has no support for platform 'darwin' (building for 'aarch64-apple-darwin'); it is implemented for: linux"; then
    ok "idstd's gl reached for darwin names the native, the call and the triple, ahead of the cases"
else
    bad "idstd's gl reached for darwin names the native, the call and the triple, ahead of the cases: $(printf '%s\n' "$out" | grep -v warning | head -1 | cut -c1-200)"
fi

# -- backend.id: a backend's link facts, as `id` declarations ----------------
# They are real `id`: each backend's file, as a project's conf.id, is parsed and
# type-checked by the compiler itself, which is what keeps the driver's line
# reader from accepting something the language does not. --fingerprints stops
# after the checks, before any C: a list constant in conf.id does not yet emit C
# that cc accepts ("initializer element is not constant"), and that is the
# emitter's gap, not these declarations'. The last file proves the check can
# fail.
decl="$TMP/decl"; mkdir -p "$decl"
printf 'main(int argc, string[] argv) {\n  string bn = (import name);\n  print(bn);\n} return int 0;\n' > "$decl/main.id"
for be in fs gfx gl; do
    cp "$(be_abs "$be")/backend.id" "$decl/conf.id"
    if $BIN_IDC "$decl" --fingerprints >"$TMP/decl.out" 2>&1 && ! grep -q 'error' "$TMP/decl.out"; then
        ok "$be's backend.id is valid id constant declarations"
    else
        bad "$be's backend.id is valid id constant declarations: $(grep -m1 error "$TMP/decl.out" | cut -c1-160)"
    fi
done
printf 'string name = "x";\nstring[] c_linux_sources = 3;\n' > "$decl/conf.id"
if ! $BIN_IDC "$decl" --fingerprints >"$TMP/decl.out" 2>&1 \
   && grep -qF "cannot initialize string[] 'c_linux_sources' with a int value" "$TMP/decl.out"; then
    ok "a mistyped declaration fails the same check"
else
    bad "a mistyped declaration fails the same check"
fi

# A line that is not a fact is reported at its line, and only once a native of
# its backend is reached: the same file attached and unreached is not read.
bdbe="$TMP/bdbe"; mkdir -p "$bdbe"
printf 'native bd_ping(int k) return int;\n' > "$bdbe/bd.id"
printf 'main(int argc, string[] argv) {\n  int r = bd_ping(1);\n  print(r);\n} return int 0;\n' > "$TMP/bdcall.id"
while IFS='|' read -r lineno body want; do
    printf '%b' "$body" > "$bdbe/backend.id"
    out=$($BIN_IDC "$TMP/bdcall.id" --backend "$bdbe" -o "$TMP/bd.bin" 2>&1)
    if printf '%s\n' "$out" | grep -qxF "idc: $bdbe/backend.id:$lineno: invalid backend declarations: $want"; then
        ok "invalid backend declarations are reported at line $lineno ($want)"
    else
        bad "invalid backend declarations are reported at line $lineno ($want): $(printf '%s\n' "$out" | grep -v warning | head -1 | cut -c1-160)"
    fi
done <<'EOF'
3|string name = "bd";\n\nstring[] c_linux_sources = "bd.c";\n|'string[] c_linux_sources = "bd.c";' is not a string or string[] constant with a literal value
2|string name = "bd";\nstring c_linux_sources = "bd.c";\n|'c_linux_sources' is a string[], not a string
4|// bd\nstring name = "bd";\nstring[] c_linux_sources = ["bd.c"];\nstring[] c_darwin_link = ["-lm"];\n|'c_darwin_link' has no c_darwin_sources, which is what declares a platform
3|string name = "bd";\nstring[] c_linux_sources = ["bd.c"];\nstring name = "bd2";\n|'name' is already declared at line 1
1|int c_linux_sources = 3;\n|'int c_linux_sources = 3;' is not a string or string[] constant with a literal value
EOF
printf 'main(int argc, string[] argv) {\n  print(2);\n} return int 0;\n' > "$TMP/bdnocall.id"
if [ "$($BIN_IDC "$TMP/bdnocall.id" --backend "$bdbe" -o "$TMP/bdn.bin" 2>/dev/null && "$TMP/bdn.bin")" = "2" ]; then
    ok "an unreached backend's declarations are not read"
else
    bad "an unreached backend's declarations are not read"
fi

# Two attached backends declare the same names -- name, c_linux_sources,
# c_linux_cflags and the rest -- and the same file name, val.c. Each is read on
# its own, so each source is compiled with its own flags and both link: 3 from
# one backend's -DBE_K, 5 from the other's.
for be in bea:3:'[]' beb:5:'["-lm"]'; do
    bn="${be%%:*}"; rest="${be#*:}"; k="${rest%%:*}"; lk="${rest#*:}"
    mkdir -p "$TMP/$bn"
    printf 'string name = "%s";\nstring[] c_linux_sources = ["val.c"];\nstring[] c_linux_cflags = ["-DBE_K=%s"];\nstring[] c_linux_link = %s;\nstring[] c_darwin_sources = ["val.c"];\nstring[] c_darwin_cflags = ["-DBE_K=%s"];\nstring[] c_darwin_link = %s;\n' \
        "$bn" "$k" "$lk" "$k" "$lk" > "$TMP/$bn/backend.id"
    printf 'int id_%s_val(int k) { return k * BE_K; }\n' "$bn" > "$TMP/$bn/val.c"
    printf 'native %s_val(int k) return int;\n' "$bn" > "$TMP/$bn/val.id"
done
two="$TMP/two"; mkdir -p "$two"
printf 'import "%s"\nimport "%s"\n' "$TMP/bea" "$TMP/beb" > "$two/conf.id"
printf 'main(int argc, string[] argv) {\n  int a = bea_val(1);\n  int b = beb_val(10);\n  print(a * 100 + b);\n} return int 0;\n' > "$two/main.id"
: > "$TMP/cc.log"
if $BIN_IDC "$two" --cc "$cclog" -o "$TMP/two.bin" >"$TMP/two.err" 2>&1 \
   && [ "$("$TMP/two.bin")" = "350" ] \
   && grep -q "bea/val\.c .*-DBE_K=3$" "$TMP/cc.log" && grep -q "beb/val\.c .*-DBE_K=5$" "$TMP/cc.log" \
   && grep 'final\.c' "$TMP/cc.log" | grep -q ' -lm$'; then
    ok "two attached backends declaring the same names and platform keys do not collide"
else
    bad "two attached backends declaring the same names and platform keys do not collide: $(grep -v warning "$TMP/two.err" | head -1 | cut -c1-160)"
fi

if ! cc -fsyntax-only "$(be_abs gfx)/gfx_linux.c" -I"$(be_abs gfx)" 2>/dev/null; then
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
    if cc -O2 -c "$(be_abs "${be%%/*}")/${be#*/}.c" -I"$(be_abs "${be%%/*}")" \
         -o "$TMP/$(basename "$be").o" 2>"$TMP/cc.err"; then
        ok "sys/win/$be.c compiles"
    else
        bad "sys/win/$be.c compiles ($(head -1 "$TMP/cc.err"))"
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
    "$(be_abs gfx)" "$(be_abs gl)" > "$dual/conf.id"
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
# frozen and will not change (docs/HACKING.md), emits an unprototyped `extern int` block
# for the same calls, so the two differ by design.
#
# idc.py no longer builds them here either. They are user programs and merge
# idstd, and idc.py cannot parse an idstd that holds a `given` case, so a check
# that idc.py builds them would fail on the library rather than on the demo.
#
# They name no backend: gfx and gl are the standard library's.
for d in gfxdemo gl3d gl3dgame fpsmaze galaxy flyover; do
    if env -u IDC_NO_STD $BIN_IDC "$ORG/demos/$d" --emit-c "$TMP/self.c" >/dev/null 2>&1; then
        ok "$d: backend build (bin/idc)"
    else
        bad "$d: backend build (bin/idc)"
    fi
done

# -- no windowed demo may hang when there is no display ----------------------
# Every one of them used to: `int ok = gfx_open(...)` was assigned and then
# ignored, and with no display gfx_poll returns -1 forever. Running with
# DISPLAY unset is the test, and it needs no display by construction.
for d in gfxdemo gl3d gl3dgame fpsmaze galaxy flyover; do
    if ! env -u IDC_NO_STD $BIN_IDC "$ORG/demos/$d" -o "$TMP/$d.bin" >/dev/null 2>&1; then
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
    printf 'import "%s"\n' "$(be_abs gl)" > "$shot/conf.id"
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
