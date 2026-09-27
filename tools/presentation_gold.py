#!/usr/bin/env python3
"""Measure the presentation layer inside a running ``Incubation.exe``.

The first two phases, both driven through ``tools/dbgcall`` at ``docs/91``'s anchor with
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

Two phases added on 2026-09-13 (the backlog's stage 4, ``docs/102``, since
retired) load **no save** and
run at the anchor alone, because what they measure is a global and not a
mission:

``jump_scream``
    the uncounted Lehmer stream's live seed, then three hundred
    ``aRandom2(0, 3)`` draws as the x87 returned them with the seed after
    each -- the draw behind ``aPlayJumpAnimaion``'s ``S_ALI_0/1/2`` ladder at
    ``0x00411950`` (``docs/97`` §31.8).  The check replays every draw from the
    seed read first and decodes the ladder's three targets and their wave
    and volume pushes out of the executable.

``frame_limiter``
    sixty calls of the skip controller ``0x0047F2E0(10, 20)`` bracketed by
    ``GetTickCount``, its tick, epoch and waited flag read after each -- the
    epoch rule ``docs/40`` §4.8 had read and called "roughly twice".  With
    nothing rendered between calls this is the ceiling, and the ceiling is
    what the check pins: the wait on every other call, the epoch moving only
    on the calls that do not wait, 27 ms a call against the nominal 50.

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
import functools
import json
import logging
import math
import struct
import sys
from pathlib import Path
from typing import Any, NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

import movemap_gold as gold                                     # noqa: E402
import blob_gold                                                # noqa: E402
from inclib import blob_creators, charisma, ctrlmap, eng3d      # noqa: E402
from inclib.cache import is_within                              # noqa: E402
from inclib.info import load_info_file                          # noqa: E402
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
                "A_51C.3DI", "A_56A.3DI", "A_56B.3DI", "A_56C.3DI",
                # The case's own model (`unitInfo + 0x6C` of type 32), which
                # `aBlob_CreateFlyingUnit` names -- the one death creator
                # whose model is the victim's.
                "A_BOX.3DI",
                # docs/42 section 7 -- the marker's arrows, the poison flash's
                # skulls and the heal flash's four crosses.
                "A_ARROW.3DI", "A_SKULL.3DI", "A_CROSS3.3DI", "A_CROSS2.3DI",
                "A_CROSS1.3DI", "A_CROSS.3DI",
                # docs/42 section 8 -- the set pieces' models.
                "A_DEBRIS.3DI", "A_LASERG.3DI", "L069EE00.3DI", "A_PARAB1.3DI")
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
#: 364 for the deaths and the unit animations, 239 for the set pieces of
#: docs/42 section 8 -- both capped at the 48 records a phase reads back.
DEATH_RECORDS_COMPARED = 364 + 239
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
    # docs/42 section 4.8 -- the three the first capture did not reach.
    # KillFire's third argument is the delay base: 0 from the fight's
    # death switch (0x0040DCE2), 20 from FireCircle (0x0041332C).
    ("kill_fire_marine", 0x00423AD0, ("m", 0), DEATH_SEED),
    ("kill_fire_circle", 0x00423AD0, ("m", 20), DEATH_SEED),
    ("fire_death_marine", 0x0042B1D0, ("m",), DEATH_SEED),
    # FlyingUnit takes twice the type's size byte; a case is small, so 0
    # is what the fight passes (0x0040DB68) -- 2 is used here so the delay
    # field is seen to be the argument rather than a constant.
    ("flying_unit_case", 0x00429700, ("c", 2), DEATH_SEED),
    # The species-3 and barrel death, and three impact arms: nine rings of
    # three from the tile's object, the third argument unread.
    ("fire_explosion_alien", 0x00429A80, ("a", 2), DEATH_SEED),
    # docs/42 section 7 -- the unit animations' creators (2026-09-03): the
    # selection marker, the landing dust, the two flash circles, and the
    # three position creators called at the marine's own object position
    # (`("@", "m")` expands to three dword reads of its `+0x10/+0x14/+0x18`).
    ("arrows_marine", 0x00422D40, ("m",), DEATH_SEED),
    ("landing_dust_marine", 0x004227C0, ("m",), DEATH_SEED),
    ("heal_flash_marine", 0x00423030, ("m",), DEATH_SEED),
    ("poison_flash_marine", 0x004232E0, ("m",), DEATH_SEED),
    ("zoombob_marine", 0x00423720, (("@", "m"), 4, 10, 3), DEATH_SEED),
    ("trail_marine", 0x00423670, (("@", "m"),), DEATH_SEED),
    ("push_dust_marine", 0x0042A6E0, (("@", "m"),), DEATH_SEED),
    # docs/42 section 8 -- the set pieces' creators (2026-09-03, docs/97 §32).
    ("tube_puffs_marine", 0x00423770, ("m",), DEATH_SEED),
    ("platform_dust_marine", 0x004234C0, (("@", "m"),), DEATH_SEED),
    ("ground_debris_marine", 0x00422610, ("m", 4800), DEATH_SEED),
    ("roof_debris_marine", 0x00422460, ("m", 8000), DEATH_SEED),
    ("wall_debris_marine", 0x004238C0, ("m",), DEATH_SEED),
    ("fire_circle_marine", 0x00422F00, ("m",), DEATH_SEED),
    ("laser_barrier_marine", 0x00428990, ("m", 0, 2), DEATH_SEED),
    ("laser_barrier_marine_x", 0x00428990, ("m", 1, 1), DEATH_SEED),
    ("statue_beam_marine", 0x00428BF0, ("m", "a", 3), DEATH_SEED),
    ("teleport_stream_marine", 0x0042A120, ("m", "a"), DEATH_SEED),
    ("bomber_marine", 0x0042A8E0, (("@", "m"), ("@", "a")), DEATH_SEED),
    ("para_bomb_marine", 0x0042B070, ("m", 3), DEATH_SEED),
)
#: The one call that spawns the victim type's own model: its record count
#: is pinned so a model the set does not carry cannot pass as agreement on
#: nothing.
DEATH_MUST_SPAWN = {"flying_unit_case": 1}


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
                    "cell_height": struct.unpack_from("<i", cells,
                                                      base + CELL_HEIGHT)[0],
                    "height": height_rows[index] if index < len(height_rows) else -1}
    del heights
    return out


def death_plan(name: str, creator: int, spec: tuple[Any, ...], seed: float,
               tiles: dict[str, dict[str, int]], handle: int) -> str:
    """One process: the symbol objects, the reset, the seed, the call, the pool."""
    args: list[Any] = []
    for item in spec:
        if isinstance(item, tuple):
            key = item[1]
            args += [f"[$s_{key}+0x10]", f"[$s_{key}+0x14]", f"[$s_{key}+0x18]"]
        elif isinstance(item, str):
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


# --------------------------------------------------------------------------
# The four cell placers -- docs/42 §9.1
# --------------------------------------------------------------------------

#: ``[0x004FA828]`` is a **pointer** to the 80-slot special-object array; each
#: record is 66 bytes and its state byte is at ``+0x40``, the subtype at
#: ``+0x41`` (``aCreateSpecialObject``'s last two arguments).
SPECIAL_ARRAY = 0x004FA828
SPECIAL_RECORD_BYTES = 66
SPECIAL_SLOTS = 80
SPECIAL_STATE = 0x40
SPECIAL_SUBTYPE = 0x41
#: The cell bytes the placers write, relative to the 23-byte record.
CELL_HEIGHT = 0x01
CELL_ACTION_POINT = 0x0B
CELL_FIELD_TYPE = 0x0D
CELL_EFFECT_TIMER = 0x0E
CELL_EFFECT_OBJECT = 0x0F
CELL_EFFECT_STATE = 0x10
CELL_DECAL_OBJECT = 0x11
CELL_DECAL_PHASE = 0x12
CELL_DECAL_STATE = 0x13

SPECIAL_DECLARATIONS = DEATH_DECLARATIONS + """\
__cdecl i32 aMakeFire(i32,i32,i32,i32)   = Incubation.exe+0x2f840
__cdecl i32 aMakeMine(i32,i32)           = Incubation.exe+0x2fa70
__cdecl i32 aMakeShield(i32,i32)         = Incubation.exe+0x2fb90
__cdecl i32 aMakeGlow(i32,i32,i32)       = Incubation.exe+0x2fcb0
__cdecl i32 aGroundEffectsTick()         = Incubation.exe+0x2ed60
"""

#: Each phase's calls, as ``(routine, arguments)``.  ``"x"``/``"y"`` name the
#: marine's tile, ``"z"`` its cell's own height and ``"z+"`` a height half a
#: field above it -- the fire placer's window test is the one gate a literal
#: can reach.  The alien's tile is ``"ax"``/``"ay"``.
SPECIAL_CALLS: dict[str, tuple[tuple[str, tuple[Any, ...]], ...]] = {
    # The nine-fire arm's centre: subtype 4, at the cell's own height.
    "special_fire": (("aMakeFire", ("x", "y", 4, "z")),),
    # The same call a full window above the cell -- refused, nothing written.
    "special_fire_out_of_window": (("aMakeFire", ("x", "y", 4, "z+")),),
    # A fire laid on top of a mine deletes the mine's object without firing it.
    "special_fire_over_a_mine": (("aMakeMine", ("x", "y")),
                                 ("aMakeFire", ("x", "y", 3, "z"))),
    "special_mine": (("aMakeMine", ("x", "y")),),
    # Twice: the second call refreshes +0x0E and makes no second object.
    "special_shield": (("aMakeShield", ("x", "y")),
                       ("aMakeShield", ("x", "y"))),
    # A fire refuses a shielded cell outright.
    "special_fire_onto_a_shield": (("aMakeShield", ("x", "y")),
                                   ("aMakeFire", ("x", "y", 4, "z"))),
    "special_glow": (("aMakeGlow", ("x", "y", 2)),),
    # One of everything, then two round ticks.
    "special_tick": (("aMakeFire", ("x", "y", 4, "z")),
                     ("aMakeShield", ("ax", "ay")),
                     ("aMakeGlow", ("x", "y", 2)),
                     ("aGroundEffectsTick", ()),
                     ("aGroundEffectsTick", ())),
}
#: How many cell records each phase reads back around its calls.  The whole
#: control map, so a placer that wrote somewhere unexpected is visible.
SPECIAL_TILE_KEYS = {"x": ("m", "x"), "y": ("m", "y"),
                     "ax": ("a", "x"), "ay": ("a", "y")}
#: The cells whose own object a placer positions around, by tile key.
SPECIAL_TILE_OBJECTS = {"m": "m", "a": "a"}
#: Written before every call, so each one's draws replay on their own.
SPECIAL_SEED = 11.0

#: ``SetGroundFire``'s glow needs ``GLOW1/2.3DI``, which only ``World_D00``
#: carries, so the two phases that reach the glow's own lifecycle run on a
#: **second** save: `_C_116.lev` -- a D00 mission, and one of the two that use
#: the command -- wrapped in `_6_.sav`'s fixed blocks by
#: ``tools/sav_gold.py`` and staged as slot 7.
SPECIAL_D00_SLOT = 7
SPECIAL_D00_WIDTH = 34
SPECIAL_D00_HEIGHT = 40
SPECIAL_D00_WORLD_SET = "D00"
#: The cell `_C_116.lcl` itself sets alight -- `SetGroundFire (12,29,0,1,1,255)`
#: -- and its land object, read out of the shipped `.lev`.
SPECIAL_D00_CELL = (12, 29)
SPECIAL_D00_SYMBOL = 998

#: The phases that run on that save, and the calls they make.
SPECIAL_D00_CALLS: dict[str, tuple[tuple[str, tuple[Any, ...]], ...]] = {
    # The placer the A00 phase measured refusing: here it works.
    "special_glow_d00": (("aMakeGlow", ("gx", "gy", 2)),),
    # And the decay: phase 2 becomes phase 1, a new object in place of the
    # old one, once per round tick.
    "special_glow_tick_d00": (("aMakeGlow", ("gx", "gy", 2)),
                              ("aGroundEffectsTick", ()),
                              ("aGroundEffectsTick", ())),
}


def special_plan(name: str, tiles: dict[str, dict[str, int]]) -> str:
    """One process: load, read the map and the array, call, read them again."""
    d00 = name in SPECIAL_D00_CALLS
    width = SPECIAL_D00_WIDTH if d00 else gold.CAPTURE_WIDTH
    height = SPECIAL_D00_HEIGHT if d00 else gold.CAPTURE_HEIGHT
    slot = SPECIAL_D00_SLOT if d00 else gold.CAPTURE_SLOT
    calls = SPECIAL_D00_CALLS[name] if d00 else SPECIAL_CALLS[name]
    symbols = {"g": SPECIAL_D00_SYMBOL} if d00 else {
        key: tiles[SPECIAL_TILE_OBJECTS[key]]["symbol"]
        for key in SPECIAL_TILE_OBJECTS}
    cells = width * height * gold.CELL_STRIDE
    array = SPECIAL_SLOTS * SPECIAL_RECORD_BYTES

    def resolve(item: Any) -> Any:
        if item == "gx":
            return SPECIAL_D00_CELL[0]
        if item == "gy":
            return SPECIAL_D00_CELL[1]
        if item in SPECIAL_TILE_KEYS:
            key, field = SPECIAL_TILE_KEYS[item]
            return tiles[key][field]
        if item == "z":
            return tiles["m"]["cell_height"]
        if item == "z+":
            return tiles["m"]["cell_height"] + 0x640
        return item

    reads = (f" --read $c0:{cells} --read [0x{SPECIAL_ARRAY:x}]:{array}"
             f" --read 0x{ARANDOM2_SEED:x}:8")
    lines = [f"# {name}: the cell placers of docs/42 section 9.1",
             SPECIAL_DECLARATIONS.rstrip("\n"),
             f"--blob seed:{struct.pack('<d', SPECIAL_SEED).hex()}",
             "aSetSaveMode(0)", f"loaded = aLoadGame({slot})"]
    # The cells' own objects: the origin every placer positions around
    # (`aGetSymbolObjectPtr(cell[+0x05])`, `docs/42` §9.1).
    for key in sorted(symbols):
        lines.append(f"s_{key} = aGetSymbolObjectPtr({symbols[key]})"
                     f" --read $s_{key}:{blob_gold.SYMBOL_RECORD_BYTES}")
    lines.append(f"c0 = aGetCtrlMapElementPtr(0,0){reads}")
    for routine, spec in calls:
        args = ", ".join(str(resolve(item)) for item in spec)
        # The seed is written before **every** call, so each one's draws are
        # replayable on their own rather than only as a chain.
        lines.append(f"memcpy(0x{ARANDOM2_SEED:x}, &seed, 8)"
                     f" --read 0x{ARANDOM2_SEED:x}:8")
        lines.append(f"{routine}({args}){reads}")
    return "\n".join(lines) + "\n"



#: `CrushWall` `0x00415C70`'s **footprint**, `docs/42` §8.2: before it throws a
#: single piece of debris it calls `0x0042F410(wallObject, 1, 0, 1)`, and that
#: is what decides which cells it reaches.  The routine sweeps the whole
#: control map and casts four probes per cell -- `x +/- 200` and `y +/- 200`
#: from `z = 100000`, cast from the cell's **own** symbol object -- against the
#: object; a cell any probe hits has its field type set to the second argument,
#: its height to 0 and its state byte to 2.
#:
#: All **nine** shipped call sites are on `World_A00`'s `Level01d`, in three
#: missions, and every one of them is measured: the mission is wrapped into
#: `_6_.sav`'s fixed blocks and staged as its own slot, and each site gets a
#: process of its own so a plan that dies takes one site with it and not five.
CRUSH_WALL_WIDTH = 30
CRUSH_WALL_HEIGHT = 30
#: `0x00415CE0`'s search box and `0x00415D6D`'s own four arguments.
CRUSH_WALL_BOX = (0x1388, 0x1388, 0x2580)
CRUSH_WALL_MARK = (1, 0, 1)
#: `(mission, save slot, ((x, y), ...))` -- the sites, in script order.
CRUSH_WALL_MISSIONS = (
    ("_C_129", 8, ((16, 18), (16, 20), (18, 23))),
    ("_C_142", 9, ((22, 11),)),
    ("_O_061", 10, ((16, 23), (11, 23), (11, 19), (13, 19), (14, 19))),
)


def crush_wall_sites() -> dict[str, tuple[str, int, int, int]]:
    """Phase name -> ``(mission, slot, x, y)``, one phase per call site."""
    out: dict[str, tuple[str, int, int, int]] = {}
    for mission, slot, cells in CRUSH_WALL_MISSIONS:
        for x, y in cells:
            out[f"crush_wall{mission.lower()}_{x}_{y}"] = (mission, slot, x, y)
    return out


CRUSH_WALL_DECLARATIONS = DEATH_DECLARATIONS + """\
__cdecl ptr aFindNearestObject(i32,i32,i32,i32,i32,i32,ptr)   = Incubation.exe+0x6f20
__cdecl i32 aMarkCellsUnderObject(ptr,i32,i32,i32)            = Incubation.exe+0x2f410
"""


def crush_wall_plan(name: str) -> str:
    """One process: load the mission, find the wall, mark, read the map twice.

    The two calls are `aPlayCrushWallAnimation`'s own first two -- the object
    search of `0x00415D00` and the mark of `0x00415D6D` -- and nothing after
    them, because everything after them renders.  `aDeleteLand` is left out
    for the same reason it is not needed: what is being measured is the
    footprint, not the wall going away.
    """
    _mission, slot, x, y = crush_wall_sites()[name]
    symbol = y * CRUSH_WALL_WIDTH + x
    cells = CRUSH_WALL_WIDTH * CRUSH_WALL_HEIGHT * gold.CELL_STRIDE
    box = ", ".join(str(v) for v in CRUSH_WALL_BOX)
    mark = ", ".join(str(v) for v in CRUSH_WALL_MARK)
    return "\n".join([
        f"# {name}: the footprint of docs/42 section 8.2",
        CRUSH_WALL_DECLARATIONS.rstrip("\n"),
        "--buf near:64",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({slot})",
        f"c0 = aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        # The cell's own symbol object is `cell[+0x05]`, which every shipped
        # map fills row-major from zero -- the same reading
        # `SPECIAL_D00_SYMBOL` is.
        f"s = aGetSymbolObjectPtr({symbol})"
        f" --read $s:{blob_gold.SYMBOL_RECORD_BYTES}",
        f"wall = aFindNearestObject([$s+0x10], [$s+0x14], [$s+0x18],"
        f" {box}, &near)",
        f"aMarkCellsUnderObject($wall, {mark}) --read $c0:{cells}",
    ]) + "\n"


# --------------------------------------------------------------------------
# The special-object table [0x004FA80C] -- docs/20 section 7.4, item 12
# --------------------------------------------------------------------------

#: The table and its count (`docs/10` §6.1-§6.2): `aLoadFile` reads the
#: `.lev`'s 724-byte block 1 to `0x004FA528`, whose `+0x28C` is the count at
#: `0x004FA7B4`, and its 150 x 66-byte block 2 to the buffer `[0x004FA80C]`
#: points at (`0x00407C70`: `0x00404C70(0)` is `[0x004FA80C] + 0 * 66`).
LAND_COUNT = 0x004FA7B4
LAND_TABLE = 0x004FA80C
LAND_SLOTS = 150
LAND_RECORD = 66
LAND_TABLE_BYTES = LAND_SLOTS * LAND_RECORD
#: The record fields the checks compare: position, rotation and both joint
#: triples (`+0x10`..`+0x32`) and the prototype letter and number
#: (`+0x40`, `+0x41`).  `+0x00..+0x0F` are the runtime pointers, the
#: prototype index the fix-up `0x00404D30` re-resolves and its handle.
LAND_POSITION = 0x10
LAND_AUTHORED = (slice(0x10, 0x32), slice(0x40, 0x42))
#: Every mission is wrapped into `_6_.sav`'s fixed blocks and staged as
#: `_{LAND_SLOT_BASE + i}_.sav`, `i` its index among the loadable missions.
LAND_SLOT_BASE = 100
#: Missions per process.  **A second `aLoadGame` in one process can fault**
#: (an `int3`, `0x80000003`, inside the loader's teardown of the previous
#: map -- the game itself never loads twice without leaving the mission
#: first), so the capture keeps what landed before the fault and starts the
#: next process on the mission that faulted.  A mission that faults as the
#: **first** load of a fresh process is a failure of its own and is recorded,
#: not retried.
LAND_CHUNK = 20
LAND_READS = (f" --read 0x{LAND_COUNT:x}:4"
              f" --read [0x{LAND_TABLE:x}]:{LAND_TABLE_BYTES}")
#: `Platform` `0x00412A00` and the box its search `0x00406F20` is asked with
#: around the centre cell's marker (`push 0x1388` x3, `0x00412BE5`); every
#: frame adds `dir * 0x140` to the found record's x or y (`0x00412D00`), for
#: `dist * 10` frames -- `dist * 3200`, one field per tile.
PLATFORM_MISSION = "_C_105"
PLATFORM_CALLS = ((20, 10, 2, 4), (20, 14, 0, 4), (17, 17, 0, 7),
                  (17, 10, 2, 7), (17, 20, 2, 6), (17, 26, 0, 6))
PLATFORM_BOX = (0x1388, 0x1388, 0x1388)
PLATFORM_STEP = {0: (0, -1), 1: (-1, 0), 2: (0, 1), 3: (1, 0)}
#: A seven-tile ride is ninety frames inside one call (`dist * 10` plus the
#: twenty `0x00412F2F` waits); the harness's own 5 s is too short for it.
PLATFORM_CALL_TIMEOUT_MS = 60000
#: `FootBridge (16,18,30,1)` -- `_C_107.lcl:76`, the one shipped call.  The
#: wrapper `0x00442650` passes `(x, y, frames, 0)` once the head count is met;
#: the routine searches `0x00406F20` around the **command cell's** marker
#: (`0x00414C4F`: `cell[+0x05]`, `aGetSymbolObjectPtr`, box 5000 x3) and frees
#: what it found (`aDeleteLand`, `0x00414F49`).
FOOT_BRIDGE_MISSION = "_C_107"
FOOT_BRIDGE_CALL = (16, 18, 30, 0)
FOOT_BRIDGE_BOX = (0x1388, 0x1388, 0x1388)
#: The objects the scripts insert at run time -- `FallingSpores`' spore under
#: a heading from the effect stream (`0x004146D3`), `GroundUnit`'s hole
#: (`0x0041237D`, heading 0) and `GrowingLand`'s growth (`0x00470064`) -- each
#: inserted with `aInsertLandObject` `0x00404E30` at a cell's marker and then
#: swept with `0x0042F410(object, 1, 0, 1)`, the mark `Spores` and `CrushWall`
#: run on the object their search finds.  `_C_174` is the `World_H00`
#: mission that drops the spores; `L110EX00` is in the shared `EX` set.
INSERTED_MISSION = "_C_174"
INSERTED_OBJECTS = (("L016EH00.3DI", (6, 6), 0),
                    ("L016EH00.3DI", (10, 6), 700),
                    ("L016EH00.3DI", (14, 6), 2348),
                    ("L110EX00.3DI", (18, 6), 0),
                    ("L022EH00.3DI", (22, 6), 0))
INSERTED_MARK = (1, 0, 1)
LAND_DECLARATIONS = CRUSH_WALL_DECLARATIONS + """\
__cdecl i32 aPlayPlatformSequence(i32,i32,i32,i32)            = Incubation.exe+0x12a00
__cdecl i32 aPlayFootBridgeSequence(i32,i32,i32,i32)          = Incubation.exe+0x14a70
__cdecl i32 aInsertLandObject(str,i32,i32,i32,i32,i32,i32)    = Incubation.exe+0x4e30
__cdecl ptr aGetSpecialObjectPtr(i32)                         = Incubation.exe+0x4c70
"""
#: The missions whose load faults even as a fresh process's first -- none
#: is expected; a capture that finds one records it and this names it.
LAND_LOAD_FAULTS: tuple[str, ...] = ()
#: The height the platform-height phase writes into every source cell of the
#: first ride (`_C_105`'s own are all 0, as are the destination's): 1600 is
#: ten height levels, a value no cell of either block holds.
PLATFORM_PROBE_HEIGHT = 1600
LAND_PHASES = ("land_table_loads", "land_table_platform",
               "land_table_platform_height", "land_table_footbridge",
               "land_table_inserted")


def land_missions(root: str | Path) -> list[str]:
    """Every shipped mission whose world set the installation carries.

    `_I_001` names `World_Z00`, which the release does not ship; the loader
    has nothing to build it from, so it is the one `.lev` left out.
    """
    return list(_land_missions(str(Path(root).resolve())))


@functools.lru_cache(maxsize=None)
def _land_missions(root: str) -> tuple[str, ...]:
    from inclib import lev as levmod
    base = Path(root)
    out: list[str] = []
    for path in sorted((base / "Missions").glob("*.lev")):
        bm = levmod.parse_lev(path.read_bytes(), str(path))
        if (base / "WorldSet" / f"World_{bm.world_set}").is_dir():
            out.append(path.stem)
    return tuple(out)


def land_slot(root: str | Path, mission: str) -> int:
    return LAND_SLOT_BASE + land_missions(root).index(mission)


def land_map(root: str | Path, mission: str) -> Any:
    from inclib import lev as levmod
    path = Path(root) / "Missions" / f"{mission}.lev"
    return levmod.parse_lev(path.read_bytes(), str(path))


def stage_land_saves(game_copy: Path) -> None:
    """Wrap every loadable mission into `_6_.sav`'s fixed blocks, once."""
    import sav_parse
    save = game_copy / "Work" / "Saves2" / f"_{gold.CAPTURE_SLOT}_.sav"
    for mission in land_missions(game_copy):
        out = game_copy / "Work" / "Saves2" / \
            f"_{land_slot(game_copy, mission)}_.sav"
        if not out.is_file():
            sav_parse.wrap(save, game_copy / "Missions" / f"{mission}.lev", out)


