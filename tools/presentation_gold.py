#!/usr/bin/env python3
"""Measure the presentation layer inside a running ``Incubation.exe``.

Two phases, both driven through ``tools/dbgcall`` at ``docs/91``'s anchor with
the fixture save loaded, both about the idle scheduler of ``docs/42`` §6:

``idle_random``
    the engine's own starter ``0x004060B0`` called two hundred times with a
    unit *type* as its argument, the second Lehmer seed and the slot table
    read after every call, and the whole unit array read once.  What it
    pins is *which* unit the starter picks: the type search at ``0x0040616C``
    compares the type byte of unit 0 two hundred times without advancing,
    so the argument is never honoured, every call past the countdown draws
    one ``aRandom2(0, 200)``, and the drawn slot is tried against the
    starter's guards -- alive, ``+0x4F`` clear, ``+0x56`` clear, the idle
    selector willing, a model handle on the object.  The replay here takes
    the measured seed, steps the generator once per call and predicts the
    slot, the guard that refused it, and the call that finally took.

``idle_pose``
    the same starter made deterministic -- the slot's countdown and the
    seed are written through the game's own imported ``memcpy`` so the
    first draw lands on the one candidate the save has -- and then stepped:
    ``IWorld::Simulate(1.0, 0)`` 45 times, 15 more, 2 more, the slot freed
    with ``aFreeCHAnimation``, one more step, one more.  At every stop the
    parts the clip is bound to are read back whole.  The parts are reached
    through the animation itself: its movement list names each movement,
    each movement holds the channel interface it attached to at ``+0x3C``,
    and the ``V100Part`` sits ``0x158`` below that interface.  What it pins
    is ``docs/42`` §6.2: the clock runs at 1.5 units a step, the last frame
    is held while the finished clip stays attached, the free changes
    nothing by itself, and the first step after it puts every bound part
    back at its bind pose and every channel slot to zero.

Usage::

    python3 tools/presentation_gold.py --game-copy /path/to/copy \\
        --dbgcall /path/to/copy/dbgcall.exe
    python3 tools/presentation_gold.py --check gog_incubation

The capture needs Wine and a **copy** of the game with
``tests/fixtures/saves/_6_.sav`` staged as ``Work/Saves2/_6_.sav``, exactly
like ``blob_gold.py``; the copy must not be inside this repository.  Phases
are written as they land and merged on re-run; ``--check`` fails when either
is missing.
"""

from __future__ import annotations

import argparse
import json
import logging
import struct
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import movemap_gold as gold                                     # noqa: E402
import blob_gold                                                # noqa: E402
from inclib import blob_creators, charisma                      # noqa: E402
from inclib.charisma_tables import SelectorKey, SelectorTables  # noqa: E402
from inclib.pe import PEFile                                    # noqa: E402
from inclib.rng import ARandom                                  # noqa: E402

LOG = logging.getLogger("presentation_gold")

SCHEMA = "presentation-capture/2"
DEFAULT_OUT = Path("tests/fixtures/presentation/capture_pose.json")

# --------------------------------------------------------------------------
# The engine's tables
# --------------------------------------------------------------------------

#: The idle slot table (`docs/42` §6.1): 19 dwords a slot.  `+0` active,
#: `+4` the `StdAnimation`, `+8` the slot's own index, `+0xC` the countdown
#: in frames, `+0x10` the unit record, `+0x14` the clip length as a float.
SLOT_TABLE = 0x004FA830
SLOT_STRIDE = 0x4C
SLOTS_READ = 2
IDLE_SLOT = 1
SLOT_ACTIVE, SLOT_ANIMATION, SLOT_INDEX, SLOT_COUNTDOWN, SLOT_UNIT, SLOT_LENGTH = range(6)
COUNTDOWN_ADDRESS = SLOT_TABLE + SLOT_STRIDE * IDLE_SLOT + 4 * SLOT_COUNTDOWN
ANIMATION_ADDRESS = SLOT_TABLE + SLOT_STRIDE * IDLE_SLOT + 4 * SLOT_ANIMATION
#: `StdAnimation`'s playback block (`docs/40` §4.8): time, mapped time,
#: length, speed at `+0x58..+0x64`, loops at `+0x70`, finished at `+0x80`,
#: and the movement list -- a `BB::DList` -- at `+0x34` with its first node
#: at `+0x38`.
ANIMATION_BYTES = 0x90
ANIMATION_TIME = 0x58
ANIMATION_LOOPS = 0x70
ANIMATION_FINISHED = 0x80
ANIMATION_MOVEMENTS_FIRST = 0x38
#: A `BB::DList` node is `{next, prev, item}`; the item of a movement node
#: is the `StdMovement`, whose `+0x3C` is the channel interface it attached
#: to (`0x0049B287`) and whose `+0x40` is the channel index.
NODE_NEXT, NODE_ITEM = 0x0, 0x8
MOVEMENT_CHANNEL = 0x3C
MOVEMENT_CHANNEL_INDEX = 0x40
#: `V100Part`: the class vtable at `+0`, the three channel slots at `+0xC0`
#: (`V100Part::DetachMovement` `0x004A675A` zeroes `this - 0x98 + 4 * ch`
#: with `this` the sub-object at `+0x158`), the Eng3d record at `+0xD0`
#: (`0x004A6FBA` returns `this + 0xD0`), and the channel interface -- the
#: sub-object whose vtable is the one holding `AttachMovement` -- at
#: `+0x158`.
PART_STRIDE = 0x170
PART_VTABLE = 0x004B1FEC
PART_CHANNELS = 0xC0
PART_RECORD = 0xD0
PART_CHANNEL_INTERFACE = 0x158
PART_IPART = 0x160
RECORD_BYTES = 0x70
RECORD_POSITION = 0x10
RECORD_MATRIX = 0x1C
#: `V100Model`: the class vtable at `+0`, the animation list at `+0x88`, and
#: the root part's `IPart` sub-object (`part + 0x160`) at `+0x98`.
MODEL_BYTES = 0x100
MODEL_ROOT_PART = 0x98
MODEL_VTABLE = 0x004B2244
#: The second Lehmer stream's seed (`docs/22` §3.2), a qword double.
ARANDOM2_SEED = 0x00514070
#: The unit array and the object array, whole.
UNIT_SLOTS = gold.UNIT_SLOTS
UNIT_STRIDE = gold.UNIT_STRIDE
OBJECT_TABLE = blob_gold.OBJECT_TABLE
OBJECT_STRIDE = blob_gold.OBJECT_STRIDE
OBJECT_MODEL = 0x45
#: The starter's guards, by offset in the unit record (`docs/21` §10).
UNIT_HP = gold.UNIT_HP
UNIT_HIDDEN = 0x4F
UNIT_ANIMATING = 0x56
UNIT_WEAPON = 0x3F
UNIT_PLAYER = gold.UNIT_PLAYER
UNIT_TYPE = gold.UNIT_TYPE
UNIT_OBJECT = 0x4B
#: The type the `idle_random` plan asks the starter for, and the reason it is
#: never honoured: the search loop at `0x0040616C` reads unit 0's type once.
STARTER_TYPE_ARGUMENT = 50
STARTER_TYPE_SLOT = 10
STARTER_LOOP = 0x0040616C
STARTER_LOOP_BYTES = bytes.fromhex("3bc5740b4181f9c80000007cf3")
IDLE_STARTS = 200
#: The speed the starter pushes (`docs/42` §1.2) and how many `Simulate`
#: steps the pose phase takes before each stop.  45 steps at 1.5 is 67.5;
#: 60 is the whole of a 90-unit clip; two past it show the hold.
IDLE_SPEED = 1.5
POSE_STEPS = (45, 15, 2)
#: The seed the pose phase writes.  Chosen so that the first
#: `aRandom2(0, 200)` is the one candidate slot the save has; the check
#: recomputes both facts rather than trusting either constant.
POSE_SEED = 139.0
POSE_UNIT_SLOT = 3
#: How many movements the pose plan follows through the animation's list:
#: exactly the clip's count, which `capture` reads out of the corpus for the
#: candidate unit before it renders the plan -- one node past the last is
#: the list's sentinel, whose item is null, and a read through it is an
#: argument error that fails the whole run.
POSE_MOVEMENTS_MAX = 32
POSE_SNAPSHOTS = ("bind", "start", "half", "end", "held", "freed", "after", "after2")

