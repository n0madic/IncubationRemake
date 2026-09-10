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

import os

import logging
import struct
from dataclasses import dataclass
from pathlib import Path

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


# --- palette companions ------------------------------------------------------

#: Libraries whose palette does not share their basename. Recovered from
#: `Incubation.exe`, which builds both names from the same id:
#: `0x00458B98` pairs `"%sItems\Item_e%d.lib"` with `"%sItems_e.pal"`
#: unconditionally, and `0x00458809`..`0x004588A6` pairs
#: `"%sItems\Item_w%d.lib"` with `"%sItm_w_13.pal"` .. `"%sItm_w_16.pal"` for
#: ids 13..16 (`add eax,-13; cmp eax,3; ja` -> the default) and with
#: `"%sItems_w.pal"` for every other id.
NAMED_PALETTES: dict[str, str] = {}
for _n in range(0, 32):
    NAMED_PALETTES[f"item_e{_n}"] = "items_e"
    NAMED_PALETTES[f"item_w{_n}"] = f"itm_w_{_n}" if 13 <= _n <= 16 else "items_w"
del _n

#: Libraries that ship **no** palette of their own because the screen that
#: draws them has already set one.  Measured, not guessed: `aInitGUI` loads
#: `GUI\plate_1.bmp` at `0x0044B290` and `AddOns.Lib` at `0x0044B2C4`, and the
#: debriefing loads the same plate at `0x0045D492` and `AddOns2.Lib` at
#: `0x0045D4C9` -- 0x38 bytes apart, with no palette load between them.  A BMP
#: carries its own 256-entry table, so the plate's is what these are drawn
#: with.
PLATE_PALETTES: dict[str, str] = {
    "addons": "GUI/plate_1.bmp",
    "addons2": "GUI/plate_1.bmp",
}

#: Libraries nothing loads.  `uicons2` appears in no string of
#: `Incubation.exe`, `iDesigner.exe` or `Eng3d.dll`, in no format string that
#: could produce it, and in no shipped `.lcl` -- so it has no palette because
#: it has no reader.  Named here rather than given an invented one.
UNREFERENCED_LIBRARIES: frozenset[str] = frozenset({"uicons2"})


def find_palette(lib_path: str, game_root: str | None, record=None
                 ) -> tuple[list[tuple[int, int, int]], str | None]:
    """Locate the colour table a library is drawn with.

    Most libraries share their basename with a `.pal`.  The `Libs/Items/` set
    does not and :data:`NAMED_PALETTES` says what it uses instead.  The two
    `AddOns` libraries have no `.pal` at all and take the screen plate's table
    (:data:`PLATE_PALETTES`), which is a BMP rather than a palette file.

    Returns the table and the file it came from, or a greyscale ramp and
    ``None`` when there is neither -- which for the shipped data means the four
    fonts, whose ramp is the caller's (``docs/60`` §5), and `uicons2`, which
    nothing reads at all.
    """
    from . import bmp as bmpmod
    from .palette import grayscale_palette, load_palette

    stem = os.path.splitext(os.path.basename(lib_path))[0]
    roots = [game_root] if game_root else []
    roots.append(os.path.dirname(os.path.dirname(lib_path)))

    plate = PLATE_PALETTES.get(stem.lower())
    if plate is not None:
        for root in roots:
            found = _existing(os.path.join(root, "Graphics", *plate.split("/")))
            if found is not None:
                source = record(Path(found)) if record is not None else Path(found)
                return bmpmod.load(str(source)).palette, str(source)

    stems = [stem]
    mapped = NAMED_PALETTES.get(stem.lower())
    if mapped:
        stems.append(mapped)
    candidates = [os.path.join(os.path.dirname(lib_path), s + ".pal")
                  for s in stems]
    for root in roots:
        candidates += [os.path.join(root, "Graphics", s + ".pal") for s in stems]
    for candidate in candidates:
        found = _existing(candidate)
        if found is not None:
            source = record(Path(found)) if record is not None else Path(found)
            return load_palette(str(source)), str(source)
    return grayscale_palette(), None


def _existing(path: str) -> str | None:
    """*path*, or its case-insensitive match -- listings are case-sensitive
    on macOS and Linux and the shipped names are not consistent."""
    if os.path.isfile(path):
        return path
    folder = os.path.dirname(path)
    target = os.path.basename(path).lower()
    if os.path.isdir(folder):
        for name in os.listdir(folder):
            if name.lower() == target:
                return os.path.join(folder, name)
    return None


#: Palette slot 0 is the shape libraries' transparent key colour
#: (``docs/60`` §3).  A library that never uses it is written opaque, which is
#: what the original does: with no index 0 in the data there is nothing to key.
TRANSPARENT_INDEX = 0


def uses_transparent_index(lib: ShapeLibrary) -> bool:
    """Whether any pixel in *lib* is :data:`TRANSPARENT_INDEX`."""
    return any(TRANSPARENT_INDEX in e.pixels
               for e in lib.elements if not e.is_empty)
