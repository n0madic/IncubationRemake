#!/usr/bin/env python3
"""Read ``DATA/Info.lcl`` as the game-balance tables.  See docs/21.

``Info.lcl`` is an ordinary LCL program whose only job is to call five
``Set*Info`` commands; each call writes one fixed-stride record into a static
table.  ``inclib.info`` applies the loader's own rules -- index range, the
first-definition-wins guard, and the wave-name field that overruns ``range
min`` -- so the result describes memory after the load rather than the text.

Usage::

    python3 tools/info_parse.py --check gog_incubation
    python3 tools/info_parse.py gog_incubation --json
    python3 tools/info_parse.py gog_incubation --table units

``--check`` gates on the shipped record counts, on the movement-cost column
agreeing with ``ai_tables.EXPECTED_DELAYS`` (which is read out of
``Incubation.exe``, so the two are independent evidence), on the eight weapons
``docs/21`` §4 names as overrun, and on the ids the specs quote by name.  It
fails on an empty or wrong root.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ai_tables  # noqa: E402
from inclib.check import Checker  # noqa: E402
from inclib.info import (  # noqa: E402
    BalanceTables,
    InfoError,
    SKILL_NAMES,
    load_info,
)

LOG = logging.getLogger("info_parse")

#: docs/21 §2 -- eleven control-map types, ids 0..10 with ``type == index``.
EXPECTED_CTRLMAP_IDS = list(range(11))
EXPECTED_CTRLMAP_NAMES = [
    "Undefined", "Free Place", "Wall", "Hole", "Deep Hole", "Debris",
    "Poison", "Enormous Obs", "Ladder", "Teleporter Entry", "Teleporter Exit",
]

#: docs/21 §3 -- "Shipped ids: 0, 1, 3..19.  Id 2 is missing."
EXPECTED_EQUIP_IDS = [0, 1] + list(range(3, 20))

#: docs/21 §5 -- the shipped unit types.
EXPECTED_UNIT_COUNT = 36

#: docs/21 §4 -- the weapons whose 9-character wave name lands its terminating
#: nul on ``range min``.  Id 28 is in the list although its authored value was
#: already 0, which is why the check is on the wave-name length.
EXPECTED_WAVE_OVERRUN_IDS = [14, 17, 20, 21, 27, 28, 29, 47]

#: docs/21 §4 -- ``SetWeaponInfo2 (35, ...)`` has no ``SetWeaponInfo`` before
#: it, so the record exists with its in-use byte still 0.
EXPECTED_WEAPON_NOT_IN_USE = [35]

#: docs/23 §7.5 -- the Jet Pack, the equipment that grants a warp.
JET_PACK_EQUIP_ID = 7
#: docs/21 §5 -- the two ``special`` values ``aBuildMoveMap`` refuses outright,
#: and the one that warps.
SPECIAL_CANNOT_MOVE = (1, 14)
SPECIAL_CAN_WARP = 15

#: docs/21 §5 -- ``size == 1`` is carried by exactly these three descriptions.
EXPECTED_LARGE_UNITS = ["Al'Coo", "ComBot", "Tr'Yn"]

#: docs/92 section 10 -- the unit model that 30 of the 36 rows point at.  A
#: four-vertex ground marker, not a body; the bodies come through Charisma.
MARKER_MODEL = "A_MK_0B.3DI"


def run_checks(root: Path) -> int:
    c = Checker()
    try:
        tables = load_info(str(root))
    except InfoError as exc:
        c.check("info.load", False, str(exc))
        return c.report()
    c.check("info.load", True, tables.path)

    c.expect("ctrlmap.ids", sorted(tables.ctrlmap), EXPECTED_CTRLMAP_IDS)
    c.expect("ctrlmap.names",
             [tables.ctrlmap[i].name for i in EXPECTED_CTRLMAP_IDS],
             EXPECTED_CTRLMAP_NAMES)
    c.expect("ctrlmap.type_is_index",
             [i for i, r in sorted(tables.ctrlmap.items()) if r.type != i], [])
    # Independent evidence: ai_tables reads this column out of Incubation.exe.
    c.expect("ctrlmap.delays", tables.delay_table(), ai_tables.EXPECTED_DELAYS)
    c.expect("ctrlmap.enterable",
             sorted(i for i, r in tables.ctrlmap.items() if r.is_enterable),
             sorted(i for i, d in ai_tables.EXPECTED_DELAYS.items() if d != 255))

    c.expect("equip.ids", sorted(tables.equipment), EXPECTED_EQUIP_IDS)
    c.expect("equip.count", len(tables.equipment), len(EXPECTED_EQUIP_IDS))
    c.expect("equip.skill_columns",
             sorted({len(r.skills) for r in tables.equipment.values()}),
             [len(SKILL_NAMES)])
    jet = tables.equipment.get(JET_PACK_EQUIP_ID)
    c.expect("equip.jet_pack", None if jet is None else jet.name, "Jet Pack")

    c.expect("unit.count", len(tables.units), EXPECTED_UNIT_COUNT)
    c.expect("unit.species_range",
             sorted({r.species for r in tables.units.values()}), [0, 1, 2, 3])
    c.expect("unit.large",
             sorted(r.description for r in tables.units.values() if r.size == 1),
             EXPECTED_LARGE_UNITS)
    c.check("unit.marker_model",
            sum(1 for r in tables.units.values() if r.model == MARKER_MODEL) >= 30,
            f"{sum(1 for r in tables.units.values() if r.model == MARKER_MODEL)}"
            f"/{len(tables.units)} rows point at {MARKER_MODEL}")
    c.check("unit.cannot_move",
            all(r.special in SPECIAL_CANNOT_MOVE
                for r in tables.units.values()
                if r.description in ("Cy'Coo", "War'Coo")),
            "Cy'Coo and War'Coo carry a special aBuildMoveMap refuses")
    c.expect("unit.can_warp",
             sorted(r.description for r in tables.units.values()
                    if r.special == SPECIAL_CAN_WARP),
             ["Ray'Coo"])
    c.expect("unit.height_positive",
             [r.id for r in tables.units.values() if r.height <= 0], [])

    c.expect("weapon.wave_overrun",
             sorted(w.id for w in tables.weapons.values()
                    if w.wave_name_fills_range_min),
             EXPECTED_WAVE_OVERRUN_IDS)
    c.expect("weapon.wave_overrun_zeroed",
             sorted({w.range_min for w in tables.weapons.values()
                     if w.wave_name_fills_range_min}), [0])
    c.expect("weapon.not_in_use",
             sorted(w.id for w in tables.weapons.values() if not w.in_use),
             EXPECTED_WEAPON_NOT_IN_USE)

    # The portable form must contain integers and strings only: a float
    # anywhere would make two conversions comparable only up to formatting.
    c.expect("balance.no_floats", _float_paths(tables.to_dict()), [])
    return c.report()


def _float_paths(value: object, path: str = "$") -> list[str]:
    """Every location in the emitted structure holding a float."""
    found: list[str] = []
    if isinstance(value, float):
        found.append(path)
    elif isinstance(value, dict):
        for key, item in value.items():
            found += _float_paths(item, f"{path}.{key}")
    elif isinstance(value, list):
        for i, item in enumerate(value):
            found += _float_paths(item, f"{path}[{i}]")
    return found


def print_table(tables: BalanceTables, which: str) -> None:
    if which == "ctrlmap":
        print(f"{'id':>3}  {'type':>4}  {'delay':>5}  {'cost':>4}  "
              f"{'cover':>5}  name")
        for i, r in sorted(tables.ctrlmap.items()):
            cost = "-" if not r.is_enterable else str(r.delay + 1)
            print(f"{i:>3}  {r.type:>4}  {r.delay:>5}  {cost:>4}  "
                  f"{r.cover:>5}  {r.name}")
    elif which == "equipment":
        print(f"{'id':>3}  {'name':<22} {'cost':>4}  {'tech':>4}  "
              f"{'icon':>4}  key  skills")
        for i, r in sorted(tables.equipment.items()):
            skills = " ".join(f"{n}={v}" for n, v in zip(SKILL_NAMES, r.skills))
            print(f"{i:>3}  {r.name:<22} {r.cost:>4}  {r.tech:>4}  "
                  f"{r.icon:>4}  {r.key:<3}  {skills}")
    elif which == "units":
        print(f"{'id':>3}  {'description':<16} {'model':<14} {'py':>3} "
              f"{'mp':>3} {'hp':>3} {'sp':>3} {'spc':>3} {'sz':>3} {'ht':>4}")
        for i, r in sorted(tables.units.items()):
            print(f"{i:>3}  {r.description:<16} {r.model:<14} {r.player:>3} "
                  f"{r.mp_max:>3} {r.hp_max:>3} {r.species:>3} "
                  f"{r.special:>3} {r.size:>3} {r.height:>4}")
    elif which == "weapons":
        print(f"{'id':>3}  {'name':<24} {'rng':>7}  {'hit':>3} {'dmg':>4} "
              f"{'ap':>3} {'ty':>3}  wave")
        for i, r in sorted(tables.weapons.items()):
            rng = f"{r.range_min}-{r.range_max}"
            print(f"{i:>3}  {r.name:<24} {rng:>7}  {r.hit:>3} {r.damage:>4} "
                  f"{r.ap:>3} {r.type:>3}  {r.wave_name}")
    else:
        raise SystemExit(f"unknown table {which!r}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root", nargs="?", type=Path,
                    help="a game installation root, or a path to Info.lcl")
    ap.add_argument("--check", metavar="GAME_ROOT", type=Path,
                    help="verify the tables against docs/21 and the binary")
    ap.add_argument("--json", action="store_true",
                    help="print the portable balance tables")
    ap.add_argument("--table", choices=("ctrlmap", "equipment", "units",
                                        "weapons"),
                    help="print one table as text")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    if args.check:
        return run_checks(args.check)
    if args.root is None:
        ap.print_help()
        return 2
    try:
        tables = load_info(str(args.root))
    except InfoError as exc:
        LOG.error("%s", exc)
        return 1
    if args.json:
        print(json.dumps(tables.to_dict(), indent=2, ensure_ascii=False))
        return 0
    if args.table:
        print_table(tables, args.table)
        return 0
    print(f"{tables.path}")
    print(f"  {len(tables.ctrlmap)} control-map types, "
          f"{len(tables.equipment)} equipment, {len(tables.units)} units, "
          f"{len(tables.weapons)} weapons")
    for note in tables.dropped:
        print(f"  note: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
