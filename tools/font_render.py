#!/usr/bin/env python3
"""Render text with Incubation's bitmap fonts.

The four `Libs/font_*.LIB` shape libraries are proportional bitmap fonts. Each
holds exactly 224 elements, one per cp1252 code point from 32 (space) to 255:

    element_index = codepoint - 32

An element's `delta_y` is the glyph's **ascent**: its top pixel row sits at
`baseline - delta_y`. Within one font, `height - delta_y` is a constant — the
descent, i.e. the rows reserved below the baseline for p/g/q/j and the
underscore. It is 3 in font_0 and font_2 and 2 in font_1 and font_3, so a
renderer must derive it per font rather than assume a value.

`delta_x` is a left side bearing, 0 for every glyph except the two blank ones —
space (index 0) and NBSP (index 128, cp 160) — which carry `delta_x = 3` and
are also the only glyphs exempt from the constant-descent rule in font_0 and
font_2.

Font glyphs are palette indices like any other .LIB sprite, but the fonts ship
without a companion .pal — the caller supplies the palette, so index values act
as an intensity ramp. This tool defaults to a white-on-transparent ramp.

Usage:
    font_render.py font_2 "Incubation" -o out.png
    font_render.py --check gog_incubation
"""

from __future__ import annotations

import argparse
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.liblib import ShapeLibrary, load_lib  # noqa: E402
from inclib.png import write_indexed_png  # noqa: E402

LOG = logging.getLogger("font_render")

FIRST_CODEPOINT = 32
GLYPH_COUNT = 224
BLANK_GLYPHS = (0, 128)
"""Indices of space (cp 32) and NBSP (cp 160), the only glyphs with delta_x != 0."""


class FontError(Exception):
    """Raised when a library is not a usable font."""


def font_descent(lib: ShapeLibrary) -> int:
    """The font's descent: the constant value of `height - delta_y`.

    Derived as the majority value so the two blank glyphs cannot skew it.
    """
    counts: dict[int, int] = {}
    for elem in lib.elements:
        key = elem.height - elem.delta_y
        counts[key] = counts.get(key, 0) + 1
    return max(counts, key=lambda k: counts[k])


def check_font(lib: ShapeLibrary, name: str) -> list[str]:
    """Return a list of problems; empty means the font matches the model."""
    problems = []
    if len(lib) != GLYPH_COUNT:
        problems.append(f"{name}: {len(lib)} elements, expected {GLYPH_COUNT}")
    descent = font_descent(lib)
    for elem in lib.elements:
        if elem.height - elem.delta_y != descent and elem.index not in BLANK_GLYPHS:
            problems.append(f"{name}: glyph {elem.index} (cp {elem.index + FIRST_CODEPOINT}) "
                            f"has height-delta_y = {elem.height - elem.delta_y}, "
                            f"font descent is {descent}")
        if elem.delta_x != 0 and elem.index not in BLANK_GLYPHS:
            problems.append(f"{name}: glyph {elem.index} has delta_x = {elem.delta_x}")
    LOG.debug("%s: descent %d", name, descent)
    return problems


#: What index 2 is worth beside index 1.  All three ramps
#: ``aPrintGUITextBox`` can install are known (``docs/24`` §4.2) and two of
#: them agree: ``0x632C / 0xFFFF`` for ``{#0}`` and ``0x6000 / 0xF800`` for
#: ``{#2}`` are both 12/31, and the body ramp's ``0x528A / 0x94B2`` is 10/18.
#: A sample is drawn in the first, the one every text box starts in.
#: See :func:`ramp_palette`.
SHADE_COVERAGE = 12 / 31


def ramp_palette() -> list[tuple[int, int, int]]:
    """Index 0 transparent, index 1 solid white, index 2 the shade beside it.

    Font libraries ship without a companion .pal, so the caller supplies the
    colour, and using the raw index as a grey level would render most glyphs
    near-black.  But a flat white for *every* non-zero index is wrong too:
    **index 2 is the glyph's antialiasing**.  The blitter ``0x00447900`` maps
    the value straight onto the caller's colour array -- at ``0x00447ADD``, the
    16-bit path, a 1 takes ``colour[0]`` and everything else ``colour[1]`` --
    and every ramp ``aPrintGUITextBox`` can install makes ``colour[1]`` a
    mid-tone of ``colour[0]``.  Painting it solid fattens every stem and fills
    the counters of ``a``, ``o`` and ``e``.
    """
    shade = int(round(255 * SHADE_COVERAGE))
    return ([(0, 0, 0), (255, 255, 255), (shade, shade, shade)]
            + [(255, 255, 255)] * 253)


def render(lib: ShapeLibrary, text: str, tracking: int = 1,
           padding: int = 2) -> tuple[int, int, bytes]:
    """Lay out `text` on a common baseline. Returns (width, height, pixels)."""
    glyphs = []
    for ch in text:
        index = ord(ch) - FIRST_CODEPOINT
        if not 0 <= index < len(lib):
            raise FontError(f"character {ch!r} (U+{ord(ch):04X}) is outside the font")
        glyphs.append(lib[index])

    ascent = max(g.delta_y for g in glyphs)
    descent = max(g.height - g.delta_y for g in glyphs)
    height = ascent + descent + 2 * padding
    width = sum(g.width + tracking for g in glyphs) + 2 * padding
    baseline = padding + ascent

    buf = bytearray(width * height)
    x = padding
    for g in glyphs:
        top = baseline - g.delta_y
        for row in range(g.height):
            dst = (top + row) * width + x + g.delta_x
            src = row * g.width
            for col in range(g.width):
                value = g.pixels[src + col]
                if value:
                    buf[dst + col] = value
        x += g.width + tracking
    return width, height, bytes(buf)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("font", nargs="?",
                        help="font name (font_0..font_3) or a path to a .LIB")
    parser.add_argument("text", nargs="?", default="Incubation")
    parser.add_argument("-o", "--output", default="tools/out/font_sample.png")
    parser.add_argument("--check", metavar="ROOT",
                        help="validate every font library under ROOT and exit")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    if args.check:
        pass
    elif not args.font:
        parser.error("a font is required unless --check is given")

    if args.check:
        problems: list[str] = []
        checked = 0
        for i in range(4):
            path = os.path.join(args.check, "Libs", f"font_{i}.LIB")
            if not os.path.isfile(path):
                LOG.error("missing %s", path)
                problems.append(path)
                continue
            problems += check_font(load_lib(path), f"font_{i}")
            checked += 1
        LOG.info("fonts checked: %d, problems: %d", checked, len(problems))
        for p in problems[:20]:
            LOG.error("%s", p)
        return 1 if problems else 0

    path = args.font if os.path.isfile(args.font) else \
        os.path.join("gog_incubation", "Libs", args.font + ".LIB")
    lib = load_lib(path)
    width, height, pixels = render(lib, args.text)
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    write_indexed_png(args.output, width, height, pixels, ramp_palette(), 0)
    LOG.info("wrote %s (%dx%d)", args.output, width, height)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
