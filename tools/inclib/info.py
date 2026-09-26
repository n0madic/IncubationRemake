"""``DATA/Info.lcl`` balance tables as typed records.

``docs/21`` recovers five ``Set*Info`` commands as fixed-stride records the
loader writes into static tables.  This module reads the ``.lcl`` program with
:mod:`inclib.lcl` and applies the *loader's* rules rather than the file's textual
order, because the two differ in three ways that matter:

* an out-of-range index is reported and the statement dropped (``docs/21`` §1);
* **the first definition of an id wins** -- ``SetUnitInfo``, ``SetEquipInfo``
  and ``SetWeaponInfo`` refuse to overwrite a record whose in-use byte is set,
  so a duplicate line is silently ignored;
* ``SetWeaponInfo2`` patches a record ``SetWeaponInfo`` already created, and
  its 9-byte wave-name field overruns into ``range min`` for eight shipped
  weapons (``docs/21`` §4).

The emitted tables therefore describe **what is in memory after the load**, not
what the text says.  For the eight affected weapons ``range_min`` is 0 while the
source line reads 1; ``range_min_authored`` keeps the file's value so the
difference stays visible instead of looking like a parse bug.

Everything here is integers and strings.  No float ever enters the balance
tables, which is what lets the converted cache be compared byte for byte.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any

from . import lcl


class InfoError(Exception):
    """Raised when ``Info.lcl`` cannot be read as the balance tables."""


#: Relative path of the balance file inside a game installation.
INFO_REL_PATH = os.path.join("DATA", "Info.lcl")

#: Highest valid index of each table, from ``docs/21`` §1.  A statement whose
#: index is outside ``0..max`` is dropped by the loader.
MAX_INDEX = {
    "SetCtrlMapInfo": 10,
    "SetEquipInfo": 20,
    "SetWeaponInfo": 50,
    "SetUnitInfo": 100,
}

#: ``docs/21`` §2 -- 255 in the ``delay`` column means the field is not
#: enterable at all, tested before the height rule in ``aBuildMoveMap``.
DELAY_IMPASSABLE = 255

#: ``docs/21`` §5 -- ``unitinfo[+0x7c]`` counts levels of this many world units.
HEIGHT_UNIT = 160

#: ``docs/21`` §4 -- ``SetWeaponInfo2`` copies ``strlen(name) + 1`` bytes to
#: +0x25 and ``range min`` begins at +0x2e, so a wave name of exactly this many
#: characters puts its terminating nul on ``range min``.
WAVE_NAME_OVERRUN_LENGTH = 9

#: The six skill columns, in the order ``Info.lcl`` heads them.
SKILL_NAMES = ("CON", "LW", "HW", "TS", "MS", "LS")


@dataclass(frozen=True)
class CtrlMapType:
    """One ``SetCtrlMapInfo`` record -- a control-map cell type."""

    index: int
    type: int
    delay: int
    cover: int
    name: str

    @property
    def is_enterable(self) -> bool:
        """``delay != 255``; the test ``aBuildMoveMap`` makes first."""
        return self.delay != DELAY_IMPASSABLE

    def to_dict(self) -> dict[str, Any]:
        return {
            "index": self.index,
            "type": self.type,
            "delay": self.delay,
            "cover": self.cover,
            "name": self.name,
        }


@dataclass(frozen=True)
class EquipmentType:
    """One ``SetEquipInfo`` record."""

    id: int
    name: str
    cost: int
    skills: tuple[int, ...]
    tech: int
    key: str
    icon: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "cost": self.cost,
            "skills": dict(zip(SKILL_NAMES, self.skills)),
            "tech": self.tech,
            "key": self.key,
            "icon": self.icon,
        }


@dataclass(frozen=True)
class UnitType:
    """One ``SetUnitInfo`` record.

    Field names follow ``docs/21`` §5 exactly.  ``special`` is left as the raw
    enumerator: the values have no names in the binary, and inventing some is
    the kind of guess this project's rules forbid.
    """

    id: int
    description: str
    model: str
    player: int
    mp_max: int
    hp_max: int
    fp_max: int
    armour_front: int
    armour_rear: int
    weapon: int
    special: int
    species: int
    exp: int
    size: int
    height: int
    key: str

    @property
    def body_height_world(self) -> int:
        """``unitinfo[+0x7c] * 0xa0`` -- the unit's world height (``0x0047ad70``)."""
        return self.height * HEIGHT_UNIT

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "description": self.description,
            "model": self.model,
            "player": self.player,
            "mp_max": self.mp_max,
            "hp_max": self.hp_max,
            "fp_max": self.fp_max,
            "armour_front": self.armour_front,
            "armour_rear": self.armour_rear,
            "weapon": self.weapon,
            "special": self.special,
            "species": self.species,
            "exp": self.exp,
            "size": self.size,
            "height": self.height,
            "key": self.key,
        }


