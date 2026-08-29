#!/usr/bin/env bash
# The real standard library, against the real demos.
#
# tests/stdlib.sh builds against tests/fixtures/idstd so it says the same thing
# on a checkout with no library beside it. That makes it hermetic, and it also
# makes it blind: it cannot see that `bin/idc compiler/parse` -- the
# compiler's own source, built the way the README tells you to build it -- fails
# against the real ../idstd on a name the library also defines. Nothing in the
# suite could see that, because tests/run.sh sets IDC_NO_STD=1 for everything.
#
# This file is what sees it. For every project in the repo it records which of
# four states it is in and compares that against tests/idstd_expect.txt:
#
#   both       builds with the library and without it
#   needs-std  builds only with it (it calls a library function)
#   broken     builds only without it -- a collision with the library
#   neither    builds neither way (needs --backend or flags this file does
#              not pass; not a statement about the library)
#
# A mismatch in EITHER direction fails. A new collision fails because the
# ledger says `both`; porting a project onto the library fails until the ledger
# is updated to say so. The ledger cannot go stale and stay green, which is the
# only property that makes it worth having.
#
# `broken` is the work list. It is not a permitted state -- every line saying
# `broken` is a project that has to be ported (C9 in docs/IDSTD.md) or a
# library name that has to move.
#
# Run from anywhere: tests/idstd_real.sh
set -u
cd "$(dirname "$0")"
BIN_IDC=../bin/idc
LEDGER=idstd_expect.txt
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

unset IDC_NO_STD

# Locate the library the same way the compilers do, so a checkout without one
# skips rather than reporting every project as broken.
STD="${IDSTD_HOME:-}"
if [ -z "$STD" ]; then
    R=$(cd .. && pwd)
    for up in "$R/../idstd" "$R/../../idstd"; do
        [ -d "$up" ] && { STD="$up"; break; }
    done
    STD="${STD:-$R/../idstd}"
fi
if [ ! -d "$STD" ]; then
    echo "SKIP: no standard library at '$STD' (set IDSTD_HOME to point at one)"
    exit 0
fi

classify() { # PATH -> both | needs-std | broken | neither
    local p="$1" w o
    "$BIN_IDC" "$p" --emit-c /dev/null >/dev/null 2>&1 && w=y || w=n
    IDC_NO_STD=1 "$BIN_IDC" "$p" --emit-c /dev/null >/dev/null 2>&1 && o=y || o=n
    case "$w$o" in
        yy) echo both ;;
        yn) echo needs-std ;;
        ny) echo broken ;;
        nn) echo neither ;;
    esac
}

# Why a project is broken, in one line, so the failure names the collision
# rather than just the project.
why() { "$BIN_IDC" "$1" --emit-c /dev/null 2>&1 | head -1; }

# The GLOB drives, not the ledger. A project added to demos/ or compiler/ is
# checked from the moment it exists; the ledger only supplies the expectation,
# and a project with no line in it fails rather than going unnoticed. Anything
# outside those two directories is picked up from the ledger by
# name, so the ledger stays the place to add a project living somewhere else.
want_of() { sed -n "s|^$1  *\([a-z-]*\).*|\1|p" "$LEDGER" | head -1; }

# demos/ lives in the umbrella repository, one level above this one.
path_of() { case "$1" in demos/*) echo "../../$1" ;; *) echo "../$1" ;; esac; }

projects=""
for d in ../../demos/*/ ../compiler/*/; do
    [ -d "$d" ] || continue
    e=${d#../}; e=${e#../}
    projects="$projects $e"
done
while read -r name _; do
    case "$name" in ''|\#*) continue ;; esac
    case " $projects " in *" $name/ "*|*" $name "*) continue ;; esac
    [ -d "$(path_of "$name")" ] && projects="$projects $name"
done < "$LEDGER"

for p in $projects; do
    name=${p%/}
    path=$(path_of "$name")
    case "$name" in demos/*) name=${name#demos/} ;; esac
    want=$(want_of "$name")
    got=$(classify "$path")
    if [ -z "$want" ]; then
        bad "$name: a project with no line in $LEDGER (it is '$got')"
    elif [ "$got" = "$want" ]; then
        ok "$name: $got"
    elif [ "$got" = broken ]; then
        bad "$name: expected '$want', the library now breaks it -- $(why "$path")"
    else
        bad "$name: expected '$want', got '$got' (update $LEDGER)"
    fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
