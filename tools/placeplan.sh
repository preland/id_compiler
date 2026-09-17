#!/usr/bin/env bash
# placeplan.sh -- read-only planning tool: where should a new or surplus
# function live, in a project that already breaks (or is about to break) the
# two structural limits of docs/PROJECT.md section 3 -- at most 3 functions
# per .id file, at most 3 entries (.id files and subdirectories together,
# conf.id and backend.id excluded -- idc/bin/idc's check_entry_limit) per
# directory?
#
#   tools/placeplan.sh PROJECT-DIR [--check]
#
#       Scans PROJECT-DIR for both kinds of violation and prints a PROPOSAL
#       for each: which surplus function(s) move to which new-or-existing
#       path, the exact `mkdir`/`git mv` that would carry it out (printed
#       only, never run), and a one-clause reason. Ends with a VERIFICATION
#       section: every path any proposal touches, with its entry or function
#       count after the whole plan is applied, so the plan can be checked by
#       hand before anyone runs a single command from it. A clean tree
#       prints "nothing to do" and exits 0.
#
#   --check
#       Exit nonzero iff PROJECT-DIR has a violation. Prints only the bare
#       counts for violating paths ("FILE: N functions", "DIR: N entries")
#       -- no proposals. Silent (exit 0) on a clean tree.
#
# NEVER WRITES. This reads bin/idc's own --calls output and the project's
# .id sources and filenames; it changes no file, runs no `git mv`, `mkdir`,
# or `idc --fix`.
#
# HOW A DESTINATION IS CHOSEN, in preference order (docs/PROJECT.md section
# 3's "push a pair of files down a level" remedy, made concrete):
#   1. An existing sibling file with a free slot (<3 functions) that a
#      project-wide call edge (idc/bin/idc PROJECT --calls, tools/calltree.sh's
#      data source) already connects to the moving function(s) -- kept
#      together with what it calls or is called by, not grouped by having
#      merely had room.
#   2. A new sibling file, named after the moving function(s), when the
#      directory has room for one more entry.
#   3. A new subdirectory, when the directory is already at 3 entries: one
#      existing sibling (preferring one the call graph already connects to
#      the movers) is relocated into it alongside the new file, which nets
#      to zero change in the parent's own entry count -- the shape
#      docs/PROJECT.md section 3 shows as shift/{shift.id,more/tail.id}.
# A directory-entry violation (not tied to any one file) is fixed the same
# way: the minimum number of entries that brings it back to 3 (count - 2)
# moves into one new subdirectory; if that set itself would exceed 3, it is
# split again the same way PROJECT.md's own example does, under a nested
# "more/" -- the one place this tool ever proposes that name, because it is
# the exact precedent, not a stand-in for a real one.
#
# CALL GRAPH AVAILABILITY. `idc/bin/idc PROJECT --calls` is what supplies
# "kept together" (tools/calltree.sh and tools/chainfind.sh both read the
# same data). A directory-entry violation does not stop it -- bin/idc's
# check_entry_limit only sets STRUCT_VIOLATIONS, which --calls's own exit
# path ignores (it exits with idparse's own parse_rc) -- and a
# too-many-functions-in-a-file violation is a parse_rc=1 diagnostic that
# print_calls still runs after, so --calls keeps working on exactly the
# trees this tool exists for. If it still produces no edges at all (a
# genuine syntax error, unrelated to either limit), placement falls back to
# "no call-graph relation found" for everything, which is noted once, up
# front, rather than pretended around.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
IDC="$HERE/bin/idc"
FUNCSCAN="$HERE/tools/funcscan.awk"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

die() { echo "placeplan: $*" >&2; exit 2; }

[ $# -ge 1 ] || die "usage: placeplan.sh PROJECT-DIR [--check]"
ROOT_ARG="$1"; shift
CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -d "$ROOT_ARG" ] || die "no such project directory: $ROOT_ARG"
ROOT=$(cd "$ROOT_ARG" && pwd)
BUILD_DIR="build"

# ---------------------------------------------------------------------------
# Filesystem scan. Mirrors idc/bin/idc's collect_ids/check_entry_limit: hidden
# entries and ROOT/build are pruned and never counted; conf.id and backend.id
# are metadata, never compiled and never counted as directory entries.

