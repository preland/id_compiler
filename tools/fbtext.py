#!/usr/bin/env python3
"""Read the kernel's framebuffer back as text.

    tools/fbtext.py shot.ppm

The kernel draws its console with the 8x16 font in
kernel/prog/sys/gfx/font/rom/*.id, so a screenshot can be turned back into the
characters that produced it by matching each cell against that same font. That
is what makes a *graphical* shell testable: without it the only thing a test
can check is the serial port, and the serial port is not the screen.

Matching is exact where it can be and nearest-Hamming otherwise, because
anti-aliasing does not apply -- the console blits whole bits.
"""
import glob, os, re, sys

FIRST = 32
COLS, ROWS, CW, CH = 80, 30, 8, 16
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def font():
    """The glyphs, in code-point order, as lists of 16 row bytes."""
    parts = []
    for p in sorted(glob.glob(f"{ROOT}/kernel/prog/sys/gfx/font/rom/rom0.id")
                    + glob.glob(f"{ROOT}/kernel/prog/sys/gfx/font/rom/more/rom*.id")):
        m = re.search(r'return string "([0-9a-f]*)"', open(p).read())
        if m:
            parts.append((p, m.group(1)))
    # rom0 first, then more/rom1, rom2, rom3 -- the order font_rom() joins them
    parts.sort(key=lambda kv: int(re.search(r"rom(\d+)\.id", kv[0]).group(1)))
    hexed = "".join(v for _, v in parts)
    b = [int(hexed[i:i + 2], 16) for i in range(0, len(hexed), 2)]
    return [b[g * 16:(g + 1) * 16] for g in range(len(b) // 16)]


def ppm(path):
    d = open(path, "rb").read()
    if not d.startswith(b"P6"):
        sys.exit(f"{path}: not a binary PPM")
    parts, at = [], 2
    while len(parts) < 3:
        while d[at:at + 1].isspace():
            at += 1
        if d[at:at + 1] == b"#":
            while d[at:at + 1] != b"\n":
                at += 1
            continue
        s = at
        while not d[at:at + 1].isspace():
            at += 1
        parts.append(int(d[s:at]))
    return parts[0], parts[1], d[at + 1:]


def main():
    w, h, px = ppm(sys.argv[1])
    gl = font()
    out = []
    for cy in range(min(ROWS, h // CH)):
        line = []
        for cx in range(min(COLS, w // CW)):
            rows = []
            for r in range(CH):
                bits = 0
                for c in range(CW):
                    o = ((cy * CH + r) * w + cx * CW + c) * 3
                    lit = (px[o] + px[o + 1] + px[o + 2]) // 3 > 0x60
                    bits = bits * 2 + (1 if lit else 0)
                rows.append(bits)
            if not any(rows):
                line.append(" ")
                continue
            best, score = " ", 10 ** 9
            for g, want in enumerate(gl):
                d = sum(bin(a ^ b).count("1") for a, b in zip(rows, want))
                if d < score:
                    best, score = chr(FIRST + g), d
            line.append(best)
        out.append("".join(line).rstrip())
    while out and not out[-1]:
        out.pop()
    print("\n".join(out))


main()
