"""Decoder for the 8-bit Windows BMP files the game ships as screen art.

`inclib/palette.py` already reads the colour table out of a BMP -- that is what
a `.pal` file is -- but it stops there, because a `.pal`'s pixels are a dummy
thumbnail nobody displays.  The 108 files under `Graphics/` are the opposite
case: the pixels *are* the payload.  This module reads them.

Every shipped file is `BM`, a 40-byte `BITMAPINFOHEADER`, 8 bits per pixel,
`BI_RGB` (uncompressed), one plane and bottom-up.  What is **not** uniform is
where the pixels start: `biClrUsed` ranges from 0 (meaning a full 256-entry
table) down to 17, so the pixel offset runs from 122 to 1078.  The file header's
`bfOffBits` at +10 is therefore read rather than assumed -- hard-coding 1078
would misread 44 of the 118.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

from . import palette as palmod

#: `BITMAPFILEHEADER` is 14 bytes; the DIB header follows it.
FILE_HEADER_SIZE = palmod.BMP_FILE_HEADER_SIZE
#: The only DIB header size the corpus uses.
INFO_HEADER_SIZE = 40
#: `BI_RGB`.
COMPRESSION_NONE = 0
BITS_PER_PIXEL = 8
#: Windows pads every pixel row up to a four-byte boundary.
ROW_ALIGNMENT = 4


class BmpError(Exception):
    """Raised when a file is not a readable 8-bit uncompressed BMP."""


@dataclass(frozen=True)
class Image:
    """One decoded image: top-down 8-bit indices plus its colour table."""

    width: int
    height: int
    #: `width * height` palette indices, **top row first** -- PNG's order, not
    #: the file's.
    pixels: bytes
    palette: palmod.Palette

    def write_png(self, path: str, transparent_index: int | None = None) -> None:
        """Write this image as an indexed PNG.

        The default is fully opaque: unlike a `.LIB` sprite, a screen plate has
        no transparent key colour, and index 0 is an ordinary colour in it.
        """
        from . import png as pngmod

        pngmod.write_indexed_png(path, self.width, self.height, self.pixels,
                                 self.palette, transparent_index)


def parse(data: bytes) -> Image:
    """Decode an 8-bit BMP buffer."""
    if data[:2] != b"BM":
        raise BmpError("not a BMP: missing 'BM' signature")
    if len(data) < FILE_HEADER_SIZE + INFO_HEADER_SIZE:
        raise BmpError(f"truncated: {len(data)} bytes")

    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    dib_size = struct.unpack_from("<I", data, FILE_HEADER_SIZE)[0]
    if dib_size != INFO_HEADER_SIZE:
        raise BmpError(f"expected a {INFO_HEADER_SIZE}-byte DIB header, got {dib_size}")

    width, height = struct.unpack_from("<ii", data, FILE_HEADER_SIZE + 4)
    planes, bpp = struct.unpack_from("<HH", data, FILE_HEADER_SIZE + 12)
    compression = struct.unpack_from("<I", data, FILE_HEADER_SIZE + 16)[0]

    if planes != 1:
        raise BmpError(f"expected 1 plane, got {planes}")
    if bpp != BITS_PER_PIXEL:
        raise BmpError(f"expected {BITS_PER_PIXEL} bpp, got {bpp}")
    if compression != COMPRESSION_NONE:
        raise BmpError(f"expected an uncompressed BMP, got compression {compression}")
    if width <= 0 or height == 0:
        raise BmpError(f"degenerate size {width}x{height}")

    # A negative height is a top-down bitmap.  No shipped file uses one, but
    # the sign is the format's own flag and reading it costs nothing.
    top_down = height < 0
    height = abs(height)

    table = palmod.parse_palette(data)

    stride = (width + ROW_ALIGNMENT - 1) // ROW_ALIGNMENT * ROW_ALIGNMENT
    needed = pixel_offset + stride * height
    if len(data) < needed:
        raise BmpError(f"truncated: {len(data)} bytes, need {needed} "
                       f"for {width}x{height} at +{pixel_offset}")

    rows = []
    for y in range(height):
        source = y if top_down else height - 1 - y
        start = pixel_offset + source * stride
        rows.append(data[start:start + width])
    return Image(width, height, b"".join(rows), table)


def load(path: str) -> Image:
    with open(path, "rb") as fh:
        return parse(fh.read())
