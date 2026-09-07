"""Parser for Incubation .lev battle-map (mission) files.

Layout
------
A .lev file is a straight `fwrite` dump of the editor's in-memory battle map.
The writer is `aSaveBattleMap` in `aBattleMap.cpp`; disassembly of iDesigner.exe
(fcn.00410260) shows it emits exactly five blocks, in this order:

    offset                     size            written by
    ------------------------------------------------------------------
    0                          864 (0x360)     aWriteFile(header)
    864                        23 * W * H      aSaveCtrlMap
    864 + 23*W*H               18200 (0x4718)  aSaveUnitMap
    ... + 18200                724   (0x2D4)   aSave3DObjects, block 1
    ... + 724                  9900  (0x26AC)  aSave3DObjects, block 2
    ... + 9900                 175000(0x2AB98) aSave3DObjects, block 3

The cell stride of 23 is computed in the binary as `(idx*24) - idx`; the two
3D-object array strides are `idx*66` and `idx*70`, giving 150 and 2500 slots
respectively. The unit array is 200 slots of 91 bytes.

Because everything but the cell grid is fixed size, the file size is fully
determined by the map dimensions:

    size = 864 + 23*W*H + 203824

This holds for all 155 shipped .lev files.

Blocks are raw structs, so uninitialised padding (MSVC's 0xCD fill) is visible
inside them; parsers must not treat those bytes as meaningful.  In particular
the two object arrays are *not* self-terminating: the authoritative element
counts live in block 1 (`+0x288` land objects, `+0x28C` special objects), and
the bytes past those counts are stale records left over from earlier edits.

See `docs/10-lev-mission-format.md` for the field-by-field derivation.
"""

from __future__ import annotations

import logging
import struct
from dataclasses import dataclass, field

LOG = logging.getLogger(__name__)

HEADER_SIZE = 864
CELL_SIZE = 23
UNIT_SIZE = 91
UNIT_SLOTS = 200
UNIT_BLOCK_SIZE = UNIT_SIZE * UNIT_SLOTS          # 18200
OBJ_HEADER_SIZE = 724                             # aSave3DObjects block 1
SPECIAL_OBJ_SIZE = 66                             # aSave3DObjects block 2 stride
SPECIAL_OBJ_SLOTS = 150
LAND_OBJ_SIZE = 70                                # aSave3DObjects block 3 stride
LAND_OBJ_SLOTS = 2500
TAIL_SIZE = (UNIT_BLOCK_SIZE + OBJ_HEADER_SIZE
             + SPECIAL_OBJ_SIZE * SPECIAL_OBJ_SLOTS
             + LAND_OBJ_SIZE * LAND_OBJ_SLOTS)    # 203824

# ---------------------------------------------------------------------------
# Header field offsets.
#
# The editor reads and writes these through one-line accessor functions in
# aBattleMap.cpp (iDesigner.exe 0x410760..0x410880); the offsets below are the
# addresses those accessors touch, relative to the header base 0x4AF030.
# ---------------------------------------------------------------------------
OFF_NEXT_MAP = 0x000        # NUL-terminated, name of the mission to load next
OFF_MAP_NAME = 0x105        # NUL-terminated, this mission's own name
OFF_EQUIP_POINTS = 0x20A    # u32[4], equipment points per player
OFF_SKILL_LEVEL = 0x21A     # u32, "Skills [0,12]"
OFF_TECH_LEVEL = 0x21E      # u32, "Techlevel [0,9]"
OFF_MAP_TYPE = 0x222        # u8, see MAP_TYPE_NAMES
OFF_MISSION_ID = 0x223      # u8, campaign mission number
OFF_CAMERA_HEIGHT = 0x224   # u32, world units; the dialog edits metres * 1600
OFF_WORLD_SCENE = 0x244     # NUL-terminated, the .3DW scene, e.g. "Level01e"
OFF_WORLD_SET = 0x349       # NUL-terminated, the WorldSet folder, e.g. "A00"
OFF_LCL_SLOT = 0x353        # u32, runtime LCL program slot - not map data
OFF_HEIGHT = 0x357          # u32, number of rows
OFF_WIDTH = 0x35B           # u32, number of columns
OFF_TRAILING_BYTE = 0x35F   # u8, default 'a'; the only reader discards it

