#!/usr/bin/env bash
# idview.sh -- show a random `id` source file.
#
#   tools/idview.sh              # a random file from demos/
#   tools/idview.sh demos/calc   # a random file from one tree
#   tools/idview.sh a/ b/ c.id   # from anything named
#
# The viewer itself is written in id (demos/idview). id has no filesystem
# access, so the file set is fed to it on stdin using the same `#file <path>`
# marker protocol bin/idc uses to give the compiler file boundaries.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bin=${IDVIEW:-$here/.idc-cache/idview}

if [ ! -x "$bin" ] || [ -n "$(find "$here/../demos/idview" -name '*.id' -newer "$bin" 2>/dev/null)" ]; then
    mkdir -p "$(dirname "$bin")"
    "$here/bin/idc" "$here/../demos/idview" -o "$bin" >&2
fi

roots=("$@")
[ ${#roots[@]} -eq 0 ] && roots=("$here/demos")

{
    for r in "${roots[@]}"; do
        if [ -f "$r" ]; then files=("$r"); else
            mapfile -t files < <(find "$r" -name '*.id' | LC_ALL=C sort)
        fi
        for f in "${files[@]}"; do
            printf '#file %s\n' "$f"
            cat "$f"
            printf '\n'
        done
    done
} | "$bin"