@dataclass
class WeaponType:
    """One weapon record, after both ``SetWeaponInfo`` and ``SetWeaponInfo2``."""

    id: int
    name: str
    range_min: int
    range_max: int
    hit: int
    damage: int
    def_mode: int
    skills: tuple[int, ...]
    ap: int
    type: int
    tech: int
    mun: int
    heat: int
    cost: int
    special: int
    param: int
    #: The value ``SetWeaponInfo`` wrote, before ``SetWeaponInfo2`` may have
    #: overwritten it with a wave name's terminating nul.
    range_min_authored: int = 0
    #: ``SetWeaponInfo`` sets the record's in-use byte.  A record created only
    #: by ``SetWeaponInfo2`` -- shipped id 35 is the one case -- stays 0 and
    #: carries nothing but that command's five fields.
    in_use: bool = True
    wave_name: str = ""
    toggle: int = 0
    mun_per_fight: int = 0
    icon: int = 0
    key: str = ""

    @property
    def wave_name_fills_range_min(self) -> bool:
        """True when the wave name's nul lands on ``range min`` (+0x2e)."""
        return len(self.wave_name) >= WAVE_NAME_OVERRUN_LENGTH

    @property
    def wave_name_overran_range_min(self) -> bool:
        """True only when the overrun actually changed the authored value."""
        return self.range_min != self.range_min_authored

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "in_use": self.in_use,
            "name": self.name,
            "range_min": self.range_min,
            "range_min_authored": self.range_min_authored,
            "range_max": self.range_max,
            "hit": self.hit,
            "damage": self.damage,
            "def_mode": self.def_mode,
            "skills": dict(zip(("LW", "HW", "TS", "CON"), self.skills)),
            "ap": self.ap,
            "type": self.type,
            "tech": self.tech,
            "mun": self.mun,
            "heat": self.heat,
            "cost": self.cost,
            "special": self.special,
            "param": self.param,
            "wave_name": self.wave_name,
            "toggle": self.toggle,
            "mun_per_fight": self.mun_per_fight,
            "icon": self.icon,
            "key": self.key,
        }


@dataclass
class BalanceTables:
    """Everything ``Info.lcl`` defines that the simulation reads."""

    path: str
    ctrlmap: dict[int, CtrlMapType] = field(default_factory=dict)
    equipment: dict[int, EquipmentType] = field(default_factory=dict)
    units: dict[int, UnitType] = field(default_factory=dict)
    weapons: dict[int, WeaponType] = field(default_factory=dict)
    #: Statements the loader would have dropped, as human-readable notes.
    dropped: list[str] = field(default_factory=list)

    def delay(self, field_type: int) -> int:
        """Movement ``delay`` of a control-map type; impassable when absent."""
        row = self.ctrlmap.get(field_type)
        return DELAY_IMPASSABLE if row is None else row.delay

    def delay_table(self) -> dict[int, int]:
        return {i: r.delay for i, r in sorted(self.ctrlmap.items())}

    def to_dict(self) -> dict[str, Any]:
        """The portable form written to ``tables/balance.json``.

        Lists rather than dictionaries, ordered by id, because a JSON object's
        keys would be strings and the cache must contain integers only.
        """
        return {
            "schema": "incubation.balance/1",
            "ctrlmap": [r.to_dict() for _, r in sorted(self.ctrlmap.items())],
            "equipment": [r.to_dict() for _, r in sorted(self.equipment.items())],
            "units": [r.to_dict() for _, r in sorted(self.units.items())],
            "weapons": [r.to_dict() for _, r in sorted(self.weapons.items())],
        }