DECLARATIONS = """\
__cdecl void aSetSaveMode(i32)              = Incubation.exe+0x48770
__cdecl i32  aLoadGame(i32)                 = Incubation.exe+0x48e60
__cdecl ptr  aGetUnitMapElementPtr(i32)     = Incubation.exe+0x77ae0
__cdecl ptr  aGetObjectRecord(i32)          = Incubation.exe+0x4bd0
__cdecl ptr  aGetSymbolObjectPtr(i32)       = Incubation.exe+0x4c40
__cdecl i32  aGetModelHandle(ptr)           = Incubation.exe+0x2c770
__cdecl i32  aStartIdleAnimation(i32,i32)   = Incubation.exe+0x60b0
__cdecl i32  aFreeCHAnimation(i32)          = Incubation.exe+0x6000
__thiscall i32 Simulate(ptr,f32,i32)        = [[[0x4fae30]]+0x40]
"""
WORLD_POINTER = 0x004FAE30
SIMULATE = f"Simulate([0x{WORLD_POINTER:x}],1.0,0)"

# --------------------------------------------------------------------------
# The death creators -- docs/42 §4.8
# --------------------------------------------------------------------------

DEATH_DECLARATIONS = DECLARATIONS + """\
__cdecl ptr  aGetCtrlMapElementPtr(i32,i32) = Incubation.exe+0x2f730
__cdecl i32  aResetBlobs()                  = Incubation.exe+0x1dec0
__cdecl i32  aGetModelIndex(ptr)            = Incubation.exe+0x38f0
__cdecl i32  aGetUnitHeight(ptr)            = Incubation.exe+0x7ad70
""" + blob_gold.MEMCPY_DECL + "\n"
#: `0x00512A00` the gore level and `0x00512A78` the output mode id, the two
#: globals the death creators branch on (`blob_creators` §deaths).
GORE_GLOBAL = 0x00512A00
DISPLAY_MODE_GLOBAL = 0x00512A78
#: Every model name the seven programs can pass to the constructor.
DEATH_MODELS = ("A_BLUT1.3DI", "A_BLUT2.3DI", "A_BLUT3.3DI", "A_BLUT4.3DI",
                "A_SPLAT1.3DI", "A_SPLAT2.3DI", "A_SPLAT3.3DI", "A_SPLAT4.3DI",
                "A_SPLAT5.3DI", "A_BDEBI0.3DI", "A_BDEBI1.3DI",
                "A_50A.3DI", "A_50B.3DI", "A_50C.3DI", "A_51A.3DI", "A_51B.3DI",
                "A_51C.3DI", "A_56A.3DI", "A_56B.3DI", "A_56C.3DI")
#: The tiles the calls use, by the unit standing there: the one marine
#: candidate, the one `Ray'Ther` (type 50, the computer's), and a case.
DEATH_TILE_SLOTS = {"m": POSE_UNIT_SLOT, "a": STARTER_TYPE_SLOT, "c": 0}
DEATH_READ_RECORDS = 48
#: Seeds written before each call.  The species burst flips a coin on its
#: first draw -- `10 * u <= 6.0` -- so two seeds take its two branches; the
#: check recomputes which branch each seed takes.
DEATH_SEED = 11.0
DEATH_SEED_SPECIES = 7.0
DEATH_SEED_OTHER = 4242.0
#: How many pool records the fourteen calls leave for the check to compare,
#: and how many of the clip's bound parts end away from their bind record.
#: Both are what the kept capture measured, pinned exactly so a thinner
#: re-take fails rather than comparing less.
DEATH_RECORDS_COMPARED = 253
POSE_PARTS_MOVED_AT_END = 10
#: `(phase, creator, argument tiles or literals, seed)`.
DEATH_CALLS: tuple[tuple[str, int, tuple[Any, ...], float], ...] = (
    ("puff_marine", 0x004297F0, ("m",), DEATH_SEED),
    ("blood_burst_marine", 0x00420B80, ("m",), DEATH_SEED),
    ("blood_burst_alien", 0x00420B80, ("a",), DEATH_SEED),
    ("barrel_burst_case", 0x004298D0, ("c",), DEATH_SEED),
    ("flying_debris_marine", 0x004216D0, ("m",), DEATH_SEED),
    ("blood_flood_0", 0x00420D80, ("m", "a", 0), DEATH_SEED),
    ("blood_flood_1", 0x00420D80, ("m", "a", 1), DEATH_SEED),
    ("blood_flood_2", 0x00420D80, ("m", "a", 2), DEATH_SEED),
    ("blood_spray_large_0", 0x00421360, ("m", "a", 0), DEATH_SEED),
    ("blood_spray_large_1", 0x00421360, ("m", "a", 1), DEATH_SEED),
    ("blood_spray_large_2", 0x00421360, ("m", "a", 2), DEATH_SEED),
    ("species_burst_alien", 0x00421C50, ("a",), DEATH_SEED_SPECIES),
    ("species_burst_alien_other", 0x00421C50, ("a",), DEATH_SEED_OTHER),
    ("species_burst_marine", 0x00421C50, ("m",), DEATH_SEED),
)


def deaths_state_plan() -> str:
    """Everything the death programs read that does not change per call."""
    cells = gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    lines = ["# deaths_state: the unit array, the control map, the gore level,",
             "# the output mode, the pool handle, the model handles and the",
             "# unit heights the death creators read.",
             DEATH_DECLARATIONS.rstrip("\n")]
    for index, name in enumerate(DEATH_MODELS):
        lines.append(f"--blob mn{index}:{(name + chr(0)).encode('ascii').hex()}")
    lines += ["aSetSaveMode(0)", f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
              f"u0 = aGetUnitMapElementPtr(0) --read $u0:{UNIT_SLOTS * UNIT_STRIDE}",
              f"c0 = aGetCtrlMapElementPtr(0,0) --read $c0:{cells}"
              f" --read 0x{GORE_GLOBAL:x}:4 --read 0x{DISPLAY_MODE_GLOBAL:x}:4",
              f"handle = aResetBlobs() --read 0x{blob_gold.POOL_HANDLE:x}:4"]
    for index in range(len(DEATH_MODELS)):
        lines.append(f"aGetModelIndex(&mn{index})")
    for key, slot in sorted(DEATH_TILE_SLOTS.items()):
        lines.append(f"h_{key} = aGetUnitHeight($u0+0x{slot * UNIT_STRIDE:x})")
    return "\n".join(lines) + "\n"