# Every directory's own entry count, "N|DIR" one per directory that has at
# least one counted child (a childless directory is looked up as 0 by
# dircount() below).
find "$ROOT" -mindepth 1 \
     \( -type d -name '.*' -prune \) -o \
     \( -type d -path "${ROOT%/}/$BUILD_DIR" -prune \) -o \
     \( -type d -printf 'd|%h\n' \) -o \
     \( -name '*.id' ! -name 'conf.id' ! -name 'backend.id' -printf 'f|%h\n' \) \
    | awk -F'|' '{ n[$2]++ } END { for (d in n) print n[d] "|" d }' \
    | LC_ALL=C sort -t'|' -k2 > "$WORK/dircounts"

# Every compiled .id file (source order irrelevant here; funcscan gives that).
find "$ROOT" -mindepth 1 \
     \( -type d -name '.*' -prune \) -o \
     \( -type d -path "${ROOT%/}/$BUILD_DIR" -prune \) -o \
     \( -name '*.id' ! -name 'conf.id' ! -name 'backend.id' -print \) \
    | LC_ALL=C sort > "$WORK/idfiles"

[ -s "$WORK/idfiles" ] || die "no .id files under $ROOT"

# A file holding an unresolved git conflict (<<<<<<< / ======= / >>>>>>>) is
# not valid id source: funcscan's brace-depth heuristic can be thrown off by
# one side's unclosed block, and a count for a file in that state cannot be
# trusted in either direction. Rather than print a number that might be
# silently wrong, such files are pulled out of the scan and reported loudly
# instead (see SKIPPED below) -- their mere presence, unlike an ordinary
# violation, is enough on its own to make --check exit nonzero.
: > "$WORK/skipped"
while IFS= read -r f; do
    if grep -qE '^<{7}([[:space:]]|$)|^={7}$|^>{7}([[:space:]]|$)' "$f" 2>/dev/null; then
        echo "$f" >> "$WORK/skipped"
    fi
done < "$WORK/idfiles"
LC_ALL=C sort -o "$WORK/skipped" "$WORK/skipped"
LC_ALL=C comm -23 "$WORK/idfiles" "$WORK/skipped" > "$WORK/idfiles_ok"

# funcs: FILE|NAME|LINE, one row per top-level function (funcscan.awk already
# folds a chain into the function it continues -- docs/PROJECT.md section 3).
# Conflict-marked files (above) are left out -- not scanned at all. funcscan
# itself exits nonzero, with nothing trustworthy on stdout, for a file whose
# braces are unbalanced at EOF (a botched merge can produce this even with
# every marker line gone) -- such a file's own (possibly undercounted) rows
# are discarded rather than fed into filecounts, and the file is recorded in
# unbalanced instead, to be reported loudly rather than trusted silently.
: > "$WORK/funcs"
: > "$WORK/unbalanced"
while IFS= read -r f; do
    if awk -f "$FUNCSCAN" "$f" > "$WORK/fs_out" 2> "$WORK/fs_err"; then
        awk -F'|' -v f="$f" '{ print f "|" $1 "|" $2 }' "$WORK/fs_out" >> "$WORK/funcs"
    else
        echo "$f" >> "$WORK/unbalanced"
    fi
done < "$WORK/idfiles_ok"
LC_ALL=C sort -o "$WORK/unbalanced" "$WORK/unbalanced"

awk -F'|' '{ n[$1]++ } END { for (f in n) print f "|" n[f] }' "$WORK/funcs" \
    | LC_ALL=C sort -t'|' -k1,1 > "$WORK/filecounts"

awk -F'|' '{ print $2 "\t" $1 }' "$WORK/funcs" | LC_ALL=C sort -u > "$WORK/name2file"

awk -F'|' '$2 + 0 > 3 { print }' "$WORK/filecounts" | LC_ALL=C sort > "$WORK/file_violations"
awk -F'|' '$1 + 0 > 3 { print }' "$WORK/dircounts" | LC_ALL=C sort -t'|' -k2 > "$WORK/dir_violations"

rel() { # rel PATH -- PATH made relative to $ROOT for display. Everything
        # this tool prints about a location inside the project goes through
        # this, so the plan stays readable at depth instead of repeating the
        # absolute project path on every line.
    case "$1" in
        "$ROOT") printf '.' ;;
        "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
