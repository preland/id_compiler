#!/usr/bin/env bash
# dupscan.sh -- find one function written twice across separate projects.
#
#   tools/dupscan.sh PROJECT...
#   tools/dupscan.sh kernel/prog idc/tests/conform ../idstd
#
# `id` already rejects two functions with the same signature and the same
# logic, but only within one compilation unit (docs/README's "One copy of a
# function, across projects"): a program, the standard library and each
# imported tree are separate units, so the rule cannot see the same helper
# carried in two of them. This closes that gap without a second opinion about
# what "the same function" means: each project's fingerprints come straight
# from `idc PATH --fingerprints` (compiler/parse/mid/unique/canon/), the exact
# strings the compiler's own uniqueness check compares, prefixed with the
# project's own basename so tools/dupscan (in `id`) can tell which lines came
# from where and only report a group that crosses that boundary.
#
# A project that fails its own checks still contributes whatever it parsed:
# --fingerprints prints after the checks, not instead of them (bin/idc's own
# --fingerprints handling explains why). dupscan.sh does not stop for that --
# a duplicate across two projects is worth knowing about even when one of them
# has an unrelated problem of its own.
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)

[ $# -gt 0 ] || { sed -n '2,6p' "$0"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

DUPSCAN="$TMP/dupscan"
"$ROOT/bin/idc" "$ROOT/tools/dupscan" --allow-untested -o "$DUPSCAN" >&2 \
    || { echo "dupscan.sh: failed to build tools/dupscan" >&2; exit 1; }

LINES="$TMP/lines"
: > "$LINES"
for p in "$@"; do
    [ -e "$p" ] || { echo "dupscan.sh: no such path: $p" >&2; exit 2; }
    name=$(basename "$p")
    "$ROOT/bin/idc" "$p" --allow-untested --fingerprints 2>"$TMP/err" \
        | awk -v name="$name" -F'\t' 'NF >= 3 { print name "\t" $0 }' >> "$LINES"
    [ -s "$TMP/err" ] && cat "$TMP/err" >&2
done

"$DUPSCAN" < "$LINES"
