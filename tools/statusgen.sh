#!/usr/bin/env bash
# Regenerate the measured numbers inside docs/TESTS.md's rollout status.
#
#   tools/statusgen.sh            # rewrite the block
#   tools/statusgen.sh --check    # exit 1 if rewriting would change anything
#   tools/statusgen.sh --count PATH FLAGS...   # one tree's counts, built with FLAGS
#
# Why this exists: docs/TESTS.md carried the line "Cases written so far: 0, of
# 6816". It was true when written and false four commits later, in the same
# session, because 200 cases had been written in idstd meanwhile. A status
# block that a human maintains is a status block that lies -- and this one was
# lying about the adoption of the very rule it describes.
#
# So the numbers are measured, written between markers, and checked by
# tests/run.sh. The prose around them stays hand-written; only the counts are
# generated, because only the counts go stale on their own.
#
# ../../../linux_id/docs/STATUS.md is where this idea comes from: it is generated and
# its own suite fails if the table and the measurement disagree. That is the
# best practice in this ecosystem and it should be the rule everywhere.
set -u
cd "$(dirname "$0")/.."

DOC=../docs/TESTS.md
BEGIN='<!-- generated: adoption -->'
END='<!-- end generated -->'

# A case is a line of the form (args):(expected), optionally opened by
# `given SETUP` and with `(import NAME)` among its values; a function
# declaration starts at column 0 with a name and an open paren. Both are
# counted the same way in every repository so the numbers mean the same thing.
# `build/` is excluded everywhere: the harnesses write generated `id` there, and
# counting a compiler's throwaway output as source made this table depend on
# whether a sibling repository had been run recently.
#
# The number that matters is functions short of two cases, not cases against
# twice the functions: a total can be met by functions with many cases while
# others have none, and "every function has its cases" is what lets
# --allow-untested be deleted. A case is only legal directly under its own
# function, so each file is walked in order and every case line is credited to
# the declaration above it.
# The patterns reach awk through the environment, not -v: -v processes escape
# sequences, which turns every \( into ( and leaves an invalid regular
# expression that counts nothing.
export CASE_RE='^(given +[A-Za-z_][A-Za-z0-9_]* +)?\((\(import [A-Za-z_][A-Za-z0-9_]*\)|[^)])*\) *: *\('
export FN_RE='^[a-z_][a-z0-9_]*\('
id_files() { find "$@" -name build -prune -o -name '*.id' -type f -print 2>/dev/null | LC_ALL=C sort; }
count_tree() {
    id_files "$@" | tr '\n' '\0' | xargs -0 -r awk '
        BEGIN      { cre = ENVIRON["CASE_RE"]; fre = ENVIRON["FN_RE"]
                     while ((getline row < ENVIRON["EXEMPT"]) > 0) exempt[row] = 1 }
        function close_fn() { if (infn && cases < 2 && !(key in exempt)) short++; infn = 0; cases = 0 }
        FNR == 1   { close_fn() }
        $0 ~ fre   { close_fn(); fns++; infn = 1; key = FILENAME "|" substr($0, 1, index($0, "(") - 1); next }
        $0 ~ cre   { total++; if (infn) cases++ }
        END        { close_fn(); printf "%d %d %d\n", fns + 0, total + 0, short + 0 }
    ' | awk 'NF == 3 { f += $1; c += $2; s += $3 } END { printf "%d %d %d\n", f + 0, c + 0, s + 0 }'
}

# A function that cannot be tested on the build host needs no cases
# (docs/TESTS.md, "A freestanding build runs its cases on the build host"), and
# only the compiler can say which functions those are: it follows the call graph
# to an `asm` body, a native or a runtime helper. So a freestanding tree is
# asked, with the flags its build passes, and the functions it names as exempt
# are not counted short.
#
# exempt_of PATH FLAGS... -- print FILE|NAME for each function bin/idc exempts.
exempt_of() {
    local rows rc
    rows=$(./bin/idc "$@" --list-untested 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "statusgen: ./bin/idc $* --list-untested failed (status $rc)" >&2
        return 1
    fi
    printf '%s\n' "$rows" | awk -F'|' '$1 == "exempt" { sub(/:[0-9]+$/, "", $2); print $2 "|" $3 }'
}
EXEMPT=$(mktemp) || exit 1
trap 'rm -f "$EXEMPT"' EXIT
export EXEMPT

# statusgen.sh --count PATH FLAGS... -- the functions, cases and functions short
# of two cases in PATH alone, built with FLAGS, as one line. It is the count the
# table is made of, so a test can check it on a tree of its own.
if [ "${1:-}" = "--count" ]; then
    shift
    exempt_of "$@" > "$EXEMPT" || exit 1
    count_tree "$1"
    exit 0
fi

STD=../../idstd
C2ID=../c2id
LINUX=../../linux_id

# The two freestanding trees, with the flags tools/kbuild.sh builds them with.
{ exempt_of ../kernel/prog --no-std --freestanding --triple x86_64-unknown-none \
  && exempt_of runtime --no-std --runtime --triple x86_64-unknown-none; } > "$EXEMPT" || exit 1

# Every tree a build in this checkout compiles with --allow-untested, the
# freestanding kernel and runtime included, so the flag cannot look finished
# while something that passes it still lacks cases.
read -r here_f here_c here_s <<< "$(count_tree compiler ../demos backends runtime tools driver ../editor ../idem ../kernel)"
std_f=0; std_c=0; std_s=0
[ -d "$STD" ]   && read -r std_f std_c std_s <<< "$(count_tree "$STD/core" "$STD/sys")"
c2_f=0; c2_c=0; c2_s=0
[ -d "$C2ID" ]  && read -r c2_f c2_c c2_s <<< "$(count_tree "$C2ID")"
lin_f=0; lin_c=0; lin_s=0
[ -d "$LINUX" ] && read -r lin_f lin_c lin_s <<< "$(count_tree "$LINUX")"

have=$((here_c + std_c + c2_c + lin_c))
all_f=$((here_f + std_f + c2_f + lin_f))
short=$((here_s + std_s + c2_s + lin_s))
pct=$(awk -v s="$short" -v n="$all_f" 'BEGIN { printf "%.1f", (n ? 100*(n-s)/n : 0) }')

block=$(cat <<EOF
$BEGIN
| repository | functions | cases written | functions short of two cases |
| --- | ---: | ---: | ---: |
| \`id_development\` (with editor, idem, kernel) | $here_f | $here_c | $here_s |
| \`idstd\` | $std_f | $std_c | $std_s |
| \`c2id\` | $c2_f | $c2_c | $c2_s |
| \`linux_id\` | $lin_f | $lin_c | $lin_s |
| **total** | **$all_f** | **$have** | **$short** |

**Functions short of two cases: $short of $all_f ($pct% complete).** Generated by
\`idc/tools/statusgen.sh\`; \`idc/tests/run.sh\` fails if it is stale. A repository
with no \`.id\` beside this checkout counts zero.
$END
EOF
)

new=$(awk -v b="$BEGIN" -v e="$END" -v blk="$block" '
    $0 == b { print blk; skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
' "$DOC")

if [ "$new" = "$(cat "$DOC")" ]; then
    [ "${1:-}" = "--check" ] && exit 0
    echo "statusgen: $DOC already current"
    exit 0
fi
if [ "${1:-}" = "--check" ]; then
    echo "statusgen: $DOC is out of date -- run tools/statusgen.sh" >&2
    exit 1
fi
printf '%s\n' "$new" > "$DOC"
echo "statusgen: wrote $DOC ($short of $all_f functions short of two cases, $pct% complete)"