if [ "$CHECK" -eq 1 ]; then
    if [ ! -s "$WORK/file_violations" ] && [ ! -s "$WORK/dir_violations" ] && [ ! -s "$WORK/skipped" ] && [ ! -s "$WORK/unbalanced" ]; then
        exit 0
    fi
    while IFS='|' read -r f c; do echo "$(rel "$f"): $c functions"; done < "$WORK/file_violations"
    while IFS='|' read -r c d; do echo "$(rel "$d"): $c entries"; done < "$WORK/dir_violations"
    if [ -s "$WORK/skipped" ]; then
        echo "SKIPPED -- $(wc -l < "$WORK/skipped" | tr -d ' ') file(s) have unresolved git conflict markers; their function counts are NOT reliable and they were left out of the scan above entirely -- resolve the conflicts and re-run before trusting this check:"
        while IFS= read -r f; do echo "  SKIPPED: $(rel "$f")"; done < "$WORK/skipped"
    fi
    if [ -s "$WORK/unbalanced" ]; then
        echo "UNBALANCED -- $(wc -l < "$WORK/unbalanced" | tr -d ' ') file(s) have unbalanced braces at end of file (no conflict markers remain, but funcscan's depth count never returns to 0); their function counts are NOT reliable, a function can be hidden inside the unclosed block, and they were left out of the scan above entirely -- resolve the brace imbalance and re-run before trusting this check:"
        while IFS= read -r f; do echo "  UNBALANCED: $(rel "$f")"; done < "$WORK/unbalanced"
    fi
    exit 1
fi

if [ -s "$WORK/skipped" ]; then
    echo "=================================================================="
    echo "SKIPPED -- $(wc -l < "$WORK/skipped" | tr -d ' ') file(s) below have unresolved git conflict markers (<<<<<<< / ======= / >>>>>>>). A file in that state is not valid id source -- the function-count heuristic this tool uses can be thrown off by one side's unclosed brace, so any count for these could not be trusted either way. They are EXCLUDED from every count and proposal below. Resolve the conflicts and re-run to get a plan that covers them."
    while IFS= read -r f; do echo "  SKIPPED: $(rel "$f")"; done < "$WORK/skipped"
    echo "=================================================================="
    echo
fi

if [ -s "$WORK/unbalanced" ]; then
    echo "=================================================================="
    echo "UNBALANCED -- $(wc -l < "$WORK/unbalanced" | tr -d ' ') file(s) below have no conflict markers left but still have unbalanced braces at end of file (funcscan's depth count never returns to 0) -- typically a botched merge that spliced two sides' overlapping edits to the same closing brace. A function past the imbalance is invisible to the depth-0 heuristic this tool uses, so any count for these could not be trusted either way. They are EXCLUDED from every count and proposal below. Resolve the brace imbalance and re-run to get a plan that covers them."
    while IFS= read -r f; do echo "  UNBALANCED: $(rel "$f")"; done < "$WORK/unbalanced"
    echo "=================================================================="
    echo
fi

if [ ! -s "$WORK/file_violations" ] && [ ! -s "$WORK/dir_violations" ] && [ ! -s "$WORK/skipped" ] && [ ! -s "$WORK/unbalanced" ]; then
    echo "placeplan: $ROOT -- nothing to do (every file has at most 3 functions, every directory at most 3 entries)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Call graph, best-effort. See the header comment: a violation of either
# limit this tool exists for does not stop --calls from producing edges, so
# this is only empty when something else entirely is wrong with the tree.
CALLS_OK=0
env -u IDC_NO_STD "$IDC" "$ROOT" --calls > "$WORK/calls.out" 2> "$WORK/calls.err"
if [ -s "$WORK/calls.out" ]; then
    CALLS_OK=1
fi
awk -F'|' 'NF == 5 { print }' "$WORK/calls.out" > "$WORK/edges" 2>/dev/null || : > "$WORK/edges"
[ -f "$WORK/edges" ] || : > "$WORK/edges"
# adj: NAME<TAB>RELATED, both directions, builtins (empty callee loc) dropped.
awk -F'|' '$4 != "" { print $1"\t"$3; print $3"\t"$1 }' "$WORK/edges" | LC_ALL=C sort -u > "$WORK/adj"

if [ "$CALLS_OK" -eq 0 ]; then
    echo "NOTE: '$IDC' $ROOT --calls produced no edges (see below); every placement below falls back to \"no call-graph relation found\" instead of being ranked by one."
    echo "  --calls stderr:"
    sed 's/^/    /' "$WORK/calls.err"
    echo
fi

