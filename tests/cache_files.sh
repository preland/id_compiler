#!/usr/bin/env bash
# A case that reads files is cached with those files, and rerun when one of them
# changes. bin/idc keys a case that reaches only file natives (compiler/parse/
# conf.id: cache_file_natives, cache_taint_natives) and records every path the
# case read or probed, found or not, with a hash of what it could see; the next
# build skips the case only if each path still hashes the same (bin/idc, "Files
# a case reads"). Counted, not timed, like cache_reach.sh: IDC_CASE_STATS says
# how many of the fixture's 22 cases ran.
#
# The fixture's cases (two per function, eleven functions), and what each reads:
#
#   plain             no native
#   rd_bytes          the first bytes of data/font.bin (case 1); data/missing.bin,
#                     which is not there (case 2)
#   rd_ex             whether data/none.txt (case 1) and data/font.bin (case 2) exist
#   rd_dir            the names in data/d (case 1) and in data/nodir, not there (case 2)
#   rd_size           the size of data/size.txt (case 1) and of data/none2.txt (case 2)
#   vol               calls ticks(): never cached
#   wr                opens a file for writing and calls fs_close: never cached
#   envr              calls env_get: never cached (the case is marked in the read log)
#   env_if            reaches env_has, but only for an argument the cases do not give
#                     it: cached
#   wr_if             reaches the same write, but only for an argument the cases
#                     do not give it: cached
#   main              nothing
#
# Every function's result is the same whatever the files hold, so each edit is
# a change the cases must be rerun for without any of them failing. The backend
# is idstd's fs_posix.c itself, the one that writes the read log, copied into
# the fixture with a minimal set of native declarations beside it.
#
# Run from anywhere: tests/cache_files.sh
set -u
cd "$(dirname "$0")"
BIN_IDC="../bin/idc --allow-untested"
unset IDC_NO_CACHE

STD="${IDSTD_HOME:-}"
if [ -z "$STD" ]; then
    R=$(cd .. && pwd)
    for up in "$R/../idstd" "$R/../../idstd"; do
        [ -d "$up" ] && { STD="$up"; break; }
    done
fi
if [ ! -f "${STD:-/nonexistent}/sys/io/fs/fs_posix.c" ] || [ ! -f "${STD:-/nonexistent}/sys/io/ipc/env/env_posix.c" ]; then
    echo "SKIP: no standard library at '${STD:-}' (set IDSTD_HOME to point at one)"
    exit 0
fi
unset IDSTD_HOME

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

CF="$TMP/cf"
mkdir -p "$CF/be/fs" "$CF/be/env" "$CF/code" "$CF/data/d"
cp "$STD/sys/io/fs/fs_posix.c" "$STD/sys/io/fs/fs.h" "$STD/sys/io/fs/backend.id" "$CF/be/fs/"
cp "$STD/sys/io/ipc/env/env_posix.c" "$STD/sys/io/ipc/env/env.h" "$STD/sys/io/ipc/env/backend.id" "$CF/be/env/"
cat > "$CF/be/fs/handle.id" <<'EOF'
native fs_open(string path, string mode) return int;
native fs_close(int handle) return int;
native fs_read(int handle, int[] buf, int n) return int;
EOF
cat > "$CF/be/fs/probe.id" <<'EOF'
native fs_size(string path) return int;
native fs_exists(string path) return int;
native fs_list(string path, int[] buf, int n) return int;
EOF
cat > "$CF/be/env/natives.id" <<'EOF'
native env_get(string name, int[] buf, int n) return int;
native env_has(string name) return int;
EOF
cat > "$CF/be/env/use.id" <<'EOF'
envr(string en) {
  int[] eb = [0, 0];
  int eg = env_get(en, eb, 2);
  int er = 5;
} return int er;
("HOME"):(5)
("NOPE_X"):(5)

env_if(int ea) {
  int ev = 0 - 1;
  if(ea > 100) {
    ev = env_has("HOME");
  }
} return int ev;
(1):(-1)
(2):(-1)
EOF
cat > "$CF/code/main.id" <<'EOF'
plain(int a) {
  int b = a * 2;
} return int b;
(1):(2)
(3):(6)

