#!/usr/bin/env python3
"""Step the ground overlay ``fcn.00417E70`` inside the live game and keep what it blits.

docs/43 open question 1 asked what keeps the hit-point digit off the original's
screen: the listing draws ``mp[min(hp, 15)]`` over a current player's unit while
``+0x15`` is non-zero, and two frames of real play showed none over unselected
squad members.  The overlay's three element slots are stack locals, so nothing
short of running the routine answers what it puts on the ground -- and running
it is possible without a window: the routine takes the **destination surface
and its stride as arguments**, so it is called here with a private 640x480x2
buffer and the buffer is read back and decoded.

Reached at ``movemap_gold``'s anchor with save slot 6 loaded (``_C_141``,
one marine, ``Sgt. Bratt`` at (2, 0) with 3 movement points and 11 hit points).
The camera is set with ``0x00403560`` first: at the anchor it stands at the
origin and every projection lands outside the clip, which is a faithful zero
that looks like "nothing drawn".  Four phases:

* ``unselected`` -- the overlay reset, the tick byte 0 then 1;
* ``selected`` -- ``0x00471E00(1)`` has picked the marine, the tick byte 1
  (``0x00471E00`` also plays the placer's ``select.wav``; the anchor's sound
  system answers the call without a device);
* ``spent`` -- points written to 0, then ``+0x41`` written to 1 (overwatch).

``--check`` decodes each phase's lit pixels against ``mp.LIB``'s own element
masks (the blitter skips palette index 0, so what an element leaves on the
surface is exactly its non-zero texels) and compares with the table below.

Measured on 2026-09-12 (five landed runs, one to seven Wine attempts each):

=============  ===========  ====  ==================================  ==========
phase          tick         sel   blitted at the marine's cell          element
=============  ===========  ====  ==================================  ==========
unselected     0 and 1      --    a 7x9 grey ``11``                     ``mp[11]``
selected       0            3     a 16x16 green cross alone            ``mp[52]``
selected       1            3     a 20x20 corner frame and the ``11``  ``mp[51]``, ``mp[11]``
spent          0            --    nothing                               --
spent+overwatch 0           --    the 7x9 yellow icon alone            ``mp[49]``
=============  ===========  ====  ==================================  ==========

So the overlay routine **does** draw the digit over an unselected unit with
points, on both tick phases, exactly as ``0x004186AF``..``0x00418708`` reads --
and the selected unit's cell blinks between the corner frame with the digit
(odd tick) and the cross alone (even tick), which is the ``51``/``52`` arm
docs/43 3.2 had filed under state 100: it is keyed on the cell's element being
51, and the selection's state-50 cell is one.  What the two frames show is
therefore not the overlay's doing; see docs/43 open question 1 for what is left.

Four more phases (2026-09-26) answer docs/43 open questions 2-4 the same way:

* ``pool_panel`` -- the unit panel's painter ``0x004756D0``, which also takes
  the destination and its stride, run over ``_31_.sav``'s pool record and
  over a recruit ``aEnlargeUnitPool`` makes at the anchor, each as loaded and
  with ``+0x3D`` written 0; the text is read back with ``font_0``'s glyphs;
* ``recall`` -- ``aTransferUnitFromMapToPool`` on ``_2_.sav``'s four marines,
  the unit array read after each, with ``aBuildVisibleMap(0)`` as the control
  after the first and the last;
* ``load_skip`` / ``load_deploy`` -- ``_31_.sav`` loaded, Bratt placed, the
  game saved and loaded back (or loaded as it is), then ``aInitBattleGround``
  itself.  Its first step opens text module 0, which the front end already
  holds at the anchor, so the module's pointer is cleared first.

This tool is **outside** ``make test``: it needs Wine, ``dbgcall.exe`` and a
copy of the game, and it refuses a game directory inside this repository.  It
stages ``_2_``, ``_6_`` and ``_31_.sav`` from ``--saves`` (the fixtures) into
the copy's ``Work/Saves2/`` before each phase; the load phases write slots 29,
31 and 33 there.  ``--check`` compares a capture with the tables below and in
docs/43.

Usage::

    python3 tools/hud_probe.py --game-copy /path/to/copy \\
        --dbgcall /path/to/copy/dbgcall.exe -o hud_probe.json [--phases ...]
    python3 tools/hud_probe.py --check hud_probe.json
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import movemap_gold as gold                                        # noqa: E402
from inclib import liblib                                          # noqa: E402
from inclib.cache import is_within                                 # noqa: E402
from inclib.check import Checker                                   # noqa: E402
from inclib.info import load_info                                  # noqa: E402

LOG = logging.getLogger("hud_probe")

SCHEMA = "incubation.hud-probe/1"

#: The surface the overlay is asked to blit into: the plate's 640x480 at two
#: bytes a pixel, and the stride the sixteen-bit modes use (docs/97 23.4).
SURFACE_WIDTH = 640
SURFACE_HEIGHT = 480
SURFACE_STRIDE = 1280
SURFACE_BYTES = SURFACE_STRIDE * SURFACE_HEIGHT
#: ``--read`` takes at most 262144 bytes; three reads cover the surface.
READ_CHUNK = 204800

#: The 3D window `aInitBattleGround` writes at `0x0041A49E` (docs/43 2).
WINDOW = (60, 34, 520, 340)
#: A hover no cell answers: `0x0042F730(255, 255)` is out of every map.
NO_HOVER = 255

#: Where the camera is put: over the marine's cell (2, 0), looking down at it
#: from 9000 units up and 9600 south, so the cell projects inside the window.
CAMERA = (8000, -8000, 9000, 8000, 1600, 0)

#: The marine `_6_.sav` holds for player 0 (docs/95): slot 3, `Sgt. Bratt`.
MARINE_SLOT = 3
UNIT_MP = 0x15
UNIT_HP = 0x16
UNIT_ACTION = 0x41
#: The 100 ms tick counter whose bit 0 is the blink (docs/43 1).
TICK_BYTE = 0x00523068
SELECTION = 0x005162F8

DECLARATIONS = gold.DECLARATIONS + gold.MEMCPY_DECL + "\n" + """\
__cdecl i32  aGetFont(i32)                  = Incubation.exe+0x39e20
__cdecl i32  aSelectUnit(i32)               = Incubation.exe+0x71e00
__cdecl void aGroundOverlay(ptr,i32,i32,i32,i32,i32,i32,i32,i32,i32,i32) = Incubation.exe+0x17e70
__cdecl void aGetCamera(ptr,ptr,ptr)        = Incubation.exe+0x3750
__cdecl void aSetCamera(i32,i32,i32,i32,i32,i32) = Incubation.exe+0x3560
"""

PHASES = ("unselected", "selected", "spent")

# ---------------------------------------------------------------------------
# docs/43 open questions 2 and 3: the place interface's panel and take-back
# ---------------------------------------------------------------------------

#: The pool, `0x0051F2A0`: four rows of 31 records of the unit stride
#: (`fcn.00463730` indexes it as `(player * 31 + index) * 91`).
POOL_BASE = 0x0051F2A0
POOL_ROW = 31
#: The unit-record fields the two phases read (docs/10 section 5).
UNIT_AMMO = 0x3D
UNIT_WEAPON = 0x3F
UNIT_POOL_FLAG = 0x4D
UNIT_VISIBILITY = 0x4F
#: The hand-over's re-entry latch and the turn counter (docs/22 9.4.1, docs/25).
REENTRY_LATCH = 0x005229D0
TURN_COUNTER = 0x00509E1D

#: `_31_.sav`: `_C_141` on turn 0 as the place interface went up, Sgt. Bratt
#: in pool slot 0 (docs/43 5.5).  The recruit `aEnlargeUnitPool` makes lands
#: in the first free slot, 1.
PANEL_SAVE_SLOT = 31
PANEL_POOL_INDEX = {"bratt": 0, "recruit": 1}
#: `0x00463730` calls the panel painter with (60, 415, 0) and the font twice.
PANEL_AT = (60, 415)
#: The rows the panel paints into: the name line is 18 above the origin and
#: the inventory sprites end above the plate's bottom edge.
PANEL_ROWS = (370, SURFACE_HEIGHT)
PANEL_SURFACES = ("bratt", "bratt_empty", "recruit", "recruit_empty")

#: `_2_.sav`: `_C_140` on turn 10, four marines of player 0, all pool
#: candidates, and aliens the load's own fog pass sees (docs/11 5.8).  Knox
#: (slot 5, at (11, 8)) is taken back first, alone, then the other three.
RECALL_SAVE_SLOT = 2
RECALL_ORDER = ((5, 11, 8), (2, 11, 5), (3, 12, 3), (4, 13, 5))
UNITS_BYTES = gold.UNIT_SLOTS * gold.UNIT_STRIDE
COMPUTER = 255

POOL_DECLARATIONS = gold.DECLARATIONS + gold.MEMCPY_DECL + "\n" + """\
__cdecl i32  aGetFont(i32)                  = Incubation.exe+0x39e20
__cdecl i32  aUnitPanel(ptr,ptr,i32,i32,i32,i32,i32,i32) = Incubation.exe+0x756d0
__cdecl i32  aEnlargeUnitPool(i32)          = Incubation.exe+0x789b0
__cdecl i32  aPoolCount(i32)                = Incubation.exe+0x78960
__cdecl i32  aTransferUnitFromMapToPool(i32,i32,i32) = Incubation.exe+0x78f20
__cdecl i32  aBuildVisibleMap(i32)          = Incubation.exe+0x798c0
"""


#: Open question 4: `_31_.sav` again -- Sgt. Bratt placed on the landing
#: cell (1, 1) with the quadrant facing 4, the game saved into a slot the
#: fixtures do not use and loaded back, and `aInitBattleGround` called over
#: it: the load command's own path (`0x0041DABD` -> `0x0042E811`).  The
#: control phase loads `_31_.sav` as it is, the pool still full.
LOAD_SKIP_SLOT = 29
LANDING_CELL = (1, 1)
LANDING_FACING = 4
CURRENT_PLAYER = 0x00509E32
MAP_TYPE = 0x004FD0F2
PLACE_SELECTION = 0x00514064
VIEW_STATE = 0x005229D4
#: `aTxtSys.cpp`'s module table: module 0's active pointer.
TEXT_MODULE_0 = 0x0051432C
LOAD_PHASES = ("load_skip", "load_deploy")

LOAD_DECLARATIONS = POOL_DECLARATIONS + """\
__cdecl i32  aTransferUnitFromPoolToMap(i32,i32,i32,i32,i32) = Incubation.exe+0x78d10
__cdecl i32  aSaveGame(i32)                 = Incubation.exe+0x48ad0
__cdecl i32  aInitBattleGround()            = Incubation.exe+0x19d90
"""


def _turn_reads() -> str:
    return (f"--read {TURN_COUNTER:#x}:1 --read {CURRENT_PLAYER:#x}:1 "
            f"--read {REENTRY_LATCH:#x}:8 --read {MAP_TYPE:#x}:1 "
            f"--read {PLACE_SELECTION:#x}:4")


def load_plan(phase: str) -> str:
    """Open question 4: what `aInitBattleGround` does over a loaded turn 0."""
    lines = [
        *gold.blob_lines([0]),
        LOAD_DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({PANEL_SAVE_SLOT})",
        f"before = aPoolCount(0) {_turn_reads()}",
    ]
    if phase == "load_skip":
        x, y = LANDING_CELL
        lines += [
            f"placed = aTransferUnitFromPoolToMap(0, 0, {x}, {y}, "
            f"{LANDING_FACING})",
            f"emptied = aPoolCount(0) {_turn_reads()}",
            f"saved = aSaveGame({LOAD_SKIP_SLOT})",
            f"reloaded = aLoadGame({LOAD_SKIP_SLOT})",
            f"again = aPoolCount(0) {_turn_reads()}",
        ]
    elif phase != "load_deploy":
        raise ProbeError(f"unknown phase {phase!r}")
    # `aInitBattleGround` opens text module 0 first and refuses a module
    # that is already active ("text module already active", `0x00470B81`);
    # at the anchor the front end holds it.  Clearing the slot's pointer
    # (the block is leaked, which a probe process can afford) is what lets
    # the routine reach its own arms.
    lines += [gold.writeb(f"{TEXT_MODULE_0 + i:#x}", 0) for i in range(4)]
    lines += [
        "built = aInitBattleGround()",
        f"after = aPoolCount(0) {_turn_reads()}",
    ]
    return "\n".join(lines) + "\n"


def _pool_record(index: int, player: int = 0) -> int:
    return POOL_BASE + (player * POOL_ROW + index) * gold.UNIT_STRIDE


def _panel_call(record: int, buf: str) -> str:
    lo, hi = PANEL_ROWS
    x, y = PANEL_AT
    return (f"aUnitPanel({record:#x}, &{buf}, {SURFACE_STRIDE}, {x}, {y}, 0, "
            f"$f0, $f0) --read &{buf}+{lo * SURFACE_STRIDE}:"
            f"{(hi - lo) * SURFACE_STRIDE} "
            f"--read {record:#x}:{gold.UNIT_STRIDE}")


def pool_panel_plan() -> str:
    """Open question 2: the panel painter over a pool record, native.

    The painter `0x004756D0` takes the destination and its stride, as the
    overlay does, so it runs at the anchor into a private buffer.  Four
    paintings: Sgt. Bratt's pool record as `_31_.sav` holds it, the same with
    `+0x3D` written 0 (what the old reading said a recruit carries), a recruit
    `aEnlargeUnitPool` makes here and now, and that recruit with `+0x3D` 0.
    """
    bratt = _pool_record(PANEL_POOL_INDEX["bratt"])
    recruit = _pool_record(PANEL_POOL_INDEX["recruit"])
    return "\n".join([
        *(f"--buf {name}:{SURFACE_BYTES}" for name in PANEL_SURFACES),
        *gold.blob_lines([0]),
        POOL_DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({PANEL_SAVE_SLOT})",
        "f0 = aGetFont(0)",
        f"count = aPoolCount(0) --read {REENTRY_LATCH:#x}:4 "
        f"--read {TURN_COUNTER:#x}:1 "
        f"--read {POOL_BASE:#x}:{POOL_ROW * gold.UNIT_STRIDE}",
        _panel_call(bratt, "bratt"),
        gold.writeb(f"{bratt + UNIT_AMMO:#x}", 0),
        _panel_call(bratt, "bratt_empty"),
        f"enlarged = aEnlargeUnitPool(0) "
        f"--read {POOL_BASE:#x}:{POOL_ROW * gold.UNIT_STRIDE}",
        _panel_call(recruit, "recruit"),
        gold.writeb(f"{recruit + UNIT_AMMO:#x}", 0),
        _panel_call(recruit, "recruit_empty"),
    ]) + "\n"


def recall_plan() -> str:
    """Open question 3: does a take-back rebuild the fog?

    `aTransferUnitFromMapToPool` is called on Knox alone, the whole unit array
    read, then `aBuildVisibleMap(0)` -- the control: what a rebuild would have
    left -- and the array read again; then the other three marines, one by
    one, and the control once more over a player with nobody on the map.
    """
    lines = [
        *gold.blob_lines([0]),
        POOL_DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({RECALL_SAVE_SLOT})",
        "u0 = aGetUnitMapElementPtr(0)",
        f"count = aPoolCount(0) --read $u0:{UNITS_BYTES}",
    ]
    for step, (slot, x, y) in enumerate(RECALL_ORDER):
        lines.append(f"back{slot} = aTransferUnitFromMapToPool(0, {x}, {y}) "
                     f"--read $u0:{UNITS_BYTES} "
                     f"--read {POOL_BASE:#x}:{POOL_ROW * gold.UNIT_STRIDE}")
        if step in (0, len(RECALL_ORDER) - 1):
            lines.append(f"fog{step} = aBuildVisibleMap(0) "
                         f"--read $u0:{UNITS_BYTES}")
    return "\n".join(lines) + "\n"

#: What each landed blit should decode to -- `(phase, tick)` -> the `mp.LIB`
#: elements that account for the lit pixels, in any order.
EXPECTED: dict[tuple[str, int], list[int]] = {
    ("unselected", 0): [11],
    ("unselected", 1): [11],
    ("selected", 0): [52],
    ("selected", 1): [51, 11],
    ("spent", 0): [],
    ("spent_overwatch", 0): [49],
}


class ProbeError(Exception):
    """Raised when a capture cannot be produced or read."""


def _overlay_call(buf: str) -> str:
    x, y, w, h = WINDOW
    reads = " ".join(
        f"--read &{buf}+{off}:{min(READ_CHUNK, SURFACE_BYTES - off)}"
        for off in range(0, SURFACE_BYTES, READ_CHUNK))
    return (f"aGroundOverlay(&{buf}, {SURFACE_STRIDE}, 0, {x}, {y}, {w}, {h}, "
            f"{NO_HOVER}, {NO_HOVER}, $f0, 1) {reads} "
            f"--read $u0:{gold.UNIT_SLOTS * gold.UNIT_STRIDE} "
            f"--read {SELECTION:#x}:4 --read {TICK_BYTE:#x}:4")


def _unit_byte(offset: int) -> str:
    return f"$u0+0x{MARINE_SLOT * gold.UNIT_STRIDE + offset:x}"


def plan_for(phase: str) -> str:
    lines = [
        "--buf surf:%d" % SURFACE_BYTES,
        "--buf surf2:%d" % SURFACE_BYTES,
        "--buf cam:12",
        *gold.blob_lines([0, 1]),
        DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "u0 = aGetUnitMapElementPtr(0)",
        "f0 = aGetFont(0)",
        "aSetCamera(%d, %d, %d, %d, %d, %d)" % CAMERA,
    ]
    if phase == "unselected":
        lines += [
            "aResetMoveOverlay()",
            gold.writeb(f"{TICK_BYTE:#x}", 0),
            _overlay_call("surf"),
            gold.writeb(f"{TICK_BYTE:#x}", 1),
            _overlay_call("surf2"),
        ]
    elif phase == "selected":
        lines += [
            "sel = aSelectUnit(1)",
            gold.writeb(f"{TICK_BYTE:#x}", 0),
            _overlay_call("surf"),
            gold.writeb(f"{TICK_BYTE:#x}", 1),
            _overlay_call("surf2"),
        ]
    elif phase == "spent":
        lines += [
            "aResetMoveOverlay()",
            gold.writeb(f"{TICK_BYTE:#x}", 0),
            gold.writeb(_unit_byte(UNIT_MP), 0),
            _overlay_call("surf"),
            gold.writeb(_unit_byte(UNIT_ACTION), 1),
            _overlay_call("surf2"),
        ]
    else:
        raise ProbeError(f"unknown phase {phase!r}")
    lines.append("aGetCamera(&cam, &cam+4, &cam+8) --read &cam:12")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Decoding what was blitted
# ---------------------------------------------------------------------------

#: The `mp.LIB` elements the unit arm can put on a cell (docs/43 3.2): the
#: sixteen digits, overwatch, the jam, the two path frames and the panic frame.
CANDIDATES = tuple(range(16)) + (49, 50, 51, 52, 54)


def _surface_of(row: dict[str, Any], buf: str) -> bytes:
    reads = row["reads"]
    return b"".join(bytes.fromhex(reads[f"&{buf}+{off}"].replace(" ", ""))
                    for off in range(0, SURFACE_BYTES, READ_CHUNK))


def lit_pixels(surface: bytes) -> list[list[int]]:
    """Every non-black pixel of the surface, as `[x, y]`, row-major."""
    out: list[list[int]] = []
    for y in range(SURFACE_HEIGHT):
        base = y * SURFACE_STRIDE
        for x in range(SURFACE_WIDTH):
            if surface[base + 2 * x] | surface[base + 2 * x + 1]:
                out.append([x, y])
    return out


def element_masks(root: Path) -> dict[int, frozenset[tuple[int, int]]]:
    """Element -> the set of its opaque texels, relative to its top-left.

    The blitter skips palette index 0 (docs/43 3.4), so the pixels an element
    leaves on the surface are exactly its non-zero texels.
    """
    lib = liblib.load_lib(str(root / "Libs" / "mp.LIB"))
    masks: dict[int, frozenset[tuple[int, int]]] = {}
    for index in CANDIDATES:
        element = lib.elements[index]
        masks[index] = frozenset(
            (i % element.width, i // element.width)
            for i, value in enumerate(element.pixels) if value != 0)
    return masks


def decode(lit: list[list[int]], masks: dict[int, frozenset[tuple[int, int]]]
           ) -> list[int]:
    """Which elements, blitted anywhere, account for *lit* exactly.

    Greedy over the whole lit set: the largest mask that lies entirely inside
    it and covers at least one pixel nothing has covered yet is taken, until
    every lit pixel is covered.  Two blits may overlap (the digit sits inside
    the corner frame), so a placed mask is not subtracted -- only marked, and
    the anchor is searched over **every** lit pixel, not the uncovered ones:
    a digit whose first texel lands on the frame already placed would
    otherwise never be found.  A pixel no element explains leaves `-1` at the
    end, so a stray write is not silently dropped.
    """
    lit_set = {(x, y) for x, y in lit}
    lit_sorted = sorted(lit_set)
    uncovered = set(lit_set)
    found: list[int] = []
    by_size = sorted(masks.items(), key=lambda kv: -len(kv[1]))
    while uncovered:
        placed = False
        for index, mask in by_size:
            if not mask:
                continue
            first = min(mask)
            for px, py in lit_sorted:
                dx, dy = px - first[0], py - first[1]
                shifted = {(mx + dx, my + dy) for mx, my in mask}
                if shifted <= lit_set and shifted & uncovered:
                    uncovered -= shifted
                    found.append(index)
                    placed = True
                    break
            if placed:
                break
        if not placed:
            found.append(-1)
            break
    return found


# ---------------------------------------------------------------------------
# Capture and check
# ---------------------------------------------------------------------------

# -- decoding what the panel painted -----------------------------------------

#: RGB565 as the panel writes it: white text, the red of an empty magazine and
#: of the status word (docs/43 5.3).
WHITE = 0xFFFF
RED = 0xF800
#: Bands of the painted panel: the name line (the status word follows the
#: name) and the weapon block's `ammo/max`, drawn from x = 254 in both
#: captures; the digit at x 236..240 and the movement number at 304..307 on
#: the same rows are left out.
NAME_BAND = ((0, SURFACE_WIDTH), (380, 400))
AMMO_BAND = ((250, 290), (430, 460))


def panel_pixels(row: dict[str, Any], buf: str) -> list[list[int]]:
    """Every non-black pixel the painter left, as `[x, y, rgb565]`."""
    lo, _hi = PANEL_ROWS
    key = f"&{buf}+{lo * SURFACE_STRIDE}"
    data = bytes.fromhex(row["reads"][key].replace(" ", ""))
    out: list[list[int]] = []
    for i in range(0, len(data), 2):
        value = data[i] | data[i + 1] << 8
        if value:
            pixel = i // 2
            out.append([pixel % SURFACE_WIDTH, pixel // SURFACE_WIDTH + lo, value])
    return out


def glyph_masks(root: Path) -> dict[str, frozenset[tuple[int, int]]]:
    """`font_0.LIB`'s glyph bodies (texel 1), keyed by character (docs/60 5)."""
    lib = liblib.load_lib(str(root / "Libs" / "font_0.LIB"))
    out: dict[str, frozenset[tuple[int, int]]] = {}
    for index, element in enumerate(lib.elements):
        if element.width == 0 or not element.pixels:
            continue
        body = frozenset((i % element.width, i // element.width)
                         for i, value in enumerate(element.pixels) if value == 1)
        if body:
            out[chr(index + 32)] = body
    return out


def read_text(pixels: list[list[int]], colour: int,
              band: tuple[tuple[int, int], tuple[int, int]],
              glyphs: dict[str, frozenset[tuple[int, int]]]) -> str:
    """The characters whose bodies account for *colour*'s pixels in *band*.

    Greedy from the left, as `decode` is for the overlay: at the leftmost
    uncovered column the glyph covering most uncovered pixels while lying
    wholly inside the set is taken.  Spaces draw nothing and are not read;
    a column no glyph explains reads `?`, so a stray pixel is not dropped.
    """
    (x0, x1), (y0, y1) = band
    ink = {(x, y) for x, y, value in pixels
           if value == colour and x0 <= x < x1 and y0 <= y < y1}
    uncovered = set(ink)
    text = ""
    while uncovered:
        left = min(x for x, _ in uncovered)
        column = [p for p in uncovered if p[0] == left]
        best: tuple[int, str, set[tuple[int, int]]] | None = None
        for char, body in glyphs.items():
            first = min(x for x, _ in body)
            for px, py in column:
                for gx, gy in body:
                    if gx != first:
                        continue
                    placed = {(x + px - gx, y + py - gy) for x, y in body}
                    if placed <= ink and (px, py) in placed:
                        score = len(placed & uncovered)
                        if best is None or score > best[0]:
                            best = (score, char, placed)
        if best is None:
            text += "?"
            uncovered -= set(column)
            continue
        text += best[1]
        uncovered -= best[2]
    return text


def _record(row: dict[str, Any], address: int) -> bytes:
    return bytes.fromhex(row["reads"][f"{address:#x}"].replace(" ", ""))


def _byte_read(row: dict[str, Any], address: int) -> int:
    return int(row["reads"][f"{address:#x}"].replace(" ", "")[:2], 16)


def _dword_read(row: dict[str, Any], address: int) -> int:
    return int.from_bytes(_record(row, address)[:4], "little")


def _pool_summary(pool: bytes) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for index in range(POOL_ROW):
        rec = pool[index * gold.UNIT_STRIDE:(index + 1) * gold.UNIT_STRIDE]
        if len(rec) == gold.UNIT_STRIDE and rec[UNIT_HP]:
            out.append({"index": index, "name": rec[:16].split(b"\0")[0].decode(
                "latin-1"), "hp": rec[UNIT_HP], "ammo": rec[UNIT_AMMO],
                "weapon": rec[UNIT_WEAPON], "pool_flag": rec[UNIT_POOL_FLAG]})
    return out


def _units_summary(units: bytes) -> dict[str, list[int]]:
    """Slot -> `[hp, player, +0x4F]` for every slot that ever held a unit."""
    out: dict[str, list[int]] = {}
    for slot in range(gold.UNIT_SLOTS):
        rec = units[slot * gold.UNIT_STRIDE:(slot + 1) * gold.UNIT_STRIDE]
        if rec[UNIT_HP] or rec[:1] != b"\0":
            out[str(slot)] = [rec[UNIT_HP], rec[gold.UNIT_PLAYER],
                              rec[UNIT_VISIBILITY]]
    return out


def _turn_state(row: dict[str, Any]) -> dict[str, int]:
    return {"pool_count": int(row["eax"], 16),
            "turn": _byte_read(row, TURN_COUNTER),
            "current_player": _byte_read(row, CURRENT_PLAYER),
            "latch": _dword_read(row, REENTRY_LATCH),
            "map_type": _byte_read(row, MAP_TYPE),
            "place_selection": _dword_read(row, PLACE_SELECTION)}


def _summarise(phase: str, rows: list[dict[str, Any]]) -> dict[str, Any]:
    if phase == "pool_panel":
        count = next(r for r in rows if r["call"] == "aPoolCount")
        enlarged = next(r for r in rows if r["call"] == "aEnlargeUnitPool")
        panels = [r for r in rows if r["call"] == "aUnitPanel"]
        if len(panels) != len(PANEL_SURFACES):
            raise ProbeError(f"pool_panel: {len(panels)} paintings")
        return {
            "loaded_pool": _pool_summary(_record(count, POOL_BASE)),
            "latch": _dword_read(count, REENTRY_LATCH),
            "turn": _byte_read(count, TURN_COUNTER),
            "enlarge_result": int(enlarged["eax"], 16),
            "pool_after_enlarge": _pool_summary(_record(enlarged, POOL_BASE)),
            "paintings": {name: {"pixels": panel_pixels(row, name)}
                          for name, row in zip(PANEL_SURFACES, panels)},
        }
    if phase == "recall":
        steps = [r for r in rows if r["call"] in (
            "aPoolCount", "aTransferUnitFromMapToPool", "aBuildVisibleMap")]
        return {"steps": [
            {"call": r["call"], "result": int(r["eax"], 16),
             "units": _units_summary(bytes.fromhex(
                 r["reads"]["$u0"].replace(" ", ""))),
             **({"pool": _pool_summary(_record(r, POOL_BASE))}
                if f"{POOL_BASE:#x}" in r["reads"] else {})}
            for r in steps]}
    if phase in LOAD_PHASES:
        states = [r for r in rows if r["call"] == "aPoolCount"]
        built = next(r for r in rows if r["call"] == "aInitBattleGround")
        return {"init_result": int(built["eax"], 16),
                "before": _turn_state(states[0]),
                "after": _turn_state(states[-1])}
    raise ProbeError(f"unknown phase {phase!r}")


# ---------------------------------------------------------------------------
# Capture and check
# ---------------------------------------------------------------------------

#: What each phase loads, staged from the fixtures into the copy's
#: `Work/Saves2/` before the phase runs (the load phases rewrite slots 31 and
#: 33 there themselves, so the stage is repeated each time).
PHASE_SAVES = {"unselected": gold.CAPTURE_SLOT, "selected": gold.CAPTURE_SLOT,
               "spent": gold.CAPTURE_SLOT, "pool_panel": PANEL_SAVE_SLOT,
               "recall": RECALL_SAVE_SLOT, "load_skip": PANEL_SAVE_SLOT,
               "load_deploy": PANEL_SAVE_SLOT}
ALL_PHASES = PHASES + ("pool_panel", "recall") + LOAD_PHASES


def _capture_overlay(game_copy: Path, dbgcall: Path, phase: str,
                     attempts: int, document: dict[str, Any]) -> None:
    rows = gold.run_plan(game_copy, dbgcall, plan_for(phase),
                         f"hud_probe_{phase}", attempts=attempts)
    overlays = [r for r in rows if r["call"] == "aGroundOverlay"]
    if len(overlays) != 2:
        raise ProbeError(f"{phase}: expected two overlay calls, "
                         f"got {len(overlays)}")
    keys = [(phase, 0), (phase, 1)] if phase != "spent" \
        else [("spent", 0), ("spent_overwatch", 0)]
    for (key, tick), row, buf in zip(keys, overlays, ("surf", "surf2")):
        marine = bytes.fromhex(row["reads"]["$u0"].replace(" ", ""))[
            MARINE_SLOT * gold.UNIT_STRIDE:(MARINE_SLOT + 1) * gold.UNIT_STRIDE]
        document.setdefault("phases", {})[f"{key}/{tick}"] = {
            "phase": key,
            "tick": int(row["reads"][f"{TICK_BYTE:#x}"].replace(" ", "")[:2], 16),
            "selection": int.from_bytes(
                bytes.fromhex(row["reads"][f"{SELECTION:#x}"].replace(" ", "")),
                "little"),
            "marine": {"mp": marine[UNIT_MP], "hp": marine[UNIT_HP],
                       "action": marine[UNIT_ACTION]},
            "lit": lit_pixels(_surface_of(row, buf)),
        }


def capture(game_copy: Path, dbgcall: Path, out: Path, attempts: int,
            phases: tuple[str, ...], saves: Path) -> int:
    repo = Path(__file__).resolve().parent.parent
    if is_within(game_copy, repo):
        raise ProbeError(
            f"{game_copy} is inside this repository; the probe must run "
            f"from a copy of the game, never from gog_incubation/")
    if not dbgcall.is_file():
        raise ProbeError(f"no dbgcall at {dbgcall}")
    document: dict[str, Any] = {"schema": SCHEMA}
    if out.is_file():
        document = json.loads(out.read_text(encoding="utf-8"))
    staging = game_copy / "Work" / "Saves2"
    for phase in phases:
        slot = PHASE_SAVES[phase]
        source = saves / f"_{slot}_.sav"
        if not source.is_file():
            raise ProbeError(f"{phase} needs {source}")
        staging.mkdir(parents=True, exist_ok=True)
        (staging / source.name).write_bytes(source.read_bytes())
        if phase in PHASES:
            _capture_overlay(game_copy, dbgcall, phase, attempts, document)
        else:
            plan = {"pool_panel": pool_panel_plan, "recall": recall_plan}.get(
                phase, lambda p=phase: load_plan(p))()
            rows = gold.run_plan(game_copy, dbgcall, plan,
                                 f"hud_probe_{phase}", attempts=attempts)
            document[phase] = _summarise(phase, rows)
        out.write_text(json.dumps(document, indent=1, sort_keys=True) + "\n",
                       encoding="utf-8")
        LOG.info("%s landed; wrote %s", phase, out)
    return 0


#: What the panel painter prints, read back with `font_0`'s glyphs:
#: painting -> (the red status word on the name line, the red `ammo/max`,
#: the white `ammo/max`).  Spaces are not ink, so `" - Out of ammo!"` reads
#: without them.
PANEL_TEXT = {
    "bratt": ("", "", "10/10"),
    "bratt_empty": ("-Outofammo!", "0/10", ""),
    "recruit": ("", "", "7/7"),
    "recruit_empty": ("-Outofammo!", "0/7", ""),
}
#: Weapon 0, `Light Combat Gun`, carries a magazine of 7 (`Info.lcl`).
RECRUIT_WEAPON = 0


def check_pool_panel(ck: Checker, entry: dict[str, Any] | None,
                     root: Path) -> None:
    ck.check("hud_probe.pool_panel.landed", entry is not None,
             "the pool_panel phase reached the anchor")
    if entry is None:
        return
    info = load_info(str(root))
    loaded = {r["index"]: r for r in entry["loaded_pool"]}
    ck.expect("hud_probe.pool_panel.bratt_loaded",
              (loaded.get(0, {}).get("name"), loaded.get(0, {}).get("ammo")),
              ("Sgt. Bratt", info.weapons[loaded.get(0, {}).get("weapon", 0)].mun),
              "_31_.sav's pool record carries a full magazine")
    after = {r["index"]: r for r in entry["pool_after_enlarge"]}
    recruit = after.get(PANEL_POOL_INDEX["recruit"], {})
    ck.expect("hud_probe.pool_panel.recruit_is_loaded",
              (entry["enlarge_result"], recruit.get("weapon"),
               recruit.get("ammo"), recruit.get("pool_flag")),
              (1, RECRUIT_WEAPON, info.weapons[RECRUIT_WEAPON].mun, 1),
              "aEnlargeUnitPool's closing 0x004759E0 fills +0x3D")
    glyphs = glyph_masks(root)
    for name, (status, red_ammo, white_ammo) in PANEL_TEXT.items():
        pixels = entry["paintings"][name]["pixels"]
        ck.expect(f"hud_probe.pool_panel.{name}.status",
                  read_text(pixels, RED, NAME_BAND, glyphs), status)
        ck.expect(f"hud_probe.pool_panel.{name}.ammo",
                  (read_text(pixels, RED, AMMO_BAND, glyphs),
                   read_text(pixels, WHITE, AMMO_BAND, glyphs)),
                  (red_ammo, white_ammo))


def check_recall(ck: Checker, entry: dict[str, Any] | None) -> None:
    ck.check("hud_probe.recall.landed", entry is not None,
             "the recall phase reached the anchor")
    if entry is None:
        return
    steps = entry["steps"]
    calls = [s["call"] for s in steps]
    ck.expect("hud_probe.recall.shape", calls,
              ["aPoolCount", "aTransferUnitFromMapToPool", "aBuildVisibleMap",
               "aTransferUnitFromMapToPool", "aTransferUnitFromMapToPool",
               "aTransferUnitFromMapToPool", "aBuildVisibleMap"])
    if len(steps) != 7:
        return

    def fog(step: int) -> dict[str, int]:
        # The computer's units: the barrels (player 252, species 2) are
        # always visible and the marines are the ones leaving.
        return {slot: v[2] for slot, v in steps[step]["units"].items()
                if v[0] and v[1] == COMPUTER}

    def changed(a: int, b: int) -> dict[str, list[int]]:
        return {slot: [fog(a)[slot], fog(b)[slot]]
                for slot in fog(b) if fog(a).get(slot) != fog(b)[slot]}

    knox = str(RECALL_ORDER[0][0])
    ck.expect("hud_probe.recall.knox_left",
              (steps[1]["result"], steps[1]["units"][knox][0],
               [r["name"] for r in steps[1]["pool"]]), (1, 0, ["Knox"]))
    ck.expect("hud_probe.recall.take_back_leaves_fog", changed(0, 1), {},
              "no +0x4F moved when Knox left the map")
    ck.expect("hud_probe.recall.knox_alone_saw", changed(1, 2),
              {"10": [0, 1]},
              "the rebuild the take-back skipped: Knox alone had the "
              "Ray'Ther at (12, 13) in sight")
    ck.expect("hud_probe.recall.all_back_leaves_fog", changed(2, 5), {},
              "three more take-backs, no +0x4F moved")
    ck.check("hud_probe.recall.rebuild_hides_all",
             bool(fog(5)) and all(v == 3 for v in fog(6).values())
             and any(v != 3 for v in fog(5).values()),
             f"before {sorted(fog(5).items())}, after {sorted(fog(6).items())}")


#: `aInitBattleGround` over the loaded turn 0: `(turn, place selection)`
#: after it, and the state its own reads leave untouched.
LOAD_EXPECTED = {"load_skip": {"pool_count": 0, "turn": 1,
                               "place_selection": 0xFFFFFFFF},
                 "load_deploy": {"pool_count": 1, "turn": 0,
                                 "place_selection": 0}}


def check_load(ck: Checker, document: dict[str, Any]) -> None:
    for phase, want in LOAD_EXPECTED.items():
        entry = document.get(phase)
        ck.check(f"hud_probe.{phase}.landed", entry is not None,
                 f"the {phase} phase reached the anchor")
        if entry is None:
            continue
        before, after = entry["before"], entry["after"]
        ck.expect(f"hud_probe.{phase}.built", entry["init_result"], 1)
        ck.expect(f"hud_probe.{phase}.loaded_turn_0",
                  (before["turn"], before["latch"], before["map_type"]),
                  (0, 1, 1), "a campaign map on turn 0, the latch spent")
        ck.expect(f"hud_probe.{phase}.after",
                  {k: after[k] for k in want}, want)
        ck.expect(f"hud_probe.{phase}.no_hand_over",
                  (after["latch"], after["current_player"]),
                  (before["latch"], before["current_player"]),
                  "aInitBattleGround neither ran the hand-over nor moved "
                  "the seat")


def check(capture_path: Path, root: Path) -> int:
    document = json.loads(capture_path.read_text(encoding="utf-8"))
    masks = element_masks(root)
    ck = Checker()
    ck.expect("hud_probe.schema", document.get("schema"), SCHEMA)
    phases = document.get("phases", {})
    ck.check("hud_probe.phases_present", bool(phases),
             "a capture with no phase verifies nothing")
    for (phase, tick), want in sorted(EXPECTED.items()):
        entry = phases.get(f"{phase}/{tick}")
        ck.check(f"hud_probe.{phase}.{tick}.landed", entry is not None,
                 "the phase reached the anchor and both overlay calls returned")
        if entry is None:
            continue
        ck.expect(f"hud_probe.{phase}.{tick}.tick", entry["tick"] & 1, tick)
        ck.expect(f"hud_probe.{phase}.{tick}.elements",
                  sorted(decode(entry["lit"], masks)), sorted(want),
                  f"{len(entry['lit'])} lit pixel(s)")
    ck.expect("hud_probe.unselected_has_points",
              phases.get("unselected/0", {}).get("marine", {}).get("mp"), 3)
    ck.expect("hud_probe.spent_has_none",
              phases.get("spent/0", {}).get("marine", {}).get("mp"), 0)
    ck.expect("hud_probe.selected_is_the_marine",
              phases.get("selected/1", {}).get("selection"), MARINE_SLOT)
    check_pool_panel(ck, document.get("pool_panel"), root)
    check_recall(ck, document.get("recall"))
    check_load(ck, document)
    return ck.report()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--game-copy", type=Path,
                    help="a copy of the game, outside this repository")
    ap.add_argument("--dbgcall", type=Path, help="path to dbgcall.exe")
    ap.add_argument("-o", "--out", type=Path,
                    help="where to write the capture (merged if it exists)")
    ap.add_argument("--phases", default=",".join(ALL_PHASES),
                    help=f"comma-separated subset of {', '.join(ALL_PHASES)}")
    ap.add_argument("--saves", type=Path,
                    default=Path("tests") / "fixtures" / "saves",
                    help="where _2_, _6_ and _31_.sav are staged from")
    ap.add_argument("--check", metavar="CAPTURE", type=Path,
                    help="compare a capture with the documented tables")
    ap.add_argument("--root", type=Path, default=Path("gog_incubation"),
                    help="the game root, for the libraries and Info.lcl "
                         "(--check)")
    ap.add_argument("--attempts", type=int, default=gold.DEFAULT_ATTEMPTS)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")
    try:
        if args.check is not None:
            return check(args.check, args.root)
        if args.game_copy is None or args.dbgcall is None or args.out is None:
            ap.error("a capture needs --game-copy, --dbgcall and -o")
        phases = tuple(p for p in args.phases.split(",") if p)
        unknown = [p for p in phases if p not in ALL_PHASES]
        if unknown:
            ap.error(f"unknown phase(s) {unknown}")
        return capture(args.game_copy, args.dbgcall, args.out, args.attempts,
                       phases, args.saves)
    except (ProbeError, gold.CaptureError) as exc:
        LOG.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
