#!/usr/bin/env bash
# editor/lib/zip -- DEFLATE and the ZIP archive, checked against zlib.
#
# The point of this file is that nothing in it is a golden blob. Every expected
# byte is produced by Python's zipfile/zlib at the moment the test runs, and the
# `id` reader has to agree with it byte for byte. A checked-in expected output
# would only prove that the reader still does what it did the day it was
# written; agreeing with the reference implementation of the format is what
# says it is *right*.
#
# `editor/` has no main, so the module cannot be run where it lives. The test
# builds a throwaway project out of a copy of editor/lib/zip and a five-line
# driver: `ziptest ARCHIVE NAME` writes that entry's bytes to stdout, and
# `ziptest FILE` inflates the file as a raw DEFLATE stream. Everything below is
# a comparison of that stdout with Python's answer.
#
# Run from anywhere: tests/editor_zip.sh   (needs python3 and a C compiler)
set -u
cd "$(dirname "$0")"
ROOT=..
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

for tool in python3 cc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: editor/lib/zip tests (need $tool on PATH)"
        exit 0
    fi
done
for need in "$ROOT/bin/idc" "$ROOT/editor/lib/zip" "$ROOT/backends/fs"; do
    if [ ! -e "$need" ]; then
        echo "SKIP: editor/lib/zip tests (missing $need)"
        exit 0
    fi
done
if [ ! -f fixtures/sample.odt ]; then
    if ! python3 "$ROOT/tools/mkodt.py" fixtures/sample.odt >/dev/null 2>&1; then
        echo "SKIP: editor/lib/zip tests (no fixtures/sample.odt and tools/mkodt.py did not run)"
        exit 0
    fi
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ABS=$(cd "$ROOT" && pwd)

# -- the throwaway project -------------------------------------------------
# $TMP holds conf.id, main.id and t/; t/ holds show.id and the copied module.
# Both directories are at the three-entry limit `id` imposes, which is why the
# driver is two files rather than one.
mkdir -p "$TMP/t/zip"
cp -r "$ABS/editor/lib/zip/." "$TMP/t/zip/"
printf 'import "%s/backends/fs"\n' "$ABS" > "$TMP/conf.id"
cat > "$TMP/main.id" <<'IDEOF'
// ziptest ARCHIVE NAME -- that entry's bytes on stdout, or MISSING.
// ziptest FILE         -- the file inflated as a raw DEFLATE stream.
main(int argc, string[] argv) {
  if (argc == 2) {
    int[] xs = zip_bytes(argv[1]);
    int[] buf = inf_inflate(xs, 0);
    show(buf);
  } else {
    ent(argv[1], argv[2]);
  }
} return int 0;

ent(string path, string name) {
  int[] xs = zip_open(path);
  int i = zip_find(xs, name);
  pick(xs, i);
} return void;

pick(int[] xs, int i) {
  if (i < 0) {
    print("MISSING");
  } else {
    int[] buf = zip_read(xs, i);
    show(buf);
  }
} return void;
IDEOF
cat > "$TMP/t/show.id" <<'IDEOF'
// Bytes to stdout. They go through the flat store rather than through
// repeated string concatenation, which is quadratic and would put a 200 KB
// entry well outside this suite's time budget.
show(int[] buf) {
  int n = len(buf);
  word a = alloc(n + 1);
  fill_and_emit(buf, a, n);
} return void;

fill_and_emit(int[] buf, word a, int n) {
  blit(buf, a);
  string out = str_of_mem(a, n);
  put(out);
} return void;

blit(int[] buf, word a) {
  int i = 0;
  while (i < len(buf)) {
    poke8(a + i, buf[i]);
    i = i + 1;
  }
} return void;
IDEOF

BIN="$TMP/ziptest"
if ! "$ROOT/bin/idc" "$TMP" -o "$BIN" >"$TMP/build.log" 2>&1; then
    bad "editor/lib/zip builds ($(head -1 "$TMP/build.log"))"
    echo; echo "$pass passed, $fail failed"; exit 1
fi
ok "editor/lib/zip builds"