# Block 1 (the 724-byte "3D object header") field offsets.
OFF_B1_RING_ACTIVE = 0x000  # u32, 1 while the deployment ring below is placed
OFF_B1_RECORDS = 0x004      # 10 x 64-byte 3D-object records: the deployment ring
OFF_B1_LAND_COUNT = 0x288   # u32, number of valid records in block 3
OFF_B1_SPECIAL_COUNT = 0x28C  # u32, number of valid records in block 2
OFF_B1_CLONE_COUNT = 0x290  # u32, number of .3DW clones loaded (array not saved)
OFF_B1_MARKER = 0x294       # one more 64-byte 3D-object record: the CLS.3DI marker
B1_RECORD_SIZE = 64
B1_RECORD_COUNT = 10

MARKER_PARK_Z = -1600000
"""z the engine gives the `CLS.3DI` marker object in block 1 when it is not in
use: exactly -1000 m at 1600 world units per metre (Incubation.exe 0x407099
stores the literal 0xFFE79600)."""

NO_UNIT = 0xFFFF
"""Value of a cell's unit link when the field is empty."""

NO_LINK = 0xFF
"""Value of a cell's runtime object links / effect state when idle."""

WORLD_UNITS_PER_FIELD = 3200
"""World-space size of one map field, in the engine's integer units."""

WORLD_UNITS_PER_METRE = 1600
"""From the editor's "camera height (meter)" control, which stores value*1600."""

ANGLE_FULL_TURN = 4096
"""Engine rotation unit: a full turn is 4096, so 1024 == 90 degrees."""

UNINIT_FILL = 0xCDCDCDCD
"""MSVC debug heap fill. Marks stale records past the authoritative counts."""

MAP_TYPE_NAMES = {
    1: "Campaign",
    2: "Single",
    3: "Multi",
    4: "Special",
    5: "COOP",
}
"""Header +0x222. Names from the editor's "Edit levelstruct" radio buttons
(dialog 120, controls 1397/1398/1399/1380/1381)."""

FIELD_TYPE_NAMES = {
    0: "Undefined",
    1: "Free Place",
    2: "Wall",
    3: "Hole",
    4: "Deep Hole",
    5: "Debris",
    6: "Poison",
    7: "Enormous Obs",
    8: "Ladder",
    9: "Teleporter Entry",
    10: "Teleporter Exit",
}
"""Cell +0x0D. Names come from the shipped `DATA/Info.lcl` `SetCtrlMapInfo`
table, which is the very table the engine indexes with this byte."""

FACING_ANGLES = {0: 0, 1: 3072, 2: 2048, 3: 1024, 4: 1536,
                 5: 3584, 6: 512, 7: 2560}
"""Unit +0x46 -> rotation, from Incubation.exe fcn.0046a6e0 (4096 = 360 deg)."""

FACING_STEPS = {0: (0, 1), 6: (1, 1), 3: (1, 0), 4: (1, -1),
                2: (0, -1), 7: (-1, -1), 1: (-1, 0), 5: (-1, 1)}
"""Unit +0x46 -> the cell step in front of it.

Derived from :data:`FACING_ANGLES` by taking **0 degrees as +y** and the angle
as growing toward +x, and then confirmed natively: `tools/turn_gold.py` phase 9
sweeps all eight facings of a unit standing on the top row and calls
``aExecuteUse``.  The three that this table gives a ``-y`` component -- 2, 4
and 7 -- are exactly the three the engine answers ``0`` for, because
``CellInFront`` runs off the map; and facing 3, the one this table sends to
``+x``, is the only one that reaches and consumes an action point written into
the cell to the east.  Eight of eight.

``FACING_ANGLES`` alone does not say which way 0 degrees points, so this is the
half that had to be measured rather than read.
"""

