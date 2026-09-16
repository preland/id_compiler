#!/usr/bin/env bash
# chainfind.sh -- read-only report of rule 6 candidates: a project function
# called exactly once in the whole build, where that one call is the last
# action of its caller's body, must become a `chain` continuation of the
# caller instead of a separate function. idstd (anything under
# $IDSTD_HOME, or /home/preland/git/idstd when that is unset -- the same
# default bin/idc resolves) is exempt as a callee: a library function's one
# caller today does not preclude a second one tomorrow.
#
#   tools/chainfind.sh PROJECT [--count]
#
#       Prints one block per candidate: the callee's file:line and name,
#       then the caller's file:line and name, then a blank line. --count
#       prints only the totals line.
#
# Nothing is written anywhere: this only reads bin/idc's own output and the
# project's .id sources. It changes no file.
#
# DATA SOURCE. `bin/idc PROJECT --calls` (idc/README.md, "The function
# dependency tree") prints caller|caller_loc|callee|callee_loc|kind rows,
# kind "call" for a direct call or "value" for the name used as a value --
# every direct call also prints a matching "value" row for the same pair,
# a known parser artifact (same section), so only kind=call rows are used
# here to count call sites; a callee with no callee_loc is a builtin and can
# never be a candidate. THAT DATA SAYS NOTHING ABOUT A CALL SITE'S POSITION
# in the caller's body -- there is one row per caller/callee pair, not per
# call site -- so "last action" cannot come from --calls at all. It is
# determined instead by reading the caller's own source with
# tools/lastaction.awk, a brace-depth scan that finds the function's last
# top-level statement and checks whether it is exactly a call (bare, or
# assigned) to the candidate callee -- not one buried inside an `if`/`while`
# arm. See that file's header for the scan itself.
#
# tools/calltree.sh already parses --calls into edges/fn tables the same
# way; this script's PROJ/WORK/IDC/IDSTD_PREFIX setup mirrors it so the two
# tools agree on what --calls means.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
IDC="$HERE/bin/idc"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

die() { echo "chainfind: $*" >&2; exit 2; }

[ $# -ge 1 ] || die "usage: chainfind.sh PROJECT [--count]"
PROJ="$1"; shift
COUNT_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --count) COUNT_ONLY=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -e "$PROJ" ] || die "no such project: $PROJ"

env -u IDC_NO_STD "$IDC" "$PROJ" --calls > "$WORK/calls.out" 2> "$WORK/calls.err"
rc=$?
if [ ! -s "$WORK/calls.out" ]; then
    cat "$WORK/calls.err" >&2
    die "'$IDC' $PROJ --calls produced no output (exit $rc)"
fi
awk -F'|' '
    NF == 5 { print > "'"$WORK"'/edges"; next }
    NF == 3 && $1 != "fn" { print > "'"$WORK"'/cases" }
' "$WORK/calls.out"
[ -f "$WORK/edges" ] || : > "$WORK/edges"

IDSTD_PREFIX=""
if [ -n "${IDSTD_HOME:-}" ]; then
    IDSTD_PREFIX=$(cd "$IDSTD_HOME" 2>/dev/null && pwd -P)
elif [ -d /home/preland/git/idstd ]; then
    IDSTD_PREFIX=$(cd /home/preland/git/idstd 2>/dev/null && pwd -P)
fi
[ -n "$IDSTD_PREFIX" ] || echo "chainfind: warning: no idstd found to exempt (checked \$IDSTD_HOME and /home/preland/git/idstd) -- library functions will not be exempted" >&2

# One row per (caller, caller_loc, callee, callee_loc) call site, kind=call
# only (a kind=value row for the same pair is the parser artifact the
# header describes, not a second use), callee_loc non-empty (a builtin
# cannot become a chain target) and outside idstd (exempt as a callee).
awk -F'|' -v idstd="$IDSTD_PREFIX" '
    $5 == "call" && $4 != "" {
        if (idstd != "" && index($4, idstd "/") == 1) next
        print $1 "|" $2 "|" $3 "|" $4
    }
' "$WORK/edges" > "$WORK/sites"

# Candidates: callees with exactly one call site project-wide (--calls
# emits one row per call site -- ../TESTS.md and edges/scan.id -- so two
# calls from the same caller, or one each from two callers, both print
# twice and are both excluded here, honestly: "called exactly once" means
# one row, not one distinct caller).
awk -F'|' '{ n[$3 "|" $4]++; row[$3 "|" $4] = $0 }
    END { for (k in n) if (n[k] == 1) print row[k] }' "$WORK/sites" \
    | LC_ALL=C sort > "$WORK/once"

CANDIDATES=0
TOTAL_ONCE=0
while IFS='|' read -r caller caller_loc callee callee_loc; do
    TOTAL_ONCE=$((TOTAL_ONCE + 1))
    caller_file="${caller_loc%:*}"
    caller_line="${caller_loc##*:}"
    [ -f "$caller_file" ] || { echo "chainfind: warning: caller file not found, skipping: $caller_file" >&2; continue; }
    verdict=$(awk -v startline="$caller_line" -v callee="$callee" -f "$HERE/tools/lastaction.awk" "$caller_file" 2>>"$WORK/lastaction.err")
    [ "$verdict" = "yes" ] || continue
    CANDIDATES=$((CANDIDATES + 1))
    if [ "$COUNT_ONLY" -eq 0 ]; then
        printf 'callee %s  %s\ncaller %s  %s\n\n' "$callee_loc" "$callee" "$caller_loc" "$caller"
    fi
done < "$WORK/once"

if [ -s "$WORK/lastaction.err" ]; then
    echo "chainfind: warnings while reading caller sources:" >&2
    cat "$WORK/lastaction.err" >&2
fi

echo "chainfind: $CANDIDATES candidate(s) (rule 6: called once and last action of the caller), out of $TOTAL_ONCE function(s) called exactly once project-wide"
