#!/usr/bin/env bash
# casework.sh -- help write the two test cases every id function needs.
#
#   tools/casework.sh list   PATH [SUBDIR]        functions short of two cases
#   tools/casework.sh packet PATH FILE:LINE       what a case writer needs to read
#   tools/casework.sh verify PATH                 build with every case running
#   tools/casework.sh mutate PATH FILE:LINE [N]   break the function, rebuild,
#                                                 restore; did a case notice?
#
# PATH is what bin/idc builds (a project tree, e.g. compiler/parse or an idstd
# checkout). FILE:LINE is a row from `list`: the function's header line.
#
# The workflow this supports (docs/TESTS.md has the case syntax):
#   1. `packet` a function and say, in one sentence, what it is for.
#   2. Write two concrete examples in plain terms: these inputs (and this state)
#      give this output (or this printed text, or these calls).
#   3. Only then write them as cases, under the function.
#   4. `verify`; then `mutate` to see that a case fails when the logic is wrong.
#
# `mutate` changes the N-th candidate (default 1) in the function's body: a
# comparison or arithmetic operator is flipped, or else an integer literal is
# increased by one. It always restores the file, even when interrupted. A
# mutation that no case notices is reported as SURVIVED; that means the cases
# do not pin down that part of the function (or the mutation happened to be
# equivalent -- try N=2).
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
IDC="$HERE/bin/idc"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

die() { echo "casework: $*" >&2; exit 2; }

fn_end() {
    awk -v s="$2" 'NR > s && /^\} *return/ { print NR; exit }' "$1"
}

build() {
    env -u IDC_NO_STD "$IDC" "$1" --allow-untested --emit-c "$WORK/out.c" >"$WORK/build.log" 2>&1
    grep ': test failed' "$WORK/build.log"
    grep -E ': error:' "$WORK/build.log" | head -20
}

cmd_list() {
    local path="$1" sub="${2:-}"
    env -u IDC_NO_STD "$IDC" "$path" --list-untested 2>/dev/null \
        | awk -F'|' -v under="$sub" '$1 == "short" && index($2, under) { print $2 "  " $3 "  (" $4 " case" ($4 == 1 ? "" : "s") ")" }'
}

cmd_packet() {
    local path="$1" loc="$2" file line end name
    file=${loc%:*}; line=${loc##*:}
    [ -f "$file" ] || die "no such file: $file"
    end=$(fn_end "$file" "$line")
    [ -n "$end" ] || die "no '} return' after $loc"
    name=$(sed -n "${line}p" "$file" | sed -E 's/^([a-z_][a-z0-9_]*)\(.*/\1/')
    echo "== $name  ($loc)"
    echo "-- source and existing cases"
    awk -v s="$line" -v e="$end" 'NR >= s && NR <= e { print; next } NR > e && /^(\(|given )/ { print; next } NR > e { exit }' "$file"
    echo "-- comment above it"
    awk -v s="$line" 'NR < s { buf = ($0 ~ /^\/\//) ? buf $0 "\n" : "" } NR == s { printf "%s", buf; exit }' "$file"
    echo "-- callers (first 8)"
    grep -rn --include='*.id' -E "(^|[^a-z0-9_])$name\(" "$path" | grep -v "^$file:$line:" | head -8
    echo "-- imports it reads, and where they are declared"
    sed -n "${line},${end}p" "$file" | grep -oE '\(import [a-z_][a-z0-9_]*\)' | sort -u | while read -r _ imp; do
        imp=${imp%)}
        where=$(grep -rn --include='*.id' -E "export [a-z]+(\[\])* $imp\b|^[a-z]+(\[\])* $imp =" "$path" 2>/dev/null | head -1)
        echo "$imp: ${where:-not found under $path}"
    done
    echo "-- given setups used in this directory and its parent"
    grep -rhoE '^given [a-z_][a-z0-9_]*' "$(dirname "$file")" "$(dirname "$(dirname "$file")")" --include='*.id' 2>/dev/null \
        | sort | uniq -c | sort -rn | head -6
}

cmd_verify() {
    local out
    out=$(build "$1")
    if [ -n "$out" ]; then
        echo "$out"
        echo "casework: FAIL ($(echo "$out" | wc -l) problem line(s))"
        return 1
    fi
    echo "casework: ok -- every case passes"
}

