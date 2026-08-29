#!/usr/bin/env bash
# editor/lib/doc: the XML pull parser and the OpenDocument content model.
#
# The fixture is the real thing -- the content.xml inside
# tests/fixtures/sample.odt, the file tools/mkodt.py generates -- because a
# hand-written scrap of XML would test the parser against the shape the parser
# already assumes. What is asserted is what a document editor has to get right:
# how many paragraphs there are including the empty one, where a run of bold
# text starts and stops inside a paragraph, that an entity came through as the
# character it names, and what a style says about its font.
#
# The module is built as a project of its own, with a main that prints one line
# per paragraph, run and style, so that this script asserts against a document
# model rather than against a parser's internals. The `tst_` prefix is the test
# harness's own; `editor/NAMES.md` owns `xml_` and `odt_`.
#
# Run from anywhere: tests/editor_doc.sh
set -u
cd "$(dirname "$0")"
ROOT=..
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P="$TMP/proj"
mkdir -p "$P/show/more"
cp -r "$ROOT/editor/lib/doc" "$P/doc"

cat > "$P/main.id" <<'IDEOF'
main(int argc, string[] argv) {
  string src = read_all();
  odt_parse(src);
  tst_show();
} return int 0;
IDEOF

cat > "$P/show/show.id" <<'IDEOF'
tst_show() {
  show_paras();
  tst_p(0);
  tst_more();
} return void;

tst_p(int i) {
  while(i < odt_paras()) {
    show_p_line(i);
    i = i + 1;
  }
} return void;

tst_more() {
  tst_r(0);
  tst_keys();
  show_err();
} return void;
IDEOF

cat > "$P/show/helpers.id" <<'IDEOF'
show_paras() {
  int n = odt_paras();
  print("paras " + n);
} return void;

show_p_line(int i) {
  int runs = odt_runs_of(i);
  int at = odt_run_at(i, 0);
  print("p" + i + " " + runs + " at " + at);
} return void;

show_err() {
  string e = odt_err();
  int at = odt_at();
  print("err |" + e + "| at " + at);
} return void;
IDEOF

cat > "$P/show/more/more.id" <<'IDEOF'
tst_r(int r) {
  while(r < odt_runs()) {
    show_r_line(r);
    r = r + 1;
  }
} return void;

tst_keys() {
  string[] names = ["T1", "T2", "T3", "P1", "nope"];
  int i = 0;
  while(i < len(names)) {
    tst_key(names[i]);
    i = i + 1;
  }
} return void;

tst_key(string key) {
  string font = odt_font(key);
  int size = odt_size(key);
  show_key_line(key, font, size);
} return void;
IDEOF

cat > "$P/show/more/helpers.id" <<'IDEOF'
show_r_line(int r) {
  string style = odt_run_style(r);
  string text = odt_run_text(r);
  print("r" + r + " " + style + " |" + text + "|");
} return void;

show_key_line(string key, string font, int size) {
  int b = odt_bold(key);
  int it = odt_italic(key);
  print("s " + key + " |" + font + "| " + size + "pt b" + b + " i" + it);
} return void;
IDEOF

if ! "$ROOT/bin/idc" "$P" -o "$TMP/doctest" >"$TMP/build.log" 2>&1; then
    bad "editor/lib/doc builds ($(head -1 "$TMP/build.log"))"
    echo; echo "$pass passed, $fail failed"; exit 1
fi
ok "editor/lib/doc builds"

python3 -c "import zipfile;print(zipfile.ZipFile('fixtures/sample.odt').read('content.xml').decode())" > "$TMP/content.xml" 2>/dev/null \
    || { bad "tests/fixtures/sample.odt has a content.xml"; echo; echo "$pass passed, $fail failed"; exit 1; }
ok "tests/fixtures/sample.odt has a content.xml"

"$TMP/doctest" < "$TMP/content.xml" > "$TMP/out" 2>&1
OUT=$(cat "$TMP/out")

# `got` is the whole line, so a failure shows what the model actually said
# rather than only that it disagreed.
want() {
    local what="$1" line="$2"
    if printf '%s\n' "$OUT" | grep -qxF "$line"; then
        ok "$what"
    else
        bad "$what"
        echo "    wanted: $line"
        echo "    got:    $(printf '%s\n' "$OUT" | grep -E "^${line%% *} " | head -1)"
    fi
}

