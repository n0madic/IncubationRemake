"""Parser for Incubation .LIB sprite libraries (the aLIB "shape library" format).

Layout
------
The file is a 20-byte header, a table of fixed 36-byte element records, and a
single blob of raw 8-bit palette-indexed pixel data. Element records address
that blob by cumulative offset; the pixels are NOT compressed.

    Header (20 bytes)
        u32 library_type   always 0xFF in the shipped data
        u32 element_count
        u32 used_size      20 + 36*element_count + sum(element sizes)
        u32 table_offset   always 20 (start of the element table)
        u32 data_offset    20 + 36*element_count (start of the pixel blob)

    Element record (36 bytes)
        u32 element_type   always 2 in the shipped data
        u32 width
        u32 height
        u32 runtime_ptr    scratch slot; holds leftover heap pointers on disk
        u32 data_offset    byte offset into the pixel blob
        u32 index          the record's own index, 0-based
        u32 data_size      always width * height
        i32 delta_x        blit offset / hot spot, X
        i32 delta_y        blit offset / hot spot, Y

Evidence: the aLIB debug format strings in Incubation.exe read
"Type:%d / Entries:%d" and "%d/[%d]_%d_(W_%d,H_%d) (dX_%d,dY_%d)".

Note that `runtime_ptr` is uninitialised memory in many shipped files (values
such as 0x81CCB500 appear); parsers must ignore it.
"""

from __future__ import annotations

import logging
import struct
from dataclasses import dataclass

LOG = logging.getLogger(__name__)

HEADER_SIZE = 20
ELEMENT_RECORD_SIZE = 36
EXPECTED_LIBRARY_TYPE = 0xFF
EXPECTED_ELEMENT_TYPE = 2
VISN_MAGIC = b"VISN"


class LibError(Exception):
    """Raised when a .LIB file does not match the documented layout."""


class VisnContainerError(LibError):
    """The file is a VISN texture container, not a shape library.

    A distinct type so callers can branch on it. They used to test for the
    substring ``"VISN"`` in the message, which made a reworded sentence change
    a corpus count.
    """


@dataclass(frozen=True)
class LibElement:
    """One sprite in a shape library."""

    index: int
    element_type: int
    width: int
    height: int
    data_offset: int
    data_size: int
    delta_x: int
    delta_y: int
    pixels: bytes

    @property
    def is_empty(self) -> bool:
        return self.width == 0 or self.height == 0


@dataclass
class ShapeLibrary:
    """A parsed .LIB file."""

    library_type: int
    used_size: int
    data_offset: int
    elements: list[LibElement]

    def __len__(self) -> int:
        return len(self.elements)

    def __getitem__(self, i: int) -> LibElement:
        return self.elements[i]


def parse_lib(data: bytes) -> ShapeLibrary:
    """Parse a .LIB buffer into a ShapeLibrary."""
    if data[:4] == VISN_MAGIC:
        raise VisnContainerError(
            "VISN container, not a shape library (see docs/50-visn-textures.md)")
    if len(data) < HEADER_SIZE:
        raise LibError("file shorter than the 20-byte header")

    library_type, count, used_size, table_offset, data_offset = struct.unpack_from("<5I", data, 0)
    if table_offset != HEADER_SIZE:
        raise LibError(f"table_offset is {table_offset}, expected {HEADER_SIZE}")
    expected_data_offset = HEADER_SIZE + count * ELEMENT_RECORD_SIZE
    if data_offset != expected_data_offset:
        raise LibError(f"data_offset is {data_offset}, expected {expected_data_offset}")
    if library_type != EXPECTED_LIBRARY_TYPE:
        LOG.warning("unexpected library_type 0x%02X", library_type)

    elements: list[LibElement] = []
    running_offset = 0
    for i in range(count):
        base = HEADER_SIZE + i * ELEMENT_RECORD_SIZE
        if base + ELEMENT_RECORD_SIZE > len(data):
            raise LibError(f"element table truncated at record {i}")
        (etype, width, height, _runtime_ptr, elem_offset,
         index, size, delta_x, delta_y) = struct.unpack_from("<7I2i", data, base)
        if index != i:
            raise LibError(f"element {i} reports index {index}")
        if elem_offset != running_offset:
            raise LibError(f"element {i} offset {elem_offset}, expected {running_offset}")
        if size != width * height:
            raise LibError(f"element {i} size {size} != {width}*{height}")
        if etype != EXPECTED_ELEMENT_TYPE:
            LOG.warning("element %d has unexpected type %d", i, etype)

        start = data_offset + elem_offset
        pixels = data[start:start + size]
        if len(pixels) != size:
            raise LibError(f"element {i} pixel data truncated ({len(pixels)}/{size})")
        elements.append(LibElement(i, etype, width, height, elem_offset,
                                   size, delta_x, delta_y, pixels))
        running_offset += size

    expected_used = data_offset + running_offset
    if used_size != expected_used:
        LOG.warning("used_size is %d, computed %d", used_size, expected_used)
    trailing = len(data) - expected_used
    if trailing:
        LOG.debug("%d trailing byte(s) after the pixel blob", trailing)

    return ShapeLibrary(library_type, used_size, data_offset, elements)


def load_lib(path: str) -> ShapeLibrary:
    with open(path, "rb") as fh:
        return parse_lib(fh.read())
