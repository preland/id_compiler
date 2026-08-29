#!/usr/bin/env bash
# The glyph rasteriser turns a real font's outlines into anti-aliased
# coverage, and two independent implementations agree about what it should
# be.
#
# Nothing here is asserted against a constant. Every expected value is
# computed at test time, out of the same font file, by the Python reference
# below -- which is two references, because there are two questions:
#
#   * Is the bitmap the right SHAPE? A second rasteriser reads the same
#     outline data and produces its own bitmap, and the two are compared cell
#     for cell. It is written out of the format's rules rather than out of the
#     `id` code, and it is what catches a wrong contour start, a dropped
#     implied on-curve point, an unflipped y, or a bounding box rounded the
#     wrong way.
#
#   * Is it the right AMOUNT of ink? That is answered from the geometry alone
#     with no sampling grid anywhere in it: the signed area the flattened
#     outline encloses. A rasteriser that agrees with the first reference but
#     not with the area of the shape it was handed is wrong about the scale
#     factor or about which way a contour winds.
#
# The winding check is the one that needs a glyph chosen rather than named.
# Nonzero and even-odd give the same answer for an 'o' -- an inner contour
# wound the other way cancels under both -- so the test hunts the font for a
# glyph whose contours actually OVERLAP, where the two rules differ, and
# asserts the rasteriser agrees with nonzero and disagrees with even-odd.
#
# Run from anywhere: tests/editor_ras.sh   (needs python3 and a TrueType font)
set -u
cd "$(dirname "$0")"
ROOT=..
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -- want [$2] got [$3]"; fi; }

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: editor rasteriser tests (need python3 on PATH for the reference)"
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

if [ -z "$DEJAVU" ] && [ -z "$LIBER" ]; then
    echo "SKIP: editor rasteriser tests (no TrueType font found -- looked for DejaVuSans.ttf and LiberationSans-Regular.ttf)"
    exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# -- the program under test -------------------------------------------------