main(int argc, string[] argv) {
  print("ok");
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
cat > "$CF/code/read.id" <<'EOF'
rd_bytes(string p) {
  int h = fs_open(p, "r");
  int[] buf = [0, 0, 0, 0];
  int n = fs_read(h, buf, 4);
} chain (string p) {
  int c = fs_close(h);
  int s = buf[0] + buf[1];
} return int s;
("data/font.bin"):(195)
("data/missing.bin"):(0)

rd_ex(string p) {
  int e = fs_exists(p);
  int r = 7;
} return int r;
("data/none.txt"):(7)
("data/font.bin"):(7)

rd_dir(string p) {
  int[] buf = [0, 0, 0, 0, 0, 0, 0, 0];
  int n = fs_list(p, buf, 8);
  int r = 9;
} return int r;
("data/d"):(9)
("data/nodir"):(9)
EOF
cat > "$CF/code/more.id" <<'EOF'
rd_size(string p) {
  int n = fs_size(p);
  int r = 3;
} return int r;
("data/size.txt"):(3)
("data/none2.txt"):(3)

vol(int a) {
  int t = ticks();
  int r = a;
} return int r;
(1):(1)
(2):(2)

wr(string p) {
  int h = fs_open(p, "w");
  int c = fs_close(h);
  int r = 4;
} return int r;
("out1.tmp"):(4)
("out2.tmp"):(4)
EOF
cat >> "$CF/code/main.id" <<'EOF'

wr_if(int a) {
  int h = 0 - 1;
  if(a > 100) {
    h = fs_open("w.tmp", "w");
  }
} return int h;
(1):(-1)
(2):(-1)
EOF
printf 'ab12cdef' > "$CF/data/font.bin"
printf 'abcd' > "$CF/data/size.txt"
printf 'x' > "$CF/data/unrelated.txt"
printf 'x' > "$CF/data/d/one.txt"

cf_build() {
    local name="$1"
    IDC_CASE_STATS=1 $BIN_IDC "$CF" -o "$TMP/$name" --no-std >"$TMP/$name.out" 2>&1
    echo $? > "$TMP/$name.rc"
    sed -n 's/^idc: cases: \([0-9]*\) total, \([0-9]*\) already passed, \([0-9]*\) to run$/\1 \2 \3/p' "$TMP/$name.out" > "$TMP/$name.st"
}
cf_expect() {
    local name="$1" runs="$2" what="$3" total hits to
    read -r total hits to < "$TMP/$name.st"
    if [ "$(rc_of "$name")" -eq 0 ] && [ "${total:-}" = 22 ] && [ "${to:-}" = "$runs" ] && [ "${hits:-}" = $((22 - runs)) ]; then
        ok "$what: $runs of 22 cases rerun"
    else
        bad "$what: want $runs of 22 cases rerun (rc $(rc_of "$name"), stats '$(cat "$TMP/$name.st")'): $(head -3 "$TMP/$name.out")"
    fi
}

cf_build cf1
cf_expect cf1 22 "a cold build runs every case"
cf_build cf2
cf_expect cf2 6 "an identical rebuild reruns only vol (calls ticks), wr (writes) and envr (reads the environment), whose cases are never cached"
printf 'ab13cdef' > "$CF/data/font.bin"
cf_build cf3
cf_expect cf3 7 "editing a byte of a file a case read reruns that case, not the case that only asked whether it exists"
printf 'y' > "$CF/data/unrelated.txt"
cf_build cf4
cf_expect cf4 6 "editing a file no case reads reruns nothing more"
printf 'wxyz' > "$CF/data/size.txt"
cf_build cf5
cf_expect cf5 6 "rewriting a file with the same size reruns nothing more: the case asked only its size"
printf 'abcdef' > "$CF/data/size.txt"
cf_build cf6
cf_expect cf6 7 "changing the size of a file a case asked the size of"
printf 'q' > "$CF/data/none.txt"
cf_build cf7
cf_expect cf7 7 "creating a file a case probed as missing (exists)"
: > "$CF/data/missing.bin"
cf_build cf8
cf_expect cf8 7 "creating a file a case tried to open and did not find"
printf 'x' > "$CF/data/d/two.txt"
cf_build cf9
cf_expect cf9 7 "adding a file to a directory a case listed"
mkdir "$CF/data/nodir"
cf_build cf10
cf_expect cf10 7 "creating a directory a case tried to list and did not find"
rm "$CF/data/size.txt"
cf_build cf11
cf_expect cf11 7 "deleting a file a case asked the size of"
rm "$CF/data/d/one.txt"
cf_build cf12
cf_expect cf12 7 "removing a file from a directory a case listed"
cf_build cf13
cf_expect cf13 6 "a rebuild after all of those"
sed -i 's/h = 0 - 1;/h = 0 - 2;/; s/(1):(-1)/(1):(-2)/; s/(2):(-1)/(2):(-2)/' "$CF/code/main.id"
cf_build cf14
cf_expect cf14 8 "editing a function reruns its own cases (and the two never cached)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