def land_load_plan(root: str | Path, missions: list[str]) -> str:
    """Load missions one after another, the table read after each."""
    lines = ["# land_table_loads: the table as each load leaves it",
             LAND_DECLARATIONS.rstrip("\n"), "aSetSaveMode(0)"]
    for mission in missions:
        lines.append(f"aLoadGame({land_slot(root, mission)}){LAND_READS}")
    return "\n".join(lines) + "\n"


def capture_land_loads(game_copy: Path, dbgcall: Path,
                       phase: dict[str, Any], attempts: int,
                       save: Any) -> None:
    """Run processes until every loadable mission has landed or faulted first.

    *phase* is ``{"rows": [...], "faulted_first": [...]}`` and is extended in
    place; *save* writes the document after every process, so an interrupted
    capture resumes where it stopped.
    """
    rows: list[dict[str, Any]] = phase.setdefault("rows", [])
    faulted: list[str] = phase.setdefault("faulted_first", [])
    by_slot = {land_slot(game_copy, m): m for m in land_missions(game_copy)}
    done = {by_slot.get(int(r["args"][0])) for r in rows
            if r.get("call") == "aLoadGame"}
    pending = [m for m in land_missions(game_copy)
               if m not in done and m not in faulted]
    while pending:
        batch = pending[:LAND_CHUNK]
        name = "pres_land_table_loads"
        try:
            gold.run_plan(game_copy, dbgcall, land_load_plan(game_copy, batch),
                          name, attempts=attempts)
        except gold.CaptureError as err:
            # "some calls failed" still leaves the rows before the fault; an
            # anchor never reached leaves none, and the loop tries again.
            LOG.warning("land_table_loads: %s", err)
        out = game_copy / f"{name}.jsonl"
        # `run_plan` removes the previous attempt's file before each launch,
        # so what is here is this process's.
        got = ([json.loads(line) for line in out.read_text().splitlines()
                if line.strip()] if out.is_file() else [])
        landed = [r for r in got if r.get("call") == "aLoadGame"
                  and r.get("status") == "ok"]
        fault = next((r for r in got if r.get("call") == "aLoadGame"
                      and r.get("status") != "ok"), None)
        if not landed and fault is None:
            LOG.error("land_table_loads: a process landed nothing; stopping "
                      "with %d pending -- re-run to resume", len(pending))
            break
        rows.extend(landed)
        for r in landed:
            pending.remove(by_slot[int(r["args"][0])])
        if fault is not None:
            mission = by_slot[int(fault["args"][0])]
            if mission == batch[0]:
                LOG.error("land_table_loads: %s faults as a first load: %s",
                          mission, fault.get("detail"))
                faulted.append(mission)
                pending.remove(mission)
            else:
                pending.remove(mission)
                pending.insert(0, mission)
        LOG.info("land_table_loads: %d landed, %d pending, %d faulted first",
                 len(rows), len(pending), len(faulted))
        save()


def _symbol_line(name: str, bm: Any, x: int, y: int) -> str:
    return (f"{name} = aGetSymbolObjectPtr({y * bm.width + x})"
            f" --read ${name}:{blob_gold.SYMBOL_RECORD_BYTES}")


def land_platform_plan(root: str | Path) -> str:
    """`_C_105`'s six rides, in script order, the table read after each."""
    bm = land_map(root, PLATFORM_MISSION)
    cells = bm.width * bm.height * gold.CELL_STRIDE
    lines = ["# land_table_platform: does the ride move its table record?",
             LAND_DECLARATIONS.rstrip("\n"), "aSetSaveMode(0)",
             f"loaded = aLoadGame({land_slot(root, PLATFORM_MISSION)})",
             f"c0 = aGetCtrlMapElementPtr(0,0) --read $c0:{cells}{LAND_READS}"]
    for i, (x, y, _d, _n) in enumerate(PLATFORM_CALLS):
        lines.append(_symbol_line(f"s{i}", bm, x, y))
    for x, y, d, n in PLATFORM_CALLS:
        lines.append(f"aPlayPlatformSequence({x}, {y}, {d}, {n})"
                     f" --read $c0:{cells}{LAND_READS}")
    return "\n".join(lines) + "\n"


def land_platform_height_plan(root: str | Path) -> str:
    """The first ride again, its source block first raised to 1600.

    `docs/20` §7.4 step 4 said the ride copies "object/height/type"; the
    copy loop at `0x00413011` moves `+0x0D`, `+0x0E`, `+0x0F` and `+0x10`
    and nothing at `+0x01`.  Every cell of both `_C_105` blocks is at 0, so
    `land_table_platform` cannot tell the two readings apart; this can.
    """
    bm = land_map(root, PLATFORM_MISSION)
    cells = bm.width * bm.height * gold.CELL_STRIDE
    x, y, d, n = PLATFORM_CALLS[0]
    lines = ["# land_table_platform_height: is the height carried?",
             LAND_DECLARATIONS.rstrip("\n"),
             f"--blob h:{struct.pack('<i', PLATFORM_PROBE_HEIGHT).hex()}",
             "aSetSaveMode(0)",
             f"loaded = aLoadGame({land_slot(root, PLATFORM_MISSION)})",
             "c0 = aGetCtrlMapElementPtr(0,0)"]
    for ox in (-1, 0, 1):
        for oy in (-1, 0, 1):
            index = (y + oy) * bm.width + x + ox
            lines.append(f"memcpy($c0+0x{index * gold.CELL_STRIDE + CELL_HEIGHT:x},"
                         f" &h, 4)")
    lines += [f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
              f"aPlayPlatformSequence({x}, {y}, {d}, {n})"
              f" --read $c0:{cells}{LAND_READS}"]
    return "\n".join(lines) + "\n"


def land_footbridge_plan(root: str | Path) -> str:
    """`_C_107`'s `FootBridge`, the command cell's marker read first."""
    bm = land_map(root, FOOT_BRIDGE_MISSION)
    cells = bm.width * bm.height * gold.CELL_STRIDE
    x, y = FOOT_BRIDGE_CALL[:2]
    args = ", ".join(str(v) for v in FOOT_BRIDGE_CALL)
    return "\n".join([
        "# land_table_footbridge: which record does the collapse free?",
        LAND_DECLARATIONS.rstrip("\n"), "aSetSaveMode(0)",
        f"loaded = aLoadGame({land_slot(root, FOOT_BRIDGE_MISSION)})",
        f"c0 = aGetCtrlMapElementPtr(0,0) --read $c0:{cells}{LAND_READS}",
        _symbol_line("s", bm, x, y),
        f"aPlayFootBridgeSequence({args}) --read $c0:{cells}{LAND_READS}",
    ]) + "\n"