AI_ORDER_NAMES = {
    0: "Berserk",
    1: "Move (ActPt)",
    2: "Attack (ActPt)",
    3: "Move (Group)",
    4: "Attack (Group)",
    5: "Turn (Wait)",
    6: "Range (Wait)",
    7: "Defend",
    8: "Visibility (Wait)",
    9: "Clever small units",
    10: "Disturb",
}
"""Unit +0x47 / +0x49.  Names are the strings the editor's unit dialog puts in
its "Primary Order" / "Secondary Order" list boxes (iDesigner.exe fcn.00430070,
controls 1287/1288); the engine's AI turn loop switches on the same byte
(Incubation.exe fcn.00409940, `switch (unit[0x47])`)."""

SPEECH_NAMES = {
    0: "undefined",
    1: "normal_1",
    2: "normal_2",
    3: "cool_1",
    4: "mimosa_1",
    5: "rambo_1",
    6: "rambo_2",
    7: "female_1",
    8: "undefined",
    9: "undefined",
    10: "hero_1",
    11: "female_2",
    12: "spidy",
}
"""Unit +0x55.  The editor's "Select Speech" list box (iDesigner.exe
fcn.004304c0, control 1470); the engine switches on the same byte to pick the
voice sample set (Incubation.exe fcn.0047b6xx)."""

EQUIPMENT_NAMES = {
    0: "Scan Module",
    1: "Long Range Scan",
    3: "Light Stimulant",
    4: "Heavy Stimulant",
    5: "Target System",
    6: "Ammo Pack",
    7: "Jet Pack",
    8: "Banner",
    9: "Explosion Pack",
    10: "Light Armor",
    11: "Standard Armor",
    12: "Attack Armor",
    13: "Heavy Armor",
    14: "Servo System",
    15: "Small Medic Kit",
    16: "Large Medic Kit",
    17: "Hydraulic Crowbar",
    18: "Damage Absorber",
    19: "Cooler",
}
"""Unit +0x21..+0x35 index -> equipment name, from the shipped `DATA/Info.lcl`
`SetEquipInfo` table.  Ids 2 and 20 are not defined by the shipped file and are
never set in any shipped map."""

SKILL_NAMES = ("CON", "LW", "HW", "TS", "MS", "LS")
"""Unit +0x1A..+0x1F, in memory order.  Short names are the editor's own labels
(dialog 112: CON/LWS/HWS/TS/MS); the game's UI spells them out as
Battle Fitness / Light Weapon Proficiency / Heavy Weapon Proficiency /
Technical Skills / Medical Skills / Leadership Skills (GUI text 160..165)."""

EQUIPMENT_SLOTS = 21
"""Length of the per-unit equipment array; the editor fills its list box from
21 `SetEquipInfo` records (iDesigner.exe fcn.004302f0)."""

UNIT_POOL_NONE = 0
UNIT_POOL_CANDIDATE = 1
UNIT_POOL_HERO = 2
"""Unit +0x4D.  The editor's two check boxes write 1 for "Unitpool candidate"
and 2 for "Hero" (iDesigner.exe fcn.0042fae0, controls 1374/1396); the engine
only tests the byte for non-zero."""

VISIBILITY_VISIBLE = 0
VISIBILITY_SCANNED = 1
VISIBILITY_HIDDEN = 3
"""Unit +0x4F, written by Incubation.exe fcn.00479370 together with the unit's
3D-object visibility flag.  Runtime state, recomputed on every line-of-sight
pass, so the shipped values are residue."""


class LevError(Exception):
    """Raised when a .lev file does not match the documented layout."""


