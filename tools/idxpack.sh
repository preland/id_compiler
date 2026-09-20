#!/usr/bin/env bash
# idxpack.sh -- transitive-closure index for id test-case writing.
#
#   tools/idxpack.sh build PATH OUTDIR
#       The expensive step, done once per project: builds tools/idxpack and
#       runs `idc PATH --calls` once, writing OUTDIR/index.txt (the
#       reshaped EDGES/FUNCS/FILES sections tools/idxpack/main.id reads)
#       and OUTDIR/idxpack.bin (the compiled binary). Re-run after cases
#       land so later queries see the updated case counts.
#
#   tools/idxpack.sh query OUTDIR TARGET
#       Cheap: reads OUTDIR/index.txt (no rebuild, no re-run of --calls) and
#       prints three blank-line-separated lists for TARGET: its transitive
#       call closure (BFS over "call" edges), the exported names that
#       closure reads anywhere (the transitive-import fix over
#       casework.sh packet's own-body-only grep), and every zero-parameter
#       void function in the build whose own transitive closure reaches
#       every one of those exports' declaring functions -- the legal
#       `given` setups.
#
#   tools/idxpack.sh PATH TARGET
#       One-shot convenience, equivalent to `build` into a throwaway
#       directory followed by one `query` -- pays the full --calls cost
#       every time, same as always calling `build` fresh. Use `build` once
#       and `query` per target when checking more than one function.
#
# All the actual reasoning (the graph BFS, the export-declaration scan, the
# candidate search) is in tools/idxpack/, written in id; this script only
# builds the binary, runs `idc PATH --calls` once, and reshapes its two
# kinds of row into the three-section format tools/idxpack/main.id expects
# -- field splitting and string concatenation, not the logic that answers
# the question. See tools/idxpack/main.id's header comment for the exact
# wire format.
#
# CURRENT LIMITS (see the validation report for the full account):
#   - Only a single TARGET per query, and only the `given`-setup search --
#     structural slots, candidate `then` checks, fold-candidate flagging,
#     and a `select`/`pack`/multi-function batch mode are designed
#     (docs in the skill) but not wired into this script or the id binary
#     yet.
#   - A name with no declaring function found among project/idstd function
#     bodies (a conf.id constant, most commonly, but also a genuine typo)
#     is silently DROPPED from the required set rather than reported --
#     docs/PROJECT.md says a conf.id constant needs no setup at all, but
#     this cannot yet tell that case apart from an import this tool simply
#     failed to find a declarer for. Read the imports list yourself.
#   - The candidate-given list can be large (measured: 453 for one real
#     function) when many fixtures in the project chain through a few
#     common "mega setup" functions -- correct, but not ranked or
#     filtered, so skim rather than assume the first entry is the best fit.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
IDC="$HERE/bin/idc"

die() { echo "idxpack.sh: $*" >&2; exit 2; }

build_index() {
    local proj="$1" outdir="$2" work
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN

    env -u IDC_NO_STD "$IDC" "$HERE/tools/idxpack" --allow-untested -o "$outdir/idxpack.bin" >&2 \
        || die "failed to build tools/idxpack"

    env -u IDC_NO_STD "$IDC" "$proj" --calls > "$work/calls.out" 2>"$work/calls.err"
    local rc=$?
    if [ ! -s "$work/calls.out" ]; then
        cat "$work/calls.err" >&2
        die "'$IDC' $proj --calls produced no output (exit $rc)"
    fi
    [ -s "$work/calls.err" ] && cat "$work/calls.err" >&2

    # Edges: "caller|caller_loc|callee|callee_loc|kind" (5 fields) -> the id
    # side only ever compares names, never a location, so those two fields
    # are dropped here rather than parsed twice.
    awk -F'|' 'NF == 5 { print $1 "|" $3 "|" $5 }' "$work/calls.out" > "$work/edges.txt"

    # Case-count rows: "name|file:line|cases" (3 fields, plus a literal
    # "fn" header row) -> "name|file|line|cases" (4 fields), splitting on
    # the LAST colon the way casework.sh's ${loc##*:} does (a POSIX path
    # never contains one, but splitting on the last occurrence costs
    # nothing and is honest about why it's safe).
    awk -F'|' '
        NF == 3 && $1 != "fn" {
            loc = $2
            n = split(loc, a, ":")
            file = a[1]
            for (k = 2; k < n; k++) file = file ":" a[k]
            line = a[n]
            print $1 "|" file "|" line "|" $3
        }
    ' "$work/calls.out" > "$work/funcs.txt"

    # Every file named in the function table, concatenated with a
    # "===F:<path>===" marker before each -- the only file I/O
    # idxpack/main.id needs, done here because `id` has no argv-path
    # file-reading of its own (docs/PROJECT.md section 7: stdin and stdout
    # only, absent a native backend) and shelling out per-file from inside
    # the id binary would need the ipc/proc backend for no real gain over
    # a `cat` loop already running in the wrapper that has the file list.
    : > "$work/files.txt"
    cut -d'|' -f2 "$work/funcs.txt" | LC_ALL=C sort -u | while IFS= read -r f; do
        [ -f "$f" ] || { echo "idxpack.sh: warning: function table names a file that does not exist, skipping: $f" >&2; continue; }
        echo "===F:$f==="
        cat "$f"
    done >> "$work/files.txt"

    {
        echo "===EDGES==="
        cat "$work/edges.txt"
        echo "===FUNCS==="
        cat "$work/funcs.txt"
        echo "===FILES==="
        cat "$work/files.txt"
    } > "$outdir/index.txt"
}

query_index() {
    local outdir="$1" target="$2"
    [ -f "$outdir/index.txt" ] || die "no $outdir/index.txt -- run 'idxpack.sh build PATH $outdir' first"
    [ -x "$outdir/idxpack.bin" ] || die "no $outdir/idxpack.bin -- run 'idxpack.sh build PATH $outdir' first"
    "$outdir/idxpack.bin" "$target" < "$outdir/index.txt"
}

case "${1:-}" in
    build)
        [ $# -eq 3 ] || die "usage: idxpack.sh build PATH OUTDIR"
        [ -e "$2" ] || die "no such path: $2"
        mkdir -p "$3"
        build_index "$2" "$3"
        ;;
    query)
        [ $# -eq 3 ] || die "usage: idxpack.sh query OUTDIR TARGET"
        query_index "$2" "$3"
        ;;
    *)
        [ $# -eq 2 ] || die "usage: idxpack.sh PATH TARGET | idxpack.sh build PATH OUTDIR | idxpack.sh query OUTDIR TARGET"
        [ -e "$1" ] || die "no such path: $1"
        WORK=$(mktemp -d)
        trap 'rm -rf "$WORK"' EXIT
        build_index "$1" "$WORK"
        query_index "$WORK" "$2"
        ;;
esac
