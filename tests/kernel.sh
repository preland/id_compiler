#!/usr/bin/env bash
# The kernel boots, draws, and answers.
#
# This is the test that makes "no C runtime" a claim rather than an intention:
# the image contains the kernel, the runtime, a boot stub and a linker script,
# and nothing that came from C source. If the runtime written in `id` is wrong
# about strings or arithmetic, there is no libc underneath to be right instead.
#
# Three things are checked, and they are different things:
#
#   * the serial port, which is what the kernel says;
#   * the framebuffer, read back through the kernel's own font by
#     tools/fbtext.py, which is what the kernel drew -- a graphical shell whose
#     only test is its serial output is not a tested graphical shell;
#   * the same `id` source run hosted, on the C runtime, which is what says the
#     `id`-written runtime is *right* rather than merely present.
#
# Run from anywhere: tests/kernel.sh   (needs clang, ld.lld, qemu and python3)
set -u
cd "$(dirname "$0")"
ROOT=..
ORG=../..
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

for tool in clang ld.lld qemu-system-x86_64 python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: kernel tests (need $tool on PATH -- run via 'tools/devshell.sh tests/kernel.sh')"
        exit 0
    fi
done

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ELF="$TMP/kernel.elf"

if ! "$ROOT/tools/kbuild.sh" "$ELF" >"$TMP/build.log" 2>&1; then
    bad "the kernel builds ($(grep -v 'warning:\|cc-wrapper\|un-wrapped' "$TMP/build.log" | head -1))"
    echo; echo "$pass passed, $fail failed"; exit 1
fi
ok "the kernel builds"

# Nothing in the image may have come from a C compiler. The runtime's own
# object is the whole runtime, so a libc symbol here would mean something was
# linked that this repository did not compile from `id`.
if command -v llvm-nm >/dev/null 2>&1; then
    if llvm-nm --undefined-only "$ELF" 2>/dev/null | grep -q .; then
        bad "the kernel has no undefined symbols ($(llvm-nm --undefined-only "$ELF" | head -3 | tr '\n' ' '))"
    else
        ok "the kernel has no undefined symbols"
    fi
fi

# -- boot, then drive the shell over the serial port ------------------------
# The shell reads the keyboard and the serial port through one function, so a
# test types at it the same way a person does.
#
# Two boots, because `fault` stops the machine and the screenshot has to be
# taken while there is still a machine to photograph.
CMDS='ls;cd bin;pwd;cat hello;cd ..;mkdir tmp;write /tmp/note hello from a shell in id;cat /tmp/note;ls tmp;rm /tmp/note;ls /tmp;uname;frobnicate'
python3 "$ROOT/tools/qmon.py" "$ELF" --wait 4 --type "$CMDS" --settle 2 \
        --shot "$TMP/screen.ppm" >"$TMP/serial.txt" 2>"$TMP/qmon.err"
got=$(cat "$TMP/serial.txt")

want_serial() { # want_serial DESCRIPTION LINE
    if printf '%s\n' "$got" | grep -qF "$2"; then ok "$1"; else bad "$1 (no '$2' on the serial port)"; fi
}

want_serial "the kernel boots"                    "id kernel: booted"
want_serial "the framebuffer comes up"            "fb: 640x480"
want_serial "the framebuffer holds what was drawn" "fb: diag 0x0000000000ffffff off 0x0000000000cc4422"
want_serial "the shell starts"                    "id shell -- an in-memory filesystem"
want_serial "ls lists the seeded filesystem"      "README"
want_serial "cd and pwd walk the tree"            "/bin"
want_serial "cat reads a seeded file"             "echo hello from a kernel with no operating system under it"
want_serial "write and cat round-trip"            "hello from a shell in id"
want_serial "uname answers"                       "id kernel -- x86_64, no libc"
want_serial "an unknown command says so"          "frobnicate: not a command -- try help"

# A fault names itself rather than resetting the machine. Without an IDT this
# is a triple fault and a silent reboot; with one it is three lines naming the
# vector, the error code and the instruction. docs/SPEC.md §8's traps have
# nowhere to go in a kernel, and this is what replaces them.
python3 "$ROOT/tools/qmon.py" "$ELF" --wait 4 --type "fault" --settle 2 \
        >"$TMP/fault.txt" 2>/dev/null
crash=$(cat "$TMP/fault.txt")
if printf '%s\n' "$crash" | grep -q '^\*\*\* fault: page fault (vector 14' \
   && printf '%s\n' "$crash" | grep -q '^\*\*\* at 0x00000000001' \
   && printf '%s\n' "$crash" | grep -q '^\*\*\* halted$'; then
    ok "a page fault reports itself and stops the machine"
else
    bad "a page fault reports itself and stops the machine"
fi

# -- the screen, not the serial port ----------------------------------------
# tools/fbtext.py matches each 8x16 cell of the framebuffer against the font
# the kernel drew it with, so this asserts on pixels that happen to spell
# words. A console that wrote to the serial port and drew nothing would pass
# every check above and fail this one.
if [ -f "$TMP/screen.ppm" ]; then
    screen=$(python3 "$ROOT/tools/fbtext.py" "$TMP/screen.ppm" 2>/dev/null)
    if printf '%s\n' "$screen" | grep -q "id kernel -- x86_64, no libc" \
       && printf '%s\n' "$screen" | grep -q "frobnicate: not a command"; then
        ok "the framebuffer shows what the shell printed"
    else
        bad "the framebuffer shows what the shell printed"
        printf '%s\n' "$screen" | tail -6
    fi
else
    bad "the framebuffer shows what the shell printed (no screenshot taken)"
fi

# -- the runtime written in `id`, against the runtime written in C ----------
# Everything the kernel demonstrates before the shell is ordinary `id` that
# says nothing about where it runs. So the same source builds hosted, on the C
# runtime, and the two must agree -- which is the only check that says the
# `id`-written runtime is *right* rather than merely present. A wrong
# `str_of_int` produces a kernel that boots and lies.
HOST="$TMP/host"
mkdir -p "$HOST"
cp -r "$ORG/kernel/prog/app/more/show" "$HOST/show"
cat > "$HOST/main.id" <<'IDEOF'
main(int argc, string[] argv) {
  show_all();
} return int 0;
IDEOF
if "$ROOT/bin/idc" "$HOST" --no-std -o "$TMP/host.bin" >"$TMP/host.log" 2>&1; then
    host_out=$("$TMP/host.bin" 2>&1)
    n=$(printf '%s\n' "$host_out" | wc -l)
    kern_out=$(printf '%s\n' "$got" | tail -n +3 | head -n "$n")
    if [ "$host_out" = "$kern_out" ]; then
        ok "the id-written runtime agrees with the C runtime, line for line"
    else
        bad "the id-written runtime agrees with the C runtime, line for line"
        diff <(printf '%s\n' "$host_out") <(printf '%s\n' "$kern_out") | head -20
    fi
else
    bad "the kernel's demonstrations build hosted ($(head -1 "$TMP/host.log"))"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