@dataclass(frozen=True)
class Cell:
    """One battle-map field (23 bytes).

    Field semantics were recovered from the engine's own CtrlMap module
    (`aInitCtrlMap` fcn.0042ec20 writes every byte of a fresh record).
    """

    index: int
    x: int
    y: int
    height: int          # +0x01 i32, world units; equals the land object's z
    land: int            # +0x05 u16, index into the land-object array
    unit: int | None     # +0x07 i16, index into the unit array, None when empty
    action_point: int    # +0x0B u8, LCL action-point id, 0 = none
    field_type: int      # +0x0D u8, see FIELD_TYPE_NAMES
    effect_timer: int    # +0x0E u8, runtime countdown
    effect_object: int   # +0x0F u8, runtime dynamic-object slot, 0xFF = none
    effect_state: int    # +0x10 u8, runtime state, 0xFF = idle
    decal_object: int    # +0x11 u8, runtime dynamic-object slot, 0xFF = none
    decal_flag: int      # +0x12 u8, runtime state
    decal_state: int     # +0x13 u8, runtime state, 0xFF = idle
    start_index: int     # +0x14 u8, deployment-field ordinal, 0xFF = not one
                         #   (set on cells whose action point is 80..85, the
                         #   band the game's own legend calls "Victorypoints
                         #   (only Multiplayer)" -- see docs/10 4.2 and 4.6)
    raw: bytes

    @property
    def field_type_name(self) -> str:
        return FIELD_TYPE_NAMES.get(self.field_type, f"type {self.field_type}")

    @property
    def is_start_field(self) -> bool:
        return self.start_index != NO_LINK


@dataclass(frozen=True)
class Unit:
    """One unit slot (91 bytes).

    A slot holds a unit that is actually placed on the map when `hit_points`
    is non-zero; that is exactly the test the engine's `GetUnits` command uses
    (`fcn.00477bf0`).  A slot may carry a leftover name with zero hit points,
    in which case no cell links to it.
    """

    slot: int
    name: str
    x: int               # +0x42 u8
    y: int               # +0x43 u8
    unit_id: int         # +0x44 u8, matches the slot index in shipped data
    type_id: int         # +0x4C u8, index into Info.lcl's SetUnitInfo table
    player: int          # +0x45 u8, 0..3 human, 252 neutral prop, 255 alien
    hit_points: int      # +0x16 u8, "HP"; 0 = slot not placed
    action_points: int   # +0x15 u8, "MP" - remaining movement/action points
    ep: int              # +0x17 u8, "EP" - experience points, rank = EP // 12
    tp: int              # +0x18 u8, "TP" - skill-point pool, 12 per skill point
    fp: int              # +0x19 u8, "FP"; 0 -> 1 AP, 1 -> 2 AP (fcn.00475160)
    skills: tuple[int, ...]      # +0x1A..+0x1F, see SKILL_NAMES
    equipment: tuple[int, ...]   # +0x21..+0x35, 21 x 0/1, see EQUIPMENT_NAMES
    absorb: int          # +0x3A u8, damage absorption from equipment 18
    armour_front: int    # +0x36 u8, cached; recomputed by fcn.00475490
    armour_rear: int     # +0x37 u8, cached; recomputed by fcn.004754F0
    ammo: int            # +0x3D u8, rounds left in the magazine
    weapon: int          # +0x3F u8, index into Info.lcl's SetWeaponInfo table
    facing: int          # +0x46 u8, 0..7, see FACING_ANGLES
    order: int           # +0x47 u8, primary AI order, see AI_ORDER_NAMES
    order_param: int     # +0x48 u8, its parameter (order-specific)
    order2: int          # +0x49 u8, secondary AI order
    order2_param: int    # +0x4A u8, its parameter
    object_slot: int     # +0x4B u8, runtime 3D-object slot
    pool_flag: int       # +0x4D u8, 0 none / 1 unit-pool candidate / 2 hero
    group: int           # +0x4E u8, AI group id
    visibility: int      # +0x4F u8, runtime, see VISIBILITY_*
    walked: int          # +0x50 u8, distance walked this turn, tenths of a field
    turn_start_x: int    # +0x51 u8, x at the start of the current turn
    turn_start_y: int    # +0x52 u8, y at the start of the current turn
    speech: int          # +0x55 u8, voice sample set, see SPEECH_NAMES
    sound_channel: int   # +0x56 u8, runtime sound-channel back-reference
    stimulant: int       # +0x58 u8, 1 Light Stimulant, 2 Heavy Stimulant
    ticket: int          # +0x59 u8, reaction ticket, per-player sequence number
    raw: bytes

    @property
    def action_state(self) -> int:
        """``+0x41`` -- runtime action state.

        5 and 6 zero the movement allowance and 7 means "stood down without
        acting" (docs/10 §5.5).  Zero in every shipped record, which is why it
        is read off ``raw`` rather than carried as a field.
        """
        return self.raw[0x41]

    @property
    def rested(self) -> int:
        """``+0x57`` -- "did not act last turn"; the allowance adds one at 1."""
        return self.raw[0x57]

    @property
    def acted(self) -> int:
        """``+0x39`` -- "this unit has acted", 3 after the AI fires or uses.

        Read by ``aAISystemControl``'s epilogue and cleared by the stat
        recompute (docs/10 §5).  Zero in every shipped record, which is why it
        is read off ``raw`` rather than carried as a field.
        """
        return self.raw[0x39]

    @property
    def heat(self) -> int:
        """``+0x3E`` -- weapon heat; the overheat roll fires at the cap.

        Zero in every shipped record (docs/10 §5.12).
        """
        return self.raw[0x3E]

    @property
    def malfunction(self) -> int:
        """``+0x40`` -- 0 none, 2 or 5 jammed; non-zero blocks firing.

        Zero in every shipped record (docs/10 §5.12).
        """
        return self.raw[0x40]

    @property
    def placed(self) -> bool:
        return bool(self.name) and self.hit_points != 0

    @property
    def facing_angle(self) -> int:
        return FACING_ANGLES.get(self.facing, 0)

    @property
    def rank(self) -> int:
        """Promotion rank; the engine computes it as EP // 12 (fcn.00475120)."""
        return self.ep // 12

    @property
    def equipment_ids(self) -> tuple[int, ...]:
        """Indices of the SetEquipInfo entries this unit carries."""
        return tuple(i for i, v in enumerate(self.equipment) if v)

    @property
    def equipment_names(self) -> tuple[str, ...]:
        return tuple(EQUIPMENT_NAMES.get(i, f"equipment {i}")
                     for i in self.equipment_ids)

    @property
    def order_name(self) -> str:
        return AI_ORDER_NAMES.get(self.order, f"order {self.order}")

    @property
    def order2_name(self) -> str:
        return AI_ORDER_NAMES.get(self.order2, f"order {self.order2}")

    @property
    def speech_name(self) -> str:
        return SPEECH_NAMES.get(self.speech, f"speech {self.speech}")

    @property
    def skill_map(self) -> dict[str, int]:
        return dict(zip(SKILL_NAMES, self.skills))