# -- the document ----------------------------------------------------------
# Five paragraphs: four with text and the <text:p/> between the third and the
# fifth, which is a blank line the author put there and has to survive as a
# paragraph of its own.
want "the document has five paragraphs, the empty one included" "paras 5"
want "the fourth paragraph is empty and owns no runs"           "p3 0 at 5"
want "the first paragraph is one run"                           "p0 1 at 0"

want "the first paragraph reads as it was written" \
     "r0 T3 |A document, read by id|"

# -- runs within a paragraph ------------------------------------------------
# The third paragraph changes style twice, so it is three runs, and the middle
# one is the one <text:span text:style-name="T2"> wraps.
want "the third paragraph is three runs"                        "p2 3 at 2"
want "the third paragraph's first run is plain"  "r2 T1 |Styles change mid-paragraph: |"
want "the third paragraph's middle run is the bold one"         "r3 T2 |this run is bold|"

# -- entities ---------------------------------------------------------------
# &amp; and &lt; are text, not markup, and reach the model as the characters
# they name.
want "&amp; and &lt; decode to & and <" \
     "r4 T1 | and this one is not. Entities survive too & so do <angle brackets>.|"

# -- styles -----------------------------------------------------------------
want "T1 is DejaVu Sans at 12pt, neither bold nor italic" "s T1 |DejaVu Sans| 12pt b0 i0"
want "T2 is bold"                                         "s T2 |DejaVu Sans| 12pt b1 i0"
want "T3 is DejaVu Serif, italic at 18pt"                 "s T3 |DejaVu Serif| 18pt b0 i1"
want "a style the document never declared reads as nothing" "s nope || 0pt b0 i0"

want "a well-formed document reports no error" "err || at -1"

# -- the constructs an ODT spells as elements -------------------------------
# text:s and text:tab exist because XML collapses literal whitespace. They are
# part of the run around them, not a break in it: a renderer that saw three
# runs here would be free to change style between them, and there is no style
# change in the document.
SYN='<office:text><text:p text:style-name="P1">a<text:s text:c="4"/>b<text:tab/>c &#233;&#x1F600;<![CDATA[<&raw>]]></text:p><text:p/><text:p><text:span text:style-name="Z">deep<text:span text:style-name="Y">er</text:span>back</text:span></text:p></office:text>'
OUT=$(printf '%s' "$SYN" | "$TMP/doctest" 2>&1)
want "text:s, text:tab, CDATA and numeric references stay in one run" \
     "$(printf 'r0 P1 |a    b\tc \xc3\xa9\xf0\x9f\x98\x80<&raw>|')"
want "a span inside a span restores the outer style after it"  "r3 Z |back|"
want "the synthetic document is three paragraphs"              "paras 3"
OUT=$(cat "$TMP/out")

# -- malformed input --------------------------------------------------------
# The point is that it is *reported*, with a position, rather than parsed into
# something plausible. Each of these is a different way for a file to be wrong.
check_bad() {
    local what="$1" doc="$2" msg="$3"
    local got
    got=$(printf '%s' "$doc" | "$TMP/doctest" 2>&1 | grep '^err ')
    case "$got" in
        "err |$msg| at "[0-9]*) ok "$what" ;;
        *) bad "$what"; echo "    wanted: err |$msg| at N"; echo "    got:    $got" ;;
    esac
}

check_bad "a tag that never closes is reported" \
    '<office:text><text:p>hello<text:p' \
    "expected '>' or an attribute"
check_bad "an end tag that names the wrong element is reported" \
    '<office:text><text:p>hello</office:text></text:p>' \
    "end tag does not match the element that is open"
check_bad "a document that stops in the middle of itself is reported" \
    '<office:text><text:p>hello</text:p>' \
    "element is still open at the end of the input"
check_bad "an unquoted attribute value is reported" \
    '<text:p text:style-name=P1>x</text:p>' \
    "expected a quoted attribute value"
check_bad "an entity that never ends is reported" \
    '<text:p>a &amp b</text:p>' \
    "unterminated entity reference"
check_bad "an entity this parser does not know is reported" \
    '<text:p>a &nbsp; b</text:p>' \
    "unknown or out-of-range entity reference"
check_bad "a comment that never ends is reported" \
    '<text:p>a</text:p><!-- and then' \
    "unterminated comment"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