def land_inserted_plan(root: str | Path) -> str:
    """Insert each run-time object at a marker and sweep its footprint."""
    bm = land_map(root, INSERTED_MISSION)
    cells = bm.width * bm.height * gold.CELL_STRIDE
    mark = ", ".join(str(v) for v in INSERTED_MARK)
    lines = ["# land_table_inserted: the footprint of a run-time object",
             LAND_DECLARATIONS.rstrip("\n"), "aSetSaveMode(0)",
             f"loaded = aLoadGame({land_slot(root, INSERTED_MISSION)})",
             f"c0 = aGetCtrlMapElementPtr(0,0) --read $c0:{cells}{LAND_READS}"]
    for i, (model, (x, y), heading) in enumerate(INSERTED_OBJECTS):
        lines += [
            _symbol_line(f"s{i}", bm, x, y),
            f'aInsertLandObject("{model}", [$s{i}+0x10], [$s{i}+0x14],'
            f" [$s{i}+0x18], 0, 0, {heading}){LAND_READS}",
            # The record just appended: `0x00404C70(count - 1)`, the count
            # being the `.lev`'s own plus the inserts so far.
            f"r{i} = aGetSpecialObjectPtr({len(bm.special) + i})"
            f" --read $r{i}:{LAND_RECORD}",
            f"aMarkCellsUnderObject($r{i}, {mark}) --read $c0:{cells}",
        ]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# The jump scream's draw -- docs/42 §7.1, docs/97 §31.8
# --------------------------------------------------------------------------

#: `aPlayJumpAnimaion`'s computer arm: `push 3; push 0; call aRandom2; add
#: esp, 8; call _ftol` at `0x0041193F`, then the ladder at `0x00411950` --
#: `sub eax, 0; je S_ALI_0; dec eax; je S_ALI_1; dec eax; jne <no scream>`
#: with the third arm falling through to `S_ALI_2`.  What the phase measures
#: is the draw itself: the uncounted stream's live seed, three hundred
#: `aRandom2(0, 3)` values as the x87 returned them, and the seed after each.
#: The mapping from the truncated draw to the wave is the bytes below, which
#: the check reads out of the executable; what a player would *hear* is not
#: capturable from a shell with no audio path, and the draw plus the ladder
#: is the whole of the claim.
SCREAM_DRAWS = 300
SCREAM_DRAW_SITE = 0x0041193F
SCREAM_DRAW_BYTES = bytes.fromhex("6a036a00e8981f050083c408e866ce0900")
SCREAM_LADDER = 0x00411950
SCREAM_LADDER_BYTES = bytes.fromhex("83e8000f8416010000480f848b000000480f8542feffff")
#: Draw value -> (`push <volume id>` site, wave name, volume id).  The wave
#: name push sits ten bytes after the id push in all three arms.
SCREAM_ARMS = {0: (0x00411A6F, "S_ALI_0.wav", 59),
               1: (0x004119EB, "S_ALI_1.wav", 60),
               2: (0x00411967, "S_ALI_2.wav", 61)}
SCREAM_NAME_PUSH_OFFSET = 0x0A
#: Where a draw of three or more would go: `0x004117A9`, the join the
#: player's arm reaches after its landing dust (`0x004117A1`) -- the head of
#: the flight loop (`mov eax, [esp+0x30]; test eax, eax; jle`), with no wave
#: loaded.  Unreachable, because the seed is kept below the modulus and
#: `3 * seed / modulus < 3`.
SCREAM_NO_ARM = 0x004117A9
#: `dbgcall` prints `st0` to six significant digits; the seed read after
#: each draw is the exact comparison, the value a rounded one.
SCREAM_TOLERANCE = 1e-5

SCREAM_DECLARATIONS = """\
__cdecl void aSetSaveMode(i32)              = Incubation.exe+0x48770
__cdecl f64  aRandom2(i32,i32)              = Incubation.exe+0x638e0
"""


def jump_scream_plan() -> str:
    """The live seed, then three hundred draws of `aRandom2(0, 3)`."""
    lines = [
        "# jump_scream: the draw behind the alien's jump scream.  No mission",
        "# is loaded -- the generator is its seed, which `main` set from",
        "# GetTickCount before the anchor (0x00449919), and nothing else.",
        SCREAM_DECLARATIONS.rstrip("\n"),
        f"aSetSaveMode(0) --read 0x{ARANDOM2_SEED:x}:8",
    ]
    lines += [f"draw = aRandom2(0,3) --read 0x{ARANDOM2_SEED:x}:8"] * SCREAM_DRAWS
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# The frame limiter -- docs/40 §4.8, docs/101 §13.7
# --------------------------------------------------------------------------

#: `aWinTools.cpp`'s skip controller `0x0047F2E0(minFps, maxFps)`, which the
#: gameplay frame routine `0x0040B6F0` calls as `(10, 20)` -- the clock the
#: upgrade base's march and every in-mission walk run on.  Its four globals:
#: the two rates, the tick it last read, the epoch it measures from, the
#: dead skip flag and the waited flag.  What the phase measures is the
#: epoch rule `docs/40` §4.8 read and called "roughly twice": the epoch is
#: written only on the branch that does **not** wait, so the wait lands on
#: every other call and the ceiling is two frames per `1000 / maxFps`
#: milliseconds plus whatever the frame itself costs.
LIMITER = 0x0047F2E0
LIMITER_MIN_FPS = 10
LIMITER_MAX_FPS = 20
LIMITER_CALLS = 60
LIMITER_TICK = 0x00522EE4
LIMITER_EPOCH = 0x00522EE8
LIMITER_WAITED = 0x00522EF0
#: The frame routine's own call site: `push 20; push 10; call 0x0047F2E0`.
LIMITER_FRAME_SITE = 0x0040B82D
LIMITER_FRAME_BYTES = bytes.fromhex("6a146a0ae8aa3a0700")
#: The epoch write is on the no-wait branch alone: `mov [0x522ee8], edi` at
#: `0x0047F390`, reached by both `jae` and by nothing after the wait loop.
LIMITER_EPOCH_WRITE = 0x0047F390
LIMITER_EPOCH_WRITE_BYTES = bytes.fromhex("893de82e5200")
#: The imported `GetTickCount`, through its IAT slot as `MEMCPY_DECL` does.
TICK_SLOT = 0x00525588

LIMITER_DECLARATIONS = f"""\
__stdcall u32 GetTickCount()                = [{TICK_SLOT:#x}]
__cdecl void aSkipController(i32,i32)       = Incubation.exe+0x{LIMITER - 0x400000:x}
"""


def frame_limiter_plan() -> str:
    """Sixty limiter calls at the frame routine's rates, the globals after each."""
    reads = (f" --read 0x{LIMITER_TICK:x}:4 --read 0x{LIMITER_EPOCH:x}:4"
             f" --read 0x{LIMITER_WAITED:x}:4")
    lines = [
        "# frame_limiter: the skip controller's epoch rule.  Between two",
        "# calls the frame costs only the harness's own round trip, so what",
        "# is measured is the ceiling, not a rendered frame rate.",
        LIMITER_DECLARATIONS.rstrip("\n"),
        "before = GetTickCount()",
    ]
    lines += [f"aSkipController({LIMITER_MIN_FPS},{LIMITER_MAX_FPS}){reads}"] * LIMITER_CALLS
    lines.append("after = GetTickCount()")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# The body aim -- docs/22 §7.1 step 5, docs/40 §6.3
# --------------------------------------------------------------------------

#: `aAttackUnit`'s lower-body aim `0x0042CD80(model, String *name, tx, ty,
#: tz)`, cdecl (`add esp, 0x14` at `0x0046B89F`), called with the literal
#: `"Unterkoerper"` at `0x004CC660`.  It returns the `ExternalRotationMovement`
#: it installed (`0x00495C99`, priority `0x65`), whose matrix is at `+0x44`
#: (`0x00495A53`); `0x004960F5(model, movement)` is the release at
#: `0x0046C1C7`.
AIM = 0x0042CD80
AIM_RELEASE = 0x004960F5
AIM_PART_NAME = 0x004CC660
AIM_MOVEMENT_BYTES = 0x90
AIM_MOVEMENT_MATRIX = 0x44
#: `BB::String::String(const char *, int)`, through its IAT slot.
STRING_CTOR_SLOT = 0x00525714
#: `StdPart::GetWorldMatrix` `0x0049DB84`, whose `this` is the part's
#: `StdPart` base at `+0xDC`: the bind matrix at `this - 0xAC` (`+0x30`),
#: the current local at `this - 0x6C` (`+0x70`), the parent at `this - 0xB4`
#: (`+0x28`) -- a pointer to the parent's `+0x160` interface.
GET_WORLD = 0x0049DB84
PART_STDPART = 0xDC
PART_PARENT = 0x28
PART_BIND = 0x30
PART_LOCAL = 0x70
PART_PARENT_INTERFACE = 0x160
#: The rotation slot of `V100Part::Update` (`0x004A6807`): channel 1.
ROTATION_CHANNEL = 1
#: `V100Model`'s placement: `0x0049E4B8` (vtable `0x004B21A4` slot 0, reached
#: from `0x0042CD80` as `[[model + 4 + vbase] + 0]`) copies it from `+0x34`.
MODEL_PLACEMENT = 0x34
V100_MODEL_BYTES = 0xE0
#: `fcn.004055E0(slot, unit, kind)`: kind 1 is the `F` clip at speed 6.0,
#: slot 3 the one `aPlayFightAnimation` uses (`0x0040BE88`).
START_ANIMATION = 0x004055E0
FIGHT_SLOT = 3
FIGHT_KIND = 1
FIGHT_STEPS = 6
#: The constants the aim reads (`0x0042CF7B` .. `0x0042CFB4`): pi, the two
#: angles and 1/180, and the world-to-Charisma scale 1/16 (`0x0042CF09`).
AIM_PI = 0x004B1320
AIM_ANGLE_X = 0x004B1370
AIM_ANGLE_Y = 0x004B1378
AIM_DEGREE = 0x004B1358
AIM_SCALE = 0x004B1334


class BodyAimCase(NamedTuple):
    """One unit of one save to aim, and where its object stands."""
    save_slot: int
    unit_slot: int
    object_id: int
    origin: tuple[int, int, int]
    forward: tuple[int, int]


#: `_6_.sav` carries one class-1 body, Sgt. Bratt (type 23, facing 6);
#: `_0_.sav` (`_C_140`) adds a marine, Rock (type 0, facing 0).  The origin
#: is the object record's `+0x10` triple, which the check re-reads.
BODY_AIM_CASES = {
    "body_aim": BodyAimCase(6, 3, 3, (6400, 0, 160), (11314, 11314)),
    "body_aim_marine": BodyAimCase(0, 3, 3, (57600, 6400, 160), (0, 16000)),
}
#: Each target as an offset from the object, `"forward"` standing for the
#: body's own forward (docs/40 §5.4's step for its facing) at 16000 units.
AIM_TARGETS: tuple[tuple[str, tuple[Any, Any, int]], ...] = (
    ("level_forward", ("forward", None, 0)),
    ("level_east", (16000, 0, 0)),
    ("above_east", (16000, 0, 9600)),
    ("below_east", (16000, 0, -9600)),
    ("above_north", (0, 16000, 9600)),
    ("above_west", (-16000, 0, 9600)),
    ("above_southwest", (-11314, -11314, 9600)),
    ("above_forward", ("forward", None, 9600)),
    ("overhead", (160, 0, 32000)),
)
#: The target the fight-clip run aims at before the clip starts.
AIM_CLIP_TARGET = "above_forward"

BODY_AIM_DECLARATIONS = DECLARATIONS + f"""\
{blob_gold.MEMCPY_DECL}
__thiscall ptr StringNew(ptr,ptr,i32)       = [{STRING_CTOR_SLOT:#x}]
__cdecl ptr  aAimBody(ptr,ptr,i32,i32,i32)  = Incubation.exe+0x{AIM - 0x400000:x}
__cdecl void aReleaseAim(ptr,ptr)           = Incubation.exe+0x{AIM_RELEASE - 0x400000:x}
__thiscall ptr GetWorldMatrix(ptr,ptr)      = Incubation.exe+0x{GET_WORLD - 0x400000:x}
__cdecl i32  aStartAnimation(i32,ptr,i32)   = Incubation.exe+0x{START_ANIMATION - 0x400000:x}
"""


def aim_target(case: BodyAimCase, spec: tuple[Any, Any, int]) -> tuple[int, int, int]:
    """A target's absolute engine position for *case*."""
    ox, oy, oz = case.origin
    dx, dy, dz = spec
    if dx == "forward":
        dx, dy = case.forward
    return ox + dx, oy + dy, oz + dz


def body_aim_plan(name: str) -> str:
    """Aim the case's body at every target, reading what the aim wrote.

    Per target: the aim, the part it attached to and that part's parent,
    both world matrices before any update (so the first is the unaimed
    control), one `Simulate`, the part again, then the release.  After the
    last, one more step shows the bind rotation back.  Then the aim once more
    with the fight clip started over it, stepped `FIGHT_STEPS` times.
    """
    case = BODY_AIM_CASES[name]
    def world(part: str, buf: str) -> str:
        return f"GetWorldMatrix(${part}+0x{PART_STDPART:x}, &{buf}) --dump {buf}"

    buffers = ["--buf name:8"]
    lines = [
        f"# {name}: 0x0042CD80 on unit {case.unit_slot} of save {case.save_slot}.",
        BODY_AIM_DECLARATIONS.rstrip("\n"),
    ]
    body = [
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({case.save_slot})",
        f"u = aGetUnitMapElementPtr({case.unit_slot}) --read $u:{UNIT_STRIDE}",
        f"o = aGetObjectRecord({case.object_id}) --read $o:{OBJECT_STRIDE}",
        f"m = memcpy([$o+0x{OBJECT_MODEL:x}], [$o+0x{OBJECT_MODEL:x}], 0)"
        f" --read $m:0x{V100_MODEL_BYTES:x}",
        f"s = StringNew(&name, 0x{AIM_PART_NAME:x}, 1) --dump name",
    ]

    def aim(k: int, target: tuple[int, int, int]) -> list[str]:
        tx, ty, tz = target
        return [
            f"a{k} = aAimBody($m, &name, {tx}, {ty}, {tz}) --read $a{k}:0x{AIM_MOVEMENT_BYTES:x}",
            f"p{k} = memcpy([$a{k}+0x{MOVEMENT_CHANNEL:x}]-0x{PART_CHANNEL_INTERFACE:x},"
            f" [$a{k}+0x{MOVEMENT_CHANNEL:x}]-0x{PART_CHANNEL_INTERFACE:x}, 0)"
            f" --read $p{k}:0x{PART_STRIDE:x}",
            f"q{k} = memcpy([$p{k}+0x{PART_PARENT:x}]-0x{PART_PARENT_INTERFACE:x},"
            f" [$p{k}+0x{PART_PARENT:x}]-0x{PART_PARENT_INTERFACE:x}, 0)"
            f" --read $q{k}:0x{PART_STRIDE:x}",
        ]

    for k, (_label, spec) in enumerate(AIM_TARGETS):
        buffers += [f"--buf pre{k}:64", f"--buf par{k}:64", f"--buf post{k}:64"]
        body += aim(k, aim_target(case, spec))
        body += [world(f"p{k}", f"pre{k}"), world(f"q{k}", f"par{k}"), SIMULATE,
                 world(f"p{k}", f"post{k}") + f" --read $p{k}:0x{PART_STRIDE:x}",
                 f"aReleaseAim($m, $a{k})"]
    buffers.append("--buf bind:64")
    body += [SIMULATE, world("p0", "bind") + f" --read $p0:0x{PART_STRIDE:x}"]
    k = len(AIM_TARGETS)
    spec = dict(AIM_TARGETS)[AIM_CLIP_TARGET]
    body += aim(k, aim_target(case, spec))
    body.append(f"f = aStartAnimation({FIGHT_SLOT}, $u, {FIGHT_KIND})")
    for j in range(FIGHT_STEPS):
        buffers += [f"--buf clip{j}:64", f"--buf clippar{j}:64"]
        body += [SIMULATE, world(f"p{k}", f"clip{j}") + f" --read $p{k}:0x{PART_STRIDE:x}",
                 world(f"q{k}", f"clippar{j}")]
    body += [f"aReleaseAim($m, $a{k})", f"freed = aFreeCHAnimation({FIGHT_SLOT})"]
    return "\n".join(lines + buffers + body) + "\n"


PLAN_NAMES = ("idle_random", "idle_pose", "jump_scream", "frame_limiter",
              "deaths_state") + tuple(
    "death_" + name for name, _c, _a, _s in DEATH_CALLS) \
    + tuple(SPECIAL_CALLS) + tuple(SPECIAL_D00_CALLS) \
    + tuple(crush_wall_sites()) + LAND_PHASES + tuple(BODY_AIM_CASES)


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
    # A present-but-null name is the selector's own "no clip" (docs/40
    # section 7.2.1), which the starter answers by returning 1.
    if not outcomes or outcomes[0].name is None:
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