@dataclass(frozen=True)
class Object3D:
    """A 64/66/70-byte 3D-object record.

    All three object blocks share the same prefix layout, which is how the
    engine's `aAdd*` helpers write them (fcn.00404ae0, fcn.00404f80).
    """

    slot: int
    prototype: int       # +0x08 u32, runtime index into the world set's prototyp.din
    x: int               # +0x10 i32, world units
    y: int               # +0x14 i32, world units
    z: int               # +0x18 i32, world units
    rotation: tuple[int, int, int]   # +0x20/+0x22/+0x24 u16, 4096 = 360 deg
    raw: bytes
    #: +0x26..+0x2A and +0x2C..+0x30, i16: the joint angles of the prototype's
    #: parts 6 and 12 (docs/28 §7.2).  Authored: a door's two leaves stand at
    #: (0, 0, -1000) / (0, 0, 1000) when it ships open, and `aDoorOpenSequence`
    #: writes exactly those (docs/26 §3.4).  Zero in every land and scene
    #: record, so only the special objects carry them into the cache.
    joints: tuple[tuple[int, int, int], tuple[int, int, int]]


@dataclass(frozen=True)
class LandObject(Object3D):
    """One entry of the 3D ground lattice (70 bytes), one per battle-map field.

    `grid_x`/`grid_y` are stored explicitly at +0x44/+0x45 and always equal
    `x // 3200` / `y // 3200`.
    """

    active: int          # +0x40 u32, always 1
    grid_x: int          # +0x44 u8
    grid_y: int          # +0x45 u8


