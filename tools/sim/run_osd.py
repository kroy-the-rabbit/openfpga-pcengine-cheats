#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Render a frame of rtl/pce/cheat_osd.sv and read the text back off it.

Ported from pocket-gg's tools/sim/run_osd.py.

tb_cheat_osd.sv parses a .cht, draws one 256x224 frame and prints it as
characters. This decodes the picture through the font the RTL drew it with,
read out of rtl/pce/cheat_font.sv, and asserts on the words, which is the only
way to catch a column shift or an off-by-one row: both still produce a
plausible looking panel. A cell holding an undriven pixel decodes as '?'.

Needs Icarus Verilog on PATH, so it is not in `make test`:

    tools/sim/run_osd.py            # the built-in cases
    tools/sim/run_osd.py x.cht      # render one file and print what it says
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILD = os.path.join(ROOT, "build", "sim")
SOURCES = ["tools/sim/tb_cheat_osd.sv", "rtl/pce/cheat_osd.sv",
           "rtl/pce/cheat_loader.sv", "rtl/pce/cheat_titles.sv",
           "rtl/pce/cheat_font.sv"]

ROW = re.compile(r"^ROW (\d+) \|(.*)\|$")
COUNTS = re.compile(r"^COUNTS cheats=(\d+) codes=(\d+)$")
ROM = re.compile(r"rom\[\s*(\d+)\]\s*=\s*8'h([0-9A-Fa-f]{2});")

# cheat_osd's geometry. Normal: 26 characters of a 6 pixel cell after a 3 cell
# inset, 18 rows of 8 after 2. DIAG_SCALE=2 doubles both and draws 13 per row.
CELL, COL0 = 6, 3
NORMAL = dict(scale=1, row0=2, cols=26, rows=18)
DOUBLE = dict(scale=2, row0=1, cols=13, rows=12)


def glyphs() -> dict[tuple[int, ...], str]:
    """The glyph a rendered cell holds, keyed by its seven rows."""
    rom = [0] * 512
    with open(os.path.join(ROOT, "rtl", "pce", "cheat_font.sv")) as fh:
        for m in ROM.finditer(fh.read()):
            rom[int(m.group(1))] = int(m.group(2), 16)
    return {tuple(rom[i * 8:i * 8 + 7]): chr(32 + i) for i in range(64)}


GLYPHS = glyphs()


def build(diag: int = 0, scale: int = 1) -> str:
    for t in ("iverilog", "vvp"):
        if shutil.which(t) is None:
            sys.exit(f"{t} is not on PATH; this check needs Icarus Verilog")
    os.makedirs(BUILD, exist_ok=True)
    out = os.path.join(BUILD, f"tb_cheat_osd_d{diag}s{scale}")
    subprocess.run(["iverilog", "-g2012", "-o", out,
                    f"-Ptb_cheat_osd.DIAG={diag}",
                    f"-Ptb_cheat_osd.DIAG_SCALE={scale}"]
                   + [os.path.join(ROOT, s) for s in SOURCES], check=True)
    return out


def render(exe: str, path: str) -> list[str]:
    r = subprocess.run(["vvp", exe, f"+f={path}"], capture_output=True,
                       text=True, check=True)
    pic: dict[int, str] = {}
    for line in r.stdout.splitlines():
        if m := ROW.match(line):
            pic[int(m.group(1))] = m.group(2)
    return [pic[y] for y in sorted(pic)]


def text_rows(pic: list[str], g: dict) -> list[str]:
    """The panel as one string per text row, decoded through the font."""
    s, cw = g["scale"], CELL * g["scale"]
    out = []
    for tr in range(g["rows"]):
        line = ""
        for col in range(COL0, COL0 + g["cols"]):
            bits, undriven = [], False
            for gr in range(7):
                y = (g["row0"] + tr) * 8 * s + gr * s
                v = 0
                for x in range(5):
                    px = pic[y][col * cw + x * s]
                    undriven |= px == "X"
                    if px == "#":
                        v |= 0x80 >> x
                bits.append(v)
            line += "?" if undriven else GLYPHS.get(tuple(bits), "?")
        out.append(line.rstrip())
    return out