def check_scream(ck: Checker, root: str, rows: list[dict[str, Any]]) -> None:
    """The jump scream's draw, replayed from the live seed."""
    ck.pin("scream.rows_all_ok", all(r.get("status") == "ok" for r in rows),
           str([r for r in rows if r.get("status") != "ok"][:3]))
    draws = [r for r in rows if r.get("call") == "aRandom2"]
    ck.pin("scream.draw_count", len(draws) == SCREAM_DRAWS, str(len(draws)))
    seed = seed_of(rows[0]) if rows else None
    ck.pin("scream.seed_read", seed is not None, "no seed read")
    if seed is None or not draws:
        return
    # `main` seeds the stream from GetTickCount, so a zero here would be the
    # generator's fixed point and every draw a faithful zero.
    ck.pin("scream.seed_nonzero_and_below_modulus",
           0.0 < seed < ARandom.MODULUS and seed == int(seed), str(seed))
    model = ARandom(seed)
    values: list[float] = []
    mismatched: list[str] = []
    for row in draws:
        predicted = model.raw(0, 3)
        got = row.get("st0")
        after = seed_of(row)
        if not isinstance(got, (int, float)) or after is None:
            mismatched.append(f"{row.get('i')}: no st0 or seed")
            continue
        if abs(float(got) - predicted) > SCREAM_TOLERANCE or after != model.seed:
            mismatched.append(f"{row.get('i')}: {got} vs {predicted}, "
                              f"seed {after} vs {model.seed}")
        values.append(float(got))
    ck.pin("scream.model_reproduces_every_draw", not mismatched, str(mismatched[:3]))
    truncated = [int(v) for v in values]
    ck.pin("scream.every_draw_below_3", all(0.0 <= v < 3.0 for v in values),
           str([v for v in values if not 0.0 <= v < 3.0][:3]))
    ck.pin("scream.all_three_arms_drawn", set(truncated) == {0, 1, 2},
           str(sorted(set(truncated))))
    counts = {k: truncated.count(k) for k in (0, 1, 2)}
    # Three hundred draws of a uniform third: each arm well clear of zero.
    ck.pin("scream.arms_roughly_even", all(c >= SCREAM_DRAWS // 6 for c in counts.values()),
           str(counts))
    pe = PEFile(str(Path(root) / "Incubation.exe"))
    ck.pin("scream.draw_site_is_aRandom2_0_3_then_ftol",
           pe.bytes_at(SCREAM_DRAW_SITE, len(SCREAM_DRAW_BYTES)) == SCREAM_DRAW_BYTES,
           pe.bytes_at(SCREAM_DRAW_SITE, len(SCREAM_DRAW_BYTES)).hex())
    ck.pin("scream.ladder_bytes",
           pe.bytes_at(SCREAM_LADDER, len(SCREAM_LADDER_BYTES)) == SCREAM_LADDER_BYTES,
           pe.bytes_at(SCREAM_LADDER, len(SCREAM_LADDER_BYTES)).hex())
    # The ladder's three targets, decoded from the displacements rather than
    # trusted: `je rel32` at +3, `je rel32` at +10, `jne rel32` at +17.
    ladder = pe.bytes_at(SCREAM_LADDER, len(SCREAM_LADDER_BYTES))
    je0 = SCREAM_LADDER + 9 + struct.unpack_from("<i", ladder, 5)[0]
    je1 = SCREAM_LADDER + 16 + struct.unpack_from("<i", ladder, 12)[0]
    jne = SCREAM_LADDER + 23 + struct.unpack_from("<i", ladder, 19)[0]
    fall = SCREAM_LADDER + len(SCREAM_LADDER_BYTES)
    ck.pin("scream.ladder_targets",
           (je0, je1, fall, jne) == (SCREAM_ARMS[0][0], SCREAM_ARMS[1][0],
                                      SCREAM_ARMS[2][0], SCREAM_NO_ARM),
           f"{je0:#x} {je1:#x} {fall:#x} {jne:#x}")
    for value, (site, name, volume) in SCREAM_ARMS.items():
        push = pe.bytes_at(site, 2)
        ck.pin(f"scream.arm_{value}_volume_id", push == bytes((0x6A, volume)), push.hex())
        name_push = pe.bytes_at(site + SCREAM_NAME_PUSH_OFFSET, 5)
        text = pe.cstring(struct.unpack_from("<I", name_push, 1)[0]) \
            if name_push[0] == 0x68 else None
        ck.pin(f"scream.arm_{value}_wave", text == name, str(text))


def _dword_read(row: dict[str, Any], address: int) -> int | None:
    raw = _reads(row).get(f"0x{address:x}")
    return None if raw is None or len(raw) != 4 else struct.unpack("<I", raw)[0]


def limiter_trace(rows: list[dict[str, Any]]) -> list[tuple[int, int, int]]:
    """`(tick, epoch, waited)` after each limiter call, in order."""
    out: list[tuple[int, int, int]] = []
    for row in rows:
        if row.get("call") != "aSkipController":
            continue
        tick = _dword_read(row, LIMITER_TICK)
        epoch = _dword_read(row, LIMITER_EPOCH)
        waited = _dword_read(row, LIMITER_WAITED)
        if tick is None or epoch is None or waited is None:
            continue
        out.append((tick, epoch, waited))
    return out


def _mat(raw: bytes, offset: int = 0) -> list[float]:
    """Sixteen floats, row-major and applied as `M * v` (docs/40 §5.1)."""
    return list(struct.unpack_from("<16f", raw, offset))


def _rotation(m: list[float]) -> list[float]:
    """*m* with its translation column cleared -- `0x004828C1`."""
    return charisma.mat_with_translation(m, (0.0, 0.0, 0.0))


def _inverse_rotation(m: list[float]) -> list[float]:
    """The inverse of a translation-free affine matrix -- `0x00482B36`.

    A general 3x3 inverse by cofactors, not a transpose: bone matrices carry
    scale (docs/40 §5.1).
    """
    a, b, c, d, e, f, g, h, i = m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    cof = ((e * i - f * h), -(b * i - c * h), (b * f - c * e),
           -(d * i - f * g), (a * i - c * g), -(a * f - c * d),
           (d * h - e * g), -(a * h - b * g), (a * e - b * d))
    out = charisma.mat_identity()
    for r in range(3):
        for col in range(3):
            out[r * 4 + col] = cof[r * 3 + col] / det
    return out


def _normalised(v: tuple[float, float, float]) -> tuple[float, float, float]:
    """`0x0048262C`: a zero vector becomes `(1, 0, 0)`."""
    n = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) ** 0.5
    return (1.0, 0.0, 0.0) if n == 0.0 else (v[0] / n, v[1] / n, v[2] / n)


def _cross(a: tuple[float, ...], b: tuple[float, ...]) -> tuple[float, float, float]:
    """`0x00482695`."""
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _axis_rotation(axis: int, degrees: float) -> list[float]:
    """`Rx` (`0x00482920`) or `Ry` (`0x00482991`), post-multiplied."""
    c, s = math.cos(math.radians(degrees)), math.sin(math.radians(degrees))
    out = charisma.mat_identity()
    if axis == 0:
        out[5], out[6], out[9], out[10] = c, -s, s, c
    else:
        out[0], out[2], out[8], out[10] = c, s, -s, c
    return out


def aim_matrices(placement: list[float], parent_world: list[float], local: list[float],
                 target: tuple[int, int, int], angle_x: float, angle_y: float,
                 scale: float) -> tuple[list[float], list[float]]:
    """`0x0042CD80`'s arithmetic: `(matrix it writes, world rotation it means)`.

    *placement* is the model's (`+0x34`), *parent_world* the aimed part's
    parent's Charisma-space world matrix, *local* the aimed part's current
    local matrix.  The pivot is `placement * parent_world * T(local)`; the
    look-at `0x0042CBA0` writes the columns `side = d x z`, `d`, `up = side x
    d`; the matrix written is that frame taken back into the parent.
    """
    pivot = charisma.mat_translation(charisma.mat_mul(
        charisma.mat_mul(placement, parent_world),
        charisma.mat_with_translation(charisma.mat_identity(),
                                      charisma.mat_translation(local))))
    aim = tuple(float(t) * scale for t in target)
    d = _normalised((aim[0] - pivot[0], aim[1] - pivot[1], aim[2] - pivot[2]))
    side = _normalised(_cross(d, (0.0, 0.0, 1.0)))
    up = _normalised(_cross(side, d))
    frame = charisma.mat_identity()
    for column, v in enumerate((side, d, up)):
        frame[column], frame[4 + column], frame[8 + column] = v
    world = charisma.mat_mul(charisma.mat_mul(frame, _axis_rotation(0, angle_x)),
                             _axis_rotation(1, angle_y))
    written = charisma.mat_mul(_inverse_rotation(_rotation(parent_world)),
                               charisma.mat_mul(_inverse_rotation(_rotation(placement)),
                                                world))
    return written, world


def _max_diff(a: list[float], b: list[float]) -> float:
    return max(abs(x - y) for x, y in zip(a, b))


def _angle_between(a: list[float], b: list[float]) -> float:
    """Degrees between two rotation matrices' 3x3 parts."""
    trace = sum(a[r * 4 + k] * b[r * 4 + k] for r in range(3) for k in range(3))
    return math.degrees(math.acos(max(-1.0, min(1.0, (trace - 1.0) / 2.0))))


#: The tolerance the replay is held to: the engine computes in x87 and stores
#: `float`; 1e-5 is two orders above the largest difference measured.
AIM_TOLERANCE = 1e-5
#: The named part and the one the movement actually lands on (docs/22 §7.1).
AIM_NAMED_PART = "Unterkoerper"
#: Measured: the aimed spine against its unaimed bind for the level target
#: straight ahead, on both bodies -- a quarter-turn-sized correction it is
#: not; see docs/22 §7.1 step 5.
AIM_LEVEL_FORWARD_DEGREES = 35.8
AIM_LEVEL_FORWARD_SLACK = 0.5
#: Call-site bytes the phase leans on: the priority push, and the literal's
#: push at both `aAttackUnit` sites.
AIM_PRIORITY_SITE = 0x0042CE0A
AIM_PRIORITY_BYTES = bytes.fromhex("6a65")
AIM_NAME_SITES = (0x0046B85A, 0x0046B8EE)


def _aim_inputs(rows: list[dict[str, Any]], k: int
                ) -> tuple[list[float], list[float], bytes, bytes]:
    """Target *k*'s capture: `(written, parent_world, part_pre, part_post)`."""
    written = _mat(_reads_named(rows, f"$a{k}")[0], AIM_MOVEMENT_MATRIX)
    part_pre, part_post = _reads_named(rows, f"$p{k}")[:2]
    parent_world = _mat(_reads_named(rows, f"par{k}")[0])
    return written, parent_world, part_pre, part_post


def _reads_named(rows: list[dict[str, Any]], key: str) -> list[bytes]:
    return [_hex_bytes(v) for row in rows for k, v in (row.get("reads") or {}).items()
            if k == key]


def check_body_aim(ck: Checker, root: str, phases: dict[str, Any]) -> None:
    pe = PEFile(str(Path(root) / "Incubation.exe"))
    angle_x = pe.f64(AIM_ANGLE_X)
    angle_y = pe.f64(AIM_ANGLE_Y)
    scale = struct.unpack("<f", pe.bytes_at(AIM_SCALE, 4))[0]
    ck.pin("aim.constants", (angle_x, angle_y, scale) == (-15.5, -90.0, 0.0625)
           and abs(pe.f64(AIM_PI) - 3.1415926535) < 1e-12
           and abs(pe.f64(AIM_DEGREE) - 1 / 180) < 1e-15,
           str((angle_x, angle_y, scale)))
    ck.pin("aim.priority_push", pe.bytes_at(AIM_PRIORITY_SITE, 2) == AIM_PRIORITY_BYTES,
           pe.bytes_at(AIM_PRIORITY_SITE, 2).hex())
    ck.pin("aim.name_literal",
           pe.cstring(AIM_PART_NAME) == AIM_NAMED_PART
           and all(pe.bytes_at(site, 5) == b"\x68" + struct.pack("<I", AIM_PART_NAME)
                   for site in AIM_NAME_SITES), pe.cstring(AIM_PART_NAME))
    replayed = 0
    for name, case in BODY_AIM_CASES.items():
        rows = (phases.get(name) or {}).get("rows")
        ck.pin(f"{name}.captured", bool(rows), "phase missing -- re-take it")
        if not rows:
            continue
        ck.pin(f"{name}.rows_all_ok", all(r.get("status") == "ok" for r in rows),
               str([r for r in rows if r.get("status") != "ok"][:3]))
        unit = _reads_named(rows, "$u")[0]
        obj = _reads_named(rows, "$o")[0]
        ck.pin(f"{name}.origin", struct.unpack_from("<3i", obj, 0x10) == case.origin,
               str(struct.unpack_from("<3i", obj, 0x10)))
        placement = _mat(_reads_named(rows, "$m")[0], MODEL_PLACEMENT)
        key = SelectorKey(unit[UNIT_TYPE], unit[UNIT_WEAPON], unit[UNIT_PLAYER])
        tables = SelectorTables(pe, [key])
        model_name = tables.lookup("model", key)[0].name
        nodes = charisma.parse_model_file(
            str(Path(root) / "CHData" / "Objects" / f"{model_name}.cho")).skeleton.nodes
        named = next(n for n in nodes if n.name == AIM_NAMED_PART)
        aimed = next(n for n in nodes if n.name == named.parent)
        grand = next(n for n in nodes if n.name == aimed.parent)

        def node_of(part: bytes) -> str | None:
            bind = _mat(part, PART_BIND)
            hits = [n.name for n in nodes if _max_diff(list(n.matrix), bind) < 1e-6]
            return hits[0] if len(hits) == 1 else None

        movements = [int(r["eax"], 16) for r in rows if r.get("call") == "aAimBody"]
        n = len(AIM_TARGETS)
        lands, parent_ok, channel, replay, local_rot, kept, world_ok = ([] for _ in range(7))
        for k, (label, spec) in enumerate(AIM_TARGETS):
            movement = _reads_named(rows, f"$a{k}")[0]
            written, parent_world, part_pre, part_post = _aim_inputs(rows, k)
            parent = _reads_named(rows, f"$q{k}")[0]
            post_world = _mat(_reads_named(rows, f"post{k}")[0])
            lands.append(node_of(part_pre) == aimed.name)
            parent_ok.append(node_of(parent) == grand.name)
            channel.append(struct.unpack_from("<I", movement, MOVEMENT_CHANNEL_INDEX)[0]
                           == ROTATION_CHANNEL and struct.unpack_from(
                               "<I", part_post, PART_CHANNELS + 4 * ROTATION_CHANNEL)[0]
                           == movements[k])
            predicted, world = aim_matrices(placement, parent_world, _mat(part_pre, PART_LOCAL),
                                            aim_target(case, spec), angle_x, angle_y, scale)
            replay.append(_max_diff(predicted, written) < AIM_TOLERANCE)
            local = _mat(part_post, PART_LOCAL)
            local_rot.append(_rotation(local) == _rotation(written))
            kept.append(charisma.mat_translation(local)
                        == charisma.mat_translation(_mat(part_pre, PART_LOCAL)))
            world_ok.append(_max_diff(_rotation(charisma.mat_mul(placement, post_world)),
                                      world) < AIM_TOLERANCE)
            if label == "level_forward":
                unaimed = charisma.mat_mul(parent_world, _mat(part_pre, PART_BIND))
                ck.pin(f"{name}.control_is_bind",
                       _max_diff(unaimed, _mat(_reads_named(rows, f"pre{k}")[0]))
                       < AIM_TOLERANCE, "pre-update world is not parent * bind")
                degrees = _angle_between(_rotation(charisma.mat_mul(placement, unaimed)), world)
                ck.pin(f"{name}.level_forward_off_bind",
                       abs(degrees - AIM_LEVEL_FORWARD_DEGREES) < AIM_LEVEL_FORWARD_SLACK,
                       f"{degrees:.2f} degrees")
        for label, flags in (("lands_on_parent_of_named_part", lands),
                             ("parent_world_is_its_parent", parent_ok),
                             ("rotation_channel", channel),
                             ("replay_matches", replay),
                             ("local_rotation_is_written_matrix", local_rot),
                             ("translation_kept", kept),
                             ("world_rotation_is_aim", world_ok)):
            ck.pin(f"{name}.{label}", all(flags), f"{sum(flags)}/{n}")
        replayed += sum(replay)
        # The release: one step later the part is back on its bind.
        after = _reads_named(rows, "$p0")[-1]
        ck.pin(f"{name}.release_restores_bind",
               _mat(after, PART_LOCAL) == _mat(after, PART_BIND), "local != bind")
        # The fight clip over the aim: its own track on the aimed part never
        # displaces the external movement, its position track still applies,
        # and the parent it moves carries the aimed part with it.
        fight = next((r for r in rows if r.get("call") == "aStartAnimation"), None)
        ck.pin(f"{name}.fight_clip_started", fight is not None and fight.get("result") == "1",
               str(fight and fight.get("result")))
        clip_name = tables.lookup("fire", key)[0].name
        clip = charisma.parse_animation_file(
            str(Path(root) / "CHData" / "Animations" / f"{clip_name}.cha"))
        ck.pin(f"{name}.fight_clip_has_rotation_on_aimed_part",
               any(m.desc_class == "LinearRotationMovementDesc" and m.target == aimed.name
                   for m in clip.movements), clip_name)
        k = n
        clip_written = _mat(_reads_named(rows, f"$a{k}")[0], AIM_MOVEMENT_MATRIX)
        clip_parts = _reads_named(rows, f"$p{k}")[1:]
        clip_parents = [_mat(_reads_named(rows, f"clippar{j}")[0]) for j in range(FIGHT_STEPS)]
        held = [struct.unpack_from("<I", part, PART_CHANNELS + 4 * ROTATION_CHANNEL)[0]
                == movements[k] and _rotation(_mat(part, PART_LOCAL)) == _rotation(clip_written)
                for part in clip_parts]
        ck.pin(f"{name}.fight_clip_keeps_the_aim", len(held) == FIGHT_STEPS and all(held),
               f"{sum(held)}/{FIGHT_STEPS}")
        ck.pin(f"{name}.fight_clip_moves_parent_and_translation",
               _max_diff(clip_parents[0], clip_parents[-1]) > 1e-3
               and charisma.mat_translation(_mat(clip_parts[0], PART_LOCAL))
               != charisma.mat_translation(_mat(clip_parts[-1], PART_LOCAL)),
               "the clip moved nothing")
        follows = [_max_diff(_mat(_reads_named(rows, f"clip{j}")[0]),
                             charisma.mat_mul(clip_parents[j], _mat(clip_parts[j], PART_LOCAL)))
                   < AIM_TOLERANCE for j in range(FIGHT_STEPS)]
        ck.pin(f"{name}.fight_clip_world_is_parent_times_local", all(follows),
               f"{sum(follows)}/{FIGHT_STEPS}")
    ck.pin("aim.replayed_total", replayed == len(AIM_TARGETS) * len(BODY_AIM_CASES),
           f"{replayed}/{len(AIM_TARGETS) * len(BODY_AIM_CASES)}")


