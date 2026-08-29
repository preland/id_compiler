#!/usr/bin/env bash
# Rewrite bootstrap/idlex.c and bootstrap/idparse.c from the working tree.
#
#   tools/regen_bootstrap.sh          # rewrite both
#   tools/regen_bootstrap.sh --check  # exit 1 if they are not what the tree emits
#
# Stage 0 is a snapshot of the compiler as C (bootstrap/README.md). It has to
# move forward exactly once: in the commit that teaches the compiler a construct
# the compiler's own source is about to start using. --check is what makes that
# a rule rather than an intention -- tests/run.sh calls it, so a tree whose
# stage 0 has drifted says so before anyone hits "stage 0 cannot compile this".
#
# The emission runs through the CURRENT bin/idc, which means through stage 1,
# which was itself built from the working tree. So this writes what the tree
# says, not what stage 0 says -- and if the two disagree the disagreement is the
# point of running it.
set -u
cd "$(dirname "$0")/.."

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0

for stage in lex parse; do
    out="bootstrap/id${stage}.c"
    # -u IDC_NO_STD for the reason bin/idc's own bootstrap does it: both stages
    # call idstd's lset, so the compiler is never built without the library,
    # whatever a caller wants for its own programs.
    if ! env -u IDC_NO_STD bin/idc "compiler/$stage" --emit-c "$TMP/id${stage}.c" >/dev/null; then
        echo "regen_bootstrap: emitting C for compiler/$stage failed" >&2
        exit 1
    fi
    if [ "$CHECK" -eq 1 ]; then
        if cmp -s "$TMP/id${stage}.c" "$out"; then
            echo "ok    $out is what compiler/$stage emits"
        else
            echo "STALE $out is not what compiler/$stage emits -- run tools/regen_bootstrap.sh" >&2
            rc=1
        fi
    else
        # Only touch the file when the bytes differ, so a no-op run leaves the
        # mtime alone and bin/idc does not rebuild stage 0 for nothing.
        if cmp -s "$TMP/id${stage}.c" "$out"; then
            echo "ok    $out unchanged"
        else
            cp "$TMP/id${stage}.c" "$out" || exit 1
            echo "wrote $out ($(wc -l < "$out") lines, $(wc -c < "$out") bytes)"
        fi
    fi
done

exit "$rc"