@dataclass(frozen=True)
class SpecialObject(Object3D):
    """One entry of the "special" object array (66 bytes).

    Unlike the land lattice these records name their prototype symbolically:
    the engine rebuilds `prototype` on load from the two bytes at +0x40/+0x41
    (`aLoadBattleMap` -> fcn.00404d30 -> fcn.00407540), so the stored
    `prototype` value is stale runtime state and `prototype_name` is the
    authoritative identity.
    """

    kind: int            # +0x40 u8, the letter in the prototype name ('E')
    number: int          # +0x41 u8, the number in the prototype name

    def prototype_name(self, world_set: str) -> str:
        """Rebuild the `.3DI` prototype name, as fcn.00407540 does."""
        if 100 <= self.number <= 129:
            return f"L{self.number:03d}EX00.3DI"
        return f"L{self.number:03d}{chr(self.kind)}{world_set}.3DI"


@dataclass
class BattleMap:
    """A parsed .lev file."""

    path: str
    next_map: str
    map_name: str
    world_scene: str
    world_set: str
    width: int
    height: int
    cells: list[Cell]
    units: list[Unit]
    # Header fields.
    map_type: int = 0
    mission_id: int = 0
    equip_points: tuple[int, int, int, int] = (0, 0, 0, 0)
    skill_level: int = 0
    tech_level: int = 0
    camera_height: int = 0
    lcl_slot: int = 0
    # Object blocks.
    land: list[LandObject] = field(repr=False, default_factory=list)
    special: list[SpecialObject] = field(repr=False, default_factory=list)
    clone_count: int = 0
    ring_active: int = 0
    scene_objects: list[Object3D] = field(repr=False, default_factory=list)
    marker_object: Object3D | None = field(repr=False, default=None)
    header: bytes = field(repr=False, default=b"")
    object_header: bytes = field(repr=False, default=b"")
    special_objects: bytes = field(repr=False, default=b"")
    land_objects: bytes = field(repr=False, default=b"")

    def cell_at(self, x: int, y: int) -> Cell:
        return self.cells[y * self.width + x]

    @property
    def active_units(self) -> list[Unit]:
        return [u for u in self.units if u.name]

    @property
    def placed_units(self) -> list[Unit]:
        return [u for u in self.units if u.placed]

    @property
    def map_type_name(self) -> str:
        return MAP_TYPE_NAMES.get(self.map_type, f"type {self.map_type}")

    @property
    def camera_height_m(self) -> float:
        return self.camera_height / WORLD_UNITS_PER_METRE

    @property
    def start_fields(self) -> list[Cell]:
        """Deployment fields, in the order the engine numbered them."""
        return sorted((c for c in self.cells if c.is_start_field),
                      key=lambda c: c.start_index)


def _cstring(data: bytes, offset: int, limit: int = 64) -> str:
    end = data.find(b"\x00", offset, offset + limit)
    if end < 0:
        end = offset + limit
    return data[offset:end].decode("cp1252", errors="replace")


def _parse_cell(raw: bytes, expected_index: int, width: int) -> Cell:
    index = struct.unpack_from("<H", raw, 0x05)[0]
    if index != expected_index:
        raise LevError(f"cell {expected_index} stores index {index}")
    unit = struct.unpack_from("<H", raw, 0x07)[0]
    x, y = raw[0x09], raw[0x0A]
    if y * width + x != expected_index:
        raise LevError(f"cell {expected_index} stores coordinates ({x},{y})")
    return Cell(
        index=index, x=x, y=y,
        height=struct.unpack_from("<i", raw, 0x01)[0],
        land=index,
        unit=None if unit == NO_UNIT else unit,
        action_point=raw[0x0B],
        field_type=raw[0x0D],
        effect_timer=raw[0x0E],
        effect_object=raw[0x0F],
        effect_state=raw[0x10],
        decal_object=raw[0x11],
        decal_flag=raw[0x12],
        decal_state=raw[0x13],
        start_index=raw[0x14],
        raw=raw,
    )


