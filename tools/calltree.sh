#!/usr/bin/env bash
# calltree.sh -- render the function dependency tree of an id program, from
# `idc PATH --calls` (docs/TESTS.md's "--calls" section documents the rows
# it reads: caller|caller_file:line|callee|callee_file:line|kind, then a
# `fn|file:line|cases` section).
#
#   tools/calltree.sh PATH NAME [--callers] [--depth N]
#       The tree rooted at NAME: what NAME calls, transitively, one line per
#       node as "name  file:line  (N cases)". --callers inverts it (who
#       calls NAME, transitively, instead of what NAME calls). --depth N
#       stops expanding a node past N levels below the root (unlimited by
#       default). A node already an ancestor of itself on the current branch
#       is marked "(recursive)" and not expanded again; a node whose subtree
#       was already printed elsewhere in this tree is marked "(shown above)"
#       instead, so a widely-shared function is not re-expanded exponentially
#       many times. A builtin (no id source, ../docs/TESTS.md's kind=builtin)
#       is always a leaf, marked "[builtin]"; a function from the standard
#       library ($IDSTD_HOME) is marked "[idstd]".
#
#   tools/calltree.sh PATH --order FILE
#       FILE's functions (one `path:line|name` per line, the coordinator's
#       batch-list format), printed bottom-up: a function's callees within
#       the set before it, with cycles grouped under a "# cycle:" line
#       (tools/callorder.awk). Edges leaving the set are ignored -- this
#       orders FILE's own functions among themselves, not the whole program.
#
# PATH is what bin/idc builds (a project tree or a single file).
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
IDC="$HERE/bin/idc"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

die() { echo "calltree: $*" >&2; exit 2; }