def stray(pic: list[str], g: dict) -> list[str]:
    """Ink in the inset, or anything drawn past the panel."""
    s, cw = g["scale"], CELL * g["scale"]
    right = (COL0 + g["cols"]) * cw
    bad = []
    for y, line in enumerate(pic):
        if y < g["row0"] * 8 * s and line.strip():
            bad.append(f"line {y} is above the panel but drawn")
        elif "#" in line[:COL0 * cw] or "X" in line[:COL0 * cw]:
            bad.append(f"line {y} has ink in the left inset")
        elif line[right:].strip():
            bad.append(f"line {y} is drawn past pixel {right}")
    return bad[:4]


def run(exe: str, name: str, body: str, want: list[str],
        g: dict = NORMAL) -> list[str]:
    with tempfile.NamedTemporaryFile("w", suffix=".cht", delete=False) as fh:
        fh.write(body)
        tmp = fh.name
    try:
        pic = render(exe, tmp)
    finally:
        os.unlink(tmp)
    rows = text_rows(pic, g)
    bad = [f"{name}: {b}" for b in stray(pic, g)]
    for i, w in enumerate(want):
        if rows[i] != w:
            bad.append(f"{name}: row {i} is {rows[i]!r}, want {w!r}")
    return bad


# cheat_loader counts a group's title only when the next cheatN_ key starts,
# so an enabled last group is never counted. Every case ends on a disabled
# group to keep that out of what this checks. See ../docs/HANDOFF.md.
TAIL = ('\ncheat9_desc = "Tail"\ncheat9_code = "1f0000:00"\n'
        'cheat9_enable = false\n')

# One disabled group in the middle, whose name must not survive, and one group
# of three codes, so the two counts differ.
CHEAT = ('cheats = 5\n\n'
         'cheat0_desc = "Infinite Energy"\ncheat0_code = "1f14c5:40"\n'
         'cheat0_enable = true\n\n'
         'cheat1_desc = "Not Wanted"\ncheat1_code = "1f0381:03"\n'
         'cheat1_enable = false\n\n'
         'cheat2_desc = "Max Gold"\n'
         'cheat2_code = "1f152f:09+1f1530:09+1f1531:09"\n'
         'cheat2_enable = true\n\n'
         'cheat3_desc = "Have Bombs"\ncheat3_code = "1f037d:02"\n'
         'cheat3_enable = true\n' + TAIL)

# 26 characters exactly, and one longer, to pin the truncation.
LONG = ('cheats = 2\n\ncheat0_desc = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"\n'
        'cheat0_code = "1f14c5:40"\ncheat0_enable = true\n' + TAIL)

OFF = ('cheats = 1\n\ncheat0_desc = "Not Wanted"\ncheat0_code = "1f14c5:40"\n'
       'cheat0_enable = false\n')

NAMES = ["INFINITE ENERGY", "MAX GOLD", "HAVE BOMBS", ""]


def diag_row(r: int, first: int = 0, n: int = 26) -> str:
    """Row r of the testbench's stand-in for cd_diag's block."""
    return "".join(chr(65 + (r * 5 + c) % 26) for c in range(first, first + n))


def main() -> int:
    exe = build()
    if len(sys.argv) > 1:
        for row in text_rows(render(exe, sys.argv[1]), NORMAL):
            print(f"  |{row}|")
        return 0

    bad = []
    # A single-digit count still reserves its tens column, blank rather than
    # dropped, so a real row here carries a leading space and a doubled one
    # before the second count. digit() in cheat_osd.sv is what decides that.
    bad += run(exe, "three cheats", CHEAT, [" 3 CHEATS  5 CODES"] + NAMES)
    bad += run(exe, "truncation", LONG,
               [" 1 CHEATS  1 CODES", "ABCDEFGHIJKLMNOPQRSTUVWXYZ", ""])
    bad += run(exe, "nothing enabled", OFF, ["NO CHEATS LOADED", ""])
    cases = 3

    # DIAG builds: the header block comes out of cd_diag's RAM instead, and
    # the titles still follow it at normal size.
    bad += run(build(diag=1), "diag", CHEAT,
               [diag_row(r) for r in range(6)] + NAMES)
    bad += run(build(diag=1, scale=2), "diag doubled", CHEAT,
               [diag_row(r // 2, 13 * (r % 2), 13) for r in range(12)], DOUBLE)
    cases += 2

    for b in bad:
        print(f"MISMATCH {b}")
    print(f"cheat_osd: {cases} cases, {len(bad)} mismatches")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