def _nums(stmt: lcl.Statement) -> list[int]:
    return [a.value for a in stmt.args if a.kind == "number"]


def _strs(stmt: lcl.Statement) -> list[str]:
    return [a.value for a in stmt.args if a.kind == "string"]


def _first_char(values: list[str], index: int) -> str:
    """The loader stores only the first character of a key column."""
    if index >= len(values) or not values[index]:
        return ""
    return values[index][0]


def _in_range(table: str, index: int) -> bool:
    return 0 <= index <= MAX_INDEX[table]


def parse_program(program: lcl.Program, path: str) -> BalanceTables:
    """Apply the loader's rules to an already-parsed ``Info.lcl``."""
    tables = BalanceTables(path=path)
    for stmt in program.statements():
        handler = _HANDLERS.get(stmt.name)
        if handler is not None:
            handler(tables, stmt)
    return tables


def _load_ctrlmap(t: BalanceTables, stmt: lcl.Statement) -> None:
    nums, strs = _nums(stmt), _strs(stmt)
    if len(nums) < 4 or not strs:
        t.dropped.append(f"line {stmt.line}: SetCtrlMapInfo with {len(nums)} numbers")
        return
    index = nums[0]
    if not _in_range("SetCtrlMapInfo", index):
        t.dropped.append(f"line {stmt.line}: SetCtrlMapInfo index {index} out of range")
        return
    # SetCtrlMapInfo has no in-use guard: it overwrites.  docs/21 section 1
    # names the guard on the other three tables only.
    t.ctrlmap[index] = CtrlMapType(
        index=index, type=nums[1], delay=nums[2], cover=nums[3], name=strs[0])


def _load_equip(t: BalanceTables, stmt: lcl.Statement) -> None:
    nums, strs = _nums(stmt), _strs(stmt)
    if len(nums) < 10 or len(strs) < 2:
        t.dropped.append(f"line {stmt.line}: SetEquipInfo with {len(nums)} numbers")
        return
    ident = nums[0]
    if not _in_range("SetEquipInfo", ident):
        t.dropped.append(f"line {stmt.line}: SetEquipInfo id {ident} out of range")
        return
    if ident in t.equipment:
        t.dropped.append(f"line {stmt.line}: SetEquipInfo_EquipType in use! ({ident})")
        return
    t.equipment[ident] = EquipmentType(
        id=ident, name=strs[0], cost=nums[1],
        skills=tuple(nums[2:8]), tech=nums[8], key=_first_char(strs, 1),
        icon=nums[9])


def _load_unit(t: BalanceTables, stmt: lcl.Statement) -> None:
    nums, strs = _nums(stmt), _strs(stmt)
    if len(nums) < 13 or len(strs) < 3:
        t.dropped.append(f"line {stmt.line}: SetUnitInfo with {len(nums)} numbers")
        return
    ident = nums[0]
    if not _in_range("SetUnitInfo", ident):
        t.dropped.append(f"line {stmt.line}: SetUnitInfo id {ident} out of range")
        return
    if ident in t.units:
        t.dropped.append(f"line {stmt.line}: SetUnitInfo_UnitType in use! ({ident})")
        return
    t.units[ident] = UnitType(
        id=ident, description=strs[0], model=strs[1],
        player=nums[1], mp_max=nums[2], hp_max=nums[3], fp_max=nums[4],
        armour_front=nums[5], armour_rear=nums[6], weapon=nums[7],
        special=nums[8], species=nums[9], exp=nums[10], size=nums[11],
        height=nums[12], key=_first_char(strs, 2))