# label_of NAME -- "NAME  file:line  (N cases)[  [idstd]]", or
# "NAME  [builtin]" for a name --calls never declared a location for.
label_of() {
    local n="$1" row loc path cases plural mark
    row=$(awk -F'\t' -v n="$n" '$1 == n { print; exit }' "$WORK/info")
    if [ -z "$row" ]; then
        printf '%s  [builtin]' "$n"
        return 0
    fi
    loc="${row#*$'\t'}"
    path="${loc%|*}"
    cases="${loc##*|}"
    plural=""
    [ "$cases" != 1 ] && plural="s"
    mark=""
    if [ -n "$IDSTD_PREFIX" ] && [[ "$path" == "$IDSTD_PREFIX"/* ]]; then
        mark="  [idstd]"
    fi
    printf '%s  %s  (%s case%s)%s' "$n" "$path" "$cases" "$plural" "$mark"
}

# children_of NAME -- its callees (forward mode) or callers (--callers), one
# per line, already deduplicated across edge kinds (../docs/TESTS.md: an
# edge's kind, call or value, is not part of the tree shape).
children_of() {
    awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$WORK/adj"
}

# render NAME PREFIX IS_LAST DEPTH -- one subtree, box-drawn under PREFIX.
# IS_LAST says whether NAME is the last child of its own parent (picks the
# connector and what the next level's prefix continues with). ONPATH is the
# current root-to-NAME branch (recursion); SHOWN is every node this whole
# render has already expanded once (shared-subtree collapse).
declare -A ONPATH=()
declare -A SHOWN=()
render() {
    local name="$1" prefix="$2" is_last="$3" depth="$4"
    local connector="├── "
    [ "$is_last" -eq 1 ] && connector="└── "
    local label suffix="" expand=1
    label=$(label_of "$name")
    if [ -n "${ONPATH[$name]:-}" ]; then
        suffix=" (recursive)"; expand=0
    elif [ -n "${SHOWN[$name]:-}" ]; then
        suffix=" (shown above)"; expand=0
    fi
    [[ "$label" == *"[builtin]"* ]] && expand=0
    [ "$HAS_DEPTH" -eq 1 ] && [ "$depth" -ge "$DEPTH" ] && expand=0
    printf '%s%s%s%s\n' "$prefix" "$connector" "$label" "$suffix"
    [ "$expand" -eq 1 ] || return 0
    local kids
    kids=$(children_of "$name")
    [ -z "$kids" ] && return 0
    SHOWN[$name]=1
    ONPATH[$name]=1
    local child_prefix="$prefix    "
    [ "$is_last" -eq 0 ] && child_prefix="$prefix│   "
    local total i=0 kid last
    total=$(printf '%s\n' "$kids" | wc -l)
    while IFS= read -r kid; do
        i=$((i + 1))
        last=0
        [ "$i" -eq "$total" ] && last=1
        render "$kid" "$child_prefix" "$last" "$((depth + 1))"
    done <<< "$kids"
    unset "ONPATH[$name]"
}

cmd_tree() {
    local name="$1"
    local label
    label=$(label_of "$name")
    printf '%s\n' "$label"
    [[ "$label" == *"[builtin]"* ]] && return 0
    local kids
    kids=$(children_of "$name")
    [ -z "$kids" ] && return 0
    SHOWN[$name]=1
    ONPATH[$name]=1
    local total i=0 kid last
    total=$(printf '%s\n' "$kids" | wc -l)
    while IFS= read -r kid; do
        i=$((i + 1))
        last=0
        [ "$i" -eq "$total" ] && last=1
        render "$kid" "" "$last" 1
    done <<< "$kids"
}

cmd_order() {
    local file="$1"
    [ -f "$file" ] || die "no such file: $file"
    awk -F'|' '{ print $2 }' "$file" > "$WORK/names"
    awk -F'|' '{ print $2 "\t" $1 }' "$file" > "$WORK/locs"
    awk -F'|' '{ print $1 "\t" $3 }' "$WORK/edges" \
        | awk -v namesfile="$WORK/names" -v locfile="$WORK/locs" -f "$HERE/tools/callorder.awk"
}

[ $# -ge 2 ] || die "usage: calltree.sh PATH NAME [--callers] [--depth N] | PATH --order FILE"
PROJ="$1"; shift

env -u IDC_NO_STD "$IDC" "$PROJ" --calls > "$WORK/calls.out" 2> "$WORK/calls.err"
rc=$?
if [ ! -s "$WORK/calls.out" ]; then
    cat "$WORK/calls.err" >&2
    die "'$IDC' $PROJ --calls produced no output (exit $rc)"
fi
awk -F'|' -v e="$WORK/edges" -v c="$WORK/cases" '
    NF == 5 { print > e; next }
    NF == 3 && $1 != "fn" { print > c }
' "$WORK/calls.out"
[ -f "$WORK/edges" ] || : > "$WORK/edges"
[ -f "$WORK/cases" ] || : > "$WORK/cases"
awk -F'|' '{ print $1 "\t" $2 "|" $3 }' "$WORK/cases" > "$WORK/info"

IDSTD_PREFIX=""
[ -n "${IDSTD_HOME:-}" ] && IDSTD_PREFIX=$(cd "$IDSTD_HOME" 2>/dev/null && pwd -P)

if [ "$1" = "--order" ]; then
    [ $# -eq 2 ] || die "--order needs exactly one FILE"
    cmd_order "$2"
    exit 0
fi

NAME="$1"; shift
CALLERS=0
HAS_DEPTH=0
DEPTH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --callers) CALLERS=1; shift ;;
        --depth) HAS_DEPTH=1; DEPTH="${2:?calltree: --depth needs a number}"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [ "$CALLERS" -eq 1 ]; then
    awk -F'|' '{ print $3 "\t" $1 }' "$WORK/edges" | LC_ALL=C sort -u > "$WORK/adj"
else
    awk -F'|' '{ print $1 "\t" $3 }' "$WORK/edges" | LC_ALL=C sort -u > "$WORK/adj"
fi

cmd_tree "$NAME"