def _parse_unit(raw: bytes, slot: int) -> Unit:
    return Unit(
        slot=slot,
        name=_cstring(raw, 0, 20),
        x=raw[0x42], y=raw[0x43],
        unit_id=raw[0x44],
        type_id=raw[0x4C],
        player=raw[0x45],
        hit_points=raw[0x16],
        action_points=raw[0x15],
        ep=raw[0x17],
        tp=raw[0x18],
        fp=raw[0x19],
        skills=tuple(raw[0x1A:0x20]),
        equipment=tuple(raw[0x21:0x21 + EQUIPMENT_SLOTS]),
        absorb=raw[0x3A],
        armour_front=raw[0x36],
        armour_rear=raw[0x37],
        ammo=raw[0x3D],
        weapon=raw[0x3F],
        facing=raw[0x46],
        order=raw[0x47],
        order_param=raw[0x48],
        order2=raw[0x49],
        order2_param=raw[0x4A],
        object_slot=raw[0x4B],
        pool_flag=raw[0x4D],
        group=raw[0x4E],
        visibility=raw[0x4F],
        walked=raw[0x50],
        turn_start_x=raw[0x51],
        turn_start_y=raw[0x52],
        speech=raw[0x55],
        sound_channel=raw[0x56],
        stimulant=raw[0x58],
        ticket=raw[0x59],
        raw=raw,
    )


def _obj_common(raw: bytes) -> tuple[int, int, int, int, tuple[int, int, int]]:
    prototype = struct.unpack_from("<I", raw, 0x08)[0]
    x, y, z = struct.unpack_from("<3i", raw, 0x10)
    rot = struct.unpack_from("<3H", raw, 0x20)
    return prototype, x, y, z, rot


OFF_JOINTS = 0x26


def _obj_joints(raw: bytes) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    """The two joint triples at +0x26 and +0x2C (docs/28 §7.2)."""
    words = struct.unpack_from("<6h", raw, OFF_JOINTS)
    return (words[0], words[1], words[2]), (words[3], words[4], words[5])


def _parse_land(block: bytes, count: int) -> list[LandObject]:
    out: list[LandObject] = []
    for slot in range(min(count, LAND_OBJ_SLOTS)):
        raw = block[slot * LAND_OBJ_SIZE:(slot + 1) * LAND_OBJ_SIZE]
        prototype, x, y, z, rot = _obj_common(raw)
        out.append(LandObject(
            slot=slot, prototype=prototype, x=x, y=y, z=z, rotation=rot,
            joints=_obj_joints(raw),
            active=struct.unpack_from("<I", raw, 0x40)[0],
            grid_x=raw[0x44], grid_y=raw[0x45],
            raw=raw,
        ))
    return out


def _parse_special(block: bytes, count: int) -> list[SpecialObject]:
    out: list[SpecialObject] = []
    for slot in range(min(count, SPECIAL_OBJ_SLOTS)):
        raw = block[slot * SPECIAL_OBJ_SIZE:(slot + 1) * SPECIAL_OBJ_SIZE]
        prototype, x, y, z, rot = _obj_common(raw)
        out.append(SpecialObject(
            slot=slot, prototype=prototype, x=x, y=y, z=z, rotation=rot,
            kind=raw[0x40], number=raw[0x41],
            raw=raw, joints=_obj_joints(raw),
        ))
    return out


def _parse_scene_objects(block: bytes) -> list[Object3D]:
    out: list[Object3D] = []
    for slot in range(B1_RECORD_COUNT):
        start = OFF_B1_RECORDS + slot * B1_RECORD_SIZE
        raw = block[start:start + B1_RECORD_SIZE]
        prototype, x, y, z, rot = _obj_common(raw)
        out.append(Object3D(slot=slot, prototype=prototype,
                            x=x, y=y, z=z, rotation=rot, raw=raw,
                            joints=_obj_joints(raw)))
    return out


