#!/usr/bin/env bash
# The editor reads an .odt and draws it.
#
# The modules below it are each tested against a reference of their own
# (editor_zip.sh, editor_doc.sh, and idstd's .tests/font for the font). What this
# file checks is the thing none of them can: that the whole chain -- archive,
# inflate, XML, styles, font, outline, raster, layout -- ends with the right
# ink in the right places.
#
# Deliberately structural rather than a golden image. A pixel-exact comparison
# would break on a different build of DejaVu, which is a fact about the font
# and not about this program; what must not change is that the document has
# five paragraphs, that one of them is empty and shows as a gap, that the
# heading is bigger than the body, that the bold run is heavier than the
# regular text beside it, and that nothing is drawn past the page width.
#
# Run from anywhere: tests/editor_render.sh
set -u
cd "$(dirname "$0")"
ROOT=..
ORG=../..
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

FONT=$(ls /nix/store/*/share/fonts/truetype/DejaVuSans.ttf 2>/dev/null | head -1)
[ -n "$FONT" ] && [ -f "$FONT" ] || FONT=$(fc-match -f '%{file}' "DejaVu Sans" 2>/dev/null)
if [ -z "${FONT:-}" ] || [ ! -f "$FONT" ]; then
    echo "SKIP: editor render tests (no DejaVuSans.ttf -- run via 'tools/devshell.sh tests/editor_render.sh')"
    exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
[ -f fixtures/sample.odt ] || { env -u IDC_NO_STD "$ROOT/bin/idc" "$ROOT/tools/buildrun" -o "$TMP/buildrun" \
    && "$TMP/buildrun" "$(cd "$ROOT" && pwd)" mkodt fixtures/sample.odt; } >/dev/null 2>&1

if ! "$ROOT/bin/idc" "$ORG/editor" --allow-untested -o "$TMP/editor" >"$TMP/build.log" 2>&1; then
    bad "the editor builds ($(head -1 "$TMP/build.log"))"
    echo; echo "$pass passed, $fail failed"; exit 1
fi
ok "the editor builds"

if ! "$TMP/editor" fixtures/sample.odt "$FONT" --ppm "$TMP/page.ppm" >"$TMP/list.txt" 2>&1; then
    bad "the editor reads the document and renders a page"
    head -3 "$TMP/list.txt"
    echo; echo "$pass passed, $fail failed"; exit 1
fi
ok "the editor reads the document and renders a page"

# The model, before any pixels: what the ODT layer made of the file.
want_line() { if grep -qF "$2" "$TMP/list.txt"; then ok "$1"; else bad "$1"; fi; }
want_line "the heading is 18pt italic"              "italic 18pt DejaVu Serif: A document, read by id"
want_line "a run inside a paragraph is bold"        "bold 12pt DejaVu Sans: this run is bold"
want_line "an empty paragraph survives as one"      "[3] 0 run(s)"
want_line "entities came through decoded"           "Entities survive too & so do <angle"

# And the pixels.
node - "$TMP/page.ppm" > "$TMP/facts.txt" <<'JSEOF'
const d = require("fs").readFileSync(process.argv[2]);
let pos = 0;
const lines = [];
while (lines.length < 3) {
    const nl = d.indexOf(10, pos);
    lines.push(d.toString("latin1", pos, nl));
    pos = nl + 1;
}
const [w, ht] = lines[1].split(/\s+/).map(Number);
const px = d.subarray(pos);
const lum = (x, y) => px[(y * w + x) * 3];

const rows = [];
let right = 0;
for (let y = 0; y < ht; y++) {
    let n = 0;
    for (let x = 0; x < w; x++) {
        if (lum(x, y) < 200) {
            n++;
            if (x > right) right = x;
        }
    }
    rows.push(n);
}
const bands = [];
let run = null;
rows.forEach((n, y) => {
    if (n && run === null) run = y;
    else if (!n && run !== null) {
        bands.push([run, y - 1]);
        run = null;
    }
});
if (run !== null) bands.push([run, ht - 1]);

const gaps = [];
for (let i = 0; i + 1 < bands.length; i++) gaps.push(bands[i + 1][0] - bands[i][1]);
console.log("size", w, ht);
console.log("ink", rows.reduce((a, b) => a + b, 0));
console.log("bands", bands.length);
console.log("first_height", bands.length ? bands[0][1] - bands[0][0] + 1 : 0);
console.log("body_height", bands.length > 1 ? bands[1][1] - bands[1][0] + 1 : 0);
console.log("rightmost", right);
console.log("biggest_gap", gaps.length ? Math.max(...gaps) : 0);
JSEOF
fact() { grep "^$1 " "$TMP/facts.txt" | cut -d' ' -f2-; }

[ "$(fact size)" = "640 480" ] && ok "the page is the size that was asked for" \
    || bad "the page is the size that was asked for (got $(fact size))"

ink=$(fact ink)
if [ "$ink" -gt 4000 ] && [ "$ink" -lt 20000 ]; then
    ok "the page has ink on it ($ink pixels)"
else
    bad "the page has ink on it (got $ink, wanted 4000..20000)"
fi

# Six lines of text: the heading, three lines of the long paragraph, two of
# the styled one, and the last one -- the exact count depends on the font's
# advances, so this checks there are several rather than one blob or none.
bands=$(fact bands)
if [ "$bands" -ge 5 ] && [ "$bands" -le 12 ]; then
    ok "the text is broken into lines ($bands of them)"
else
    bad "the text is broken into lines (got $bands, wanted 5..12)"
fi

# The heading is 18pt and the body 12pt, so the first band must be taller.
fh=$(fact first_height); bh=$(fact body_height)
if [ "$fh" -gt "$bh" ]; then
    ok "the 18pt heading is taller than the 12pt body ($fh vs $bh)"
else
    bad "the 18pt heading is taller than the 12pt body ($fh vs $bh)"
fi

# Nothing may be drawn past the page width the layout was given.
right=$(fact rightmost)
if [ "$right" -lt 620 ]; then
    ok "no glyph is drawn past the page width (rightmost ink at $right)"
else
    bad "no glyph is drawn past the page width (rightmost ink at $right)"
fi

# The empty paragraph is a blank line, so somewhere there is a gap wider than
# the gap between two lines of the same paragraph.
gap=$(fact biggest_gap)
if [ "$gap" -gt 8 ]; then
    ok "the empty paragraph shows as a gap ($gap blank rows)"
else
    bad "the empty paragraph shows as a gap (widest gap $gap rows)"
fi

# Rendering is deterministic: the same document twice is the same page.
"$TMP/editor" fixtures/sample.odt "$FONT" --ppm "$TMP/again.ppm" >/dev/null 2>&1
if cmp -s "$TMP/page.ppm" "$TMP/again.ppm"; then
    ok "rendering the same document twice gives the same page"
else
    bad "rendering the same document twice gives the same page"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
