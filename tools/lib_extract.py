#!/usr/bin/env python3
"""Extract sprites from Incubation .LIB shape libraries as PNG files.

Each .LIB holds raw 8-bit palette-indexed bitmaps. The palette lives in a
same-named .pal file (a Windows BMP whose colour table is the payload); this
tool locates it automatically in gog_incubation/Graphics or next to the library,
and falls back to greyscale when no companion palette exists.

Usage:
    lib_extract.py gog_incubation/Libs/mouse.LIB -o out/
    lib_extract.py gog_incubation --all -o out/
    lib_extract.py gog_incubation --check
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import liblib                                            # noqa: E402
from inclib.liblib import (  # noqa: E402
    ShapeLibrary, LibError, VisnContainerError, load_lib,
)
from inclib.palette import Palette, grayscale_palette, load_palette  # noqa: E402
from inclib.png import write_indexed_png, write_rgb_png  # noqa: E402

LOG = logging.getLogger("lib_extract")

TRANSPARENT_INDEX = liblib.TRANSPARENT_INDEX
"""Palette slot treated as transparent when a library actually uses it.

Only libraries that contain index 0 get a `tRNS` entry. 33 of the 58 shape
libraries -- the whole `Libs/Items/` set -- contain no index-0 pixel at all, so
emitting the entry for them would point at a colour the image never uses while
leaving the real background opaque. What the engine keys on for those is
**UNVERIFIED**; see `docs/60-lib-sprites.md`.
"""

#: The palette companions, and the two families that have none: see
#: :data:`inclib.liblib.NAMED_PALETTES`, :data:`inclib.liblib.PLATE_PALETTES`
#: and :data:`inclib.liblib.UNREFERENCED_LIBRARIES`.
NAMED_PALETTES = liblib.NAMED_PALETTES

HOTSPOT_MARK = 4
"""Half-length, in pixels, of the crosshair arms drawn by --hotspots."""


def find_libs(root: str) -> list[str]:
    out: list[str] = []
    if os.path.isfile(root):
        return [root]
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.lower().endswith(".lib"):
                out.append(os.path.join(dirpath, name))
    return sorted(out)


#: The palette lookup lives in `inclib.liblib` so the converter and this CLI
#: share one implementation rather than two.
find_palette = liblib.find_palette


uses_transparent_index = liblib.uses_transparent_index


def export(lib: ShapeLibrary, palette: Palette, outdir: str, stem: str) -> int:
    os.makedirs(outdir, exist_ok=True)
    # Only key the background out when the library actually contains the index.
    # Writing a tRNS entry for an unused slot leaves the picture fully opaque
    # while claiming otherwise, which is worse than writing no entry at all.
    keyed = TRANSPARENT_INDEX if uses_transparent_index(lib) else None
    if keyed is None:
        LOG.debug("%s: no index %d in any element, writing opaque",
                  stem, TRANSPARENT_INDEX)
    written = 0
    for elem in lib.elements:
        if elem.is_empty:
            LOG.debug("%s element %d is 0x0, skipped", stem, elem.index)
            continue
        path = os.path.join(outdir, f"{stem}_{elem.index:03d}.png")
        write_indexed_png(path, elem.width, elem.height, elem.pixels,
                          palette, keyed)
        written += 1
    return written


def hotspot_sheet(lib: ShapeLibrary, palette: Palette, path: str,
                  scale: int = 4, pad: int = 6) -> None:
    """Write one image with every sprite drawn and its (delta_x, delta_y) marked.

    `delta_x`/`delta_y` are the sprite's anchor point measured from its top-left
    corner: the engine blits so that the anchor lands on the caller's position.
    On mouse.LIB the marks fall exactly on each cursor's tip and on the centre
    of the magnifier lens, which is what establishes the convention.
    """
    tiles = [e for e in lib.elements if not e.is_empty]
    if not tiles:
        return
    width = sum(e.width * scale + pad for e in tiles) + pad
    height = max(e.height * scale for e in tiles) + 2 * pad
    canvas = bytearray(b"\x20\x22\x28" * (width * height))

    def put(x: int, y: int, rgb: tuple[int, int, int]) -> None:
        if 0 <= x < width and 0 <= y < height:
            off = (y * width + x) * 3
            canvas[off:off + 3] = bytes(rgb)

    x0 = pad
    for elem in tiles:
        for sy in range(elem.height):
            for sx in range(elem.width):
                value = elem.pixels[sy * elem.width + sx]
                if value == TRANSPARENT_INDEX:
                    continue
                rgb = palette[value]
                for dy in range(scale):
                    for dx in range(scale):
                        put(x0 + sx * scale + dx, pad + sy * scale + dy, rgb)
        cx = x0 + elem.delta_x * scale + scale // 2
        cy = pad + elem.delta_y * scale + scale // 2
        for d in range(-HOTSPOT_MARK * scale // 2, HOTSPOT_MARK * scale // 2 + 1):
            put(cx + d, cy, (255, 40, 40))
            put(cx, cy + d, (255, 40, 40))
        x0 += elem.width * scale + pad

    write_rgb_png(path, width, height, bytes(canvas))


def describe(lib: ShapeLibrary, path: str, pal_path: str | None) -> dict:
    return {
        "file": path,
        "palette": pal_path,
        "uses_transparent_index": uses_transparent_index(lib),
        "library_type": lib.library_type,
        "element_count": len(lib),
        "elements": [
            {"index": e.index, "width": e.width, "height": e.height,
             "delta_x": e.delta_x, "delta_y": e.delta_y,
             "data_offset": e.data_offset, "data_size": e.data_size}
            for e in lib.elements
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", help="a .LIB file, or a directory to scan")
    parser.add_argument("-o", "--outdir", default="tools/out/sprites")
    parser.add_argument("--all", action="store_true", help="recurse into directories")
    parser.add_argument("--check", action="store_true",
                        help="parse every library and report coverage, write nothing")
    parser.add_argument("--json", action="store_true", help="dump metadata as JSON")
    parser.add_argument("--hotspots", action="store_true",
                        help="write one sheet per library with the anchor points marked")
    parser.add_argument("--game-root", default=None,
                        help="game directory used to find Graphics/*.pal")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    game_root = args.game_root
    if game_root is None and os.path.isdir(args.input):
        game_root = args.input

    paths = find_libs(args.input) if (args.all or args.check or os.path.isdir(args.input)) \
        else [args.input]

    parsed = failed = visn = sprites = 0
    metadata = []
    for path in paths:
        try:
            lib = load_lib(path)
        except VisnContainerError:
            visn += 1
            LOG.debug("%s: VISN container, skipped", path)
            continue
        except LibError as exc:
            failed += 1
            LOG.error("%s: %s", path, exc)
            continue
        parsed += 1
        palette, pal_path = find_palette(path, game_root)
        if args.json or args.check:
            metadata.append(describe(lib, path, pal_path))
        if not args.check:
            stem = os.path.splitext(os.path.basename(path))[0]
            if args.hotspots:
                os.makedirs(args.outdir, exist_ok=True)
                hotspot_sheet(lib, palette,
                              os.path.join(args.outdir, stem + "_hotspots.png"))
                sprites += 1
            else:
                sprites += export(lib, palette, os.path.join(args.outdir, stem), stem)

    if args.json:
        json.dump(metadata, sys.stdout, indent=2)
        sys.stdout.write("\n")

    LOG.info("shape libraries parsed: %d, VISN containers skipped: %d, failures: %d",
             parsed, visn, failed)
    if args.check:
        if not parsed:
            LOG.error("no shape library was parsed under %r -- nothing was "
                      "checked, which is a failure, not a pass", args.input)
            return 1
        # Both of these used to be invisible: a library with no palette was
        # silently exported as a grey ramp, and a tRNS entry was written for
        # index 0 whether or not the library contained one.
        unpalettedd = [m["file"] for m in metadata if not m["palette"]]
        LOG.info("libraries with a palette: %d/%d", parsed - len(unpalettedd), parsed)
        for name in unpalettedd:
            LOG.info("  no palette (exported greyscale): %s", name)
        opaque = [m["file"] for m in metadata if not m["uses_transparent_index"]]
        LOG.info("libraries containing index %d: %d/%d",
                 TRANSPARENT_INDEX, parsed - len(opaque), parsed)
        for name in opaque:
            LOG.info("  no index %d, written opaque: %s", TRANSPARENT_INDEX, name)
    else:
        LOG.info("sprites written: %d -> %s", sprites, args.outdir)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