def check_limiter(ck: Checker, root: str, rows: list[dict[str, Any]]) -> None:
    """The skip controller's epoch rule, measured."""
    ck.pin("limiter.rows_all_ok", all(r.get("status") == "ok" for r in rows),
           str([r for r in rows if r.get("status") != "ok"][:3]))
    trace = limiter_trace(rows)
    ck.pin("limiter.call_count", len(trace) == LIMITER_CALLS, str(len(trace)))
    ticks = [int(r.get("eax", "0"), 16) for r in rows if r.get("call") == "GetTickCount"]
    ck.pin("limiter.bracketed_by_two_tick_reads", len(ticks) == 2, str(ticks))
    if len(trace) != LIMITER_CALLS or len(ticks) != 2:
        return
    period = 1000 // LIMITER_MAX_FPS
    pe = PEFile(str(Path(root) / "Incubation.exe"))
    ck.pin("limiter.frame_routine_calls_10_20",
           pe.bytes_at(LIMITER_FRAME_SITE, len(LIMITER_FRAME_BYTES)) == LIMITER_FRAME_BYTES,
           pe.bytes_at(LIMITER_FRAME_SITE, len(LIMITER_FRAME_BYTES)).hex())
    ck.pin("limiter.epoch_written_on_the_no_wait_branch",
           pe.bytes_at(LIMITER_EPOCH_WRITE, len(LIMITER_EPOCH_WRITE_BYTES))
           == LIMITER_EPOCH_WRITE_BYTES,
           pe.bytes_at(LIMITER_EPOCH_WRITE, len(LIMITER_EPOCH_WRITE_BYTES)).hex())
    # The rule, call by call.  A call that did not wait wrote the epoch as
    # the tick it read; a call that waited left the epoch alone and read
    # ticks until the period had passed since it.
    #
    # **The first call has no predecessor, and it may wait.**  The front end
    # runs this same limiter (`0x0044BDB0`), so the epoch global `0x00522EE8`
    # is warm at the anchor: the first `aSkipController` here can find it
    # within a period and wait.  `previous_epoch` is therefore only compared
    # once it exists -- both branches guard it -- so the first call is checked
    # for the invariants it can carry alone (a no-wait writes the tick; a wait
    # lasts a period) and not for one about a predecessor it does not have.
    odd: list[str] = []
    previous_epoch: int | None = None
    for index, (tick, epoch, waited) in enumerate(trace):
        if waited == 0:
            if epoch != tick:
                odd.append(f"{index}: no wait but epoch {epoch} != tick {tick}")
            if previous_epoch is not None and tick - previous_epoch < period:
                odd.append(f"{index}: no wait after only {tick - previous_epoch} ms")
        else:
            if previous_epoch is not None and epoch != previous_epoch:
                odd.append(f"{index}: waited but epoch moved {previous_epoch} -> {epoch}")
            if tick - epoch < period:
                odd.append(f"{index}: left the wait at {tick - epoch} ms")
        previous_epoch = epoch
    ck.pin("limiter.epoch_rule_holds_every_call", not odd, str(odd[:4]))
    waits = [w for _t, _e, w in trace]
    # The behaviour is pinned by these three, all host-independent: the wait
    # falls on every other call and never twice running (the epoch bug), and
    # every waited call above already had to last a whole period.  The two
    # wall-time checks below are only a loose sanity cross-check, because the
    # elapsed time is 60 debugger round trips over Wine and its overhead is
    # the host's, not the engine's.
    ck.pin("limiter.no_two_consecutive_waits",
           not any(a and b for a, b in zip(waits, waits[1:])), str(waits))
    ck.pin("limiter.waits_on_about_every_other_call",
           LIMITER_CALLS * 2 // 5 <= sum(waits) <= LIMITER_CALLS // 2 + 1, str(sum(waits)))
    # The floor is the engine's own wall-clock waits and is host-independent:
    # each of the `sum(waits)` waited calls held a full period (checked above),
    # so the run cannot be shorter than that.  The ceiling is only a sanity
    # cap: the debugger's overhead adds to the floor and is the host's, so the
    # bound is generous -- a run that hits it wants a re-run, not a verdict.
    elapsed = ticks[1] - ticks[0]
    per_call = elapsed / LIMITER_CALLS
    wait_floor = sum(waits) * period
    ck.pin("limiter.elapsed_at_least_the_waits",
           elapsed >= wait_floor - period,
           f"{elapsed} ms against {sum(waits)} waits x {period} ms")
    ck.pin("limiter.elapsed_not_every_call_waited",
           per_call < period, f"{per_call:.1f} ms a call over {elapsed} ms")
    ck.pin("limiter.elapsed_within_a_sane_ceiling",
           elapsed < LIMITER_CALLS * period,
           f"{elapsed} ms, ceiling {LIMITER_CALLS * period} ms (else re-run)")


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


def corpus_type_models(root: str) -> dict[int, str]:
    """`unitInfo[type] + 0x6C` for every type, from the root's `Info.lcl`."""
    tables = load_info_file(str(Path(root) / "DATA" / "Info.lcl"))
    return {type_id: row.model for type_id, row in tables.units.items()}


def corpus_sizes(root: str) -> dict[int, int]:
    """`unitInfo[type] + 0x7B` for every type -- the large flag the ring
    creators pick their radius by."""
    tables = load_info_file(str(Path(root) / "DATA" / "Info.lcl"))
    return {type_id: row.size for type_id, row in tables.units.items()}


def call_args(spec: tuple[Any, ...], tiles: dict[str, dict[str, int]],
              inputs: blob_creators.DeathInputs) -> list[int]:
    """The arguments a spec expands to, with the object positions the
    capture read for the `("@", key)` items."""
    args: list[int] = []
    for item in spec:
        if isinstance(item, tuple):
            args += list(inputs.object(tiles[item[1]]["x"], tiles[item[1]]["y"]))
        elif isinstance(item, str):
            args += [tiles[item]["x"], tiles[item]["y"]]
        else:
            args.append(item)
    return args


def death_inputs(state_rows: list[dict[str, Any]], call_rows: list[dict[str, Any]],
                 tiles: dict[str, dict[str, int]],
                 type_models: dict[int, str] | None = None,
                 tables: Any = None, sizes: dict[int, int] | None = None
                 ) -> blob_creators.DeathInputs:
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
    return blob_creators.DeathInputs(tiles=table, gore=gore, display_mode=mode,
                                     models=models, type_models=type_models or {},
                                     tables=tables, sizes=sizes or {})


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
    type_models = corpus_type_models(root)
    sizes = corpus_sizes(root)
    trig = eng3d.load(root)
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
        inputs = death_inputs(state, phase, tiles, type_models, trig, sizes)
        seeded = _row_after(phase, "memcpy", 0)
        made = _row_after(phase, f"c{creator:08X}", 0)
        after = _row_after(phase, "aGetUnitMapElementPtr", 0)
        ck.pin(f"death.{name}.seed_written", seed_of(seeded) == seed, str(seed_of(seeded)))
        ck.pin(f"death.{name}.returned_1", made is not None and made.get("result") == "1",
               str(made and made.get("result")))
        pool_raw = next((raw for key, raw in _reads(after).items() if key.startswith("[0x")), b"")
        records = blob_gold.parse_records(pool_raw)
        args = call_args(spec, tiles, inputs)
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
        if name in DEATH_MUST_SPAWN:
            ck.pin(f"death.{name}.spawned", len(records) >= DEATH_MUST_SPAWN[name],
                   f"{len(records)} record(s); the type's model must resolve")
    ck.pin("deaths.records_compared", compared == DEATH_RECORDS_COMPARED,
           f"{compared} records compared, {DEATH_RECORDS_COMPARED} pinned")
    # Each of the five doubles the programs carry is told from its neighbour
    # by this capture: perturbed by one, some phase's replay changes.
    undiscriminated = [name for name in DEATH_CONSTANTS
                       if not _death_constant_discriminated(
                           name, state, phases, tiles, root, type_models)]
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
                   tiles: dict[str, dict[str, int]], root: str,
                   type_models: dict[int, str] | None = None) -> list[Any]:
    out: list[Any] = []
    geometry = eng3d.load(root)
    sizes = corpus_sizes(root)
    for name, creator, spec, seed in DEATH_CALLS:
        phase = (phases.get("death_" + name) or {}).get("rows")
        if not phase or any(r.get("status") != "ok" for r in phase):
            continue
        inputs = death_inputs(state, phase, tiles, type_models, geometry,
                              sizes)
        args = call_args(spec, tiles, inputs)
        pool = blob_creators.Pool(inputs)
        draws = blob_creators.Draws(seed)
        blob_creators.DEATH_PROGRAMS[creator][1](pool, draws, args, inputs)
        out.append((draws.count, pool.records[:DEATH_READ_RECORDS]))
    return out


def _death_constant_discriminated(name: str, state: list[dict[str, Any]],
                                  phases: dict[str, Any],
                                  tiles: dict[str, dict[str, int]], root: str,
                                  type_models: dict[int, str]) -> bool:
    """Whether moving one creator constant changes what the programs build.

    ``type_models`` is handed over rather than left to default: without it
    ``FlyingUnit`` names no model and builds **no record at all**, so the one
    phase whose model is the victim's own would sit out the sweep it is part
    of.
    """
    base = _death_replays(state, phases, tiles, root, type_models)
    was = getattr(blob_creators, name)
    setattr(blob_creators, name, was + 1.0)
    try:
        return _death_replays(state, phases, tiles, root,
                              type_models) != base
    finally:
        setattr(blob_creators, name, was)


AIM_CASES_SCHEMA = "incubation.aim-cases/1"


def emit_aim_cases(path: Path, out: Path) -> int:
    """`0x0042CD80`'s captured inputs and the matrix it wrote, per target.

    `godot/tests/test_charisma.gd` replays each through `AttackAim.spine_local`
    and holds it to :data:`AIM_TOLERANCE` against the engine's own matrix --
    the capture, not :func:`aim_matrices`, is the oracle.
    """
    if not path.is_file():
        LOG.error("%s: no capture; take one with --game-copy", path)
        return 1
    phases = json.loads(path.read_text(encoding="utf-8")).get("phases") or {}
    cases: list[dict[str, Any]] = []
    for name, case in BODY_AIM_CASES.items():
        rows = (phases.get(name) or {}).get("rows")
        if not rows:
            LOG.error("%s: phase missing -- re-take the capture", name)
            return 1
        placement = _mat(_reads_named(rows, "$m")[0], MODEL_PLACEMENT)
        for k, (label, spec) in enumerate(AIM_TARGETS):
            written, parent_world, part_pre, _post = _aim_inputs(rows, k)
            cases.append({"phase": name, "label": label,
                          "placement": placement, "parent_world": parent_world,
                          "local": _mat(part_pre, PART_LOCAL),
                          "target": list(aim_target(case, spec)),
                          "written": written})
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"schema": AIM_CASES_SCHEMA,
                               "tolerance": AIM_TOLERANCE, "cases": cases},
                              indent=1) + "\n", encoding="utf-8")
    LOG.info("wrote %s -- %d case(s)", out, len(cases))
    return 0


DEATH_CASES_SCHEMA = "incubation.death-cases/1"


def emit_death_cases(path: Path, root: str, out: Path) -> int:
    """Write the death creators' cases for `godot/tests/test_presentation_native.gd`.

    One case per captured phase: the arguments, the seed written, everything
    the creator read (`DeathInputs`, as the capture measured it), the draw
    count the seed answers and **the engine's own records** -- so the
    GDScript programs of `game/fx/blob_programs.gd` are compared with what
    `Incubation.exe` left in its pool, not with this file's Python.  The
    oracle boundary is therefore **native**, and the fixture says so.
    """
    if not path.is_file():
        LOG.error("%s: no capture; take one with --game-copy", path)
        return 1
    document = json.loads(path.read_text(encoding="utf-8"))
    phases = document.get("phases") or {}
    state = (phases.get("deaths_state") or {}).get("rows")
    if not state:
        LOG.error("the capture holds no deaths_state phase")
        return 1
    tiles = death_tiles(state)
    type_models = corpus_type_models(root)
    geometry = eng3d.load(root)
    sizes = corpus_sizes(root)
    cases: list[dict[str, Any]] = []
    for name, creator, spec, seed in DEATH_CALLS:
        phase = (phases.get("death_" + name) or {}).get("rows")
        if not phase or any(r.get("status") != "ok" for r in phase):
            # **Refused, not skipped.**  `check_deaths` requires every phase
            # by name, so a warning here would write a case file thin enough
            # to pass the Godot suite's minimums while `--check` failed on
            # the same capture -- the two would disagree about whether the
            # capture is whole.  `emit_special_cases` has always refused.
            LOG.error("death_%s: not captured; re-take it before emitting",
                      name)
            return 1
        inputs = death_inputs(state, phase, tiles, type_models, geometry,
                              sizes)
        after = _row_after(phase, "aGetUnitMapElementPtr", 0)
        pool_raw = next((raw for key, raw in _reads(after).items() if key.startswith("[0x")), b"")
        records = blob_gold.parse_records(pool_raw)
        args = call_args(spec, tiles, inputs)
        pool = blob_creators.Pool(inputs)
        draws = blob_creators.Draws(seed)
        blob_creators.DEATH_PROGRAMS[creator][1](pool, draws, args, inputs)
        used_types = {u.type_id for _o, u in inputs.tiles.values() if u is not None}
        cases.append({
            "name": name, "creator": f"0x{creator:08X}", "args": args, "seed": seed,
            "inputs": {
                "tiles": [{"x": x, "y": y, "object": list(obj),
                           "unit": None if unit is None else
                           {"type": unit.type_id, "player": unit.player,
                            "height": unit.height}}
                          for (x, y), (obj, unit) in sorted(inputs.tiles.items())],
                "gore": inputs.gore, "display_mode": inputs.display_mode,
                "models": dict(inputs.models),
                "type_models": {str(t): type_models.get(t, "") for t in sorted(used_types)},
                "sizes": {str(t): inputs.sizes.get(t, 0) for t in sorted(used_types)},
            },
            "draws": draws.count,
            "records_built": len(pool.records),
            "records_read": DEATH_READ_RECORDS,
            "records": [{f: r[f] for f in blob_creators.FIELDS} for r in records],
        })
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"schema": DEATH_CASES_SCHEMA, "oracle": "native-runtime",
                               "fields": list(blob_creators.FIELDS),
                               "cases": cases}, indent=1), encoding="utf-8")
    LOG.info("wrote %s (%d case(s))", out, len(cases))
    return 0 if cases else 1


