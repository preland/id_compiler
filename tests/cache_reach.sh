#!/usr/bin/env bash
# The case-result cache is exact: a change reruns the cases that can reach it
# and no others. bin/idc's case keys (compiler/parse/mid/form/unique/dump/
# digest/) hash a case's own tokens and everything it can reach -- the functions
# it calls, the exports it reads, and the conf.id constants it reads, through
# other constants' initialisers too -- so editing a constant nothing reads must
# rerun nothing, and editing one a case reads must rerun exactly the cases that
# read it. The count is read from IDC_CASE_STATS, not timed; cache.sh covers the
# same cache by time and is a separate file because it is over a minute.
#
# Run from anywhere: tests/cache_reach.sh
set -u
cd "$(dirname "$0")"
BIN_IDC="../bin/idc --allow-untested"
unset IDSTD_HOME IDC_NO_CACHE

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
rc_of() { cat "$TMP/$1.rc"; }

CACHE="$TMP/cache"
mkdir -p "$CACHE"
for f in idlex0 idparse0 idlex idparse ccrun idlayout; do
    [ -x "../.idc-cache/$f" ] && cp "../.idc-cache/$f" "$CACHE/"
done
export IDC_CACHE_DIR="$CACHE"

# Counted, not timed: IDC_CASE_STATS=1 makes the build say how many of its cases
# were already passed and how many it had to run. The fixture has 18 cases over
# these functions (two each) and conf.id constants:
#
#   plain, uses_plain   uses_plain calls plain; neither reads a constant
#   rd_ub               reads ub (its test differs in shape from rd_ua and rd_ex, which
#                       the import-only duplicate rule would otherwise reject)
#   rd_ua               reads ua
#   rd_ul               reads ul, a list whose initialiser reads ua
#   mk_ex, ex_up, rd_ex mk_ex declares the export ex_v, ex_up is the setup that
#                       calls it, rd_ex reads it and its cases `given ex_up`
#   main                reads nothing
#
# and uu, which nothing reads. Every function's result is the same whatever a
# constant's value, so an edit to one is a change the cases must be rerun for
# without any of them failing.
CST="$TMP/cst"; mkdir -p "$CST/reads" "$CST/ex"
cat > "$CST/conf.id" <<'EOF'
int ua = 3;
int ub = 4;
int uu = 9;
int[] ul = [(import ua), 7];
EOF
cat > "$CST/main.id" <<'EOF'
plain(int a) {
  int b = a * 2;
} return int b;
(1):(2)
(3):(6)

uses_plain(int a) {
  int b = plain(a) + 1;
} return int b;
(1):(3)
(3):(7)