# -- every entry of the fixture, against zipfile ---------------------------
# The .odt has a stored entry (mimetype, which the OpenDocument specification
# requires to be stored and first) and three deflated ones, so this single
# loop covers both compression methods the reader implements.
names=$(python3 -c "
import zipfile
print('\n'.join(zipfile.ZipFile('fixtures/sample.odt').namelist()))")
if [ -z "$names" ]; then
    bad "the fixture lists its entries"
else
    miss=0
    while read -r n; do
        [ -z "$n" ] && continue
        python3 -c "
import zipfile, sys
sys.stdout.buffer.write(zipfile.ZipFile('fixtures/sample.odt').read('$n'))" > "$TMP/want"
        if ! "$BIN" fixtures/sample.odt "$n" > "$TMP/got" 2>"$TMP/err"; then
            bad "sample.odt: $n reads back ($(head -1 "$TMP/err"))"; miss=1
        elif ! cmp -s "$TMP/got" "$TMP/want"; then
            bad "sample.odt: $n is byte-identical to what zipfile extracts"; miss=1
        fi
    done <<< "$names"
    [ "$miss" -eq 0 ] && ok "every entry of sample.odt is found by name and matches zipfile"
fi

# The mimetype entry is the one whose exact text identifies the format, and it
# is stored rather than deflated -- so this checks the no-compression path
# against a literal, not against another decompressor.
got=$("$BIN" fixtures/sample.odt mimetype 2>"$TMP/err")
want="application/vnd.oasis.opendocument.text"
if [ "$got" = "$want" ]; then
    ok "the stored mimetype entry reads back exactly"
else
    bad "the stored mimetype entry reads back exactly (got '$got')"
fi

# content.xml on its own, called out because it is the entry an editor
# actually wants and the one that exercises dynamic Huffman.
python3 -c "
import zipfile, sys
sys.stdout.buffer.write(zipfile.ZipFile('fixtures/sample.odt').read('content.xml'))" > "$TMP/want"
if "$BIN" fixtures/sample.odt content.xml > "$TMP/got" 2>"$TMP/err" \
   && cmp -s "$TMP/got" "$TMP/want"; then
    ok "the deflated content.xml is byte-identical to what zipfile extracts"
else
    bad "the deflated content.xml is byte-identical to what zipfile extracts"
    cmp "$TMP/got" "$TMP/want" 2>&1 | head -3
fi

# A name that is not there is -1, not an abort and not a wrong entry.
if [ "$("$BIN" fixtures/sample.odt no/such/entry.xml 2>/dev/null)" = "MISSING" ]; then
    ok "a name that is not in the archive gives -1"
else
    bad "a name that is not in the archive gives -1"
fi

# -- raw DEFLATE, all three block types ------------------------------------
# The distance-less-than-length case is the one worth naming: DEFLATE spells a
# run as a back-reference that overlaps its own output, so a copy that reads
# the whole source before writing any of it produces the right length of the
# wrong bytes. "abcabc..." compresses to a distance of 3 with lengths up to
# 258, and "xxxx..." to a distance of 1, which is the extreme of it.
python3 - "$TMP" <<'PYEOF'
import sys, zlib
tmp = sys.argv[1]
cases = {
    "overlap": (("abc" * 4000).encode(), 9),   # dynamic Huffman, distance 3 < length
    "rle":     ((b"x" * 5000), 9),             # distance 1: a run
    "fixed":   (b"aaaa", 9),                   # too small for a code table: fixed Huffman
    "stored":  (bytes(1 + (i * 37 + 11) % 250 for i in range(200000)), 0),
    "empty":   (b"", 6),
}
for name, (data, lvl) in cases.items():
    c = zlib.compressobj(lvl, zlib.DEFLATED, -15)
    open("%s/%s.def" % (tmp, name), "wb").write(c.compress(data) + c.flush())
    open("%s/%s.want" % (tmp, name), "wb").write(data)
PYEOF
for case in overlap rle fixed stored empty; do
    if "$BIN" "$TMP/$case.def" > "$TMP/$case.got" 2>"$TMP/err" \
       && cmp -s "$TMP/$case.got" "$TMP/$case.want"; then
        ok "inflate: $case"
    else
        bad "inflate: $case ($(head -1 "$TMP/err"))"
    fi
done

# The overlapping case again, but proving the reference really did emit one:
# a 12000-byte input in under 30 bytes is only possible as a back-reference
# whose distance is far below its length.
sz=$(wc -c < "$TMP/overlap.def")
if [ "$sz" -lt 64 ]; then
    ok "the overlap case really is a short-distance back-reference ($sz bytes in, 12000 out)"
else
    bad "the overlap case really is a short-distance back-reference ($sz bytes)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