# `editor/` is a library and has no main, so the smallest thing that can call
# ras_scale is a program built out of the font module, the shared byte readers
# under it, and a main that calls the module's own ras_selftest.
PROJ="$TMP/p"
mkdir -p "$PROJ/font" "$PROJ/byte"
cp -r "$ROOT/editor/lib/font/." "$PROJ/font/"
cp "$ROOT"/editor/lib/zip/byte/*.id "$PROJ/byte/"
cat > "$PROJ/main.id" <<'IDEOF'
main(int argc, string[] argv) {
  ras_selftest(argv);
} return int 0;
IDEOF
printf 'import "%s/backends/fs"\n' "$(cd "$ROOT" && pwd)" > "$PROJ/conf.id"

if ! "$ROOT/bin/idc" "$PROJ" -o "$TMP/ras" >"$TMP/build.log" 2>&1; then
    bad "the rasteriser builds ($(head -3 "$TMP/build.log" | tr '\n' ' '))"
    echo; echo "$pass passed, $fail failed"; exit 1
fi
ok "the rasteriser builds"

# -- the reference ----------------------------------------------------------
cat > "$TMP/ras.py" <<'PYEOF'
import struct, sys


# ---------------------------------------------------------------------------
# The font, read again. struct only; fontTools is not assumed to be installed.
# This half is the reader tests/editor_ttf.sh already checks against the `id`
# parser field by field, so the rasteriser reference starts from outline data
# that is known to be right.
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
        endb, startb = at + 14, at + 16 + n * 2
        deltab, rob = at + 16 + n * 4, at + 16 + n * 6
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
                pts[i] = (f2d(m[0] * x + m[2] * y) + a1, f2d(m[1] * x + m[3] * y) + a2, on)
            if not (k & 32):
                break


def f2d(v):
    # F2Dot14 divided back out, rounded half away from zero.
    return (v + 8192) // 16384 if v >= 0 else -((-v + 8192) // 16384)


# ---------------------------------------------------------------------------
# The rasteriser, again.
#
# Same sampling model as the module under test and the same 1/64 pixel fixed
# point -- a comparison of bitmaps is only meaningful if both were asked for
# the same thing -- but its own code for every decision that model leaves
# open: where a contour starts, where the implied on-curve points are, how
# many pieces a curve becomes, which way the y axis runs, where the bounding
# box rounds to.
def tdiv(n, d):
    # C integer division truncates towards zero; Python's // floors.
    q = abs(n) // abs(d)
    return q if (n < 0) == (d < 0) else -q


def half(v):
    return v // 2 if v >= 0 else -((-v) // 2)


def bez(b, c, v, j, n):
    m = n - j
    return tdiv(m * m * b + 2 * m * j * c + j * j * v, n * n)


class R:
    def __init__(self, f, g, px, rule='nonzero'):
        self.f, self.px, self.upem, self.rule = f, px, f.upem, rule
        self.ends, self.pts = f.outline(g)
        self.x0, self.y0, self.x1, self.y1 = [], [], [], []
        self.w = self.h = self.bx = self.by = 0
        self.cov = []
        for k in range(len(self.ends)):
            self.contour(0 if k == 0 else self.ends[k - 1] + 1, self.ends[k])
        if self.x0:
            self.box()
            self.fill()

    # -- the transform ------------------------------------------------------
    def fu(self, v):
        return tdiv(v * self.px * 64, self.upem)

    def dx(self, m):
        return self.fu(self.pts[m][0])

    def dy(self, m):
        return -self.fu(self.pts[m][1])

    def on(self, m):
        return self.pts[m][2]

    # -- flattening ---------------------------------------------------------
    # Three ways for a contour to start, and the third is also the contour
    # that has no on-curve point anywhere in it.
    def contour(self, lo, hi):
        if self.on(lo):
            st, i, end = (self.dx(lo), self.dy(lo)), lo + 1, hi + 1
        elif self.on(hi):
            st, i, end = (self.dx(hi), self.dy(hi)), lo, hi
        else:
            st = (half(self.dx(lo) + self.dx(hi)), half(self.dy(lo) + self.dy(hi)))
            i, end = lo, hi + 1
        cur, ctl = st, None
        while i < end:
            q = (self.dx(i), self.dy(i))
            if self.on(i):
                cur = self.quad(cur, ctl, q) if ctl else self.line(cur, q)
                ctl = None
            else:
                if ctl:
                    cur = self.quad(cur, ctl, (half(ctl[0] + q[0]), half(ctl[1] + q[1])))
                ctl = q
            i += 1
        if ctl:
            self.quad(cur, ctl, st)
        else:
            self.line(cur, st)

    def line(self, cur, q):
        self.x0.append(cur[0]); self.y0.append(cur[1])
        self.x1.append(q[0]);   self.y1.append(q[1])
        return q

    def quad(self, p0, c, p1):
        n = abs(c[0] - p0[0]) + abs(c[1] - p0[1]) + abs(p1[0] - c[0]) + abs(p1[1] - c[1])
        n = min(32, max(1, n // 128 + 1))
        cur = p0
        for j in range(1, n + 1):
            cur = self.line(cur, (bez(p0[0], c[0], p1[0], j, n),
                                  bez(p0[1], c[1], p1[1], j, n)))
        return cur

    # -- the box, rounded outwards -----------------------------------------
    def box(self):
        lo, hi = min(self.x0) // 64, -((-max(self.x0)) // 64)
        self.w, self.bx = hi - lo, lo
        lo, hi = min(self.y0) // 64, -((-max(self.y0)) // 64)
        self.h, self.by = hi - lo, -lo

    # -- the fill -----------------------------------------------------------
    def fill(self):
        self.cov = [[0] * self.w for _ in range(self.h)]
        for r in range(self.h):
            acc = [0] * self.w
            for j in range(4):
                self.sample((r - self.by) * 64 + j * 16 + 8, acc)
            for x in range(self.w):
                self.cov[r][x] = acc[x] * 255 // 256

    def sample(self, y, acc):
        cuts = []
        for i in range(len(self.x0)):
            lo, hi = self.y0[i], self.y1[i]
            v = 1 if lo <= y < hi else (-1 if hi <= y < lo else 0)
            if v:
                at = self.x0[i] + tdiv((self.x1[i] - self.x0[i]) * (y - lo), (self.y1[i] - lo))
                cuts.append((min(max(at - self.bx * 64, 0), self.w * 64), v))
        cuts.sort()
        wind, k = 0, 0
        for c in range(self.w * 64):
            while k < len(cuts) and cuts[k][0] <= c:
                wind += cuts[k][1]; k += 1
            if (wind != 0) if self.rule == 'nonzero' else (wind % 2 != 0):
                acc[c // 64] += 1

    def dim(self):
        return (self.w, self.h, self.bx, self.by)

    def lines(self, cp, px):
        out = ['dim %d %d %d %d %d %d %d'
               % (cp, px, self.w, self.h, self.bx, self.by,
                  1 if self.w > 0 and self.h > 0 else 0)]
        for i, r in enumerate(self.cov):
            out.append('cov %d %d %d %s' % (cp, px, i, ' '.join(str(v) for v in r)))
        return out

    # The ink the outline encloses, from the geometry and nothing else: the
    # signed area of the closed polygon. A hole wound the other way subtracts
    # itself, which is the nonzero rule stated as arithmetic.
    def ink(self):
        s = 0
        for i in range(len(self.x0)):
            s += self.x0[i] * self.y1[i] - self.x1[i] * self.y0[i]
        return abs(s) / 2.0 / 4096.0


# ---------------------------------------------------------------------------
# Facts read back out of a bitmap dump, whoever produced it. The same code
# runs over the `id` program's output and over the reference's, so a
# disagreement about a hole is a disagreement about the bitmap and not about
# what counts as one.
RAMP = ' .:-=+*#%@'


def read_dump(path):
    shots = {}
    order = []
    for ln in open(path):
        p = ln.split()
        if not p:
            continue
        if p[0] == 'dim':
            k = (int(p[1]), int(p[2]))
            shots[k] = []
            order.append(k)
        elif p[0] == 'cov':
            shots[(int(p[1]), int(p[2]))].append([int(v) for v in p[4:]])
    return order, shots


def blobs(grid, want):
    # 4-connected components of the cells that pass `want`, and how many of
    # them touch no border -- an enclosed background component is a hole.
    h = len(grid)
    w = len(grid[0]) if h else 0
    seen = [[False] * w for _ in range(h)]
    n = shut = 0
    for y in range(h):
        for x in range(w):
            if seen[y][x] or not want(grid[y][x]):
                continue
            n += 1
            edge = False
            stack = [(x, y)]
            seen[y][x] = True
            while stack:
                cx, cy = stack.pop()
                if cx == 0 or cy == 0 or cx == w - 1 or cy == h - 1:
                    edge = True
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and want(grid[ny][nx]):
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            if not edge:
                shut += 1
    return n, shut


def facts(path):
    order, shots = read_dump(path)
    out = []
    for (cp, px) in order:
        grid = shots[(cp, px)]
        if not grid:
            out.append('total %d %d 0' % (cp, px))
            continue
        out.append('total %d %d %d' % (cp, px, sum(sum(r) for r in grid)))
        ink, _ = blobs(grid, lambda v: v >= 128)
        _, holes = blobs(grid, lambda v: v < 128)
        out.append('regions %d %d %d' % (cp, px, ink))
        out.append('holes %d %d %d' % (cp, px, holes))
        out.append('centre %d %d %d' % (cp, px, grid[len(grid) // 2][len(grid[0]) // 2]))
        for r in grid:
            out.append('art %d %d |%s|' % (cp, px, ''.join(RAMP[min(9, v * 10 // 256)] for v in r)))
    return out


# ---------------------------------------------------------------------------
# A glyph whose contours overlap, so that nonzero and even-odd disagree about
# it. Named glyphs do not do this -- an 'o' looks the same under both rules --
# so the font is asked which of its glyphs does.
def overlap(f):
    rev = {}
    for cp in range(0x30000):
        g = f.glyph(cp)
        if g and g not in rev:
            rev[g] = cp
    cand = []
    for g in sorted(rev):
        e, p = f.outline(g)
        if len(e) < 2:
            continue
        cs, lo = [], 0
        for k in range(len(e)):
            hi = e[k]
            q = [(a[0], a[1]) for a in p[lo:hi + 1]]
            lo = hi + 1
            if len(q) >= 3:
                cs.append(q)
        for j in range(len(cs)):
            if any(abs(sum(pnw(c, x, y) for c in cs)) >= 2 for (x, y) in cs[j][::2]):
                cand.append(g)
                break
    best = None
    for g in cand[:40]:
        a, b = R(f, g, 24), R(f, g, 24, 'evenodd')
        if a.dim() != b.dim() or not a.cov:
            continue
        t = sum(sum(r) for r in a.cov)
        d = sum(abs(u - v) for r, s in zip(a.cov, b.cov) for u, v in zip(r, s))
        if t and (best is None or d / t > best[0]):
            best = (d / t, g, rev[g])
    return best


def pnw(poly, x, y):
    # Winding number of a polygon about a point, by counting the crossings of
    # a ray to the right of it.
    w = 0
    n = len(poly)
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % n]
        if y0 <= y < y1 or y1 <= y < y0:
            if x0 + (x1 - x0) * (y - y0) / (y1 - y0) > x:
                w += 1 if y1 > y0 else -1
    return w


mode = sys.argv[1]
if mode == '--facts':
    print('\n'.join(facts(sys.argv[2])))
elif mode == '--overlap':
    b = overlap(F(sys.argv[2]))
    print('%d %.3f' % (b[2], b[0]) if b else '0 0')
else:
    fnt = F(sys.argv[2])
    pairs = [(int(sys.argv[i]), int(sys.argv[i + 1])) for i in range(3, len(sys.argv), 2)]
    if mode == '--ref':
        for cp, px in pairs:
            print('\n'.join(R(fnt, fnt.glyph(cp), px).lines(cp, px)))
    elif mode == '--evenodd':
        for cp, px in pairs:
            print('\n'.join(R(fnt, fnt.glyph(cp), px, 'evenodd').lines(cp, px)))
    elif mode == '--ink':
        for cp, px in pairs:
            print('ink %d %d %.1f' % (cp, px, R(fnt, fnt.glyph(cp), px).ink() * 255.0))
PYEOF

# The glyphs, and why each is here.
#   o   a contour inside a contour, wound the other way: the hole
#   A   a hole with straight sides, and diagonals that anti-alias
#   i   two disjoint contours in one glyph
#   e-acute  a composite, built out of two other glyphs at an offset
#   g   a descender, so the bitmap sits below the baseline as well as above
#   m   small, where four y samples per row is all the vertical detail there is
#   W   large, where the curve step count has to grow with the size
PAIRS="111 16 111 32 65 16 65 32 105 32 233 32 103 24 109 12 87 48"

run_font() {
    label=$1; font=$2
    # shellcheck disable=SC2086
    "$TMP/ras" "$font" $PAIRS > "$TMP/id.out" 2>"$TMP/id.err"
    if [ "$(head -1 "$TMP/id.out")" != "load 1" ]; then
        bad "$label: the font is accepted ($(head -1 "$TMP/id.err"))"
        return
    fi
    # shellcheck disable=SC2086
    if ! python3 "$TMP/ras.py" --ref "$font" $PAIRS > "$TMP/py.out" 2>"$TMP/py.err"; then
        bad "$label: the reference rasteriser ran ($(tail -1 "$TMP/py.err"))"
        return
    fi
    # shellcheck disable=SC2086
    python3 "$TMP/ras.py" --ink "$font" $PAIRS > "$TMP/ink.out"
    tail -n +2 "$TMP/id.out" > "$TMP/id.grid"
    python3 "$TMP/ras.py" --facts "$TMP/id.grid" > "$TMP/id.fact"
    python3 "$TMP/ras.py" --facts "$TMP/py.out"  > "$TMP/py.fact"

    set -- $PAIRS
    while [ $# -gt 1 ]; do
        cp=$1; px=$2; shift 2
        # The placement: width, height, left bearing and rows above the
        # baseline. A renderer that gets these wrong draws the right glyph in
        # the wrong place, which no coverage total would notice.
        same "$label: U+$(printf '%04X' "$cp") at ${px}px is placed and sized" \
             "$(grep "^dim $cp $px " "$TMP/py.out")" "$(grep "^dim $cp $px " "$TMP/id.grid")"
        # Every pixel of it.
        same "$label: U+$(printf '%04X' "$cp") at ${px}px, pixel for pixel" \
             "$(grep -c "^cov $cp $px " "$TMP/py.out"):$(grep "^cov $cp $px " "$TMP/py.out" | cksum)" \
             "$(grep -c "^cov $cp $px " "$TMP/id.grid"):$(grep "^cov $cp $px " "$TMP/id.grid" | cksum)"
        # And the total, against the area of the shape rather than against
        # another sampling of it. Below 16px four y samples per row is coarse
        # enough that the two legitimately differ by more than this, so the
        # small sizes are checked for shape only.
        if [ "$px" -ge 16 ]; then
            want=$(grep "^ink $cp $px " "$TMP/ink.out" | awk '{print $4}')
            got=$(grep "^total $cp $px " "$TMP/id.fact" | awk '{print $4}')
            if [ -n "$want" ] && [ -n "$got" ] && \
               awk -v a="$want" -v b="$got" 'BEGIN{exit !(a>0 && (b-a)/a<0.03 && (a-b)/a<0.03)}'; then
                ok "$label: U+$(printf '%04X' "$cp") at ${px}px inks the area the outline encloses ($got vs $want)"
            else
                bad "$label: U+$(printf '%04X' "$cp") at ${px}px inks the area the outline encloses -- want ~$want got $got"
            fi
        fi
    done

    # Every derived fact -- totals, ink regions, enclosed holes, the centre
    # pixel and the ASCII art of every glyph -- read out of both bitmaps by
    # the same code.
    same "$label: what the bitmaps say about themselves" \
         "$(cksum < "$TMP/py.fact")" "$(cksum < "$TMP/id.fact")"

    # The claims worth stating in their own right, so that a change to the
    # reference cannot quietly make them vacuous.
    same "$label: 'o' has a hole -- one enclosed background region" \
         "holes 111 32 1" "$(grep '^holes 111 32 ' "$TMP/id.fact")"
    same "$label: 'o' is empty in the middle of it" \
         "centre 111 32 0" "$(grep '^centre 111 32 ' "$TMP/id.fact")"
    same "$label: 'o' is a single ring, not two arcs" \
         "regions 111 32 1" "$(grep '^regions 111 32 ' "$TMP/id.fact")"
    same "$label: 'i' inks two disjoint regions -- the stem and the dot" \
         "regions 105 32 2" "$(grep '^regions 105 32 ' "$TMP/id.fact")"
    same "$label: 'e' acute, a composite, inks in two places" \
         "regions 233 32 2" "$(grep '^regions 233 32 ' "$TMP/id.fact")"
    same "$label: 'A' has a hole" \
         "holes 65 32 1" "$(grep '^holes 65 32 ' "$TMP/id.fact")"

    # One glyph as a picture, so that a failure anywhere above has something
    # a person can look at.
    same "$label: 'A' at 16px, drawn" \
         "$(grep '^art 65 16 ' "$TMP/py.fact")" "$(grep '^art 65 16 ' "$TMP/id.fact")"

    # -- the winding rule ---------------------------------------------------
    # Even-odd and nonzero agree about every glyph whose contours merely nest.
    # They disagree about one whose contours OVERLAP, so the font is searched
    # for one and the rasteriser is asked to take a side.
    found=$(python3 "$TMP/ras.py" --overlap "$font")
    wcp=$(echo "$found" | awk '{print $1}')
    wratio=$(echo "$found" | awk '{print $2}')
    if [ "$wcp" = "0" ] || awk -v r="$wratio" 'BEGIN{exit !(r<0.02)}'; then
        echo "SKIP: $label: no glyph in this font has overlapping contours, so nonzero and even-odd cannot be told apart here"
    else
        "$TMP/ras" "$font" "$wcp" 24 | tail -n +2 > "$TMP/w.id"
        python3 "$TMP/ras.py" --ref "$font" "$wcp" 24 > "$TMP/w.nz"
        python3 "$TMP/ras.py" --evenodd "$font" "$wcp" 24 > "$TMP/w.eo"
        same "$label: U+$(printf '%04X' "$wcp") -- overlapping contours -- fills by nonzero winding" \
             "$(cksum < "$TMP/w.nz")" "$(cksum < "$TMP/w.id")"
        if [ "$(cksum < "$TMP/w.eo")" = "$(cksum < "$TMP/w.id")" ]; then
            bad "$label: U+$(printf '%04X' "$wcp") is NOT filled by the even-odd rule"
        else
            ok "$label: U+$(printf '%04X' "$wcp") is NOT filled by the even-odd rule"
        fi
    fi
}

# DejaVu and Liberation draw the same letters out of different outlines --
# different point counts, different contour directions in places, and
# different composites -- so agreeing about both is worth more than agreeing
# about either twice.
if [ -n "$DEJAVU" ]; then
    run_font "DejaVuSans" "$DEJAVU"
else
    echo "SKIP: DejaVuSans.ttf not found"
fi
if [ -n "$LIBER" ]; then
    run_font "LiberationSans" "$LIBER"
else
    echo "SKIP: LiberationSans-Regular.ttf not found"
fi

# -- a glyph with nothing in it ---------------------------------------------
# A space has an advance and no contour. ras_scale must say 0 and leave a
# bitmap of no size, rather than trapping or producing one pixel of nothing.
if [ -n "$DEJAVU" ]; then
    same "a space has no bitmap at all" \
         "dim 32 16 0 0 0 0 0" "$("$TMP/ras" "$DEJAVU" 32 16 | grep '^dim ')"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