def _load_weapon(t: BalanceTables, stmt: lcl.Statement) -> None:
    nums, strs = _nums(stmt), _strs(stmt)
    if len(nums) < 18 or not strs:
        t.dropped.append(f"line {stmt.line}: SetWeaponInfo with {len(nums)} numbers")
        return
    ident = nums[0]
    if not _in_range("SetWeaponInfo", ident):
        t.dropped.append(f"line {stmt.line}: SetWeaponInfo id {ident} out of range")
        return
    if ident in t.weapons:
        t.dropped.append(f"line {stmt.line}: SetWeaponInfo_WeaponType in use! ({ident})")
        return
    t.weapons[ident] = WeaponType(
        id=ident, name=strs[0], range_min=nums[1], range_min_authored=nums[1],
        range_max=nums[2], hit=nums[3], damage=nums[4], def_mode=nums[5],
        skills=tuple(nums[6:10]), ap=nums[10], type=nums[11], tech=nums[12],
        mun=nums[13], heat=nums[14], cost=nums[15], special=nums[16],
        param=nums[17])


def _load_weapon2(t: BalanceTables, stmt: lcl.Statement) -> None:
    nums, strs = _nums(stmt), _strs(stmt)
    if len(nums) < 4 or len(strs) < 2:
        t.dropped.append(f"line {stmt.line}: SetWeaponInfo2 with {len(nums)} numbers")
        return
    ident = nums[0]
    if not _in_range("SetWeaponInfo", ident):
        t.dropped.append(f"line {stmt.line}: SetWeaponInfo2 id {ident} out of range")
        return
    row = t.weapons.get(ident)
    if row is None:
        # SetWeaponInfo2 has no in-use guard and no requirement that the record
        # exist: it writes its five fields into a still-zeroed record.  Shipped
        # id 35 is the only case, and its in-use byte therefore stays 0.
        row = WeaponType(
            id=ident, name="", range_min=0, range_min_authored=0, range_max=0,
            hit=0, damage=0, def_mode=0, skills=(0, 0, 0, 0), ap=0, type=0,
            tech=0, mun=0, heat=0, cost=0, special=0, param=0, in_use=False)
        t.weapons[ident] = row
        t.dropped.append(
            f"line {stmt.line}: SetWeaponInfo2 for id {ident} with no "
            f"SetWeaponInfo; the record's in-use byte stays 0")
    row.wave_name = strs[0]
    row.toggle = nums[1]
    row.mun_per_fight = nums[2]
    row.icon = nums[3]
    row.key = _first_char(strs, 1)
    if len(row.wave_name) >= WAVE_NAME_OVERRUN_LENGTH:
        # The nul that terminates a 9-character wave name lands on +0x2e.
        # Longer names would overrun further, but none is shipped, so only the
        # exactly-9 case is modelled and anything longer is reported.
        row.range_min = 0
        if len(row.wave_name) > WAVE_NAME_OVERRUN_LENGTH:
            t.dropped.append(
                f"line {stmt.line}: wave name {row.wave_name!r} is longer than "
                f"{WAVE_NAME_OVERRUN_LENGTH}; only range_min is modelled")


_HANDLERS = {
    "SetCtrlMapInfo": _load_ctrlmap,
    "SetEquipInfo": _load_equip,
    "SetUnitInfo": _load_unit,
    "SetWeaponInfo": _load_weapon,
    "SetWeaponInfo2": _load_weapon2,
}


def info_path(root: str) -> str:
    return os.path.join(root, INFO_REL_PATH)


def load_info(root: str) -> BalanceTables:
    """Read ``DATA/Info.lcl`` from a game installation root."""
    path = info_path(root)
    if not os.path.isfile(path):
        raise InfoError(f"no {INFO_REL_PATH} under {root!r}")
    return load_info_file(path)


def load_info_file(path: str,
                   encoding: str = lcl.SOURCE_ENCODING) -> BalanceTables:
    """*encoding* is the release's code page; it reaches only the name
    columns, since every other column is a number or an ASCII key."""
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        raise InfoError(f"{path}: {exc}") from exc
    try:
        program = lcl.parse_bytes(data, path, encoding)
    except lcl.LclSyntaxError as exc:
        raise InfoError(f"{path}: {exc}") from exc
    return parse_program(program, path)