mutate_awk='
function flip(t) {
    if (t == "==") return "!="; if (t == "!=") return "==";
    if (t == "<=") return ">";  if (t == ">=") return "<";
    if (t == "<")  return ">="; if (t == ">")  return "<=";
    if (t == "+")  return "-";  if (t == "-")  return "+";
    if (t == "*")  return "+";  if (t == "&&") return "||"; if (t == "||") return "&&";
    return t
}
NR <= s || NR >= e { print; next }
{
    line = $0; out = ""; q = 0; i = 1; n = length(line)
    while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\"") { q = !q; out = out c; i++; continue }
        if (!q && !done && substr(line, i, 3) ~ /^ (==|!=|<=|>=|&&|\|\|) $/) {
            k++; if (k == want) { out = out " " flip(substr(line, i + 1, 2)) " "; i += 4; done = 1; continue }
        }
        if (!q && !done && substr(line, i, 3) ~ /^ [<>+*-] $/) {
            k++; if (k == want) { out = out " " flip(substr(line, i + 1, 1)) " "; i += 3; done = 1; continue }
        }
        out = out c; i++
    }
    print out
}
END { if (!done) exit 3 }'

mutate_lit_awk='
NR <= s || NR >= e { print; next }
{
    if (!done && match($0, /[^a-zA-Z0-9_"][0-9]+([^a-zA-Z0-9_]|$)/)) {
        lit = substr($0, RSTART + 1, RLENGTH - 1); sub(/[^0-9].*$/, "", lit)
        $0 = substr($0, 1, RSTART) (lit + 1) substr($0, RSTART + 1 + length(lit)); done = 1
    }
    print
}
END { if (!done) exit 3 }'

cmd_mutate() {
    local path="$1" loc="$2" want="${3:-1}" line end name out
    CW_FILE=${loc%:*}; line=${loc##*:}
    local file="$CW_FILE"
    [ -f "$file" ] || die "no such file: $file"
    end=$(fn_end "$file" "$line")
    [ -n "$end" ] || die "no '} return' after $loc"
    name=$(sed -n "${line}p" "$file" | sed -E 's/^([a-z_][a-z0-9_]*)\(.*/\1/')
    CW_BACKUP="$WORK/backup.id"
    local backup="$CW_BACKUP"
    cp "$file" "$backup"
    trap 'cp "$CW_BACKUP" "$CW_FILE"; rm -rf "$WORK"' EXIT INT TERM
    if ! awk -v s="$line" -v e="$end" -v want="$want" "$mutate_awk" "$backup" >"$WORK/m.id"; then
        awk -v s="$line" -v e="$end" "$mutate_lit_awk" "$backup" >"$WORK/m.id" \
            || { cp "$backup" "$file"; die "$name: nothing to mutate (no operator or integer literal in its body)"; }
    fi
    cp "$WORK/m.id" "$file"
    echo "-- mutation in $name:"
    diff "$backup" "$file" | grep '^[<>]'
    out=$(build "$path")
    cp "$backup" "$file"
    if echo "$out" | grep -q "test failed: $name("; then
        echo "casework: KILLED -- a case of $name failed:"
        echo "$out" | grep "test failed: $name(" | head -3
    elif echo "$out" | grep -q 'test failed'; then
        echo "casework: KILLED (indirectly) -- another function's case failed:"
        echo "$out" | grep 'test failed' | head -3
    elif echo "$out" | grep -q ': error:'; then
        echo "casework: INVALID -- the mutation did not compile; try N=$((want + 1))"
    else
        echo "casework: SURVIVED -- no case noticed; the cases do not pin this down (or try N=$((want + 1)))"
        return 1
    fi
}

[ $# -ge 2 ] || die "usage: casework.sh list|packet|verify|mutate PATH [...] (see the header of this file)"
cmd="$1"; shift
case "$cmd" in
    list)   cmd_list "$@" ;;
    packet) [ $# -ge 2 ] || die "packet PATH FILE:LINE"; cmd_packet "$@" ;;
    verify) cmd_verify "$1" ;;
    mutate) [ $# -ge 2 ] || die "mutate PATH FILE:LINE [N]"; cmd_mutate "$@" ;;
    *)      die "unknown command '$cmd'" ;;
esac