# ---------------------------------------------------------------------------
# Mutable planning state: every count starts at the filesystem scan's value
# and is overridden as proposals are made, so a later proposal in the same
# run sees the tree as it would stand after the earlier ones.
declare -A DIRCOUNT
declare -A FILECOUNT
declare -A DIRENTRIES   # dir path -> space-joined current entry basenames; populated on demand and kept in sync by dir_entries_remove/dir_entries_add as proposals are made
TOUCHED=()              # every path any proposal mentions, in first-touched order
TOUCH_KIND=()           # parallel: "file" or "dir"

touch_path() { # touch_path PATH KIND
    local p="$1" k="$2" existing
    for existing in "${TOUCHED[@]:-}"; do
        [ "$existing" = "$p" ] && return 0
    done
    TOUCHED+=("$p")
    TOUCH_KIND+=("$k")
}

dircount() {
    local d="$1"
    if [ -n "${DIRCOUNT[$d]+x}" ]; then printf '%s' "${DIRCOUNT[$d]}"; return; fi
    awk -F'|' -v d="$d" '$2 == d { print $1; f=1 } END { if (!f) print 0 }' "$WORK/dircounts"
}
set_dircount() { DIRCOUNT["$1"]="$2"; touch_path "$1" dir; }

filecount() {
    local f="$1"
    if [ -n "${FILECOUNT[$f]+x}" ]; then printf '%s' "${FILECOUNT[$f]}"; return; fi
    awk -F'|' -v f="$f" '$1 == f { print $2; found=1 } END { if (!found) print 0 }' "$WORK/filecounts"
}
set_filecount() { FILECOUNT["$1"]="$2"; touch_path "$1" file; }

dir_entries() { # dir_entries DIR -- current entry basenames, sorted, one per
                 # line, AS OF EVERY PRIOR PROPOSAL IN THIS RUN. build/ is only
                 # ever exempt at ROOT itself (idc/bin/idc's check_entry_limit
                 # prunes "$root/$BUILD_DIR" by full path, not by basename, so
                 # a directory named "build" nested elsewhere is an ordinary
                 # counted entry) -- matched here the same way, so this never
                 # disagrees with the dircounts scan above. Populated from disk
                 # on first call and cached from then on in DIRENTRIES, so a
                 # dir_entries_remove/dir_entries_add by an earlier proposal is
                 # what every later caller in the same run actually sees --
                 # this is the fix for two proposals independently picking the
                 # same still-on-disk entry to relocate to two different places.
    if [ -n "${DIRENTRIES[$1]+x}" ]; then
        [ -n "${DIRENTRIES[$1]}" ] && printf '%s\n' ${DIRENTRIES[$1]} | LC_ALL=C sort
        return 0
    fi
    if [ ! -d "$1" ]; then
        # A directory a proposal is about to create (mkdir -p in the plan,
        # never actually run) does not exist yet -- start it empty rather
        # than asking `find` to scan something that is not there.
        DIRENTRIES["$1"]=""
        return 0
    fi
    local prune_build="$1/$BUILD_DIR.never-matches-anything"
    [ "$1" = "$ROOT" ] && prune_build="$1/$BUILD_DIR"
    mapfile -t _de < <(find "$1" -mindepth 1 -maxdepth 1 \
         \( -type d -name '.*' -prune \) -o \
         \( -type d -path "$prune_build" -prune \) -o \
         \( -type d -printf '%f\n' \) -o \
         \( -name '*.id' ! -name 'conf.id' ! -name 'backend.id' -printf '%f\n' \) \
        | LC_ALL=C sort)
    DIRENTRIES["$1"]="${_de[*]:-}"
    [ "${#_de[@]}" -gt 0 ] && printf '%s\n' "${_de[@]}"
    return 0
}

dir_entries_remove() { # dir_entries_remove DIR NAME -- NAME no longer lives
                        # in DIR's cached entry list (call once a proposal
                        # moves it out), so a later proposal's search over DIR
                        # will not offer it again.
    dir_entries "$1" > /dev/null
    local -a cur=(${DIRENTRIES[$1]:-}) kept=()
    local e
    for e in "${cur[@]}"; do
        [ "$e" = "$2" ] || kept+=("$e")
    done
    DIRENTRIES["$1"]="${kept[*]:-}"
}

dir_entries_add() { # dir_entries_add DIR NAME -- NAME now lives in DIR's
                     # cached entry list (call once a proposal moves or
                     # creates it there).
    dir_entries "$1" > /dev/null
    DIRENTRIES["$1"]="${DIRENTRIES[$1]:-} $2"
}

