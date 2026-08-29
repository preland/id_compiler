#!/usr/bin/env bash
# The TrueType parser reads a real font, and a second implementation agrees.
#
# Nothing here is asserted against a constant. Every expected value is
# computed at test time by the small Python reader below, out of the same
# font file, so the test says "two independent implementations of the format
# agree" rather than "the numbers are the ones that came out the day this was
# written". A hard-coded 2048 would pass just as happily on a parser that had
# stopped reading `head` at all.
#
# The last check is the one that matters most: every glyph in the font, its
# contour and point counts and a rolling hash of every coordinate and
# on-curve bit. Four letters can be right by accident; six thousand glyphs
# including every composite with a 2x2 transform in it cannot.
#
# Run from anywhere: tests/editor_ttf.sh   (needs python3 and a TrueType font)
set -u
cd "$(dirname "$0")"
ROOT=..
ORG=../..
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -- want [$2] got [$3]"; fi; }

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: editor ttf tests (need python3 on PATH for the reference reader)"
    exit 0
fi

find_font() {
    for p in "$@"; do
        # shellcheck disable=SC2086
        f=$(ls $p 2>/dev/null | head -1)
        [ -n "$f" ] && { echo "$f"; return; }
    done
}
DEJAVU=$(find_font \
    '/nix/store/*/share/fonts/truetype/DejaVuSans.ttf' \
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf' \
    '/usr/share/fonts/TTF/DejaVuSans.ttf' \
    '/Library/Fonts/DejaVuSans.ttf')
LIBER=$(find_font \
    '/nix/store/*/share/fonts/truetype/LiberationSans-Regular.ttf' \
    '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf' \
    '/usr/share/fonts/liberation-fonts/LiberationSans-Regular.ttf')
OTF=$(find_font \
    '/nix/store/*/share/fonts/opentype/*.otf' \
    '/usr/share/fonts/opentype/*/*.otf' \
    '/usr/share/fonts/OTF/*.otf')

if [ -z "$DEJAVU" ] && [ -z "$LIBER" ]; then
    echo "SKIP: editor ttf tests (no TrueType font found -- looked for DejaVuSans.ttf and LiberationSans-Regular.ttf)"
    exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# -- the program under test -------------------------------------------------
# `editor/` is a library: it has no main, so it builds to a .o and cannot be
# run. The smallest thing that can exercise tt_glyph is a program, so one is
# built here out of the font module, the shared byte readers it depends on,
# and a main that calls the module's own tt_selftest. The project directory
# holds three entries plus conf.id, which is the limit.
PROJ="$TMP/p"
mkdir -p "$PROJ/ttf" "$PROJ/byte"
cp -r "$ORG/editor/lib/font/ttf/." "$PROJ/ttf/"
cp "$ORG"/editor/lib/zip/byte/*.id "$PROJ/byte/"
cat > "$PROJ/main.id" <<'IDEOF'
main(int argc, string[] argv) {
  tt_selftest(argv);
} return int 0;
IDEOF
printf 'import "%s/backends/fs"\n' "$(cd "$ROOT" && pwd)" > "$PROJ/conf.id"

if ! "$ROOT/bin/idc" "$PROJ" -o "$TMP/ttf" >"$TMP/build.log" 2>&1; then
    bad "the font module builds ($(head -3 "$TMP/build.log" | tr '\n' ' '))"
    echo; echo "$pass passed, $fail failed"; exit 1
fi
ok "the font module builds"

# -- the reference ----------------------------------------------------------
# A second reader of the same format, written against the spec rather than
# against the `id` code, printing the same lines so the two can be compared
# field by field. struct only; fontTools is not assumed to be installed.
cat > "$TMP/ref.py" <<'PYEOF'
import struct, sys

class F:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        n = struct.unpack_from('>H', self.d, 4)[0]
        self.t = {}
        for i in range(n):
            tag, ck, off, ln = struct.unpack_from('>4sIII', self.d, 12 + 16 * i)
            self.t[tag.decode('latin1')] = (off, ln)
        h = self.t['head'][0]
        self.upem = struct.unpack_from('>H', self.d, h + 18)[0]
        self.iltf = struct.unpack_from('>h', self.d, h + 50)[0]
        hh = self.t['hhea'][0]
        self.asc, self.desc, self.gap = struct.unpack_from('>hhh', self.d, hh + 4)
        self.nhm = struct.unpack_from('>H', self.d, hh + 34)[0]
        self.nglyph = struct.unpack_from('>H', self.d, self.t['maxp'][0] + 4)[0]
        self.pick_cmap()

    def pick_cmap(self):
        c = self.t['cmap'][0]
        n = struct.unpack_from('>H', self.d, c + 2)[0]
        best, bo = -1, -1
        for i in range(n):
            p, e, o = struct.unpack_from('>HHI', self.d, c + 4 + 8 * i)
            r = 0
            if p == 3:
                r = {10: 4, 1: 3}.get(e, 1)
            elif p == 0:
                r = 2
            if r > best:
                best, bo = r, c + o
        self.cm = bo
        self.cmfmt = struct.unpack_from('>H', self.d, bo)[0] if bo >= 0 else 0

    def glyph(self, cp):
        if self.cmfmt == 4:
            return self.g4(cp)
        if self.cmfmt == 12:
            return self.g12(cp)
        return 0

    def g4(self, cp):
        if cp > 0xFFFF:
            return 0
        at = self.cm
        n = struct.unpack_from('>H', self.d, at + 6)[0] // 2
        endb, startb, deltab, rob = at + 14, at + 16 + n * 2, at + 16 + n * 4, at + 16 + n * 6
        i = 0
        while struct.unpack_from('>H', self.d, endb + i * 2)[0] < cp:
            i += 1
        st = struct.unpack_from('>H', self.d, startb + i * 2)[0]
        if st > cp:
            return 0
        dl = struct.unpack_from('>H', self.d, deltab + i * 2)[0]
        ro = struct.unpack_from('>H', self.d, rob + i * 2)[0]
        v = cp if ro == 0 else struct.unpack_from('>H', self.d, rob + i * 2 + ro + (cp - st) * 2)[0]
        return 0 if v == 0 else (v + dl) % 65536

    def g12(self, cp):
        at = self.cm
        ng = struct.unpack_from('>I', self.d, at + 12)[0]
        lo, hi = 0, ng
        while lo < hi:
            m = (lo + hi) // 2
            if struct.unpack_from('>I', self.d, at + 20 + m * 12)[0] < cp:
                lo = m + 1
            else:
                hi = m
        if lo >= ng:
            return 0
        s, e, g = struct.unpack_from('>III', self.d, at + 16 + lo * 12)
        return 0 if s > cp else g + cp - s

    def adv(self, g):
        return struct.unpack_from('>H', self.d, self.t['hmtx'][0] + min(g, self.nhm - 1) * 4)[0]

    def loca(self, g):
        l = self.t['loca'][0]
        if self.iltf == 1:
            return struct.unpack_from('>I', self.d, l + g * 4)[0]
        return struct.unpack_from('>H', self.d, l + g * 2)[0] * 2

    def outline(self, g, pts=None, ends=None):
        if pts is None:
            pts, ends = [], []
        if self.loca(g + 1) - self.loca(g) <= 0:
            return ends, pts
        at = self.t['glyf'][0] + self.loca(g)
        nc = struct.unpack_from('>h', self.d, at)[0]
        if nc > 0:
            self.simple(at + 10, nc, pts, ends)
        elif nc < 0:
            self.comp(at + 10, pts, ends)
        return ends, pts

    def simple(self, at, nc, pts, ends):
        base = len(pts)
        e = [struct.unpack_from('>H', self.d, at + i * 2)[0] for i in range(nc)]
        for v in e:
            ends.append(base + v)
        npts = e[-1] + 1
        p = at + nc * 2
        p += 2 + struct.unpack_from('>H', self.d, p)[0]
        flags = []
        while len(flags) < npts:
            f = self.d[p]; p += 1
            flags.append(f)
            if f & 8:
                r = self.d[p]; p += 1
                flags += [f] * r
        cols = []
        for short, sign in ((2, 16), (4, 32)):
            col, acc = [], 0
            for f in flags:
                if f & short:
                    v = self.d[p]; p += 1
                    if not (f & sign):
                        v = -v
                elif f & sign:
                    v = 0
                else:
                    v = struct.unpack_from('>h', self.d, p)[0]; p += 2
                acc += v
                col.append(acc)
            cols.append(col)
        for i in range(npts):
            pts.append((cols[0][i], cols[1][i], flags[i] & 1))

    def comp(self, at, pts, ends):
        while True:
            k, gi = struct.unpack_from('>HH', self.d, at); at += 4
            if k & 1:
                a1, a2 = struct.unpack_from('>hh', self.d, at); at += 4
            else:
                a1, a2 = struct.unpack_from('>bb', self.d, at); at += 2
            if not (k & 2):
                a1 = a2 = 0
            m = [16384, 0, 0, 16384]
            if k & 8:
                s = struct.unpack_from('>h', self.d, at)[0]; at += 2
                m = [s, 0, 0, s]
            elif k & 64:
                sx, sy = struct.unpack_from('>hh', self.d, at); at += 4
                m = [sx, 0, 0, sy]
            elif k & 128:
                m = list(struct.unpack_from('>hhhh', self.d, at)); at += 8
            b = len(pts)
            self.outline(gi, pts, ends)
            for i in range(b, len(pts)):
                x, y, on = pts[i]
                pts[i] = (fix(m[0] * x + m[2] * y) + a1, fix(m[1] * x + m[3] * y) + a2, on)
            if not (k & 32):
                break

    def has2x2(self):
        if 'glyf' not in self.t:
            return False
        for g in range(self.nglyph):
            if self.loca(g + 1) - self.loca(g) <= 0:
                continue
            at = self.t['glyf'][0] + self.loca(g)
            if struct.unpack_from('>h', self.d, at)[0] >= 0:
                continue
            if struct.unpack_from('>H', self.d, at + 10)[0] & (8 | 64 | 128):
                return True
        return False

    def csweep(self):
        h = 0
        for c in range(0, 196608, 3):
            h = (h * 31 + self.glyph(c)) % 1000003
        return h

    def asweep(self):
        h = 0
        for g in range(self.nglyph):
            h = (h * 31 + self.adv(g)) % 1000003
        return h

    def sweep(self):
        h = nc = np = 0
        for g in range(self.nglyph):
            e, pts = self.outline(g)
            nc += len(e); np += len(pts)
            for (x, y, on) in pts:
                for v in (x, y, on):
                    h = (h * 31 + v + 1000003) % 1000003
        return nc, np, h


# F2Dot14 divided back out, rounded half away from zero -- the same rule the
# `id` side uses, and the one the fonts' own stored bounding boxes agree with.
def fix(v):
    return (v + 8192) // 16384 if v >= 0 else -((-v + 8192) // 16384)


if sys.argv[1] == '--find2x2':
    # The first font on stdin that builds a glyph out of a SCALED component.
    # Neither DejaVu nor Liberation has one, so without this the 2x2 branch
    # of the composite reader is never executed by this test at all.
    for path in sys.stdin.read().split():
        try:
            if F(path).has2x2():
                print(path)
                break
        except Exception:
            continue
    sys.exit(0)

f = F(sys.argv[1])
print('load 1')
print('upem', f.upem)
print('nglyph', f.nglyph)
print('vmet', f.asc, f.desc, f.gap)
print('hmet', f.nhm, 'loca', f.iltf)
print('cmap', f.cmfmt)
for cp in (65, 103, 48, 32, 1046, 8211):
    g = f.glyph(cp)
    print('cp', cp, 'g', g, 'adv', f.adv(g))
for cp in (111, 65, 105, 233):
    g = f.glyph(cp)
    e, pts = f.outline(g)
    xs = [q[0] for q in pts]; ys = [q[1] for q in pts]
    print('out', cp, 'g', g, 'any', 1 if e else 0, 'nc', len(e), 'np', len(pts),
          'bbox', min(xs), min(ys), max(xs), max(ys),
          'ends', ','.join(str(v) for v in e),
          'on', ''.join(str(q[2]) for q in pts))
print('sweep', *f.sweep())
print('more', f.csweep(), f.asweep())
PYEOF

field() { grep "^$2 " "$1" | head -1; }
outline_of() { grep "^out $2 " "$1" | head -1; }

# -- one font, every claim --------------------------------------------------
run_font() {
    label=$1; font=$2
    "$TMP/ttf" "$font" > "$TMP/id.out" 2>"$TMP/id.err"
    if [ ! -s "$TMP/id.out" ]; then
        bad "$label: the parser produced output ($(head -1 "$TMP/id.err"))"
        return
    fi
    if ! python3 "$TMP/ref.py" "$font" > "$TMP/py.out" 2>"$TMP/py.err"; then
        bad "$label: the reference reader ran ($(tail -1 "$TMP/py.err"))"
        return
    fi

    same "$label: the font is accepted"        "load 1"                       "$(field "$TMP/id.out" load)"
    same "$label: unitsPerEm"                  "$(field "$TMP/py.out" upem)"   "$(field "$TMP/id.out" upem)"
    same "$label: numGlyphs"                   "$(field "$TMP/py.out" nglyph)" "$(field "$TMP/id.out" nglyph)"
    same "$label: ascender, descender, lineGap" "$(field "$TMP/py.out" vmet)"  "$(field "$TMP/id.out" vmet)"
    same "$label: numberOfHMetrics, indexToLocFormat" "$(field "$TMP/py.out" hmet)" "$(field "$TMP/id.out" hmet)"
    same "$label: the cmap subtable chosen"    "$(field "$TMP/py.out" cmap)"   "$(field "$TMP/id.out" cmap)"

    # 'A', 'g' and '0' are three separate segments of a format 4 subtable;
    # U+0416 and U+2013 are outside Latin-1 and outside the first segments.
    for cp in 65 103 48 1046 8211; do
        same "$label: the glyph and advance for U+$(printf '%04X' "$cp")" \
             "$(grep "^cp $cp " "$TMP/py.out")" "$(grep "^cp $cp " "$TMP/id.out")"
    done
    # A space has an advance and no outline at all, which is the case a
    # parser that reads the header of every glyph gets wrong.
    same "$label: the advance of a space" \
         "$(grep '^cp 32 ' "$TMP/py.out")" "$(grep '^cp 32 ' "$TMP/id.out")"

    # 'o' is a hole, 'A' is a hole and a diagonal, 'i' is two disjoint
    # contours, and 'e' acute is a composite of two other glyphs. The line
    # carries the contour count, the point count, the bounding box of the
    # points, every contour end and every on-curve bit.
    same "$label: the outline of 'o' -- a contour inside a contour" \
         "$(outline_of "$TMP/py.out" 111)" "$(outline_of "$TMP/id.out" 111)"
    same "$label: the outline of 'A' -- a hole with straight sides" \
         "$(outline_of "$TMP/py.out" 65)" "$(outline_of "$TMP/id.out" 65)"
    same "$label: the outline of 'i' -- two separate contours" \
         "$(outline_of "$TMP/py.out" 105)" "$(outline_of "$TMP/id.out" 105)"
    same "$label: the outline of 'e' acute -- a composite glyph" \
         "$(outline_of "$TMP/py.out" 233)" "$(outline_of "$TMP/id.out" 233)"

    same "$label: every glyph in the font, point for point" \
         "$(field "$TMP/py.out" sweep)" "$(field "$TMP/id.out" sweep)"
    # The outline sweep walks glyph ids, so it says nothing about cmap or
    # hmtx. These two walk code points and glyph advances instead.
    same "$label: every third code point up to U+2FFFF, and every advance" \
         "$(field "$TMP/py.out" more)" "$(field "$TMP/id.out" more)"
}

# A font found rather than named cannot be assumed to have an 'o' in it, so
# only the whole-font sweeps are compared for it.
run_sweeps() {
    label=$1; font=$2
    "$TMP/ttf" "$font" > "$TMP/id.out" 2>"$TMP/id.err"
    if ! python3 "$TMP/ref.py" "$font" > "$TMP/py.out" 2>"$TMP/py.err"; then
        bad "$label: the reference reader ran ($(tail -1 "$TMP/py.err"))"
        return
    fi
    same "$label: every glyph in the font, point for point" \
         "$(field "$TMP/py.out" sweep)" "$(field "$TMP/id.out" sweep)"
    same "$label: every third code point up to U+2FFFF, and every advance" \
         "$(field "$TMP/py.out" more)" "$(field "$TMP/id.out" more)"
}

# DejaVu carries a format 12 cmap (it has glyphs above U+FFFF); Liberation
# carries a format 4 one. Between them both lookup paths are exercised, which
# one font cannot do.
if [ -n "$DEJAVU" ]; then
    run_font "DejaVuSans (cmap format 12)" "$DEJAVU"
else
    echo "SKIP: DejaVuSans.ttf not found -- the format 12 cmap path is untested here"
fi
if [ -n "$LIBER" ]; then
    run_font "LiberationSans (cmap format 4)" "$LIBER"
else
    echo "SKIP: LiberationSans-Regular.ttf not found -- the format 4 cmap path is untested here"
fi

# A composite component may carry a 2x2 -- a scale, a mirror, a rotation --
# and neither font above has a single one, so that whole branch of the
# composite reader would go unexecuted. Rather than name a font that may not
# be installed, the machine's fonts are asked which of them has one.
SCALED=$(ls /nix/store/*/share/fonts/truetype/*.ttf \
            /usr/share/fonts/truetype/*/*.ttf \
            /usr/share/fonts/TTF/*.ttf \
            /usr/share/fonts/*/*.ttf 2>/dev/null \
         | xargs -r -n1 sh -c 'printf "%s %s\n" "$(wc -c < "$0")" "$0"' 2>/dev/null \
         | sort -u -k1,1 | awk '{print $2}' | head -30 \
         | python3 "$TMP/ref.py" --find2x2)
if [ -n "$SCALED" ]; then
    run_sweeps "$(basename "$SCALED") (composites with a 2x2)" "$SCALED"
else
    echo "SKIP: no font on this machine builds a glyph from a scaled component -- the 2x2 branch is untested here"
fi

# -- what the parser refuses ------------------------------------------------
# A refusal has to be a message and a 0, not a trap: the editor above this
# will be handed whatever font a document names.
if [ -n "$OTF" ]; then
    out=$("$TMP/ttf" "$OTF" 2>&1)
    if [ "$(printf '%s\n' "$out" | tail -1)" = "load 0" ] && printf '%s' "$out" | grep -q 'OTTO'; then
        ok "a CFF font is refused by name, not by a trap"
    else
        bad "a CFF font is refused by name, not by a trap ($(printf '%s' "$out" | head -1))"
    fi
else
    echo "SKIP: no .otf found -- the CFF refusal is untested here"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
