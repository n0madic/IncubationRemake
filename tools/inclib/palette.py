"""Loader for Incubation .pal palette files.

A .pal file is an ordinary Windows BMP. The image content is a small dummy
thumbnail that the game never displays; the payload is the 256-entry colour
table in the BMP header, which is the palette that the matching .LIB sprite
library is drawn with.
"""

from __future__ import annotations

import logging
import struct

LOG = logging.getLogger(__name__)

PALETTE_SIZE = 256
BMP_FILE_HEADER_SIZE = 14

Palette = list[tuple[int, int, int]]


class PaletteError(Exception):
    """Raised when a .pal file is not a readable 8-bit BMP."""


def parse_palette(data: bytes) -> Palette:
    """Return the RGB colour table of a .pal (BMP) buffer, padded to 256 entries."""
    if data[:2] != b"BM":
        raise PaletteError("not a BMP: missing 'BM' signature")
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    dib_size = struct.unpack_from("<I", data, BMP_FILE_HEADER_SIZE)[0]
    bpp = struct.unpack_from("<H", data, BMP_FILE_HEADER_SIZE + 14)[0]
    if bpp != 8:
        raise PaletteError(f"expected 8 bpp, got {bpp}")

    table_start = BMP_FILE_HEADER_SIZE + dib_size
    entry_count = (pixel_offset - table_start) // 4
    if entry_count <= 0:
        raise PaletteError("BMP carries no colour table")
    if entry_count > PALETTE_SIZE:
        LOG.warning("colour table has %d entries, clamping to %d", entry_count, PALETTE_SIZE)
        entry_count = PALETTE_SIZE

    palette: Palette = []
    for i in range(entry_count):
        b, g, r, _reserved = data[table_start + i * 4: table_start + i * 4 + 4]
        palette.append((r, g, b))
    # Some files ship a short table (mouse.pal has 254 entries); pad with black.
    palette.extend([(0, 0, 0)] * (PALETTE_SIZE - len(palette)))
    return palette


def load_palette(path: str) -> Palette:
    with open(path, "rb") as fh:
        return parse_palette(fh.read())


def grayscale_palette() -> Palette:
    """Fallback palette used when no .pal companion exists."""
    return [(i, i, i) for i in range(PALETTE_SIZE)]