dir_id_siblings() { # dir_id_siblings DIR EXCLUDE -- .id files DIR currently
                     # holds (per every prior proposal this run, not just the
                     # filesystem), excluding EXCLUDE and conf.id/backend.id
                     # (dir_entries never lists those) and subdirectories.
    local d="$1" excl="$2" e
    while IFS= read -r e; do
        case "$e" in
            *.id) [ "$e" = "$excl" ] || printf '%s\n' "$e" ;;
        esac
    done < <(dir_entries "$d")
}

shared_stage_word() { # shared_stage_word NAME... -- an underscore-separated
                       # word shared by at least two of the given identifiers
                       # (function names or file stems), and not itself equal
                       # to any whole one of them -- the closest this tool can
                       # come, from the signals it actually has (function
                       # names, sibling names), to a real "stage of work"
                       # word for a new subdirectory, rather than reusing one
                       # of the names it is trying to tell apart. Prints
                       # nothing and returns 1 if no such word exists.
    local -a names=("$@")
    local i j w1 w2 bad n
    local -a wa wb
    for ((i = 0; i < ${#names[@]}; i++)); do
        IFS='_' read -ra wa <<< "${names[$i]}"
        for ((j = i + 1; j < ${#names[@]}; j++)); do
            IFS='_' read -ra wb <<< "${names[$j]}"
            for w1 in "${wa[@]}"; do
                [ -z "$w1" ] && continue
                for w2 in "${wb[@]}"; do
                    if [ "$w1" = "$w2" ]; then
                        bad=0
                        for n in "${names[@]}"; do [ "$n" = "$w1" ] && bad=1; done
                        if [ "$bad" -eq 0 ]; then printf '%s' "$w1"; return 0; fi
                    fi
                done
            done
        done
    done
    return 1
}

related_score() { # related_score NAME SIBLING_FILE -- adj edges from NAME into functions of SIBLING_FILE
    awk -F'\t' -v name="$1" -v sib="$2" -v n2f="$WORK/name2file" '
        BEGIN { while ((getline l < n2f) > 0) { split(l, p, "\t"); f[p[1]] = p[2] }; close(n2f) }
        $1 == name && f[$2] == sib { c++ }
        END { print c + 0 }
    ' "$WORK/adj"
}

group_score() { # group_score SIBLING_FILE NAME... -- summed related_score over every NAME
    local sib="$1"; shift
    local total=0 n s
    for n in "$@"; do
        s=$(related_score "$n" "$sib")
        total=$((total + s))
    done
    echo "$total"
}

PLAN_OUT="$WORK/plan.txt"
: > "$PLAN_OUT"
plan() { printf '%s\n' "$*" >> "$PLAN_OUT"; }

# ---------------------------------------------------------------------------
# Directory-entry violations first: PROJECT.md section 3's remedy, generalised
# to any count. moved = count - 2 entries relocate into one new subdirectory,
# which is the smallest move that brings the directory back to 3 (count -
# moved existing entries + 1 new subdirectory entry == 3). If the moved set
# itself would then be a violation (count >= 6), it is split again the same
# way under a nested "more/" -- the literal precedent in PROJECT.md section 3.
place_name_for() { # place_name_for NAME... -- filename stem for a group, from its first (lowest-line) member
    echo "$1"
}

fix_dir_violation() { # fix_dir_violation DIR COUNT
    local dir="$1" count="$2" moved
    moved=$((count - 2))
    mapfile -t entries < <(dir_entries "$dir")
    local n=${#entries[@]}
    if [ "$moved" -ge "$n" ]; then moved=$((n - 1)); fi
    [ "$moved" -lt 1 ] && moved=1

    # Score every FILE entry by how connected it is to every other FILE
    # entry (sum of related_score in both directions, restricted to this
    # directory's own functions); a directory entry (subdirectory) is left
    # alone by this scoring and only moved if there is no other way to reach
    # the required count -- relocating a subtree needs a person to confirm
    # what else is nested under it, which this tool will not guess at.
    local -a files=() dirs=()
    local e
    for e in "${entries[@]}"; do
        if [ -d "$dir/$e" ]; then dirs+=("$e"); else files+=("$e"); fi
    done

    local -a chosen=()
    if [ "$CALLS_OK" -eq 1 ] && [ "${#files[@]}" -ge 2 ]; then
        # seed = the file with the highest total relatedness to its file
        # siblings in this directory; greedily add the most-related
        # remaining file until `moved` are chosen.
        local best_seed="" best_seed_score=-1 fa fb sc total
        for fa in "${files[@]}"; do
            total=0
            for fb in "${files[@]}"; do
                [ "$fa" = "$fb" ] && continue
                mapfile -t fa_names < <(awk -F'|' -v f="$dir/$fa" '$1==f{print $2}' "$WORK/funcs")
                sc=$(group_score "$dir/$fb" "${fa_names[@]:-__none__}")
                total=$((total + sc))
            done
            if [ "$total" -gt "$best_seed_score" ]; then best_seed_score=$total; best_seed="$fa"; fi
        done
        chosen=("$best_seed")
        while [ "${#chosen[@]}" -lt "$moved" ]; do
            local best="" best_score=-1
            for fa in "${files[@]}"; do
                local already=0 c
                for c in "${chosen[@]}"; do [ "$c" = "$fa" ] && already=1; done
                [ "$already" -eq 1 ] && continue
                total=0
                for fb in "${chosen[@]}"; do
                    mapfile -t fb_names < <(awk -F'|' -v f="$dir/$fb" '$1==f{print $2}' "$WORK/funcs")
                    sc=$(group_score "$dir/$fa" "${fb_names[@]:-__none__}")
                    total=$((total + sc))
                done
                if [ "$total" -gt "$best_score" ]; then best_score=$total; best="$fa"; fi
            done
            [ -z "$best" ] && break
            chosen+=("$best")
        done
    fi
    if [ "${#chosen[@]}" -lt "$moved" ]; then
        # No call graph, or too few files to score: alphabetically-last
        # entries (files preferred over subdirectories), deterministic.
        local -a pool=("${files[@]}" "${dirs[@]}")
        local need=$((moved - ${#chosen[@]}))
        local i=${#pool[@]}
        while [ "$need" -gt 0 ] && [ "$i" -gt 0 ]; do
            i=$((i - 1))
            local cand="${pool[$i]}" already=0 c
            for c in "${chosen[@]}"; do [ "$c" = "$cand" ] && already=1; done
            [ "$already" -eq 1 ] && continue
            chosen+=("$cand")
            need=$((need - 1))
        done
    fi

    local -a remaining=()
    for e in "${entries[@]}"; do
        local already=0 c
        for c in "${chosen[@]}"; do [ "$c" = "$e" ] && already=1; done
        [ "$already" -eq 0 ] && remaining+=("$e")
    done

    local -a chosen_stems=()
    for e in "${chosen[@]}"; do chosen_stems+=("${e%.id}"); done
    local subdir_name
    if [ "${#chosen_stems[@]}" -ge 2 ] && subdir_name=$(shared_stage_word "${chosen_stems[@]}"); then
        :
    else
        subdir_name="<needs-human-name>"
    fi
    local subdir="$dir/$subdir_name"
    plan "PROPOSAL: $(rel "$dir") has $count entries (limit 3); move ${#chosen[@]} of them into a new subdirectory"
    plan "  reason: minimum move that brings $(rel "$dir") back to 3 entries ($count - ${#chosen[@]} existing + 1 new subdirectory)"
    if [ "$subdir_name" = "<needs-human-name>" ]; then
        plan "  NOTE: no shared stage-of-work word could be derived from ${chosen_stems[*]} (function names, call-graph, sibling names) that wasn't just one of their own names -- pick a real directory name by hand instead of <needs-human-name>."
    fi
    plan "    mkdir -p \"$(rel "$subdir")\""
    local mv
    for mv in "${chosen[@]}"; do
        plan "    git mv \"$(rel "$dir")/$mv\" \"$(rel "$subdir")/$mv\""
        dir_entries_remove "$dir" "$mv"
        dir_entries_add "$subdir" "$mv"
    done
    plan ""

    local new_parent_count=$(( ${#remaining[@]} + 1 ))
    set_dircount "$dir" "$new_parent_count"

    if [ "${#chosen[@]}" -le 3 ]; then
        set_dircount "$subdir" "${#chosen[@]}"
    else
        local -a rest=("${chosen[@]:2}")
        plan "PROPOSAL: $(rel "$subdir") would itself hold ${#chosen[@]} entries (limit 3); nest the overflow under $(rel "$subdir")/more/ (docs/PROJECT.md section 3's own shift/more/tail.id shape)"
        plan "    mkdir -p \"$(rel "$subdir")/more\""
        for mv in "${rest[@]}"; do
            plan "    git mv \"$(rel "$subdir")/$mv\" \"$(rel "$subdir")/more/$mv\""
            dir_entries_remove "$subdir" "$mv"
            dir_entries_add "$subdir/more" "$mv"
        done
        plan ""
        set_dircount "$subdir" 3
        set_dircount "$subdir/more" "${#rest[@]}"
        if [ "${#rest[@]}" -gt 3 ]; then
            plan "  NOTE: $(rel "$subdir")/more still has ${#rest[@]} entries, over the limit -- re-run placeplan.sh after applying this proposal to plan the next split; this tool only nests one level automatically."
            plan ""
        fi
    fi
}

if [ -s "$WORK/dir_violations" ]; then
    while IFS='|' read -r c d; do
        fix_dir_violation "$d" "$c"
    done < "$WORK/dir_violations"
fi

# ---------------------------------------------------------------------------
# File function-count violations.
declare -A UF_PARENT
uf_find() { local x="$1"; while [ "${UF_PARENT[$x]}" != "$x" ]; do x="${UF_PARENT[$x]}"; done; echo "$x"; }
uf_union() {
    local ra rb; ra=$(uf_find "$1"); rb=$(uf_find "$2")
    [ "$ra" = "$rb" ] && return
    UF_PARENT["$ra"]="$rb"
}

fix_file_violation() { # fix_file_violation FILE COUNT
    local file="$1" count="$2" dir; dir=$(dirname "$file")
    mapfile -t ordered < <(awk -F'|' -v f="$file" '$1==f{print $3"|"$2}' "$WORK/funcs" | LC_ALL=C sort -t'|' -k1,1n | awk -F'|' '{print $2}')
    local keep=("${ordered[@]:0:3}")
    local surplus=("${ordered[@]:3}")

    local n
    UF_PARENT=()
    for n in "${surplus[@]}"; do UF_PARENT["$n"]="$n"; done
    local a b
    for a in "${surplus[@]}"; do
        for b in "${surplus[@]}"; do
            [ "$a" = "$b" ] && continue
            if grep -Fxq "$a"$'\t'"$b" "$WORK/adj" 2>/dev/null; then
                uf_union "$a" "$b"
            fi
        done
    done
    declare -A SGROUPS=()
    for n in "${surplus[@]}"; do
        local r; r=$(uf_find "$n")
        SGROUPS["$r"]="${SGROUPS[$r]:-} $n"
    done

    plan "PROPOSAL: $(rel "$file") has $count functions (limit 3); keeps ${keep[*]}"
    for r in "${!SGROUPS[@]}"; do
        local -a group=(${SGROUPS[$r]})
        # Sibling search: every other .id file dir_entries says DIR currently
        # holds (per prior proposals this run, not just the filesystem).
        mapfile -t sibling_names < <(dir_id_siblings "$dir" "$(basename "$file")")
        local -a siblings=()
        local sn
        for sn in "${sibling_names[@]}"; do siblings+=("$dir/$sn"); done
        local best_sib="" best_score=0
        local sib
        for sib in "${siblings[@]}"; do
            local sc; sc=$(group_score "$sib" "${group[@]}")
            local fc; fc=$(filecount "$sib")
            if [ "$sc" -gt 0 ] && [ $((fc + ${#group[@]})) -le 3 ] && [ "$sc" -gt "$best_score" ]; then
                best_score="$sc"; best_sib="$sib"
            fi
        done

        if [ -n "$best_sib" ]; then
            plan "  move ${group[*]} -> $(rel "$best_sib")"
            plan "    reason: $best_score call-graph edge(s) already connect this group to $(rel "$best_sib"), which has room ($(filecount "$best_sib") of 3 used)"
            plan "    (no mkdir/git mv here -- a function moving between two files that both already exist is a source edit, not a filesystem move: cut ${group[*]} out of $(basename "$file") by hand and paste into $(rel "$best_sib"))"
            plan ""
            set_filecount "$best_sib" $(( $(filecount "$best_sib") + ${#group[@]} ))
        else
            local dc; dc=$(dircount "$dir")
            local stem; stem=$(place_name_for "${group[@]}")
            local newfile="$dir/$stem.id"
            if [ $((dc + 1)) -le 3 ]; then
                plan "  move ${group[*]} -> new file $(rel "$newfile")"
                if [ "$CALLS_OK" -eq 1 ]; then
                    plan "    reason: no sibling in $(rel "$dir") both has room and is call-graph-connected to ${group[*]}; new file named for what it does, not what calls it"
                else
                    plan "    reason: no call-graph data available (see NOTE above); new file named for what it does -- confirm by hand that this is the right grouping"
                fi
                plan "    # placeplan does not edit .id files -- cut ${group[*]} out of $(basename "$file") by hand and paste into a new file at this path"
                plan ""
                set_filecount "$newfile" "${#group[@]}"
                set_dircount "$dir" $((dc + 1))
                dir_entries_add "$dir" "$stem.id"
            else
                mapfile -t dsibs < <(dir_id_siblings "$dir" "$(basename "$file")")
                local relocate=""
                if [ "${#dsibs[@]}" -gt 0 ]; then relocate="${dsibs[$((${#dsibs[@]} - 1))]}"; fi
                if [ -z "$relocate" ]; then
                    plan "  ${group[*]}: $(rel "$dir") is full (3 entries) and has no sibling file to relocate to make room -- NEEDS A PERSON: decide by hand where this goes."
                    plan ""
                else
                    local -a pool=("${group[@]}" "${relocate%.id}")
                    local osb
                    for osb in "${dsibs[@]}"; do
                        [ "$osb" = "$relocate" ] && continue
                        pool+=("${osb%.id}")
                    done
                    local subdir_name
                    if subdir_name=$(shared_stage_word "${pool[@]}"); then
                        :
                    else
                        subdir_name="<needs-human-name>"
                    fi
                    local subdir="$dir/$subdir_name"
                    plan "  move ${group[*]} -> new file $(rel "$subdir")/$stem.id, alongside $relocate relocated down to make room in $(rel "$dir")"
                    plan "    reason: $(rel "$dir") is already at 3 entries; $relocate is relocated (docs/PROJECT.md section 3's shift/{shift.id,...} shape) rather than adding a 4th entry to $(rel "$dir")"
                    if [ "$subdir_name" = "<needs-human-name>" ]; then
                        plan "    NOTE: no shared stage-of-work word could be derived from ${pool[*]} (function names, call-graph, sibling names) that wasn't just one of their own names -- pick a real directory name by hand instead of <needs-human-name>."
                    fi
                    plan "    mkdir -p \"$(rel "$subdir")\""
                    plan "    git mv \"$(rel "$dir")/$relocate\" \"$(rel "$subdir")/$relocate\""
                    plan "    # placeplan does not edit .id files -- cut ${group[*]} out of $(basename "$file") by hand and paste into a new file at $(rel "$subdir")/$stem.id"
                    plan ""
                    dir_entries_remove "$dir" "$relocate"
                    dir_entries_add "$subdir" "$relocate"
                    dir_entries_add "$subdir" "$stem.id"
                    dir_entries_add "$dir" "$subdir_name"
                    set_dircount "$dir" "$dc"
                    set_dircount "$subdir" 2
                    set_filecount "$subdir/$stem.id" "${#group[@]}"
                fi
            fi
        fi
    done
    set_filecount "$file" "${#keep[@]}"
    plan ""
}

if [ -s "$WORK/file_violations" ]; then
    while IFS='|' read -r f c; do
        fix_file_violation "$f" "$c"
    done < "$WORK/file_violations"
fi

# ---------------------------------------------------------------------------
echo "placeplan: $ROOT"
echo "violations: $(wc -l < "$WORK/file_violations" | tr -d ' ') file(s) over 3 functions, $(wc -l < "$WORK/dir_violations" | tr -d ' ') director(y/ies) over 3 entries, $(wc -l < "$WORK/skipped" | tr -d ' ') file(s) skipped (conflict markers -- see SKIPPED above, not covered by anything below), $(wc -l < "$WORK/unbalanced" | tr -d ' ') file(s) skipped (unbalanced braces -- see UNBALANCED above, not covered by anything below)"
echo
cat "$PLAN_OUT"

echo "VERIFICATION -- every path this plan touches, count after the plan is applied:"
i=0
for p in "${TOUCHED[@]:-}"; do
    [ -z "$p" ] && { i=$((i+1)); continue; }
    k="${TOUCH_KIND[$i]}"
    if [ "$k" = "dir" ]; then
        v=$(dircount "$p")
        status="ok"
        [ "$v" -gt 3 ] && status="STILL OVER LIMIT"
        echo "  $(rel "$p"): $v entries ($status)"
    else
        v=$(filecount "$p")
        status="ok"
        [ "$v" -gt 3 ] && status="STILL OVER LIMIT"
        echo "  $(rel "$p"): $v functions ($status)"
    fi
    i=$((i+1))
done