IDLE_CASES_SCHEMA = "incubation.idle-cases/1"


def emit_idle_cases(path: Path, root: str, out: Path) -> int:
    """Write the idle scheduler's cases for `godot/tests/test_presentation_native.gd`.

    From the `idle_random` phase: every starter call as the engine made it
    -- the seed before and after, slot 1's countdown and occupancy either
    side -- classified by the replay, plus the guard inputs of all 200 unit
    records (alive, `+0x4F`, `+0x56`, the selector's answer, the object's
    model) so the GDScript scheduler classifies from the fixture and not
    from a `World`.  From `idle_pose`: the forced start's clock -- length,
    speed, the three stops -- and the bind snap after the free.
    """
    if not path.is_file():
        LOG.error("%s: no capture; take one with --game-copy", path)
        return 1
    document = json.loads(path.read_text(encoding="utf-8"))
    phases = document.get("phases") or {}
    rows = (phases.get("idle_random") or {}).get("rows")
    pose = (phases.get("idle_pose") or {}).get("rows")
    if not rows or not pose:
        LOG.error("the capture holds no idle_random / idle_pose phase")
        return 1
    unit_base, units = unit_array(rows)
    objects = object_array(rows)
    guards = IdleGuards(root, units, objects)
    records = []
    for slot in range(UNIT_SLOTS):
        record = unit_record(units, slot)
        clip = idle_clip_of(root, record) if record[UNIT_HP] else None
        base = record[UNIT_OBJECT] * OBJECT_STRIDE
        records.append({
            "slot": slot, "hp": record[UNIT_HP], "visibility": record[UNIT_HIDDEN],
            "animating": record[UNIT_ANIMATING], "type": record[UNIT_TYPE],
            "weapon": record[UNIT_WEAPON], "player": record[UNIT_PLAYER],
            "has_model": int(base + OBJECT_STRIDE <= len(objects)
                             and objects[base + OBJECT_MODEL] != 0),
            "has_idle": int(clip is not None),
            "idle_clip": clip.name if clip is not None else "",
            "idle_length": engine_length(clip) if clip is not None else 0.0,
            "refused": guards.refuses(slot),
        })
    calls = []
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
            continue
        drawn = -1
        if seed != prev_seed:
            drawn = int(ARandom(prev_seed).raw(0, 200))
        calls.append({
            "seed_before": prev_seed, "seed_after": seed,
            "countdown_before": prev_slot[SLOT_COUNTDOWN],
            "countdown_after": slot[SLOT_COUNTDOWN],
            "active_before": prev_slot[SLOT_ACTIVE], "active_after": slot[SLOT_ACTIVE],
            "drawn": drawn,
            "unit_after": ((slot[SLOT_UNIT] - unit_base) // UNIT_STRIDE
                           if slot[SLOT_ACTIVE] else -1),
        })
        prev_seed, prev_slot = seed, slot
    replay = replay_random(rows, guards, unit_base)
    _base_pose, pose_units = unit_array(pose)
    pose_clip = idle_clip_of(root, unit_record(pose_units, POSE_UNIT_SLOT))
    stops = snapshot_rows(pose)
    parts_moved = 0
    if "end" in stops and "bind" in stops:
        end_parts = parse_snapshot(stops["end"])
        bind_parts = parse_snapshot(stops["bind"])
        parts_moved = sum(1 for a, b in zip(end_parts, bind_parts)
                          if a is not None and b is not None and a["record"] != b["record"])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({
        "schema": IDLE_CASES_SCHEMA, "oracle": "native-runtime",
        "slots": [1, 2, 4, 5], "slot_read": IDLE_SLOT,
        "type_argument": STARTER_TYPE_ARGUMENT,
        "units": records, "calls": calls,
        "summary": {"ticks": replay["ticks"], "misses": replay["misses"],
                    "starts": len(replay["starts"]), "frees": replay["frees"],
                    "draws": replay["draws"]},
        "pose": {"seed": POSE_SEED, "unit": POSE_UNIT_SLOT,
                 "clip": pose_clip.name if pose_clip else "",
                 "length": engine_length(pose_clip) if pose_clip else 0.0,
                 "speed": IDLE_SPEED, "steps": list(POSE_STEPS),
                 "parts_moved_at_end": parts_moved},
    }, indent=1), encoding="utf-8")
    LOG.info("wrote %s (%d call(s), %d unit(s))", out, len(calls), len(records))
    return 0 if calls else 1


def _cells_of(row: dict[str, Any] | None) -> bytes:
    return _reads(row).get("$c0", b"")


def _array_of(row: dict[str, Any] | None) -> bytes:
    return _reads(row).get(f"[0x{SPECIAL_ARRAY:x}]", b"")


def _model_columns(cells: bytes, width: int = gold.CAPTURE_WIDTH,
                   height: int = gold.CAPTURE_HEIGHT) -> ctrlmap.CtrlMap:
    """A `CtrlMap` over the captured control map, as the model's own lists."""
    n = len(cells) // gold.CELL_STRIDE

    def column(offset: int) -> list[int]:
        return [cells[i * gold.CELL_STRIDE + offset] for i in range(n)]

    heights = [struct.unpack_from("<i", cells,
                                  i * gold.CELL_STRIDE + CELL_HEIGHT)[0]
               for i in range(n)]
    return ctrlmap.CtrlMap(
        width=width, height=height,
        cell_height=heights, unit_at=[-1] * n,
        action_point=column(CELL_ACTION_POINT),
        field_type=column(CELL_FIELD_TYPE),
        effect_timer=column(CELL_EFFECT_TIMER),
        effect_object=column(CELL_EFFECT_OBJECT),
        effect_state=column(CELL_EFFECT_STATE),
        decal_object=column(CELL_DECAL_OBJECT),
        decal_phase=column(CELL_DECAL_PHASE),
        decal_state=column(CELL_DECAL_STATE))


def _engine_columns(cells: bytes) -> dict[str, list[int]]:
    n = len(cells) // gold.CELL_STRIDE
    return {name: [cells[i * gold.CELL_STRIDE + off] for i in range(n)]
            for name, off in (("effect_timer", CELL_EFFECT_TIMER),
                              ("effect_object", CELL_EFFECT_OBJECT),
                              ("effect_state", CELL_EFFECT_STATE),
                              ("decal_object", CELL_DECAL_OBJECT),
                              ("decal_phase", CELL_DECAL_PHASE),
                              ("decal_state", CELL_DECAL_STATE))}


def _engine_slots(array: bytes) -> list[int]:
    return [array[i * SPECIAL_RECORD_BYTES + SPECIAL_STATE]
            for i in range(SPECIAL_SLOTS)]


def _engine_subtypes(array: bytes) -> list[int]:
    return [array[i * SPECIAL_RECORD_BYTES + SPECIAL_SUBTYPE]
            for i in range(SPECIAL_SLOTS)]


def _model_subtypes(cells: ctrlmap.CtrlMap) -> dict[int, int]:
    """The subtype `aCreateSpecialObject` was handed, by object id.

    Not carried by the model: every placer passes the cell byte it has just
    written, so it is derivable and derived here rather than stored twice.
    """
    out: dict[int, int] = {}
    for i in range(len(cells.effect_state)):
        if cells.effect_state[i] in (ctrlmap.OBSTACLE_FIRE,
                                     ctrlmap.OBSTACLE_MINE,
                                     ctrlmap.OBSTACLE_SHIELD):
            out[cells.effect_object[i]] = cells.effect_timer[i]
        if cells.decal_state[i] == ctrlmap.DECAL_GLOW:
            out[cells.decal_object[i]] = cells.decal_phase[i]
    return out


#: The world set the fixture save is on (`_C_141`, `Level01e`).
CAPTURE_WORLD_SET = "A00"


def special_models(root: str, world_set: str) -> frozenset[str]:
    """The placer model names a world set's prototype container carries."""
    from inclib import prototyp  # noqa: PLC0415
    path = (Path(root) / "WorldSet" / f"World_{world_set}" / "Objects"
            / "prototyp.din")
    wanted = {ctrlmap.FIRE_MODEL_SMALL, ctrlmap.FIRE_MODEL_MEDIUM,
              ctrlmap.FIRE_MODEL_LARGE, ctrlmap.MINE_MODEL,
              ctrlmap.SHIELD_MODEL, *ctrlmap.GLOW_MODELS.values()}
    container = prototyp.load_container(str(path))
    return frozenset(set(container.names) & wanted)


def _origin_of(rows: list[dict[str, Any]], key: str) -> tuple[int, int, int]:
    """The cell's own object position -- ``+0x10``/``+0x14``/``+0x18``."""
    for row in rows:
        raw = _reads(row).get(f"$s_{key}")
        if raw is not None and len(raw) >= 0x1C:
            return tuple(struct.unpack_from("<iii", raw, 0x10))  # type: ignore
    return (0, 0, 0)


def _record_position(array: bytes, object_id: int) -> tuple[int, int, int]:
    """One special-object record's position."""
    at = object_id * SPECIAL_RECORD_BYTES
    return tuple(struct.unpack_from("<iii", array, at + 0x10))  # type: ignore


def _draws_between(rows: list[dict[str, Any]],
                   row: dict[str, Any]) -> int:
    """How many `aRandom2` draws the engine spent on this call.

    The seed is written afresh before every call, so the count is whatever
    turns the written seed into the one the call left.
    """
    seed_key = f"[0x{ARANDOM2_SEED:x}]"
    del seed_key
    after = _reads(row).get(f"0x{ARANDOM2_SEED:x}")
    if after is None:
        return -1
    from inclib.rng import ARandom  # noqa: PLC0415
    rng = ARandom(SPECIAL_SEED)
    want = struct.unpack("<d", after)[0]
    for n in range(64):
        if rng.seed == want:
            return n
        rng.raw(0, 1)
    return -1


def check_special(ck: Checker, root: str, phases: dict[str, Any]) -> None:
    """docs/42 §9.1 -- the four placers and the round tick, in the engine.

    Each phase reads the whole control map and the whole 80-slot array before
    and after every call, so what is compared is not "the cell the placer was
    aimed at" but every cell and every slot.  The model is
    :mod:`inclib.ctrlmap`, replayed from the captured *before* state.
    """
    tiles: dict[str, dict[str, int]] = {}
    state = (phases.get("deaths_state") or {}).get("rows")
    if state:
        tiles = death_tiles(state)
    # The capture runs on `_C_141`, which is `World_A00` -- and A00 carries no
    # `GLOW1/2.3DI`.  Handing the model set over is what makes the glow phase a
    # check of the name gate rather than a failure.
    models = special_models(root, CAPTURE_WORLD_SET)
    ck.pin("special.world_set_has_no_glow",
           ctrlmap.GLOW_MODELS[2] not in models,
           f"{CAPTURE_WORLD_SET} carries {sorted(models)}")
    d00_models = special_models(root, SPECIAL_D00_WORLD_SET)
    ck.pin("special.d00_has_the_glow",
           ctrlmap.GLOW_MODELS[2] in d00_models,
           f"{SPECIAL_D00_WORLD_SET} carries {sorted(d00_models)}")
    every: dict[str, Any] = dict(SPECIAL_CALLS)
    every.update(SPECIAL_D00_CALLS)
    for name, calls in every.items():
        rows = (phases.get(name) or {}).get("rows")
        ck.pin(f"{name}.captured", bool(rows), "phase missing -- re-take it")
        if not rows:
            continue
        placed = [r for r in rows if r.get("call") in
                  ("aMakeFire", "aMakeMine", "aMakeShield", "aMakeGlow",
                   "aGroundEffectsTick")]
        ck.pin(f"{name}.calls", len(placed) == len(calls),
               f"{len(placed)} row(s) for {len(calls)} call(s)")
        if len(placed) != len(calls):
            continue
        before = _cells_of(_row_after(rows, "aGetCtrlMapElementPtr"))
        array0 = _array_of(_row_after(rows, "aGetCtrlMapElementPtr"))
        origins = {key: _origin_of(rows, key)
                   for key in (("g",) if name in SPECIAL_D00_CALLS
                               else tuple(SPECIAL_TILE_OBJECTS))}
        # **The array is seeded from the capture, not rebuilt.**
        # `rebuild_objects` only knows the cell-owned objects, and `_C_116`
        # loads with slot 0 already holding a **state-5** one -- the static
        # kind `0x00431F45` makes, which no cell names. Rebuilding would put
        # the model's first object in a slot the engine had taken and every
        # comparison after it would be off by one id.
        ck.pin(f"{name}.array_seeded",
               len(_engine_slots(array0)) == ctrlmap.SPECIAL_OBJECT_SLOTS,
               "the phase read the whole array before its first call")
        d00 = name in SPECIAL_D00_CALLS
        cells = _model_columns(
            before, SPECIAL_D00_WIDTH if d00 else gold.CAPTURE_WIDTH,
            SPECIAL_D00_HEIGHT if d00 else gold.CAPTURE_HEIGHT)
        cells.models = d00_models if d00 else models
        cells.objects = _engine_slots(array0)

        def resolve(item: Any) -> Any:
            if item == "gx":
                return SPECIAL_D00_CELL[0]
            if item == "gy":
                return SPECIAL_D00_CELL[1]
            if item in SPECIAL_TILE_KEYS:
                key, field = SPECIAL_TILE_KEYS[item]
                return tiles[key][field]
            if item == "z":
                return tiles["m"]["cell_height"]
            if item == "z+":
                return tiles["m"]["cell_height"] + 0x640
            return item

        for step, ((routine, spec), row) in enumerate(zip(calls, placed)):
            args = [resolve(item) for item in spec]
            draws = blob_creators.Draws(SPECIAL_SEED)
            made = -1
            state = 0
            if routine == "aMakeFire":
                made = ctrlmap.place_fire(cells, *args)
                state = ctrlmap.OBSTACLE_FIRE
            elif routine == "aMakeMine":
                made = ctrlmap.place_mine(cells, *args)
                state = ctrlmap.OBSTACLE_MINE
            elif routine == "aMakeShield":
                made = ctrlmap.place_shield(cells, *args)
                state = ctrlmap.OBSTACLE_SHIELD
            elif routine == "aMakeGlow":
                made = ctrlmap.place_glow(cells, *args)
                state = ctrlmap.DECAL_GLOW
            else:
                ctrlmap.round_tick(cells)
            # **The position, and the draws it spends.**  The cell's own
            # object is the origin; the fire and the glow scatter around it
            # with two `aRandom2` draws each and the mine and the shield take
            # it exactly (`docs/42` §9.1).
            if made >= 0:
                key = "g" if name in SPECIAL_D00_CALLS else (
                    "a" if routine == "aMakeShield" and args[0:2] == [
                        tiles["a"]["x"], tiles["a"]["y"]] else "m")
                want = _record_position(_array_of(row), made)
                got = ctrlmap.object_position(origins[key], state, draws)
                ck.pin(f"{name}.{step}.{routine}.position", want == got,
                       f"engine {want} model {got}")
                ck.pin(f"{name}.{step}.{routine}.draws",
                       draws.count == _draws_between(rows, row),
                       f"model {draws.count}, engine "
                       f"{_draws_between(rows, row)}")
            want = _engine_columns(_cells_of(row))
            got = {"effect_timer": cells.effect_timer,
                   "effect_object": cells.effect_object,
                   "effect_state": cells.effect_state,
                   "decal_object": cells.decal_object,
                   "decal_phase": cells.decal_phase,
                   "decal_state": cells.decal_state}
            for column in sorted(want):
                bad = [(i, want[column][i], got[column][i])
                       for i in range(len(want[column]))
                       if want[column][i] != got[column][i]]
                ck.pin(f"{name}.{step}.{routine}.{column}", not bad,
                       f"{len(bad)} cell(s) differ, first {bad[:2]}")
            slots = _engine_slots(_array_of(row))
            ck.pin(f"{name}.{step}.{routine}.array", slots == cells.objects,
                   f"engine {[ (i,v) for i,v in enumerate(slots) if v != 255 ]}"
                   f" model {[ (i,v) for i,v in enumerate(cells.objects) if v != 255 ]}")
            subtypes = _engine_subtypes(_array_of(row))
            derived = _model_subtypes(cells)
            bad = [(oid, subtypes[oid], value) for oid, value in derived.items()
                   if subtypes[oid] != value]
            ck.pin(f"{name}.{step}.{routine}.subtypes", not bad, str(bad[:2]))