def _parse_marker(block: bytes) -> Object3D:
    """Block 1's eleventh 3D-object record, the `CLS.3DI` selection marker."""
    raw = block[OFF_B1_MARKER:OFF_B1_MARKER + B1_RECORD_SIZE]
    prototype, x, y, z, rot = _obj_common(raw)
    return Object3D(slot=B1_RECORD_COUNT, prototype=prototype,
                    x=x, y=y, z=z, rotation=rot, raw=raw,
                    joints=_obj_joints(raw))


def parse_lev(data: bytes, path: str = "<memory>") -> BattleMap:
    """Parse a .lev buffer into a BattleMap."""
    if len(data) < HEADER_SIZE + TAIL_SIZE:
        raise LevError(f"file too short: {len(data)} bytes")

    height = struct.unpack_from("<I", data, OFF_HEIGHT)[0]
    width = struct.unpack_from("<I", data, OFF_WIDTH)[0]
    expected = HEADER_SIZE + CELL_SIZE * width * height + TAIL_SIZE
    if expected != len(data):
        raise LevError(f"size {len(data)} does not match {width}x{height} "
                       f"(expected {expected})")

    cells: list[Cell] = []
    for i in range(width * height):
        start = HEADER_SIZE + i * CELL_SIZE
        cells.append(_parse_cell(data[start:start + CELL_SIZE], i, width))

    unit_base = HEADER_SIZE + CELL_SIZE * width * height
    units = [_parse_unit(data[unit_base + s * UNIT_SIZE:
                              unit_base + (s + 1) * UNIT_SIZE], s)
             for s in range(UNIT_SLOTS)]

    obj_base = unit_base + UNIT_BLOCK_SIZE
    special_base = obj_base + OBJ_HEADER_SIZE
    land_base = special_base + SPECIAL_OBJ_SIZE * SPECIAL_OBJ_SLOTS

    object_header = data[obj_base:special_base]
    land_count, special_count, clone_count = struct.unpack_from(
        "<3I", object_header, OFF_B1_LAND_COUNT)
    if land_count > LAND_OBJ_SLOTS:
        raise LevError(f"land object count {land_count} exceeds {LAND_OBJ_SLOTS}")
    if special_count > SPECIAL_OBJ_SLOTS:
        raise LevError(f"special object count {special_count} exceeds "
                       f"{SPECIAL_OBJ_SLOTS}")

    special_block = data[special_base:land_base]
    land_block = data[land_base:land_base + LAND_OBJ_SIZE * LAND_OBJ_SLOTS]

    return BattleMap(
        path=path,
        next_map=_cstring(data, OFF_NEXT_MAP),
        map_name=_cstring(data, OFF_MAP_NAME),
        world_scene=_cstring(data, OFF_WORLD_SCENE),
        world_set=_cstring(data, OFF_WORLD_SET),
        width=width, height=height,
        cells=cells, units=units,
        map_type=data[OFF_MAP_TYPE],
        mission_id=data[OFF_MISSION_ID],
        equip_points=struct.unpack_from("<4I", data, OFF_EQUIP_POINTS),
        skill_level=struct.unpack_from("<I", data, OFF_SKILL_LEVEL)[0],
        tech_level=struct.unpack_from("<I", data, OFF_TECH_LEVEL)[0],
        camera_height=struct.unpack_from("<I", data, OFF_CAMERA_HEIGHT)[0],
        lcl_slot=struct.unpack_from("<I", data, OFF_LCL_SLOT)[0],
        land=_parse_land(land_block, land_count),
        special=_parse_special(special_block, special_count),
        clone_count=clone_count,
        ring_active=struct.unpack_from("<I", object_header, OFF_B1_RING_ACTIVE)[0],
        scene_objects=_parse_scene_objects(object_header),
        marker_object=_parse_marker(object_header),
        header=data[:HEADER_SIZE],
        object_header=object_header,
        special_objects=special_block,
        land_objects=land_block,
    )


def load_lev(path: str) -> BattleMap:
    with open(path, "rb") as fh:
        return parse_lev(fh.read(), path)