def death_tiles(state_rows: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    """Each tile key's `x, y`, symbol object id and unit height."""
    _base, units = unit_array(state_rows)
    cells = b""
    for row in state_rows:
        raw = _reads(row).get("$c0")
        if raw is not None:
            cells = raw
    heights = {row["call"]: int(row["eax"], 16) for row in state_rows
               if row.get("call") == "aGetUnitHeight"}
    # `aGetUnitHeight` rows do not carry the binding; match them in order.
    height_rows = [int(row["eax"], 16) for row in state_rows
                   if row.get("call") == "aGetUnitHeight" and row.get("status") == "ok"]
    out: dict[str, dict[str, int]] = {}
    for index, (key, slot) in enumerate(sorted(DEATH_TILE_SLOTS.items())):
        record = unit_record(units, slot)
        x, y = record[gold.UNIT_X], record[gold.UNIT_Y]
        base = (y * gold.CAPTURE_WIDTH + x) * gold.CELL_STRIDE
        symbol = struct.unpack_from("<H", cells, base + blob_gold.CELL_OBJECT)[0]
        out[key] = {"x": x, "y": y, "symbol": symbol, "slot": slot,
                    "type": record[UNIT_TYPE], "player": record[UNIT_PLAYER],
                    "height": height_rows[index] if index < len(height_rows) else -1}
    del heights
    return out


def death_plan(name: str, creator: int, spec: tuple[Any, ...], seed: float,
               tiles: dict[str, dict[str, int]], handle: int) -> str:
    """One process: the symbol objects, the reset, the seed, the call, the pool."""
    args = []
    for item in spec:
        if isinstance(item, str):
            args += [tiles[item]["x"], tiles[item]["y"]]
        else:
            args.append(item)
    arity = len(args)
    entry = blob_gold._entry_address(handle)
    lines = [f"# death_{name}: 0x{creator:08X}({', '.join(map(str, args))}) from seed {seed}",
             DEATH_DECLARATIONS.rstrip("\n"),
             f"__cdecl i32 c{creator:08X}({','.join('i32' for _ in args)})"
             f" = Incubation.exe+0x{creator - 0x400000:x}",
             f"--blob seed:{struct.pack('<d', seed).hex()}",
             "aSetSaveMode(0)", f"loaded = aLoadGame({gold.CAPTURE_SLOT})"]
    for key in sorted(DEATH_TILE_SLOTS):
        lines.append(f"s_{key} = aGetSymbolObjectPtr({tiles[key]['symbol']})"
                     f" --read $s_{key}:{blob_gold.SYMBOL_RECORD_BYTES}")
    lines += [f"handle = aResetBlobs() --read 0x{blob_gold.POOL_HANDLE:x}:4"
              f" --read 0x{GORE_GLOBAL:x}:4 --read 0x{DISPLAY_MODE_GLOBAL:x}:4",
              f"seeded = memcpy(0x{ARANDOM2_SEED:x}, &seed, 8) --read 0x{ARANDOM2_SEED:x}:8",
              f"made = c{creator:08X}({', '.join(map(str, args))}) --read 0x{ARANDOM2_SEED:x}:8",
              f"aGetUnitMapElementPtr(0) --read [0x{entry:x}]:"
              f"{DEATH_READ_RECORDS * blob_gold.RECORD_BYTES} --read 0x{ARANDOM2_SEED:x}:8"]
    del arity
    return "\n".join(lines) + "\n"


def _slots() -> str:
    return (f" --read 0x{SLOT_TABLE:x}:{SLOTS_READ * SLOT_STRIDE}"
            f" --read [0x{ANIMATION_ADDRESS:x}]:{ANIMATION_BYTES}"
            f" --read 0x{ARANDOM2_SEED:x}:8")


# --------------------------------------------------------------------------
# The plans
# --------------------------------------------------------------------------

def idle_random_plan() -> str:
    """Two hundred starter calls, the seed and the slot table after each."""
    lines = [
        "# idle_random: who the idle starter picks.  The type argument is a",
        "# real type the save carries (slot 10 is the only unit of it); the",
        "# search loop never reaches slot 10 and the draw decides instead.",
        DECLARATIONS.rstrip("\n"),
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        f"u0 = aGetUnitMapElementPtr(0) --read $u0:{UNIT_SLOTS * UNIT_STRIDE}",
        f"objects = aGetSymbolObjectPtr(0) --read [0x{OBJECT_TABLE:x}]:"
        f"{UNIT_SLOTS * OBJECT_STRIDE}" + _slots(),
    ]
    lines += [f"started = aStartIdleAnimation({IDLE_SLOT},{STARTER_TYPE_ARGUMENT})"
              + _slots()] * IDLE_STARTS
    lines.append(f"freed = aFreeCHAnimation({IDLE_SLOT})" + _slots())
    return "\n".join(lines) + "\n"


def _node(index: int) -> str:
    """The expression for the *index*-th node of the movement list."""
    expr = f"[[0x{ANIMATION_ADDRESS:x}]+0x{ANIMATION_MOVEMENTS_FIRST:x}]"
    for _ in range(index):
        expr = f"[{expr}+0x{NODE_NEXT:x}]"
    return expr


def _part_expression(index: int) -> str:
    return (f"[[{_node(index)}+0x{NODE_ITEM:x}]+0x{MOVEMENT_CHANNEL:x}]"
            f"-0x{PART_CHANNEL_INTERFACE:x}")


def _snapshot(name: str, movements: int) -> str:
    """Read every bound part whole, plus the slot table and the animation."""
    reads = "".join(f" --read $p{k}:{PART_STRIDE}" for k in range(movements))
    return f"s_{name} = aGetModelHandle([$o+0x45])" + reads + _slots()


def idle_pose_plan(movements: int) -> str:
    """Start the one candidate deterministically and step it to the end."""
    if not 1 <= movements <= POSE_MOVEMENTS_MAX:
        raise ValueError(f"movements {movements} out of range")
    seed = struct.pack("<d", POSE_SEED).hex()
    lines = [
        "# idle_pose: the parts a clip binds, at eight stops from bind pose",
        "# to bind pose.  The countdown and the seed are written through the",
        "# game's own memcpy so the starter takes on its first call.",
        DECLARATIONS.rstrip("\n"),
        blob_gold.MEMCPY_DECL,
        "--blob zero:00000000",
        f"--blob seed:{seed}",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        f"u0 = aGetUnitMapElementPtr(0) --read $u0:{UNIT_SLOTS * UNIT_STRIDE}",
        f"u = aGetUnitMapElementPtr({POSE_UNIT_SLOT}) --read $u:{UNIT_STRIDE}",
        f"o = aGetObjectRecord({POSE_UNIT_SLOT}) --read $o:{OBJECT_STRIDE}",
        f"freed0 = aFreeCHAnimation({IDLE_SLOT})" + _slots(),
        f"countdown = memcpy(0x{COUNTDOWN_ADDRESS:x}, &zero, 4)" + _slots(),
        f"seeded = memcpy(0x{ARANDOM2_SEED:x}, &seed, 8)" + _slots(),
        f"model = aGetModelHandle([$o+0x45]) --read [$o+0x45]:{MODEL_BYTES}",
        f"started = aStartIdleAnimation({IDLE_SLOT},{STARTER_TYPE_ARGUMENT})"
        + _slots(),
    ]
    # Bind each part's address to a name while the movements still point
    # at their channels: `memcpy(p, p, 0)` copies nothing and returns `p`.
    for k in range(movements):
        expr = _part_expression(k)
        lines.append(f"p{k} = memcpy({expr}, {expr}, 0)"
                     f" --read [{_node(k)}+0x{NODE_ITEM:x}]:0x44")
    # "bind" is read after the start but before any step: the start binds
    # the movements and writes nothing into a record until `Simulate` runs.
    lines.append(_snapshot("bind", movements))
    lines.append(_snapshot("start", movements))
    lines += [SIMULATE] * POSE_STEPS[0]
    lines.append(_snapshot("half", movements))
    lines += [SIMULATE] * POSE_STEPS[1]
    lines.append(_snapshot("end", movements))
    lines += [SIMULATE] * POSE_STEPS[2]
    lines.append(_snapshot("held", movements))
    lines.append(f"freed = aFreeCHAnimation({IDLE_SLOT})" + _slots())
    lines.append(_snapshot("freed", movements))
    lines.append(SIMULATE)
    lines.append(_snapshot("after", movements))
    lines.append(SIMULATE)
    lines.append(_snapshot("after2", movements))
    return "\n".join(lines) + "\n"


PLAN_NAMES = ("idle_random", "idle_pose", "deaths_state") + tuple(
    "death_" + name for name, _c, _a, _s in DEATH_CALLS)


# --------------------------------------------------------------------------
# Reading the capture back
# --------------------------------------------------------------------------

def _hex_bytes(text: str) -> bytes:
    return bytes.fromhex(text.replace(" ", ""))


def _reads(row: dict[str, Any] | None) -> dict[str, bytes]:
    out: dict[str, bytes] = {}
    for key, text in ((row or {}).get("reads") or {}).items():
        if "<" not in text:
            out[key] = _hex_bytes(text)
    return out


def slot_of(row: dict[str, Any] | None) -> tuple[int, ...] | None:
    raw = _reads(row).get(f"0x{SLOT_TABLE:x}")
    if raw is None:
        return None
    return struct.unpack_from("<6I", raw, SLOT_STRIDE * IDLE_SLOT)


def seed_of(row: dict[str, Any] | None) -> float | None:
    raw = _reads(row).get(f"0x{ARANDOM2_SEED:x}")
    return None if raw is None else struct.unpack("<d", raw)[0]


def animation_of(row: dict[str, Any] | None) -> dict[str, float] | None:
    raw = _reads(row).get(f"[0x{ANIMATION_ADDRESS:x}]")
    if raw is None or len(raw) < ANIMATION_BYTES:
        return None
    t, mapped, length, speed = struct.unpack_from("<4f", raw, ANIMATION_TIME)
    return {"time": t, "mapped": mapped, "length": length, "speed": speed,
            "loops": struct.unpack_from("<I", raw, ANIMATION_LOOPS)[0],
            "finished": struct.unpack_from("<I", raw, ANIMATION_FINISHED)[0]}


def unit_array(rows: list[dict[str, Any]]) -> tuple[int, bytes]:
    """The unit array's address and bytes, from the phase's own read."""
    for row in rows:
        if row.get("call") == "aGetUnitMapElementPtr" and row.get("args") == ["0"]:
            raw = _reads(row).get("$u0")
            if raw is not None:
                return int(row["eax"], 16), raw
    raise SystemExit("the phase has no unit-array read")


def object_array(rows: list[dict[str, Any]]) -> bytes:
    for row in rows:
        raw = _reads(row).get(f"[0x{OBJECT_TABLE:x}]")
        if raw is not None:
            return raw
    return b""


def unit_record(units: bytes, slot: int) -> bytes:
    return units[slot * UNIT_STRIDE:(slot + 1) * UNIT_STRIDE]


class IdleGuards:
    """The starter's guards, in the order `0x004060B0` applies them.

    Returns the name of the guard that refuses a slot, or `None` when the
    starter would take it.  The selector is `docs/40` §7.2's idle selector,
    interpreted by `charisma_tables` -- an empty outcome is the selector's
    own `return 0`, which the starter answers by returning 1.
    """

    def __init__(self, root: str, units: bytes, objects: bytes) -> None:
        self.units = units
        self.objects = objects
        self.pe = PEFile(str(Path(root) / "Incubation.exe"))
        self._cache: dict[SelectorKey, bool] = {}

    def selector_takes(self, record: bytes) -> bool:
        key = SelectorKey(record[UNIT_TYPE], record[UNIT_WEAPON], record[UNIT_PLAYER])
        if key not in self._cache:
            self._cache[key] = bool(SelectorTables(self.pe, [key]).lookup("idle", key))
        return self._cache[key]

    def refuses(self, slot: int) -> str | None:
        record = unit_record(self.units, slot)
        if len(record) < UNIT_STRIDE:
            return "no record"
        if record[UNIT_HP] == 0:
            return "dead"
        if record[UNIT_HIDDEN] != 0:
            return "+0x4F"
        if record[UNIT_ANIMATING] != 0:
            return "+0x56"
        if not self.selector_takes(record):
            return "selector"
        base = record[UNIT_OBJECT] * OBJECT_STRIDE
        if base + OBJECT_STRIDE > len(self.objects):
            return "no object"
        if self.objects[base + OBJECT_MODEL] == 0:
            return "no model"
        return None

    def candidates(self) -> list[int]:
        return [slot for slot in range(UNIT_SLOTS) if self.refuses(slot) is None]


def replay_random(rows: list[dict[str, Any]], guards: IdleGuards,
                  unit_base: int) -> dict[str, Any]:
    """Classify every starter call of the `idle_random` phase.

    A call is one of: a countdown tick (no draw, countdown one less); a
    miss (one draw, the drawn slot refused, the slot stays empty); the
    start (one draw, the drawn slot taken, the slot filled with its
    record); a free (the slot was held with its countdown spent, this call
    emptied it, and the draw that followed missed or took).  Anything else
    is reported.
    """
    out: dict[str, Any] = {"ticks": 0, "misses": 0, "starts": [], "frees": 0,
                           "odd": [], "refusals": {}, "draws": 0}
    prev_seed: float | None = None
    prev_slot: tuple[int, ...] | None = None
    for row in rows:
        seed = seed_of(row)
        slot = slot_of(row)
        if row.get("call") != "aStartIdleAnimation":
            if seed is not None:
                prev_seed = seed
            if slot is not None:
                prev_slot = slot
            continue
        if seed is None or slot is None or prev_seed is None or prev_slot is None:
            out["odd"].append((row.get("i"), "unread"))
            continue
        if seed == prev_seed:
            if prev_slot[SLOT_COUNTDOWN] > 0 and \
                    slot[SLOT_COUNTDOWN] == prev_slot[SLOT_COUNTDOWN] - 1:
                out["ticks"] += 1
            else:
                out["odd"].append((row.get("i"), "no draw", prev_slot[:5], slot[:5]))
        else:
            rng = ARandom(prev_seed)
            drawn = int(rng.raw(0, 200))
            out["draws"] += 1
            refused = guards.refuses(drawn)
            if abs(rng.seed - seed) > 1e-9:
                out["odd"].append((row.get("i"), "not one draw", prev_seed, seed))
            elif prev_slot[SLOT_ACTIVE] == 1:
                out["frees"] += 1
                if refused is None and slot[SLOT_ACTIVE] == 1:
                    out["starts"].append((row.get("i"), drawn, slot))
                elif refused is None or slot[SLOT_ACTIVE] != 0:
                    out["odd"].append((row.get("i"), "free then", drawn, refused, slot[:5]))
                else:
                    out["misses"] += 1
                    out["refusals"][refused] = out["refusals"].get(refused, 0) + 1
            elif slot[SLOT_ACTIVE] == 1:
                if refused is not None:
                    out["odd"].append((row.get("i"), "took a refused slot", drawn, refused))
                elif slot[SLOT_UNIT] != unit_base + UNIT_STRIDE * drawn:
                    out["odd"].append((row.get("i"), "took another unit", drawn,
                                       hex(slot[SLOT_UNIT])))
                else:
                    out["starts"].append((row.get("i"), drawn, slot))
            elif refused is None:
                out["odd"].append((row.get("i"), "missed a candidate", drawn))
            else:
                out["misses"] += 1
                out["refusals"][refused] = out["refusals"].get(refused, 0) + 1
        prev_seed, prev_slot = seed, slot
    return out


def parse_snapshot(row: dict[str, Any]) -> list[dict[str, Any] | None]:
    """One stop's bound parts, decoded; `None` for an index past the clip."""
    parts: list[dict[str, Any] | None] = []
    reads = row.get("reads") or {}
    for k in range(POSE_MOVEMENTS_MAX):
        text = reads.get(f"$p{k}")
        if text is None or "<" in text:
            parts.append(None)
            continue
        raw = _hex_bytes(text)
        if len(raw) < PART_STRIDE or struct.unpack_from("<I", raw, 0)[0] != PART_VTABLE:
            parts.append(None)
            continue
        record = raw[PART_RECORD:PART_RECORD + RECORD_BYTES]
        parts.append({
            "channels": list(struct.unpack_from("<3I", raw, PART_CHANNELS)),
            "record": record.hex(),
            "position": list(struct.unpack_from("<3i", raw, PART_RECORD + RECORD_POSITION)),
            "matrix": list(struct.unpack_from("<9i", raw, PART_RECORD + RECORD_MATRIX)),
        })
    return parts


def snapshot_rows(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """The eight stops of the pose phase, by name, in plan order.

    A JSONL row names the *call*, not the binding, so the stops are matched
    to their names by the order the plan makes them in.
    """
    stops = [r for r in rows if r.get("call") == "aGetModelHandle"
             and "$p0" in (r.get("reads") or {})]
    return dict(zip(POSE_SNAPSHOTS, stops))


def _read_dword(rows: list[dict[str, Any]], key: str) -> int:
    for row in rows:
        raw = _reads(row).get(key)
        if raw is not None:
            return struct.unpack_from("<I", raw)[0]
    raise SystemExit(f"no read of {key} in the phase")


def _row_after(rows: list[dict[str, Any]], call: str, skip: int = 0) -> dict[str, Any] | None:
    seen = 0
    for row in rows:
        if row.get("call") == call:
            if seen == skip:
                return row
            seen += 1
    return None


def idle_clip_of(root: str, record: bytes) -> charisma.Animation | None:
    """The idle clip the selector names for a unit record, parsed."""
    pe = PEFile(str(Path(root) / "Incubation.exe"))
    key = SelectorKey(record[UNIT_TYPE], record[UNIT_WEAPON], record[UNIT_PLAYER])
    outcomes = SelectorTables(pe, [key]).lookup("idle", key)
    if not outcomes:
        return None
    path = Path(root) / "CHData" / "Animations" / (outcomes[0].name + ".cha")
    return charisma.parse_animation_file(str(path))


def model_part_names(root: str, record: bytes) -> list[str]:
    """The part names of the model the selector gives a unit record."""
    pe = PEFile(str(Path(root) / "Incubation.exe"))
    key = SelectorKey(record[UNIT_TYPE], record[UNIT_WEAPON], record[UNIT_PLAYER])
    outcomes = SelectorTables(pe, [key]).lookup("model", key)
    if not outcomes:
        return []
    path = Path(root) / "CHData" / "Objects" / (outcomes[0].name + ".cho")
    return [part.name for part in charisma.parse_model_file(str(path)).parts]


def movement_channels(rows: list[dict[str, Any]]) -> list[tuple[int, int] | None]:
    """`(channel interface, channel index)` per movement node, from the
    reads the binding calls carry; `None` where the node was unreadable."""
    out: list[tuple[int, int] | None] = []
    for row in rows:
        if row.get("call") != "memcpy":
            continue
        reads = row.get("reads") or {}
        text = next((v for k, v in reads.items() if k.endswith(f"+0x{NODE_ITEM:x}]")), None)
        if text is None:
            continue
        if "<" in text:
            out.append(None)
            continue
        raw = _hex_bytes(text)
        out.append((struct.unpack_from("<I", raw, MOVEMENT_CHANNEL)[0],
                    struct.unpack_from("<I", raw, MOVEMENT_CHANNEL_INDEX)[0]))
    return out


def engine_length(clip: charisma.Animation) -> float:
    """What `KeyFramedAnimation::Init` stores at `+0x60`.

    `0x004A0A01` asks the animation for its **first** movement, casts it to
    `IMovement` and calls slot `0x2C`, which for every keyframed movement
    class answers the last key's `+4` -- its time.  Not a descriptor field,
    and not the maximum over the movements.
    """
    return clip.movements[0].keys[-1].time if clip.movements else 0.0


# --------------------------------------------------------------------------
# The checks
# --------------------------------------------------------------------------

class Checker:
    def __init__(self) -> None:
        self.passed = 0
        self.failed: list[str] = []

    def pin(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            self.passed += 1
        else:
            self.failed.append(f"{name}: {detail}")


def check_random(ck: Checker, root: str, rows: list[dict[str, Any]]) -> None:
    ck.pin("random.rows_all_ok", all(r.get("status") == "ok" for r in rows),
           str([r for r in rows if r.get("status") != "ok"][:3]))
    unit_base, units = unit_array(rows)
    objects = object_array(rows)
    ck.pin("random.unit_array_whole", len(units) == UNIT_SLOTS * UNIT_STRIDE, str(len(units)))
    ck.pin("random.object_array_whole", len(objects) == UNIT_SLOTS * OBJECT_STRIDE,
           str(len(objects)))
    guards = IdleGuards(root, units, objects)
    # The type argument names a type the save has (slot 10), and the search
    # loop can only ever match unit 0 -- whose type is another.
    typed = [s for s in range(UNIT_SLOTS) if unit_record(units, s)[UNIT_TYPE]
             == STARTER_TYPE_ARGUMENT and unit_record(units, s)[UNIT_HP]]
    ck.pin("random.type_argument_exists_in_save", typed == [STARTER_TYPE_SLOT], str(typed))
    ck.pin("random.type_search_cannot_match",
           unit_record(units, 0)[UNIT_TYPE] != STARTER_TYPE_ARGUMENT,
           f"unit 0 is type {unit_record(units, 0)[UNIT_TYPE]}")
    pe = PEFile(str(Path(root) / "Incubation.exe"))
    ck.pin("random.type_search_loop_does_not_advance",
           pe.bytes_at(STARTER_LOOP, len(STARTER_LOOP_BYTES)) == STARTER_LOOP_BYTES,
           pe.bytes_at(STARTER_LOOP, len(STARTER_LOOP_BYTES)).hex())
    candidates = guards.candidates()
    ck.pin("random.one_candidate_in_save", candidates == [POSE_UNIT_SLOT], str(candidates))
    ck.pin("random.type_argument_unit_is_refused",
           guards.refuses(STARTER_TYPE_SLOT) == "+0x4F", str(guards.refuses(STARTER_TYPE_SLOT)))
    replay = replay_random(rows, guards, unit_base)
    ck.pin("random.every_call_classified", not replay["odd"], str(replay["odd"][:4]))
    ck.pin("random.one_draw_per_call_past_countdown",
           replay["draws"] == IDLE_STARTS - replay["ticks"],
           f"{replay['draws']} draws, {replay['ticks']} ticks")
    ck.pin("random.misses_are_refusals", replay["misses"] > 0
           and set(replay["refusals"]) <= {"dead", "+0x4F", "+0x56", "selector", "no model"},
           str(replay["refusals"]))
    # A start is a chance event -- one slot in two hundred a draw -- so what
    # is pinned unconditionally is the classification; the start's own state
    # is pinned when the run had one (the pose phase forces one either way).
    ck.pin("random.misses_at_least_50", replay["misses"] >= 50, str(replay["misses"]))
    ck.pin("random.every_start_is_the_candidate",
           all(drawn == POSE_UNIT_SLOT for _, drawn, _ in replay["starts"]),
           str(replay["starts"]))
    if replay["starts"]:
        first = replay["starts"][0]
        slot = first[2]
        clip = idle_clip_of(root, unit_record(units, first[1]))
        ck.pin("random.clip_is_the_selectors", clip is not None, "no clip")
        if clip is not None:
            ck.pin("random.countdown_is_engine_length",
                   slot[SLOT_COUNTDOWN] == int(engine_length(clip)),
                   f"{slot[SLOT_COUNTDOWN]} vs {engine_length(clip)} ({clip.name})")
            row = next((r for r in rows if r.get("i") == first[0]), None)
            anim = animation_of(row)
            ck.pin("random.animation_read", anim is not None, "unreadable")
            if anim:
                ck.pin("random.length_is_first_movement_last_key",
                       anim["length"] == engine_length(clip), str(anim))
                ck.pin("random.speed_1_5", anim["speed"] == IDLE_SPEED, str(anim))
                ck.pin("random.loops_1_time_0", anim["loops"] == 1 and anim["time"] == 0.0
                       and anim["finished"] == 0, str(anim))
        if clip is not None and first[0] + int(engine_length(clip)) + 2 <= len(rows):
            ck.pin("random.freed_by_the_engine_after_countdown", replay["frees"] >= 1,
                   f"{replay['frees']} frees")


def check_pose(ck: Checker, root: str, rows: list[dict[str, Any]]) -> None:
    ck.pin("pose.rows_all_ok", all(r.get("status") == "ok" for r in rows),
           str([r for r in rows if r.get("status") != "ok"][:3]))
    _unit_base, units = unit_array(rows)
    record = unit_record(units, POSE_UNIT_SLOT)
    clip = idle_clip_of(root, record)
    ck.pin("pose.unit_has_an_idle_clip", clip is not None, "none")
    length = engine_length(clip) if clip else 0.0
    ck.pin("pose.seed_draws_the_candidate",
           int(ARandom(POSE_SEED).raw(0, 200)) == POSE_UNIT_SLOT,
           str(int(ARandom(POSE_SEED).raw(0, 200))))
    seeded = _row_after(rows, "memcpy", 1)
    ck.pin("pose.seed_written", seed_of(seeded) == POSE_SEED, str(seed_of(seeded)))
    slot0 = slot_of(_row_after(rows, "memcpy", 0))
    ck.pin("pose.countdown_zeroed", slot0 is not None and slot0[SLOT_COUNTDOWN] == 0
           and slot0[SLOT_ACTIVE] == 0, str(slot0))
    started = _row_after(rows, "aStartIdleAnimation", 0)
    slot = slot_of(started)
    ck.pin("pose.started_on_the_first_call", slot is not None and slot[SLOT_ACTIVE] == 1,
           str(slot))
    if slot is not None and started is not None:
        rng = ARandom(POSE_SEED)
        rng.raw(0, 200)
        ck.pin("pose.one_draw", abs((seed_of(started) or 0.0) - rng.seed) < 1e-9,
               str(seed_of(started)))
        u_row = _row_after(rows, "aGetUnitMapElementPtr", 1)
        ck.pin("pose.unit_is_the_candidate",
               u_row is not None and slot[SLOT_UNIT] == int(u_row["eax"], 16),
               f"{slot[SLOT_UNIT]:#x}")
        ck.pin("pose.countdown_is_engine_length", slot[SLOT_COUNTDOWN] == int(length),
               f"{slot[SLOT_COUNTDOWN]} vs {length}")
        anim = animation_of(started)
        ck.pin("pose.start_state", anim is not None and anim["length"] == length
               and anim["speed"] == IDLE_SPEED and anim["loops"] == 1
               and anim["time"] == 0.0 and anim["finished"] == 0, str(anim))
    model_row = _row_after(rows, "aGetModelHandle", 0)
    model = _reads(model_row).get("[$o+0x45]")
    ck.pin("pose.model_vtable", model is not None
           and struct.unpack_from("<I", model, 0)[0] == MODEL_VTABLE, "")
    if model is not None and model_row is not None:
        root_part = struct.unpack_from("<I", model, MODEL_ROOT_PART)[0]
        bridge = int(model_row["eax"], 16)
        ck.pin("pose.bridge_is_the_root_parts_record",
               root_part - PART_IPART + PART_RECORD == bridge,
               f"root IPart {root_part:#x}, bridge {bridge:#x}")
    stop_rows = snapshot_rows(rows)
    ck.pin("pose.eight_stops", set(stop_rows) == set(POSE_SNAPSHOTS), str(sorted(stop_rows)))
    if set(stop_rows) != set(POSE_SNAPSHOTS):
        return
    stops = {name: parse_snapshot(row) for name, row in stop_rows.items()}
    bound = [k for k, p in enumerate(stops["start"]) if p is not None]
    ck.pin("pose.parts_reached_through_the_movements", len(bound) >= 1, "none")
    # A movement binds when the model has a part of its target's name; the
    # clip may name a part this model lacks (P0_S0_000's `Banner` is not in
    # P1_002), and that movement's channel pointer stays null.
    names = model_part_names(root, record)
    targets = [m.target for m in clip.movements] if clip else []
    expected = sum(1 for t in targets if t in names)
    ck.pin("pose.model_named_and_read", bool(names), "no model")
    ck.pin("pose.every_binding_movement_names_a_part",
           expected > 0 and len(bound) == expected,
           f"{len(bound)} parts for {expected} of {len(targets)} movements")
    channels = movement_channels(rows)
    ck.pin("pose.movement_channel_indices_are_0_or_1",
           len(channels) == len(targets) and
           all(c is not None and (c[0] == 0) == (c[1] == 0xFFFFFFFF)
               and (c[1] in (0, 1) or c[0] == 0) for c in channels),
           str(channels[:8]))
    rotation = sum(1 for c in channels if c and c[0] and c[1] == 1)
    position = sum(1 for c in channels if c and c[0] and c[1] == 0)
    wanted = {kind: sum(1 for m in (clip.movements if clip else [])
                        if m.target in names and m.channel == kind)
              for kind in ("Rotation matrix", "Position")}
    ck.pin("pose.rotation_is_channel_1_position_channel_0",
           (rotation, position) == (wanted["Rotation matrix"], wanted["Position"]),
           f"{rotation} rotation, {position} position vs {wanted}")
    if not bound:
        return
    slots_bound = [c for k in bound for c in stops["start"][k]["channels"]]
    ck.pin("pose.channels_bound_while_attached", any(slots_bound) and
           all(stops[n][k] is not None
               and stops[n][k]["channels"] == stops["start"][k]["channels"]
               for n in ("half", "end", "held") for k in bound),
           str([hex(c) for c in slots_bound[:6]]))
    ck.pin("pose.channels_zero_after_free",
           all(stops[n][k] is not None and stops[n][k]["channels"] == [0, 0, 0]
               for n in ("freed", "after", "after2") for k in bound), "")

    def same(a: str, b: str) -> bool:
        return all(stops[a][k] is not None and stops[b][k] is not None
                   and stops[a][k]["record"] == stops[b][k]["record"] for k in bound)

    def moved(a: str, b: str) -> int:
        return sum(stops[a][k] is None or stops[b][k] is None
                   or stops[a][k]["record"] != stops[b][k]["record"] for k in bound)

    ck.pin("pose.start_writes_nothing", same("bind", "start"), "")
    ck.pin("pose.clip_moves_the_parts", moved("start", "half") >= 1,
           f"{moved('start', 'half')} of {len(bound)}")
    half = animation_of(stop_rows["half"])
    ck.pin("pose.clock_runs_at_1_5", half is not None
           and half["time"] == POSE_STEPS[0] * IDLE_SPEED, str(half))
    end = animation_of(stop_rows["end"])
    ck.pin("pose.clip_finished_at_the_length", end is not None
           and end["time"] == length and end["finished"] == 1
           and (POSE_STEPS[0] + POSE_STEPS[1]) * IDLE_SPEED == length, str(end))
    held = animation_of(stop_rows["held"])
    ck.pin("pose.clock_clamped_past_the_end", held is not None
           and held["time"] == length and held["finished"] == 1, str(held))
    ck.pin("pose.last_frame_held_while_attached", same("end", "held"), "")
    ck.pin("pose.free_alone_moves_nothing", same("held", "freed"), "")
    ck.pin("pose.first_step_after_free_is_bind", same("bind", "after"),
           f"{moved('bind', 'after')} of {len(bound)} differ")
    ck.pin("pose.bind_pose_stays", same("after", "after2"), "")
    ck.pin("pose.parts_away_from_bind_at_the_end",
           moved("bind", "held") == POSE_PARTS_MOVED_AT_END,
           f"{moved('bind', 'held')} of {len(bound)} differ, {POSE_PARTS_MOVED_AT_END} pinned")
    freed = _row_after(rows, "aFreeCHAnimation", 1)
    ck.pin("pose.free_reports_the_slot", freed is not None and freed.get("result") == "1"
           and (slot_of(freed) or (1,))[SLOT_ACTIVE] == 0, str(freed and freed.get("result")))
    sims = [r for r in rows if r.get("call") == "Simulate"]
    ck.pin("pose.simulate_count", len(sims) == sum(POSE_STEPS) + 2, str(len(sims)))
    ck.pin("pose.simulate_thiscall_pops_8", all(r.get("esp_delta") == 8 for r in sims),
           str({r.get("esp_delta") for r in sims}))


def death_inputs(state_rows: list[dict[str, Any]], call_rows: list[dict[str, Any]],
                 tiles: dict[str, dict[str, int]]) -> blob_creators.DeathInputs:
    symbols = {}
    for row in call_rows:
        if row.get("call") != "aGetSymbolObjectPtr":
            continue
        for key, raw in _reads(row).items():
            if key.startswith("$s_"):
                symbols[key[3:]] = struct.unpack_from("<3i", raw, 0x10)
    models = {}
    handles = [int(row["eax"], 16) for row in state_rows
               if row.get("call") == "aGetModelIndex" and row.get("status") == "ok"]
    for name, handle in zip(DEATH_MODELS, handles):
        models[name] = handle if handle < 0x80000000 else handle - 0x100000000
    reset = _row_after(call_rows, "aResetBlobs", 0)
    gore = struct.unpack("<I", _reads(reset)[f"0x{GORE_GLOBAL:x}"])[0]
    mode = struct.unpack("<I", _reads(reset)[f"0x{DISPLAY_MODE_GLOBAL:x}"])[0]
    table: dict[tuple[int, int], Any] = {}
    for key, tile in tiles.items():
        unit = None
        if tile["type"] and tile["height"] >= 0 and tile["slot"] is not None:
            unit = blob_creators.DeathUnit(tile["type"], tile["player"], tile["height"])
        table[(tile["x"], tile["y"])] = (tuple(symbols[key]), unit)
    return blob_creators.DeathInputs(tiles=table, gore=gore, display_mode=mode, models=models)


def check_deaths(ck: Checker, root: str, phases: dict[str, Any]) -> None:
    state = (phases.get("deaths_state") or {}).get("rows")
    ck.pin("deaths_state.captured", bool(state), "phase missing")
    if not state:
        return
    ck.pin("deaths_state.rows_all_ok", all(r.get("status") == "ok" for r in state), "")
    tiles = death_tiles(state)
    ck.pin("deaths_state.tiles_have_units",
           all(tiles[k]["height"] > 0 for k in ("m", "a")), str(tiles))
    ck.pin("deaths_state.alien_is_species_50_of_the_computer",
           tiles["a"]["type"] == 50 and tiles["a"]["player"] == 0xFF, str(tiles["a"]))
    ck.pin("deaths_state.marine_is_the_players", tiles["m"]["player"] == 0, str(tiles["m"]))
    _base, units = unit_array(state)
    ck.pin("deaths_state.height_is_type_byte_x160",
           all(tiles[k]["height"] % blob_creators.Death.HEIGHT_UNIT == 0 for k in tiles), str(tiles))
    handle_state = _read_dword(state, f"0x{blob_gold.POOL_HANDLE:x}")
    compared = 0
    for name, creator, spec, seed in DEATH_CALLS:
        phase = (phases.get("death_" + name) or {}).get("rows")
        ck.pin(f"death.{name}.captured", bool(phase), "phase missing")
        if not phase:
            continue
        ok_rows = all(r.get("status") == "ok" for r in phase)
        ck.pin(f"death.{name}.rows_all_ok", ok_rows, str([r for r in phase if r.get("status") != "ok"][:2]))
        if not ok_rows:
            continue
        ck.pin(f"death.{name}.pool_handle_stable",
               _read_dword(phase, f"0x{blob_gold.POOL_HANDLE:x}") == handle_state, "")
        inputs = death_inputs(state, phase, tiles)
        seeded = _row_after(phase, "memcpy", 0)
        made = _row_after(phase, f"c{creator:08X}", 0)
        after = _row_after(phase, "aGetUnitMapElementPtr", 0)
        ck.pin(f"death.{name}.seed_written", seed_of(seeded) == seed, str(seed_of(seeded)))
        ck.pin(f"death.{name}.returned_1", made is not None and made.get("result") == "1",
               str(made and made.get("result")))
        pool_raw = next((raw for key, raw in _reads(after).items() if key.startswith("[0x")), b"")
        records = blob_gold.parse_records(pool_raw)
        args = []
        for item in spec:
            args += [tiles[item]["x"], tiles[item]["y"]] if isinstance(item, str) else [item]
        arity, program = blob_creators.DEATH_PROGRAMS[creator]
        ck.pin(f"death.{name}.arity", arity == len(args), f"{arity} vs {len(args)}")
        pool = blob_creators.Pool(inputs)
        draws = blob_creators.Draws(seed)
        program(pool, draws, args, inputs)
        rng = ARandom(seed)
        for _ in range(draws.count):
            rng.raw(0, 1)
        ck.pin(f"death.{name}.draw_count", abs(rng.seed - (seed_of(made) or -1.0)) < 1e-9,
               f"{draws.count} draws replayed, seed {rng.seed} vs {seed_of(made)}")
        seen = min(len(pool.records), DEATH_READ_RECORDS)
        ck.pin(f"death.{name}.record_count", len(records) == seen,
               f"{len(records)} read, {len(pool.records)} built")
        wrong = []
        for index, record in enumerate(records):
            if index >= len(pool.records):
                wrong.append((index, "missing"))
                continue
            built = pool.records[index]
            for field in blob_creators.FIELDS:
                if record[field] != built[field]:
                    wrong.append((index, field, record[field], built[field]))
            compared += 1
        ck.pin(f"death.{name}.records_field_for_field", not wrong, str(wrong[:6]))
    ck.pin("deaths.records_compared", compared == DEATH_RECORDS_COMPARED,
           f"{compared} records compared, {DEATH_RECORDS_COMPARED} pinned")
    # Each of the five doubles the programs carry is told from its neighbour
    # by this capture: perturbed by one, some phase's replay changes.
    undiscriminated = [name for name in DEATH_CONSTANTS
                       if not _death_constant_discriminated(name, state, phases, tiles)]
    ck.pin("deaths.constants_discriminated",
           undiscriminated == list(DEATH_CONSTANTS_UNDISCRIMINATED), str(undiscriminated))


DEATH_CONSTANTS = ("BLOOD_VELOCITY", "BLOOD_VELOCITY_LARGE", "BLOOD_LIFT",
                   "BLOOD_STEP", "SPECIES_COIN")
#: The one this capture cannot tell from a neighbour: `BLOOD_LIFT` scales
#: the direction's vertical term, and the two tiles' objects stand at the
#: same height (both at z 0, and the direction service raises each by half
#: its own unit's height, 1 440 for both units), so the term is zero.  Its
#: value is read back out of the executable by `blob_tables` instead.
DEATH_CONSTANTS_UNDISCRIMINATED = ("BLOOD_LIFT",)


def _death_replays(state: list[dict[str, Any]], phases: dict[str, Any],
                   tiles: dict[str, dict[str, int]]) -> list[Any]:
    out: list[Any] = []
    for name, creator, spec, seed in DEATH_CALLS:
        phase = (phases.get("death_" + name) or {}).get("rows")
        if not phase or any(r.get("status") != "ok" for r in phase):
            continue
        inputs = death_inputs(state, phase, tiles)
        args: list[int] = []
        for item in spec:
            args += [tiles[item]["x"], tiles[item]["y"]] if isinstance(item, str) else [item]
        pool = blob_creators.Pool(inputs)
        draws = blob_creators.Draws(seed)
        blob_creators.DEATH_PROGRAMS[creator][1](pool, draws, args, inputs)
        out.append((draws.count, pool.records[:DEATH_READ_RECORDS]))
    return out


def _death_constant_discriminated(name: str, state: list[dict[str, Any]],
                                  phases: dict[str, Any],
                                  tiles: dict[str, dict[str, int]]) -> bool:
    base = _death_replays(state, phases, tiles)
    was = getattr(blob_creators, name)
    setattr(blob_creators, name, was + 1.0)
    try:
        return _death_replays(state, phases, tiles) != base
    finally:
        setattr(blob_creators, name, was)


def check(path: Path, root: str) -> int:
    if not path.is_file():
        LOG.error("%s: no capture; take one with --game-copy", path)
        return 1
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schema") != SCHEMA:
        LOG.error("%s: schema %r, expected %r -- re-take the capture",
                  path, document.get("schema"), SCHEMA)
        return 1
    phases = document.get("phases") or {}
    ck = Checker()
    for name, fn in (("idle_random", check_random), ("idle_pose", check_pose)):
        rows = (phases.get(name) or {}).get("rows")
        ck.pin(f"{name}.captured", bool(rows), "phase missing -- re-take it")
        if rows:
            fn(ck, root, rows)
    check_deaths(ck, root, phases)
    for line in ck.failed:
        print("FAIL " + line)
    print(f"presentation_gold: {ck.passed}/{ck.passed + len(ck.failed)} checks passed")
    return 0 if not ck.failed and ck.passed > 0 else 1


# --------------------------------------------------------------------------
# Taking the capture
# --------------------------------------------------------------------------

def pose_movements(root: str, phases: dict[str, Any]) -> int:
    """How many movements the candidate's idle clip has, from the corpus.

    The candidate is read off the `idle_random` phase's own unit array, so
    the pose phase cannot be rendered before that phase exists -- and the
    game copy is a game root, so the clip is parsed from **its** `CHData`.
    """
    rows = (phases.get("idle_random") or {}).get("rows")
    if not rows:
        raise SystemExit("idle_pose needs the idle_random phase first")
    _base, units = unit_array(rows)
    guards = IdleGuards(root, units, object_array(rows))
    candidates = guards.candidates()
    if candidates != [POSE_UNIT_SLOT]:
        raise SystemExit(f"the save's idle candidates are {candidates}, "
                         f"not [{POSE_UNIT_SLOT}]")
    clip = idle_clip_of(root, unit_record(units, POSE_UNIT_SLOT))
    if clip is None or not clip.movements:
        raise SystemExit("the candidate has no idle clip")
    return len(clip.movements)

def capture(game_copy: Path, dbgcall: Path, out: Path, attempts: int,
            only: list[str] | None = None) -> int:
    document: dict[str, Any] = {}
    if out.is_file():
        try:
            document = json.loads(out.read_text(encoding="utf-8"))
        except ValueError:
            document = {}
    if document.get("schema") != SCHEMA:
        document = {"schema": SCHEMA, "phases": {}}
    phases: dict[str, Any] = document.setdefault("phases", {})
    status = 0
    for name in PLAN_NAMES:
        if only and name not in only:
            continue
        if name in phases and not only:
            LOG.info("%s: already captured, skipping (name it with --phase to re-take)", name)
            continue
        if name == "idle_random":
            plan = idle_random_plan()
        elif name == "idle_pose":
            plan = idle_pose_plan(pose_movements(str(game_copy), phases))
        elif name == "deaths_state":
            plan = deaths_state_plan()
        else:
            state = (phases.get("deaths_state") or {}).get("rows")
            if not state:
                LOG.error("%s needs the deaths_state phase first", name)
                status = 1
                continue
            call = next(c for c in DEATH_CALLS if "death_" + c[0] == name)
            plan = death_plan(call[0], call[1], call[2], call[3], death_tiles(state),
                              _read_dword(state, f"0x{blob_gold.POOL_HANDLE:x}"))
        try:
            rows = gold.run_plan(game_copy, dbgcall, plan, f"pres_{name}", attempts=attempts)
        except gold.CaptureError as err:
            LOG.error("%s: %s", name, err)
            status = 1
            continue
        if not rows:
            LOG.error("%s: the anchor was never reached", name)
            status = 1
            continue
        phases[name] = {"rows": rows}
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(document, indent=1), encoding="utf-8")
        LOG.info("%s: wrote %d rows to %s", name, len(rows), out)
    return status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--game-copy", type=Path)
    parser.add_argument("--dbgcall", type=Path)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--attempts", type=int, default=gold.DEFAULT_ATTEMPTS)
    parser.add_argument("--phase", action="append", choices=PLAN_NAMES,
                        help="take (or re-take) only this phase")
    parser.add_argument("--print-plan", choices=PLAN_NAMES)
    parser.add_argument("--movements", type=int, default=21,
                        help="movement count for --print-plan idle_pose")
    parser.add_argument("--check", metavar="ROOT",
                        help="re-read the capture against the game root")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s")
    if args.print_plan:
        if args.print_plan == "idle_random":
            sys.stdout.write(idle_random_plan())
        elif args.print_plan == "idle_pose":
            sys.stdout.write(idle_pose_plan(args.movements))
        elif args.print_plan == "deaths_state":
            sys.stdout.write(deaths_state_plan())
        else:
            parser.error("a death plan is rendered from the deaths_state phase; "
                         "take that phase and read the copy's pres_death_*.plan")
        return 0
    if args.check:
        return check(args.out, args.check)
    if args.game_copy is None or args.dbgcall is None:
        parser.error("--game-copy and --dbgcall are required for a capture")
    repo = Path(__file__).resolve().parent.parent
    copy = args.game_copy.resolve()
    if repo in copy.parents or copy == repo:
        parser.error(f"{copy} is inside this repository; the capture must "
                     "run against a copy of the game")
    return capture(args.game_copy, args.dbgcall, args.out, args.attempts, args.phase)


if __name__ == "__main__":
    sys.exit(main())