SPECIAL_CASES_SCHEMA = "incubation.special-cases/1"
#: The idle value of each of the six columns, in `MapState` slot order.
SPECIAL_IDLE = (0, 255, 255, 255, 0, 255)


def _sparse(cells: ctrlmap.CtrlMap) -> list[list[int]]:
    """Every cell away from idle, as ``[index, +0x0E .. +0x13]``."""
    columns = (cells.effect_timer, cells.effect_object, cells.effect_state,
               cells.decal_object, cells.decal_phase, cells.decal_state)
    out: list[list[int]] = []
    for i in range(len(cells.effect_state)):
        row = [column[i] for column in columns]
        if tuple(row) != SPECIAL_IDLE:
            out.append([i] + row)
    return out


def emit_special_cases(path: Path, root: str, out: Path) -> int:
    """The eight placer phases as a case file the GDScript twin replays.

    Sparse rather than whole: every cell away from idle, before and after each
    call, plus the object slots that are taken.  A model that wrote a cell the
    engine left alone shows up as an extra row, so the sparse form asserts the
    same thing the whole map does.
    """
    if not path.is_file():
        LOG.error("%s: no capture; take one with --game-copy", path)
        return 1
    document = json.loads(path.read_text(encoding="utf-8"))
    phases = document.get("phases") or {}
    state = (phases.get("deaths_state") or {}).get("rows")
    if not state:
        LOG.error("the deaths_state phase is missing; re-take the capture")
        return 1
    tiles = death_tiles(state)
    models = sorted(special_models(root, CAPTURE_WORLD_SET))
    cases: list[dict[str, Any]] = []
    d00_models = sorted(special_models(root, SPECIAL_D00_WORLD_SET))
    every: dict[str, Any] = dict(SPECIAL_CALLS)
    every.update(SPECIAL_D00_CALLS)
    for name, calls in every.items():
        rows = (phases.get(name) or {}).get("rows")
        if not rows:
            LOG.error("%s: phase missing", name)
            return 1
        placed = [r for r in rows if r.get("call") in
                  ("aMakeFire", "aMakeMine", "aMakeShield", "aMakeGlow",
                   "aGroundEffectsTick")]
        # The same refusal :func:`check_special` makes: `zip` truncates, so a
        # phase that lost a row would emit a shorter case file and pass.
        if len(placed) != len(calls):
            LOG.error("%s: %d placer row(s) for %d call(s) -- re-take the "
                      "capture", name, len(placed), len(calls))
            return 1
        d00 = name in SPECIAL_D00_CALLS
        head = _row_after(rows, "aGetCtrlMapElementPtr")
        before = _model_columns(
            _cells_of(head),
            SPECIAL_D00_WIDTH if d00 else gold.CAPTURE_WIDTH,
            SPECIAL_D00_HEIGHT if d00 else gold.CAPTURE_HEIGHT)
        origins = {key: list(_origin_of(rows, key))
                   for key in (("g",) if d00 else tuple(SPECIAL_TILE_OBJECTS))}
        steps: list[dict[str, Any]] = []
        for (routine, spec), row in zip(calls, placed):
            args = []
            for item in spec:
                if item == "gx":
                    args.append(SPECIAL_D00_CELL[0])
                elif item == "gy":
                    args.append(SPECIAL_D00_CELL[1])
                elif item in SPECIAL_TILE_KEYS:
                    key, field = SPECIAL_TILE_KEYS[item]
                    args.append(tiles[key][field])
                elif item == "z":
                    args.append(tiles["m"]["cell_height"])
                elif item == "z+":
                    args.append(tiles["m"]["cell_height"] + 0x640)
                else:
                    args.append(item)
            after = _model_columns(
                _cells_of(row),
                SPECIAL_D00_WIDTH if d00 else gold.CAPTURE_WIDTH,
                SPECIAL_D00_HEIGHT if d00 else gold.CAPTURE_HEIGHT)
            slots = _engine_slots(_array_of(row))
            array = _array_of(row)
            steps.append({
                "routine": routine, "args": args,
                # Which of the phase's origins this call places against --
                # the checker's own choice, written down rather than
                # re-derived by the GDScript twin from the phase's name.
                "origin": ("g" if d00 else
                           ("a" if routine == "aMakeShield"
                            and args[0:2] == [tiles["a"]["x"], tiles["a"]["y"]]
                            else "m")),
                "cells": _sparse(after),
                "objects": [[i, v] for i, v in enumerate(slots) if v != 255],
                # Every taken slot's position, so the GDScript twin's scatter
                # is compared against the engine's and not only its own.
                "positions": [[i] + list(_record_position(array, i))
                              for i, v in enumerate(slots) if v != 255],
            })
        cases.append({"name": name, "seed": SPECIAL_SEED,
                      "origins": origins,
                      "models": d00_models if d00 else models,
                      "objects_before": [[i, v] for i, v
                                         in enumerate(_engine_slots(
                                             _array_of(head)))
                                         if v != 255],
                      "width": before.width,
                      "height": before.height,
                      "heights": list(before.cell_height),
                      "field_types": list(before.field_type),
                      "action_points": list(before.action_point),
                      "before": _sparse(before), "steps": steps})
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"schema": SPECIAL_CASES_SCHEMA,
                               "world_set": CAPTURE_WORLD_SET,
                               "models": models, "cases": cases}, indent=1),
                   encoding="utf-8")
    LOG.info("wrote %s -- %d case(s)", out, len(cases))
    return 0


#: What the nine shipped `CrushWall` footprints turned out to be
#: (`docs/97` §41.7, measured 2026-09-03): phase -> the cells `0x0042F410`
#: marked, in row-major order.  Every one is a **straight run of two or three
#: cells** and the command's own cell is always in it -- but which run is the
#: wall piece's own geometry, and nothing in the `.lev` records it: the wall
#: column `_C_129` crushes at x 16 is five identical cells that split 2 + 3,
#: and `_O_061`'s row at y 19 is seven that split 2 + 2 + 3.
CRUSH_WALL_FOOTPRINTS: dict[str, tuple[tuple[int, int], ...]] = {
    "crush_wall_c_129_16_18": ((16, 18), (16, 19)),
    "crush_wall_c_129_16_20": ((16, 20), (16, 21), (16, 22)),
    "crush_wall_c_129_18_23": ((17, 23), (18, 23)),
    "crush_wall_c_142_22_11": ((22, 11), (22, 12)),
    "crush_wall_o_061_16_23": ((15, 23), (16, 23)),
    "crush_wall_o_061_11_23": ((10, 23), (11, 23)),
    "crush_wall_o_061_11_19": ((10, 19), (11, 19)),
    "crush_wall_o_061_13_19": ((12, 19), (13, 19)),
    "crush_wall_o_061_14_19": ((14, 19), (15, 19), (16, 19)),
}
#: What a marked cell was and became: field type 2 at 3280 -> field type 1 at
#: 0, with the state byte on 2 until the debris sweep puts it back.
CRUSH_WALL_BEFORE = (2, 3280)
CRUSH_WALL_AFTER = (1, 0)
CRUSH_WALL_MARKED_STATE = 2


