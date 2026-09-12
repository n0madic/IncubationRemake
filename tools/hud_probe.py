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

This tool is **outside** ``make test``: it needs Wine, ``dbgcall.exe`` and a
copy of the game with ``Work/Saves2/_6_.sav`` in it, and it refuses a game
directory inside this repository.  ``--check`` compares a capture's decoded
blits with the table above.

Usage::

    python3 tools/hud_probe.py --game-copy /path/to/copy \\
        --dbgcall /path/to/copy/dbgcall.exe -o hud_probe.json
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
from inclib.check import Checker                                   # noqa: E402

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

def capture(game_copy: Path, dbgcall: Path, out: Path, attempts: int) -> int:
    repo = Path(__file__).resolve().parent.parent
    if repo in game_copy.resolve().parents or game_copy.resolve() == repo:
        raise ProbeError(
            f"{game_copy} is inside this repository; the probe must run "
            f"from a copy of the game, never from gog_incubation/")
    save = game_copy / "Work" / "Saves2" / f"_{gold.CAPTURE_SLOT}_.sav"
    if not save.is_file():
        raise ProbeError(f"the copy needs {save}")
    if not dbgcall.is_file():
        raise ProbeError(f"no dbgcall at {dbgcall}")
    document: dict[str, Any] = {"schema": SCHEMA, "phases": {}}
    for phase in PHASES:
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
            document["phases"][f"{key}/{tick}"] = {
                "phase": key,
                "tick": int(row["reads"][f"{TICK_BYTE:#x}"].replace(" ", "")[:2], 16),
                "selection": int.from_bytes(
                    bytes.fromhex(row["reads"][f"{SELECTION:#x}"].replace(" ", "")),
                    "little"),
                "marine": {"mp": marine[UNIT_MP], "hp": marine[UNIT_HP],
                           "action": marine[UNIT_ACTION]},
                "lit": lit_pixels(_surface_of(row, buf)),
            }
    out.write_text(json.dumps(document, indent=1, sort_keys=True) + "\n",
                   encoding="utf-8")
    LOG.info("wrote %s", out)
    return 0


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
    return ck.report()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--game-copy", type=Path,
                    help="a copy of the game, outside this repository")
    ap.add_argument("--dbgcall", type=Path, help="path to dbgcall.exe")
    ap.add_argument("-o", "--out", type=Path, help="where to write the capture")
    ap.add_argument("--check", metavar="CAPTURE", type=Path,
                    help="compare a capture's blits with the documented table")
    ap.add_argument("--root", type=Path, default=Path("gog_incubation"),
                    help="the game root, for `Libs/mp.LIB` (--check)")
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
        return capture(args.game_copy, args.dbgcall, args.out, args.attempts)
    except (ProbeError, gold.CaptureError) as exc:
        LOG.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
