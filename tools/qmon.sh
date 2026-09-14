#!/usr/bin/env bash
# qmon.sh -- drive the kernel under QEMU: type at it, photograph it, read
# what it said.
#
#   tools/qmon.sh build/kernel.elf --wait 2 --type "ls;uname" --shot out.ppm
#
# tools/qmon (in `id`) does the driving, over QMP and the guest's serial port
# (idstd's sys/io/ipc/proc and sys/io/ipc/sock). This builds it and forwards
# every argument straight through -- tools/qmon/main.id takes the same ones
# qmon.py did.
#
# Serial output goes to stdout, exactly as it always has.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)

[ $# -ge 1 ] || { sed -n '4,6p' "$0" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

env -u IDC_NO_STD "$ROOT/bin/idc" "$ROOT/tools/qmon" --allow-untested -o "$TMP/qmon" >&2 \
    || { echo "qmon.sh: failed to build tools/qmon" >&2; exit 1; }

"$TMP/qmon" "$@"