main(int argc, string[] argv) {
  print("ok");
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
cat > "$CST/reads/r.id" <<'EOF'
rd_ua(int a) {
  int b = a;
  if((import ua) > 0) {
    b = a + 1;
  }
} return int b;
(1):(2)
(2):(3)

rd_ub(int a) {
  int b = a;
  if((import ub) > 0 && a >= 0) {
    b = a + 1;
  }
} return int b;
(1):(2)
(2):(3)

rd_ul(int a) {
  int b = a;
  if((import ul)[0] > 0) {
    b = a + 1;
  }
} return int b;
(1):(2)
(2):(3)
EOF
cat > "$CST/ex/e.id" <<'EOF'
mk_ex(int a) {
  export int ex_v = 5;
  int b = a;
} return int b;
(1):(1)
(2):(2)

ex_up(int a) {
  int d = mk_ex(a);
} return void;
(1):()
(2):()

rd_ex(int a) {
  int b = a;
  if((import ex_v) >= 0) {
    b = a + 1;
  }
} return int b;
given ex_up(1) (1):(2)
given ex_up(2) (2):(3)
EOF
cst_build() {
    local name="$1"
    IDC_CASE_STATS=1 $BIN_IDC "$CST" -o "$TMP/$name" --no-std >"$TMP/$name.out" 2>&1
    echo $? > "$TMP/$name.rc"
    sed -n 's/^idc: cases: \([0-9]*\) total, \([0-9]*\) already passed, \([0-9]*\) to run$/\1 \2 \3/p' "$TMP/$name.out" > "$TMP/$name.st"
}
cst_total() { awk '{print $1}' "$TMP/$1.st"; }
cst_hits()  { awk '{print $2}' "$TMP/$1.st"; }
cst_runs()  { awk '{print $3}' "$TMP/$1.st"; }
cst_expect() {
    local name="$1" runs="$2" what="$3"
    if [ "$(rc_of "$name")" -eq 0 ] && [ "$(cst_total "$name")" = 18 ] && [ "$(cst_runs "$name")" = "$runs" ] \
       && [ "$(cst_hits "$name")" = $((18 - runs)) ]; then
        ok "$what: $runs of 18 cases rerun"
    else
        bad "$what: want $runs of 18 cases rerun (rc $(rc_of "$name"), stats '$(cat "$TMP/$name.st")'): $(head -2 "$TMP/$name.out")"
    fi
}

cst_build ct1
cst_expect ct1 18 "a cold build runs every case"
cst_build ct2
cst_expect ct2 0 "an identical rebuild"
sed -i 's/^int uu = 9;/int uu = 10;/' "$CST/conf.id"
cst_build ct3
cst_expect ct3 0 "editing a constant nothing reads"
sed -i 's/^int ub = 4;/int ub = 5;/' "$CST/conf.id"
cst_build ct4
cst_expect ct4 2 "editing a constant one function's two cases read"
sed -i 's/^int ua = 3;/int ua = 4;/' "$CST/conf.id"
cst_build ct5
cst_expect ct5 4 "editing a constant a function reads, and a list constant's initialiser reads"
sed -i 's/a \* 2/2 * a/' "$CST/main.id"
cst_build ct6
cst_expect ct6 4 "editing a function reruns its own cases and its caller's, and nothing else"
sed -i 's/export int ex_v = 5;/export int ex_v = 6;/' "$CST/ex/e.id"
cst_build ct7
cst_expect ct7 6 "editing an exporting function reruns its readers' cases, its setup's and its own, and nothing else"
cst_build ct8
cst_expect ct8 0 "a rebuild after all of those"

# A scalar constant initialised by another is folded when it is parsed, so the
# emitted code for `fb` no longer reads `fa`. A case that reads `fb` must still
# be keyed on `fa`'s tokens: this edit changes the value it computes, and the
# cached result would be stale if the key only saw `fb`'s own tokens.
CSF="$TMP/csf"; mkdir -p "$CSF"
cat > "$CSF/conf.id" <<'EOF2'
int fa = 3;
int fb = (import fa);
EOF2
cat > "$CSF/main.id" <<'EOF2'
rd_fb(int a) {
  int b = a * 2 + (import fb);
} return int b;
(1):(5)
(2):(7)

main(int argc, string[] argv) {
  print("fold");
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF2
csf_build() {
    IDC_CASE_STATS=1 $BIN_IDC "$CSF" -o "$TMP/$1" --no-std >"$TMP/$1.out" 2>&1
    echo $? > "$TMP/$1.rc"
    sed -n 's/^idc: cases: \([0-9]*\) total, \([0-9]*\) already passed, \([0-9]*\) to run$/\1 \2 \3/p' "$TMP/$1.out" > "$TMP/$1.st"
}
csf_build cf1
if [ "$(rc_of cf1)" -eq 0 ] && [ "$(cst_runs cf1)" = 4 ]; then ok "a folded constant: a cold build runs every case"; else bad "a folded constant: cold build (rc $(rc_of cf1), stats '$(cat "$TMP/cf1.st")'): $(head -2 "$TMP/cf1.out")"; fi
sed -i 's/^int fa = 3;/int fa = 5;/; s/(1):(5)/(1):(7)/; s/(2):(7)/(2):(9)/' "$CSF/conf.id" "$CSF/main.id"
csf_build cf2
if [ "$(rc_of cf2)" -eq 0 ] && [ "$(cst_runs cf2)" = 2 ]; then ok "a folded constant: editing the constant it was initialised from reruns the cases that read it"; else bad "a folded constant: edit of its source (rc $(rc_of cf2), stats '$(cat "$TMP/cf2.st")'): $(head -2 "$TMP/cf2.out")"; fi


# Every case is cached, a scaling claim's and one that reads the clock
# included, and a pass is trusted for IDC_CASE_MAX_AGE_DAYS (7) days: the
# pass list stamps each entry, and an older one reruns. IDC_FRESH_CASES=PATH
# reruns the cases of the tree at PATH and nothing else. The fixture has eight
# cases: plain (2), stamped (2, reads the clock), linear (2, one scaling
# claim) and main (2).
CSA="$TMP/csa"; mkdir -p "$CSA"
cat > "$CSA/main.id" <<'EOF2'
age_double(int a) {
  int b = a * 2;
} return int b;
(1):(2)
(3):(6)

main(int argc, string[] argv) {
  print("age");
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF2
cat > "$CSA/more.id" <<'EOF2'
stamped(int a) {
  int t = ticks();
  int b = a;
  if(t < 0) {
    b = 0 - 1;
  }
} return int b;
(1):(1)
(2):(2)

linear(int[] xs) {
  int s = 0;
  int i = 0;
  while(i < len(xs)) {
    s = s + xs[i];
    i = i + 1;
  }
} return int s;
([1, 2, 3, 4]):(10)[time:O(n), mem:O(1)]
([1, 2, 3, 4, 5, 6, 7, 8]):(36)[time:O(n), mem:O(1)]
EOF2
csa_build() {
    IDC_CASE_STATS=1 $BIN_IDC "${2:-$CSA}" -o "$TMP/$1" --no-std >"$TMP/$1.out" 2>&1
    echo $? > "$TMP/$1.rc"
    sed -n 's/^idc: cases: \([0-9]*\) total, \([0-9]*\) already passed, \([0-9]*\) to run$/\1 \2 \3/p' "$TMP/$1.out" > "$TMP/$1.st"
}
csa_expect() {
    if [ "$(rc_of "$1")" -eq 0 ] && [ "$(cst_total "$1")" = 8 ] && [ "$(cst_runs "$1")" = "$2" ]; then ok "$3: $2 of 8 cases run"; else bad "$3 (rc $(rc_of "$1"), stats '$(cat "$TMP/$1.st")'): $(head -2 "$TMP/$1.out")"; fi
}
csa_age() {
    local list then
    then=$(( $(date +%s) - $1 * 86400 ))
    for list in "$CACHE"/cases/*; do
        awk -F'\t' -v OFS='\t' -v t="$then" '{ $2 = t; print }' "$list" > "$list.aged" && mv -f "$list.aged" "$list"
    done
}
csa_build ca1
csa_expect ca1 8 "a cold build runs the claim's cases and the clock's with the rest"
csa_build ca2
csa_expect ca2 0 "a rebuild runs none of them, the claim's and the clock's included"
csa_age 6
csa_build ca3
csa_expect ca3 0 "entries six days old are still trusted"
csa_age 8
csa_build ca4
csa_expect ca4 8 "entries eight days old run again"
csa_build ca5
csa_expect ca5 0 "and the rerun stamps them afresh"
IDC_CASE_MAX_AGE_DAYS=0 csa_build ca6
csa_expect ca6 8 "a limit of zero days runs every case"
IDC_FRESH_CASES="$CSA" csa_build ca7
csa_expect ca7 8 "IDC_FRESH_CASES naming the tree runs all its cases"
IDC_FRESH_CASES="$TMP/elsewhere" csa_build ca8
csa_expect ca8 0 "IDC_FRESH_CASES naming another tree runs none"
IDC_FRESH_CASES="$CSA" csa_build ca9
csa_expect ca9 8 "IDC_FRESH_CASES runs them again, not once"
sed -i 's/s = s + xs\[i\]/s = xs[i] + s/' "$CSA/more.id"
csa_build ca10
csa_expect ca10 2 "editing the claim's function runs its two cases and no others"
sed -i 's/a \* 2/2 * a/' "$CSA/main.id"
csa_build ca11
csa_expect ca11 2 "editing a function runs its own cases and no others"

# A claim that does not hold must not be cached as a pass: its cases pass one
# by one, and only the judging of the group says otherwise.
CSB="$TMP/csb"; mkdir -p "$CSB"
big=$(seq -s ', ' 1 64)
cat > "$CSB/main.id" <<EOF2
linear(int[] xs) {
  int s = 0;
  int i = 0;
  while(i < len(xs)) {
    s = s + xs[i];
    i = i + 1;
  }
} return int s;
([1, 2, 3, 4]):(10)[time:O(1)]
([$big]):(2080)[time:O(1)]

main(int argc, string[] argv) {
  print("claim");
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF2
csa_build cb1 "$CSB"
csa_build cb2 "$CSB"
if [ "$(rc_of cb1)" -ne 0 ] && [ "$(rc_of cb2)" -ne 0 ] && grep -q 'does not hold' "$TMP/cb2.out" && [ "$(awk '{print $3}' "$TMP/cb2.st")" = 2 ]; then ok "a claim that fails is judged again on the next build, and its cases are not taken for a pass"; else bad "failing claim (rc $(rc_of cb1)/$(rc_of cb2), stats '$(cat "$TMP/cb2.st")'): $(head -2 "$TMP/cb2.out")"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
