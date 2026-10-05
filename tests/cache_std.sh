#!/usr/bin/env bash
# The standard library's index and its pre-check are exact: a change to the
# library redoes the work of the files it touched and of the programs that reach
# them, and nothing else. bin/idc keeps what idparse --index found in each
# library file under that file's content hash ($CACHE/stdidx/*/shards/), the
# assembled index under the hash of all of them (.../idx/), and the check of the
# part of the library a program reaches under the hash of that part
# (std_precheck/). The counts are read off those directories, not timed.
#
# Run from anywhere: tests/cache_std.sh
set -u
cd "$(dirname "$0")"
BIN_IDC="../bin/idc --allow-untested"
unset IDSTD_HOME IDC_NO_CACHE IDC_STD_FULL IDC_NO_STD

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

CACHE="$TMP/cache"
mkdir -p "$CACHE"
for f in idlex0 idparse0 idlex idparse ccrun idlayout; do
    [ -x "../.idc-cache/$f" ] && cp "../.idc-cache/$f" "$CACHE/"
done
export IDC_CACHE_DIR="$CACHE"

shards() { find "$CACHE/stdidx" -path '*/shards/*' -type f ! -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' '; }
indexes() { find "$CACHE/stdidx" -path '*/idx/*' -maxdepth 4 -name ok 2>/dev/null | wc -l | tr -d ' '; }
prechecks() { find "$CACHE/std_precheck" -mindepth 1 -maxdepth 1 -type d ! -name '.bincache' 2>/dev/null | wc -l | tr -d ' '; }

LIB="$TMP/lib"
mkdir -p "$LIB/math" "$LIB/text" "$LIB/misc"
cat > "$LIB/math/cm.id" <<'EOF'
cm_max(int a, int b) {
  int m = a;
  if (b > a) {
    m = b;
  }
} return int m;
(3, 9):(9)
(9, 3):(9)
EOF
cat > "$LIB/text/ct.id" <<'EOF'
ct_twice(string s) {
  string t = s + s;
} return string t;
("ab"):("abab")
("c"):("cc")
EOF
cat > "$LIB/misc/cz.id" <<'EOF'
cz_inc(int a) {
  int b = a + 1;
} return int b;
(1):(2)
(5):(6)
EOF
PROG="$TMP/prog"
mkdir -p "$PROG"
cat > "$PROG/main.id" <<'EOF'
main(int argc, string[] argv) {
  int r = cm_max(4, 9);
  print(r);
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
build() { $BIN_IDC --std "$LIB" "$PROG" -o "$TMP/out" >"$TMP/build.log" 2>&1; }

# -- 1. the first build reads every library file once, and keeps one index -----
if build && [ "$("$TMP/out")" = "9" ]; then
    s1=$(shards); i1=$(indexes); p1=$(prechecks)
    if [ "$s1" -eq 3 ] && [ "$i1" -eq 1 ] && [ "$p1" -eq 1 ]; then
        ok "the first build keeps a record per library file, one index and one pre-check"
    else
        bad "the first build keeps a record per library file, one index and one pre-check (shards $s1, indexes $i1, pre-checks $p1)"
    fi
else
    bad "the first build builds ($(head -2 "$TMP/build.log" | tr '\n' ' '))"
    s1=0; i1=0; p1=0
fi

# -- 2. an identical build, and a build of a changed program, redo none of it ---
build
printf '\n' >> "$PROG/main.id"
build
if [ "$(shards)" -eq "$s1" ] && [ "$(indexes)" -eq "$i1" ] && [ "$(prechecks)" -eq "$p1" ]; then
    ok "a rebuild, and a build after editing only the program, re-read and re-check nothing of the library"
else
    bad "a rebuild, and a build after editing only the program, re-read and re-check nothing of the library (shards $(shards), indexes $(indexes), pre-checks $(prechecks))"
fi

# -- 3. editing a function the program does not reach re-reads that one file and
# leaves the program's pre-check alone ---------------------------------------
cat > "$LIB/misc/cz.id" <<'EOF'
cz_inc(int a) {
  int b = a + 2;
} return int b;
(1):(3)
(5):(7)
EOF
build
if [ "$(shards)" -eq $((s1 + 1)) ] && [ "$(indexes)" -eq $((i1 + 1)) ] && [ "$(prechecks)" -eq "$p1" ]; then
    ok "editing a library function the program does not reach reads that file again and re-checks nothing"
else
    bad "editing a library function the program does not reach reads that file again and re-checks nothing (shards $(shards), indexes $(indexes), pre-checks $(prechecks))"
fi

# -- 4. editing one it does reach re-reads that file and re-checks the program's
# part of the library --------------------------------------------------------
cat > "$LIB/math/cm.id" <<'EOF'
cm_max(int a, int b) {
  int m = b;
  if (a > b) {
    m = a;
  }
} return int m;
(3, 9):(9)
(9, 3):(9)
EOF
build
if [ "$(shards)" -eq $((s1 + 2)) ] && [ "$(indexes)" -eq $((i1 + 2)) ] && [ "$(prechecks)" -eq $((p1 + 1)) ] && [ "$("$TMP/out")" = "9" ]; then
    ok "editing a library function the program reaches reads that file again and checks it again"
else
    bad "editing a library function the program reaches reads that file again and checks it again (shards $(shards), indexes $(indexes), pre-checks $(prechecks))"
fi

# -- 5. moving a file costs a new index and no new record: a record is the file's
# content, and its path is put back when the index is assembled --------------
mkdir -p "$LIB/misc2"
mv "$LIB/misc/cz.id" "$LIB/misc2/cz.id"
rmdir "$LIB/misc"
s5=$(shards); i5=$(indexes)
build
if [ "$(shards)" -eq "$s5" ] && [ "$(indexes)" -eq $((i5 + 1)) ] && [ "$("$TMP/out")" = "9" ]; then
    ok "moving a library file keeps its record and makes one new index"
else
    bad "moving a library file keeps its record and makes one new index (shards $(shards), indexes $(indexes))"
fi

# -- 6. a program that reaches nothing of the library parses none of it -------
cat > "$PROG/main.id" <<'EOF'
main(int argc, string[] argv) {
  print(7);
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
if IDC_TIMES=1 $BIN_IDC --std "$LIB" "$PROG" --emit-c "$TMP/none.c" >"$TMP/none.log" 2>&1 \
   && grep -q "idc: times: stdlib: 0 of 3 functions loaded" "$TMP/none.log" \
   && ! grep -q "id_cm_max\|id_ct_twice\|id_cz_inc" "$TMP/none.c"; then
    ok "a program that reaches nothing of the library loads none of it"
else
    bad "a program that reaches nothing of the library loads none of it ($(grep stdlib "$TMP/none.log" | head -1))"
fi
cat > "$PROG/main.id" <<'EOF'
main(int argc, string[] argv) {
  int r = cz_inc(cm_max(1, 2));
  print(r);
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
if IDC_TIMES=1 $BIN_IDC --std "$LIB" "$PROG" --emit-c "$TMP/two.c" >"$TMP/two.log" 2>&1 \
   && grep -q "idc: times: stdlib: 2 of 3 functions loaded" "$TMP/two.log"; then
    ok "a program that reaches two of the library's three functions loads those two"
else
    bad "a program that reaches two of the library's three functions loads those two ($(grep stdlib "$TMP/two.log" | head -1))"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
