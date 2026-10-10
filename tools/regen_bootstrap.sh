#!/usr/bin/env bash
# Rewrite bootstrap/idlex.c and bootstrap/idparse.c from the working tree.
#
#   tools/regen_bootstrap.sh          # rewrite both
#   tools/regen_bootstrap.sh --check  # exit 1 if they are not what the tree emits
#   tools/regen_bootstrap.sh STEP     # one step of the above, see below
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
#
# Why steps: warm the whole thing is two seconds, cold it is minutes, and no
# command may run for a minute. The cold cost is four separate pieces, so each
# is a step that prints one result line and fits in a minute on its own:
#
#   stages       build stage 0 from bootstrap/*.c and stage 1 from compiler/
#   lex          emit C for compiler/lex (this carries the library's pre-check)
#   parse-front  check compiler/parse, which fills the front-end cache
#   emit         emit C for compiler/parse, from that cache
#   compare      put the two emitted files beside bootstrap/ (or, with --check,
#                compare them with it)
#
# With no step they run in that order. A step whose inputs have not changed since
# it last succeeded prints "skip" and does nothing, so a run that was stopped
# resumes at the step that was cut short. Inputs are bin/idc, bootstrap/,
# compiler/, runtime/, driver/, interop/ and the standard library the build
# merges; the record is kept in the compiler cache, under regen/.
set -u
cd "$(dirname "$0")/.."

CHECK=0
STEPS=()
for arg in "$@"; do
    case "$arg" in
        --check) CHECK=1 ;;
        stages|lex|parse-front|emit|compare) STEPS+=("$arg") ;;
        *) echo "regen_bootstrap: unknown argument '$arg' (steps: stages lex parse-front emit compare; or --check)" >&2; exit 2 ;;
    esac
done
[ "${#STEPS[@]}" -eq 0 ] && STEPS=(stages lex parse-front emit compare)

STATE="${IDC_CACHE_DIR:-$PWD/.idc-cache}/regen"
mkdir -p "$STATE" || exit 1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

STD_ROOT=$(env -u IDC_NO_STD bin/idc compiler/lex --print-std 2>/dev/null)
KEY=$({ find bin compiler runtime driver interop ${STD_ROOT:+"$STD_ROOT"} -type f \
            \( -name '*.id' -o -name '*.c' -o -name '*.h' -o -name idc \) \
            -not -path "$STD_ROOT/build/*" -print0 | sort -z | xargs -0 md5sum; } | md5sum | cut -d' ' -f1)
BOOT_KEY=$(cat bootstrap/idlex.c bootstrap/idparse.c | md5sum | cut -d' ' -f1)

step_key() {
    printf '%s' "$KEY$BOOT_KEY"
}

current() {
    [ "$(cat "$STATE/$1.stamp" 2>/dev/null)" = "$(step_key "$1")" ] && { [ -z "${2:-}" ] || [ -f "$STATE/$2" ]; }
}

emit_c() {
    env -u IDC_NO_STD bin/idc "compiler/$1" --allow-untested --emit-c "$STATE/id$1.c" >"$TMP/step.out" 2>&1
}

step_stages() {
    printf 'main(int argc, string[] argv) {\n  int a = 1;\n} return int a;\n' > "$STATE/stages.id"
    env -u IDC_NO_STD bin/idc "$STATE/stages.id" --allow-untested --check >"$TMP/step.out" 2>&1
}

step_lex() { emit_c lex; }

step_parse_front() {
    env -u IDC_NO_STD bin/idc compiler/parse --allow-untested --check >"$TMP/step.out" 2>&1
}

step_emit() { emit_c parse; }

step_compare() {
    local stage out rc=0
    for stage in lex parse; do
        out="bootstrap/id${stage}.c"
        if [ ! -f "$STATE/id${stage}.c" ]; then
            echo "regen_bootstrap: no emitted C for compiler/$stage yet -- run the lex and emit steps first" >&2
            return 1
        fi
        if cmp -s "$STATE/id${stage}.c" "$out"; then
            continue
        elif [ "$CHECK" -eq 1 ]; then
            echo "STALE $out is not what compiler/$stage emits -- run tools/regen_bootstrap.sh" >&2
            rc=1
        else
            cp "$STATE/id${stage}.c" "$out" || return 1
            echo "wrote $out ($(wc -l < "$out") lines, $(wc -c < "$out") bytes)"
        fi
    done
    return "$rc"
}

run_step() {
    local name="$1" fn="step_${1//-/_}" output="" started=$SECONDS
    case "$name" in
        lex) output=idlex.c ;;
        emit) output=idparse.c ;;
    esac
    if [ "$name" != compare ] && current "$name" "$output"; then
        echo "skip  $name (inputs unchanged since it last succeeded)"
        return 0
    fi
    if "$fn"; then
        [ "$name" = compare ] || step_key "$name" > "$STATE/$name.stamp"
        echo "ok    $name ($((SECONDS - started))s)"
        return 0
    fi
    echo "FAIL  $name: $(grep -v 'warning:' "$TMP/step.out" 2>/dev/null | head -1)" >&2
    return 1
}

rc=0
for name in "${STEPS[@]}"; do
    run_step "$name" || { rc=1; break; }
done
exit "$rc"
