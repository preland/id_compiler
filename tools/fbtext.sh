#!/usr/bin/env bash
# fbtext.sh -- read the kernel's framebuffer back as text.
#
#   tools/fbtext.sh shot.ppm
#
# The kernel draws its console with the 8x16 font in kernel/prog/conf.id, so a
# screenshot can be turned back into the characters that produced it by
# matching each cell against that same font. That is what makes a graphical
# shell testable: without it the only thing a test can check is the serial
# port, and the serial port is not the screen.
#
# tools/fbtext (in `id`) does the matching. This builds it and runs it with the
# screenshot's path and, on stdin, the conf.id it reads the font from. The
# build's own output goes to stderr, so stdout is the screen and nothing else.
#
# The program is built with idstd whatever the caller's IDC_NO_STD says:
# tests/run.sh exports IDC_NO_STD=1 for everything it runs, and tests/kernel.sh
# calls this from inside it.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)

[ $# -eq 1 ] || { sed -n '2,4p' "$0" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

env -u IDC_NO_STD "$ROOT/bin/idc" "$ROOT/tools/fbtext" -o "$TMP/fbtext" >&2 \
    || { echo "fbtext.sh: failed to build tools/fbtext" >&2; exit 1; }

"$TMP/fbtext" "$1" < "$ROOT/../kernel/prog/conf.id"