def check_crush_wall(ck: Checker, phases: dict[str, Any]) -> None:
    """`CrushWall`'s footprint, on all nine shipped call sites -- `docs/42` §8.2.

    Each phase loads its own mission, finds the wall the way `0x00415D00`
    does and calls `0x0042F410(wall, 1, 0, 1)` with the **whole** control map
    read either side, so what is compared is every one of the 900 cells and
    not the one the command names.
    """
    sites = crush_wall_sites()
    for name, (mission, _slot, x, y) in sites.items():
        rows = (phases.get(name) or {}).get("rows")
        ck.pin(f"{name}.captured", bool(rows), "phase missing -- re-take it")
        if not rows:
            continue
        found = _row_after(rows, "aFindNearestObject")
        ck.pin(f"{name}.found_the_wall", bool(found and int(
            (found or {}).get("eax", "0x0"), 16)),
            "0x00406F20 answered nothing, so the mark would fall back to the "
            "last land object")
        before = _cells_of(_row_after(rows, "aGetCtrlMapElementPtr"))
        after = _cells_of(_row_after(rows, "aMarkCellsUnderObject"))
        if before is None or after is None:
            ck.pin(f"{name}.reads", False, "the map was not read either side")
            continue
        stride = gold.CELL_STRIDE
        marked: list[tuple[int, int]] = []
        for index in range(CRUSH_WALL_WIDTH * CRUSH_WALL_HEIGHT):
            was = before[index * stride:(index + 1) * stride]
            now = after[index * stride:(index + 1) * stride]
            if was != now:
                marked.append((index % CRUSH_WALL_WIDTH,
                               index // CRUSH_WALL_WIDTH))
        want = list(CRUSH_WALL_FOOTPRINTS[name])
        ck.pin(f"{name}.footprint", marked == want,
               f"{mission} ({x},{y}) marked {marked}, expected {want}")
        ck.pin(f"{name}.the_command_cell_is_in_it", (x, y) in marked,
               f"({x},{y}) not among {marked}")
        # Two or three cells sharing a column or a row: enough to say "a run
        # along one axis" for a footprint of this size, and no more than that.
        ck.pin(f"{name}.is_one_straight_run",
               len(marked) > 1
               and (len({c[0] for c in marked}) == 1
                    or len({c[1] for c in marked}) == 1),
               f"{marked} is not a run along one axis")
        for cx, cy in marked:
            index = cy * CRUSH_WALL_WIDTH + cx
            was = before[index * stride:(index + 1) * stride]
            now = after[index * stride:(index + 1) * stride]
            ck.pin(f"{name}.{cx}_{cy}.was",
                   (was[CELL_FIELD_TYPE],
                    struct.unpack_from("<i", was, CELL_HEIGHT)[0])
                   == CRUSH_WALL_BEFORE,
                   f"({cx},{cy}) was not a wall at 3280")
            ck.pin(f"{name}.{cx}_{cy}.became",
                   (now[CELL_FIELD_TYPE],
                    struct.unpack_from("<i", now, CELL_HEIGHT)[0])
                   == CRUSH_WALL_AFTER
                   and now[0] == CRUSH_WALL_MARKED_STATE,
                   f"({cx},{cy}) became "
                   f"{(now[CELL_FIELD_TYPE], struct.unpack_from('<i', now, CELL_HEIGHT)[0], now[0])}")
            # Everything between the height and the field type -- the symbol
            # object at `+0x05`, the unit word at `+0x07`, the action point at
            # `+0x0B` and the damage byte at `+0x0C` -- and everything after
            # the field type. `CELL_HEIGHT` is 1, so the first slice has to
            # start at `CELL_HEIGHT + 4`; starting it at 5 spelled the same
            # number and read nothing at all.
            ck.pin(f"{name}.{cx}_{cy}.nothing_else_moved",
                   was[CELL_HEIGHT + 4:CELL_FIELD_TYPE]
                   == now[CELL_HEIGHT + 4:CELL_FIELD_TYPE]
                   and was[CELL_FIELD_TYPE + 1:] == now[CELL_FIELD_TYPE + 1:],
                   "a byte outside the state, the height and the field type "
                   "changed")
    # The finding that decides where the footprint can come from: the runs
    # tile a wall that the control map cannot tell apart.
    ck.pin("crush_wall.every_site_is_two_or_three_cells",
           sorted({len(v) for v in CRUSH_WALL_FOOTPRINTS.values()}) == [2, 3],
           "the nine footprints are runs of two or three")
    for mission, _slot, _cells in CRUSH_WALL_MISSIONS:
        pooled = [c for name, cells in CRUSH_WALL_FOOTPRINTS.items()
                  for c in cells if sites[name][0] == mission]
        ck.pin(f"crush_wall.{mission}.the_runs_tile_the_wall",
               len(pooled) == len(set(pooled)),
               f"{mission}: two calls marked the same cell")


def _land_state(row: dict[str, Any] | None) -> tuple[int, bytes] | None:
    """`(count, table)` as a row's two land reads left them."""
    reads = _reads(row)
    count = reads.get(f"0x{LAND_COUNT:x}")
    table = reads.get(f"[0x{LAND_TABLE:x}]")
    if count is None or table is None or len(table) != LAND_TABLE_BYTES:
        return None
    return struct.unpack("<I", count)[0], table


def _land_record(table: bytes, index: int) -> bytes:
    return table[index * LAND_RECORD:(index + 1) * LAND_RECORD]


def _land_position(table: bytes, index: int) -> tuple[int, int, int]:
    return struct.unpack_from("<3i", table, index * LAND_RECORD + LAND_POSITION)


def land_search(table: bytes, count: int, at: tuple[int, int, int],
                box: tuple[int, int, int]) -> int:
    """`0x00406F20`: strictly inside the box on every axis, the smallest
    `|dx| + |dy| + |dz|`, the first in table order on a tie (`jae` against
    a best that starts at `-1`); `-1` for none."""
    best, best_sum = -1, None
    for index in range(count):
        d = [abs(a - b) for a, b in zip(_land_position(table, index), at)]
        if any(v >= limit for v, limit in zip(d, box)):
            continue
        if best_sum is None or sum(d) < best_sum:
            best, best_sum = index, sum(d)
    return best


def _symbol_position(row: dict[str, Any] | None) -> tuple[int, int, int] | None:
    for key, raw in _reads(row).items():
        if key.startswith("$s"):
            return struct.unpack_from("<3i", raw, RECORD_POSITION)
    return None


def _changed_cells(before: bytes, after: bytes, width: int) -> list[tuple[int, int]]:
    stride = gold.CELL_STRIDE
    return [(i % width, i // width) for i in range(len(before) // stride)
            if before[i * stride:(i + 1) * stride]
            != after[i * stride:(i + 1) * stride]]


def check_land_table(ck: Checker, root: str, phases: dict[str, Any]) -> None:
    """`docs/20` §7.4 item 12 -- the special-object table, read live.

    (a) every loadable mission's load leaves the `.lev`'s count and its
    records in the table; (b) `Platform` moves the record its search finds,
    by the ride's own distance; (c) an object inserted at run time has its
    own cell as its footprint; (d) `FootBridge` frees the record nearest the
    **command cell's** marker.
    """
    missions = land_missions(root)
    by_slot = {land_slot(root, m): m for m in missions}
    loaded: dict[str, tuple[int, bytes]] = {}
    phase = phases.get("land_table_loads") or {}
    ck.pin("land_table_loads.captured", bool(phase.get("rows")),
           "phase missing -- re-take it")
    for row in phase.get("rows") or []:
        mission = by_slot.get(int(row["args"][0]))
        state = _land_state(row)
        ck.pin(f"land.load.{mission}.loaded",
               mission is not None and row.get("result") == "1"
               and state is not None, f"{row.get('args')} {row.get('result')}")
        if mission is not None and state is not None:
            loaded[mission] = state
    # A mission that faulted as a fresh process's first load is named, and
    # the pin below holds the list: a capture that reached fewer fails.
    ck.pin("land.load.faulted_first", list(phase.get("faulted_first") or [])
           == list(LAND_LOAD_FAULTS), f"{phase.get('faulted_first')}")
    ck.pin("land.load.every_mission",
           sorted(set(loaded) | set(LAND_LOAD_FAULTS)) == missions,
           f"{len(loaded)}/{len(missions)} loaded; missing "
           f"{sorted(set(missions) - set(loaded) - set(LAND_LOAD_FAULTS))[:5]}")
    count_bad, record_bad, tail_bad = [], [], []
    for mission, (count, table) in sorted(loaded.items()):
        bm = land_map(root, mission)
        if count != len(bm.special):
            count_bad.append(f"{mission}: {count} != {len(bm.special)}")
        for index, record in enumerate(bm.special):
            live = _land_record(table, index)
            if any(live[f] != record.raw[f] for f in LAND_AUTHORED):
                record_bad.append(f"{mission}[{index}]")
        # Past the count the block is the file's, byte for byte: the load is
        # one `aLoadFile` of 9900 bytes, and the fix-up `0x00404D30` walks
        # the counted records only.
        if table[count * LAND_RECORD:] != bm.special_objects[count * LAND_RECORD:]:
            tail_bad.append(mission)
    ck.pin("land.load.count_is_the_levs", not count_bad and bool(loaded),
           f"{len(loaded) - len(count_bad)}/{len(loaded)}; {count_bad[:5]}")
    ck.pin("land.load.records_are_the_levs", not record_bad and bool(loaded),
           f"{record_bad[:5]}")
    ck.pin("land.load.block_read_verbatim_past_the_count",
           not tail_bad and bool(loaded), f"{tail_bad[:5]}")
    LOG.info("land table: %d/%d missions loaded with the .lev's count and "
             "records", len(loaded) - len(count_bad), len(missions))

    # (b) Platform.
    rows = (phases.get("land_table_platform") or {}).get("rows")
    ck.pin("land_table_platform.captured", bool(rows), "phase missing")
    if rows:
        bm = land_map(root, PLATFORM_MISSION)
        first = _land_state(_row_after(rows, "aGetCtrlMapElementPtr"))
        markers = [_symbol_position(r) for r in rows
                   if r.get("call") == "aGetSymbolObjectPtr"]
        rides = [r for r in rows if r.get("call") == "aPlayPlatformSequence"]
        ck.pin("platform.reads", first is not None
               and len(rides) == len(PLATFORM_CALLS)
               and len(markers) == len(PLATFORM_CALLS), "a read is missing")
        found: list[int] = []
        if first is not None and len(rides) == len(PLATFORM_CALLS):
            count, table = first
            for i, (x, y, d, n) in enumerate(PLATFORM_CALLS):
                ck.pin(f"platform.{i}.marker_is_the_cell_origin",
                       markers[i] == (x * 3200, y * 3200,
                                      bm.cells[y * bm.width + x].height),
                       f"{markers[i]}")
                after = _land_state(rides[i])
                if after is None:
                    ck.pin(f"platform.{i}.read", False, "no table read")
                    break
                index = land_search(table, count, markers[i], PLATFORM_BOX)
                found.append(index)
                want = bytearray(table)
                if index >= 0:
                    px, py, pz = _land_position(table, index)
                    dx, dy = PLATFORM_STEP[d]
                    struct.pack_into("<3i", want, index * LAND_RECORD + LAND_POSITION,
                                     px + dx * n * 3200, py + dy * n * 3200, pz)
                ck.pin(f"platform.{i}.count_unchanged", after[0] == count,
                       f"{count} -> {after[0]}")
                ck.pin(f"platform.{i}.moves_the_found_record_by_the_ride",
                       index >= 0 and after[1] == bytes(want),
                       f"found {index}; changed records "
                       f"{[k for k in range(LAND_SLOTS) if _land_record(after[1], k) != _land_record(table, k)]}")
                count, table = after
        # The rides are `_C_105`'s three platforms there and back: each pair
        # finds the same record, the second time at the cell the first left
        # it on -- which only a table that moved can answer.
        ck.pin("platform.each_pair_finds_one_record",
               found == [8, 8, 7, 7, 44, 44], f"{found}")
        ck.pin("platform.the_records_are_the_platforms",
               all(bm.special[k].prototype_name(bm.world_set) == "L024EB00.3DI"
                   for k in set(found) if k >= 0), f"{found}")

    # (b') The ride and the cell height: `0x00413011` copies `+0x0D..+0x10`
    # and never `+0x01`, so a raised source block stays raised and the
    # destination keeps its own height.
    rows = (phases.get("land_table_platform_height") or {}).get("rows")
    ck.pin("land_table_platform_height.captured", bool(rows), "phase missing")
    if rows:
        bm = land_map(root, PLATFORM_MISSION)
        dumps = [_cells_of(r) for r in rows if _cells_of(r)]
        x, y, d, n = PLATFORM_CALLS[0]
        dx, dy = PLATFORM_STEP[d]
        ck.pin("platform_height.reads", len(dumps) == 2, f"{len(dumps)} map reads")
        if len(dumps) == 2:
            before, after = dumps

            def height(cells: bytes, cx: int, cy: int) -> int:
                at = (cy * bm.width + cx) * gold.CELL_STRIDE + CELL_HEIGHT
                return struct.unpack_from("<i", cells, at)[0]

            block = [(x + ox, y + oy) for ox in (-1, 0, 1) for oy in (-1, 0, 1)]
            ck.pin("platform_height.source_was_raised",
                   all(height(before, cx, cy) == PLATFORM_PROBE_HEIGHT
                       for cx, cy in block)
                   and all(height(before, cx + dx * n, cy + dy * n) == 0
                           for cx, cy in block), "the probe write did not land")
            ck.pin("platform_height.source_keeps_its_height",
                   all(height(after, cx, cy) == PLATFORM_PROBE_HEIGHT
                       for cx, cy in block),
                   f"{[height(after, cx, cy) for cx, cy in block]}")
            ck.pin("platform_height.destination_keeps_its_own",
                   all(height(after, cx + dx * n, cy + dy * n) == 0
                       for cx, cy in block),
                   f"{[height(after, cx + dx * n, cy + dy * n) for cx, cy in block]}")
            ck.pin("platform_height.the_ride_ran",
                   all(after[((cy + dy * n) * bm.width + cx + dx * n)
                             * gold.CELL_STRIDE + CELL_FIELD_TYPE]
                       == before[(cy * bm.width + cx) * gold.CELL_STRIDE
                                 + CELL_FIELD_TYPE]
                       and after[(cy * bm.width + cx) * gold.CELL_STRIDE
                                 + CELL_FIELD_TYPE] == 4
                       for cx, cy in block), "the field types did not move")

    # (c) The run-time objects' footprints.
    rows = (phases.get("land_table_inserted") or {}).get("rows")
    ck.pin("land_table_inserted.captured", bool(rows), "phase missing")
    if rows:
        bm = land_map(root, INSERTED_MISSION)
        base = _land_state(_row_after(rows, "aGetCtrlMapElementPtr"))
        inserts = [r for r in rows if r.get("call") == "aInsertLandObject"]
        marks = [r for r in rows if r.get("call") == "aMarkCellsUnderObject"]
        markers = [_symbol_position(r) for r in rows
                   if r.get("call") == "aGetSymbolObjectPtr"]
        cells = [_cells_of(_row_after(rows, "aGetCtrlMapElementPtr"))] + \
            [_cells_of(r) for r in marks]
        ck.pin("inserted.reads", base is not None
               and len(inserts) == len(marks) == len(markers)
               == len(INSERTED_OBJECTS) and None not in cells,
               "a read is missing")
        if base is not None and len(inserts) == len(INSERTED_OBJECTS) \
                and None not in cells:
            count = base[0]
            for i, (model, (x, y), heading) in enumerate(INSERTED_OBJECTS):
                tag = f"inserted.{i}.{model[:8]}"
                state = _land_state(inserts[i])
                ck.pin(f"{tag}.appended", inserts[i].get("result") == "1"
                       and state is not None and state[0] == count + i + 1,
                       f"{inserts[i].get('result')} {state and state[0]}")
                if state is None:
                    continue
                record = _land_record(state[1], count + i)
                ck.pin(f"{tag}.at_the_marker",
                       markers[i] is not None
                       and _land_position(state[1], count + i) == markers[i]
                       and markers[i][:2] == (x * 3200, y * 3200)
                       and struct.unpack_from("<3H", record, 0x20)
                       == (0, 0, heading),
                       f"{_land_position(state[1], count + i)} vs {markers[i]}")
                marked = _changed_cells(cells[i], cells[i + 1], bm.width)
                ck.pin(f"{tag}.footprint_is_its_own_cell", marked == [(x, y)],
                       f"marked {marked}")
            # The same answer is arithmetic for every heading the effect
            # stream can draw: `inclib.footprint` over all 4096.
            from inclib import prototyp as protomod
            from inclib.convert import world_paths
            paths = world_paths(Path(root), bm.world_set, bm.world_scene)
            container = protomod.load_container(str(paths["din"]), str(paths["bin"]))
            tables = eng3d.load(root)
            from inclib import footprint as footprintmod
            for model in sorted({m for m, _c, _h in INSERTED_OBJECTS}):
                proto = container.parse(container.find(model))
                x = y = 10
                shapes = {tuple(footprintmod.cells_under(
                    footprintmod.object_polygons(
                        proto, x * 3200, y * 3200, (0, 0, h), tables),
                    bm.width, bm.height)) for h in range(4096)}
                ck.pin(f"inserted.{model[:8]}.own_cell_at_every_heading",
                       shapes == {(y * bm.width + x,)}, f"{shapes}")

    # (d) FootBridge.
    rows = (phases.get("land_table_footbridge") or {}).get("rows")
    ck.pin("land_table_footbridge.captured", bool(rows), "phase missing")
    if rows:
        bm = land_map(root, FOOT_BRIDGE_MISSION)
        before = _land_state(_row_after(rows, "aGetCtrlMapElementPtr"))
        after = _land_state(_row_after(rows, "aPlayFootBridgeSequence"))
        marker = _symbol_position(_row_after(rows, "aGetSymbolObjectPtr"))
        x, y = FOOT_BRIDGE_CALL[:2]
        ck.pin("footbridge.reads", None not in (before, after, marker), "a read is missing")
        if before is not None and after is not None and marker is not None:
            ck.pin("footbridge.marker_is_the_cell_origin",
                   marker == (x * 3200, y * 3200, bm.cells[y * bm.width + x].height),
                   f"{marker}")
            index = land_search(before[1], before[0], marker, FOOT_BRIDGE_BOX)
            ck.pin("footbridge.search_finds_the_bridge",
                   index >= 0 and bm.special[index].prototype_name(bm.world_set)
                   == "L025EB00.3DI", f"{index}")
            # `aDeleteLand` `0x00406C30`: the records above move down one,
            # in order, and the count drops by one.
            count, table = before
            want = (table[:index * LAND_RECORD]
                    + table[(index + 1) * LAND_RECORD:count * LAND_RECORD])
            ck.pin("footbridge.frees_that_record_and_keeps_the_order",
                   after[0] == count - 1
                   and after[1][:(count - 1) * LAND_RECORD] == want,
                   f"count {count} -> {after[0]}")


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
    for name, fn in (("idle_random", check_random), ("idle_pose", check_pose),
                     ("jump_scream", check_scream), ("frame_limiter", check_limiter)):
        rows = (phases.get(name) or {}).get("rows")
        ck.pin(f"{name}.captured", bool(rows), "phase missing -- re-take it")
        if rows:
            fn(ck, root, rows)
    check_deaths(ck, root, phases)
    check_special(ck, root, phases)
    check_crush_wall(ck, phases)
    check_land_table(ck, root, phases)
    check_body_aim(ck, root, phases)
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
        call_timeout: int | None = None
        if name in LAND_PHASES:
            stage_land_saves(game_copy)
        if name == "idle_random":
            plan = idle_random_plan()
        elif name == "land_table_loads":
            phase = phases.setdefault(name, {})

            def save() -> None:
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_text(json.dumps(document, indent=1), encoding="utf-8")
            capture_land_loads(game_copy, dbgcall, phase, attempts, save)
            continue
        elif name == "land_table_platform":
            plan = land_platform_plan(game_copy)
            call_timeout = PLATFORM_CALL_TIMEOUT_MS
        elif name == "land_table_platform_height":
            plan = land_platform_height_plan(game_copy)
            call_timeout = PLATFORM_CALL_TIMEOUT_MS
        elif name == "land_table_footbridge":
            plan = land_footbridge_plan(game_copy)
            call_timeout = PLATFORM_CALL_TIMEOUT_MS
        elif name == "land_table_inserted":
            plan = land_inserted_plan(game_copy)
        elif name == "idle_pose":
            plan = idle_pose_plan(pose_movements(str(game_copy), phases))
        elif name == "jump_scream":
            plan = jump_scream_plan()
        elif name == "frame_limiter":
            plan = frame_limiter_plan()
        elif name in BODY_AIM_CASES:
            slot = BODY_AIM_CASES[name].save_slot
            if not (game_copy / "Work" / "Saves2" / f"_{slot}_.sav").is_file():
                LOG.error("%s loads slot %d, which is not staged: copy "
                          "tests/fixtures/saves/_%d_.sav to Work/Saves2/",
                          name, slot, slot)
                status = 1
                continue
            plan = body_aim_plan(name)
        elif name == "deaths_state":
            plan = deaths_state_plan()
        elif name in crush_wall_sites():
            mission, slot, _x, _y = crush_wall_sites()[name]
            slot_file = game_copy / "Work" / "Saves2" / f"_{slot}_.sav"
            if not slot_file.is_file():
                LOG.error(
                    "%s loads slot %d, which is not staged. Build it:\n"
                    "  python3 tools/sav_parse.py "
                    "tests/fixtures/saves/_6_.sav --wrap "
                    "gog_incubation/Missions/%s.lev --out %s\n"
                    "It is one of the three missions that call CrushWall "
                    "(docs/42 section 8.2).",
                    name, slot, mission, slot_file)
                status = 1
                continue
            plan = crush_wall_plan(name)
        elif name in SPECIAL_D00_CALLS:
            slot_file = (game_copy / "Work" / "Saves2"
                         / f"_{SPECIAL_D00_SLOT}_.sav")
            if not slot_file.is_file():
                LOG.error(
                    "%s loads slot %d, which is not staged. Build it:\n"
                    "  python3 tools/sav_parse.py "
                    "tests/fixtures/saves/_6_.sav --wrap "
                    "gog_incubation/Missions/_C_116.lev --out %s\n"
                    "It is a `World_D00` mission, the one world set with "
                    "GLOW1/2.3DI (docs/97 §38.1).",
                    name, SPECIAL_D00_SLOT, slot_file)
                status = 1
                continue
            state = (phases.get("deaths_state") or {}).get("rows")
            plan = special_plan(name, death_tiles(state) if state else {})
        elif name in SPECIAL_CALLS:
            state = (phases.get("deaths_state") or {}).get("rows")
            if not state:
                LOG.error("%s needs the deaths_state phase first", name)
                status = 1
                continue
            plan = special_plan(name, death_tiles(state))
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
            rows = gold.run_plan(game_copy, dbgcall, plan, f"pres_{name}", attempts=attempts,
                                 call_timeout_ms=call_timeout)
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
    parser.add_argument("--emit-death-cases", metavar="PATH", type=Path,
                        help="write the death creators' cases for the Godot suite")
    parser.add_argument("--emit-idle-cases", metavar="PATH", type=Path,
                        help="write the idle scheduler's cases for the Godot suite")
    parser.add_argument("--emit-special-cases", metavar="PATH", type=Path,
                        help="write the cell placers' cases for the Godot suite")
    parser.add_argument("--emit-aim-cases", metavar="PATH", type=Path,
                        help="write the body-aim cases test_charisma.gd replays")
    parser.add_argument("--root", default="gog_incubation",
                        help="game root for --emit-death-cases")
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
        elif args.print_plan in BODY_AIM_CASES:
            sys.stdout.write(body_aim_plan(args.print_plan))
        else:
            parser.error("a death plan is rendered from the deaths_state phase; "
                         "take that phase and read the copy's pres_death_*.plan")
        return 0
    if args.emit_death_cases:
        return emit_death_cases(args.out, args.root, args.emit_death_cases)
    if args.emit_idle_cases:
        return emit_idle_cases(args.out, args.root, args.emit_idle_cases)
    if args.emit_special_cases:
        return emit_special_cases(args.out, args.root, args.emit_special_cases)
    if args.emit_aim_cases:
        return emit_aim_cases(args.out, args.emit_aim_cases)
    if args.check:
        return check(args.out, args.check)
    if args.game_copy is None or args.dbgcall is None:
        parser.error("--game-copy and --dbgcall are required for a capture")
    repo = Path(__file__).resolve().parent.parent
    copy = args.game_copy.resolve()
    if is_within(copy, repo):
        parser.error(f"{copy} is inside this repository; the capture must "
                     "run against a copy of the game")
    return capture(args.game_copy, args.dbgcall, args.out, args.attempts, args.phase)


if __name__ == "__main__":
    sys.exit(main())
