"""Minimal dependency-free PNG writer.

The format tools only need to dump indexed or RGBA images for inspection, so a
small encoder here avoids making Pillow a hard requirement.
"""

from __future__ import annotations

import struct
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _chunk(tag: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def write_indexed_png(path: str, width: int, height: int, pixels: bytes,
                      palette: list[tuple[int, int, int]],
                      transparent_index: int | None = 0) -> None:
    """Write an 8-bit palette-indexed PNG.

    `pixels` must hold width*height bytes in top-to-bottom row order.
    `transparent_index` marks one palette slot fully transparent; pass None to
    write the image fully opaque.
    """
    if len(pixels) != width * height:
        raise ValueError(f"expected {width * height} pixels, got {len(pixels)}")

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw += pixels[y * width:(y + 1) * width]

    plte = b"".join(struct.pack("3B", *rgb) for rgb in palette)
    body = [
        _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)),
        _chunk(b"PLTE", plte),
    ]
    if transparent_index is not None:
        alpha = bytes(0 if i == transparent_index else 255 for i in range(len(palette)))
        body.append(_chunk(b"tRNS", alpha))
    body.append(_chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
    body.append(_chunk(b"IEND", b""))

    with open(path, "wb") as fh:
        fh.write(PNG_SIGNATURE + b"".join(body))


def write_rgb_png(path: str, width: int, height: int, rgb: bytes) -> None:
    """Write a 24-bit truecolour PNG from packed RGB triples."""
    if len(rgb) != width * height * 3:
        raise ValueError(f"expected {width * height * 3} bytes, got {len(rgb)}")
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgb[y * width * 3:(y + 1) * width * 3]
    body = (_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + _chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(PNG_SIGNATURE + body)
