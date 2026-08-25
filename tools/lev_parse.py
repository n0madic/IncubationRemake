#!/usr/bin/env python3
"""Inspect Incubation .lev battle-map (mission) files.

Usage:
    lev_parse.py gog_incubation/Missions/_C_105.lev            # summary
    lev_parse.py gog_incubation/Missions/_C_105.lev --json
    lev_parse.py gog_incubation/Missions/_C_105.lev --map      # ASCII terrain map
    lev_parse.py gog_incubation/Missions/_C_105.lev --objects  # 3D object blocks
    lev_parse.py gog_incubation --check                        # corpus validation
    lev_parse.py gog_incubation --png -o tools/out/maps        # render height maps
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.lev import (  # noqa: E402
    AI_ORDER_NAMES, BattleMap, LevError, MARKER_PARK_Z, NO_LINK, SKILL_NAMES,
    SPEECH_NAMES, WORLD_UNITS_PER_FIELD, load_lev,
)
from inclib.png import write_rgb_png  # noqa: E402

LOG = logging.getLogger("lev_parse")

TERRAIN_GLYPHS = {0: " ", 1: ".", 2: "#", 3: "u", 4: "v", 5: ";",
                  6: "P", 7: "O", 8: "L", 9: "T", 10: "X"}
"""Glyph per field type, following the editor's "Select Field Type" menu.

The menu labels the types `[.] [#] [v] [P] [T] [X] [;]`, and its `Hole [v]`
button writes type **4** (`Deep Hole`), not 3 -- see
`docs/10-lev-mission-format.md` section 4.1. `v` therefore belongs to 4, which
is also the common one (44653 cells across 65 files); type 3 (`Hole`, 2241
cells) has no button of its own and takes the neighbouring `u`. A previous
revision had `v` on 3 and `V` on 4, which read every Deep Hole as the rarer
type.
"""


def find_levs(root: str) -> list[str]:
    if os.path.isfile(root):
        return [root]
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.lower().endswith(".lev"):
                out.append(os.path.join(dirpath, name))
    return sorted(out)


def summarize(bm: BattleMap) -> None:
    print(f"file        : {bm.path}")
    print(f"map name    : {bm.map_name}")
    print(f"next map    : {bm.next_map}")
    print(f"map type    : {bm.map_type} ({bm.map_type_name})   mission id: "
          f"{bm.mission_id}")
    print(f"world set   : {bm.world_set}   scene: {bm.world_scene}")
    print(f"dimensions  : {bm.width} x {bm.height}  ({bm.width * bm.height} cells)")
    print(f"equip pts   : {list(bm.equip_points)}   skills: {bm.skill_level}"
          f"   techlevel: {bm.tech_level}")
    print(f"camera      : {bm.camera_height} world units "
          f"({bm.camera_height_m:g} m)")
    heights = [c.height for c in bm.cells]
    print(f"height range: {min(heights)} .. {max(heights)} world units "
          f"({WORLD_UNITS_PER_FIELD} = one field)")
    types = sorted({c.field_type for c in bm.cells})
    print("field types : " + ", ".join(f"{t}={_type_name(bm, t)}"
                                       for t in types))
    aps = sorted({c.action_point for c in bm.cells if c.action_point})
    print(f"action pts  : {aps}")
    starts = bm.start_fields
    if starts:
        print(f"start fields: {len(starts)} -> "
              + ", ".join(f"({c.x},{c.y})" for c in starts))
    print(f"3D objects  : {len(bm.land)} land, {len(bm.special)} special, "
          f"{bm.clone_count} scene clones")
    units = bm.active_units
    placed = bm.placed_units
    print(f"units       : {len(placed)} placed, {len(units)} named slots of "
          f"{len(bm.units)}")
    for u in units:
        mark = " " if u.placed else "*"
        print(f"  {mark}[{u.slot:3d}] type={u.type_id:3d} p={u.player:3d} "
              f"hp={u.hit_points:3d} mp={u.action_points:2d} wpn={u.weapon:3d} "
              f"dir={u.facing} at ({u.x:2d},{u.y:2d})  {u.name}")
        extras = []
        if u.order or u.order_param:
            extras.append(f"order={u.order_name}({u.order_param})")
        if u.order2 or u.order2_param:
            extras.append(f"order2={u.order2_name}({u.order2_param})")
        if u.group:
            extras.append(f"group={u.group}")
        if u.ep:
            extras.append(f"ep={u.ep} rank={u.rank}")
        if u.tp:
            extras.append(f"tp={u.tp}")
        if u.fp != 255:
            extras.append(f"fp={u.fp}")
        if any(u.skills):
            extras.append("skills=" + "/".join(
                f"{n}{v}" for n, v in zip(SKILL_NAMES, u.skills) if v))
        if u.equipment_ids:
            extras.append("equip=" + ", ".join(u.equipment_names))
        if u.pool_flag:
            extras.append("hero" if u.pool_flag == 2 else "unitpool candidate")
        if u.speech:
            extras.append(f"speech={u.speech_name}")
        if extras:
            print("        " + "  ".join(extras))
    if units and len(placed) != len(units):
        print("  (* = named slot with 0 hit points: not placed on the map)")


def _type_name(bm: BattleMap, value: int) -> str:
    for cell in bm.cells:
        if cell.field_type == value:
            return cell.field_type_name
    return str(value)


def dump_objects(bm: BattleMap) -> None:
    print(f"land objects : {len(bm.land)} (= {bm.width}x{bm.height})")
    for obj in bm.land[:5]:
        print(f"  [{obj.slot:4d}] proto={obj.prototype} grid=({obj.grid_x},"
              f"{obj.grid_y}) xyz=({obj.x},{obj.y},{obj.z})")
    if len(bm.land) > 5:
        print("  ...")
    print(f"special objs : {len(bm.special)}")
    for obj in bm.special:
        print(f"  [{obj.slot:3d}] {obj.prototype_name(bm.world_set):16s} "
              f"xyz=({obj.x},{obj.y},{obj.z}) rot={obj.rotation}")
    print("scene objects (block 1, 10 slots):")
    for obj in bm.scene_objects:
        if obj.x or obj.y or obj.z or obj.prototype:
            print(f"  [{obj.slot:2d}] proto={obj.prototype} "
                  f"xyz=({obj.x},{obj.y},{obj.z}) rot={obj.rotation}")


def ascii_map(bm: BattleMap) -> str:
    lines = []
    for y in range(bm.height):
        row = []
        for x in range(bm.width):
            cell = bm.cell_at(x, y)
            if cell.unit is not None:
                row.append("U")
            elif cell.is_start_field:
                row.append("S")
            elif cell.action_point:
                row.append("A")
            else:
                row.append(TERRAIN_GLYPHS.get(cell.field_type, "?"))
        lines.append("".join(row))
    return "\n".join(lines)


def png_stem(lev_path: str) -> str:
    """A per-input output name that cannot collide.

    Uses the directory the file sits in plus its basename, so
    `Missions/_C_173.lev` and `Missions/backup/_C_173.lev` -- which share a
    `map_name` but differ in content -- produce two images rather than one.
    """
    folder = os.path.basename(os.path.dirname(os.path.abspath(lev_path)))
    stem = os.path.splitext(os.path.basename(lev_path))[0]
    return f"{folder}_{stem}" if folder else stem


def render_png(bm: BattleMap, path: str) -> None:
    """Colour by field type, brightness by height, units and action points marked."""
    heights = [c.height for c in bm.cells]
    lo, hi = min(heights), max(heights)
    span = max(1, hi - lo)
    type_hue = [(70, 90, 110), (60, 120, 70), (120, 100, 60), (90, 90, 140),
                (110, 110, 110), (140, 80, 60), (60, 130, 130), (130, 60, 130),
                (150, 150, 90), (80, 160, 200), (200, 120, 200)]
    rgb = bytearray()
    for y in range(bm.height):
        for x in range(bm.width):
            c = bm.cell_at(x, y)
            if c.unit is not None:
                rgb += bytes((255, 60, 60))
                continue
            if c.action_point:
                rgb += bytes((255, 210, 60))
                continue
            base = type_hue[c.field_type % len(type_hue)]
            k = 0.45 + 0.55 * (c.height - lo) / span
            rgb += bytes(min(255, max(0, int(v * k))) for v in base)
    write_rgb_png(path, bm.width, bm.height, bytes(rgb))


def as_dict(bm: BattleMap) -> dict:
    return {
        "file": bm.path,
        "map_name": bm.map_name,
        "next_map": bm.next_map,
        "map_type": bm.map_type,
        "map_type_name": bm.map_type_name,
        "mission_id": bm.mission_id,
        "world_set": bm.world_set,
        "world_scene": bm.world_scene,
        "width": bm.width,
        "height": bm.height,
        "equip_points": list(bm.equip_points),
        "skill_level": bm.skill_level,
        "tech_level": bm.tech_level,
        "camera_height": bm.camera_height,
        "cells": [
            {"index": c.index, "x": c.x, "y": c.y, "height": c.height,
             "land": c.land, "unit": c.unit, "action_point": c.action_point,
             "field_type": c.field_type, "field_type_name": c.field_type_name,
             "start_index": None if c.start_index == NO_LINK else c.start_index}
            for c in bm.cells
        ],
        "units": [
            {"slot": u.slot, "name": u.name, "x": u.x, "y": u.y,
             "unit_id": u.unit_id, "type_id": u.type_id, "player": u.player,
             "hit_points": u.hit_points, "action_points": u.action_points,
             "ep": u.ep, "rank": u.rank, "tp": u.tp, "fp": u.fp,
             "skills": u.skill_map,
             "equipment": list(u.equipment),
             "equipment_ids": list(u.equipment_ids),
             "armour_front": u.armour_front, "armour_rear": u.armour_rear,
             "absorb": u.absorb, "stimulant": u.stimulant, "ammo": u.ammo,
             "weapon": u.weapon, "facing": u.facing, "placed": u.placed,
             "order": u.order, "order_name": u.order_name,
             "order_param": u.order_param,
             "order2": u.order2, "order2_name": u.order2_name,
             "order2_param": u.order2_param,
             "pool_flag": u.pool_flag, "group": u.group,
             "visibility": u.visibility,
             "turn_start_x": u.turn_start_x, "turn_start_y": u.turn_start_y,
             "speech": u.speech, "speech_name": u.speech_name,
             "sound_channel": u.sound_channel}
            for u in bm.active_units
        ],
        "land_objects": [
            {"slot": o.slot, "prototype": o.prototype,
             "x": o.x, "y": o.y, "z": o.z,
             "grid_x": o.grid_x, "grid_y": o.grid_y}
            for o in bm.land
        ],
        "special_objects": [
            {"slot": o.slot, "prototype_name": o.prototype_name(bm.world_set),
             "kind": o.kind, "number": o.number,
             "x": o.x, "y": o.y, "z": o.z, "rotation": list(o.rotation)}
            for o in bm.special
        ],
    }


def check(bm: BattleMap) -> list[str]:
    """Structural invariants that must hold for every shipped file."""
    problems = []
    if len(bm.land) != bm.width * bm.height:
        problems.append(f"land count {len(bm.land)} != {bm.width}x{bm.height}")
    for obj in bm.land:
        if obj.x % WORLD_UNITS_PER_FIELD or obj.y % WORLD_UNITS_PER_FIELD:
            problems.append(f"land {obj.slot} off lattice ({obj.x},{obj.y})")
            break
        if obj.grid_x != obj.x // WORLD_UNITS_PER_FIELD or \
                obj.grid_y != obj.y // WORLD_UNITS_PER_FIELD:
            problems.append(f"land {obj.slot} grid mismatch")
            break
    for cell in bm.cells:
        land = bm.land[cell.land]
        if land.grid_x != cell.x or land.grid_y != cell.y:
            problems.append(f"cell {cell.index} land link mismatch")
            break
        if cell.height != land.z:
            problems.append(f"cell {cell.index} height {cell.height} != "
                            f"land z {land.z}")
            break
    for obj in bm.special:
        if obj.kind != ord("E"):
            problems.append(f"special {obj.slot} kind {obj.kind}")
            break
    # Object rotation is yaw only: the first two components are zero in every
    # shipped record, which is what makes +0x24 the heading (docs/10 6.0, 9.6).
    for name, array in (("land", bm.land), ("special", bm.special),
                        ("clone", bm.scene_objects)):
        stray = next((o for o in array if o.rotation[0] or o.rotation[1]), None)
        if stray is not None:
            problems.append(f"{name} {stray.slot} rotation not yaw-only "
                            f"{stray.rotation}")
    for u in bm.units:
        if u.hit_points == 0:
            continue
        if any(v > 1 for v in u.equipment):
            problems.append(f"unit {u.slot} equipment byte not 0/1")
            break
        if u.order not in AI_ORDER_NAMES or u.order2 not in AI_ORDER_NAMES:
            problems.append(f"unit {u.slot} order out of range "
                            f"({u.order}/{u.order2})")
            break
        if u.speech not in SPEECH_NAMES:
            problems.append(f"unit {u.slot} speech {u.speech} out of range")
            break
        if u.pool_flag > 2:
            problems.append(f"unit {u.slot} pool flag {u.pool_flag}")
            break
    marker = bm.marker_object
    if marker is not None and (marker.x, marker.y, marker.z) != (0, 0, MARKER_PARK_Z):
        problems.append(f"block 1 marker object at "
                        f"({marker.x},{marker.y},{marker.z})")
    if bm.ring_active:
        problems.append(f"block 1 deployment ring flag {bm.ring_active}")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", help="a .lev file, or a directory to scan")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--map", action="store_true", help="print an ASCII terrain map")
    parser.add_argument("--objects", action="store_true",
                        help="dump the three 3D object blocks")
    parser.add_argument("--png", action="store_true", help="render map images")
    parser.add_argument("--check", action="store_true",
                        help="parse every .lev found and report coverage")
    parser.add_argument("-o", "--outdir", default="tools/out/maps")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    paths = find_levs(args.input)
    if not paths:
        LOG.error("no .lev files under %s", args.input)
        return 1

    parsed = 0
    failures: list[tuple[str, str]] = []
    for path in paths:
        try:
            bm = load_lev(path)
        except LevError as exc:
            failures.append((path, str(exc)))
            LOG.error("%s: %s", path, exc)
            continue
        parsed += 1
        if args.check:
            for problem in check(bm):
                failures.append((path, problem))
                LOG.error("%s: %s", path, problem)
            continue
        if args.png:
            os.makedirs(args.outdir, exist_ok=True)
            # Name from the input path, not from `map_name`: two shipped pairs
            # (`_C_173`, `_C_174`) carry the same `map_name` in `Missions/` and
            # `Missions/backup/` with different content, so naming by the field
            # silently produced 153 images from 155 inputs -- the backup copy
            # overwriting the retail one -- while the parse count still said
            # 155/155.
            render_png(bm, os.path.join(args.outdir, png_stem(path)) + ".png")
        elif args.json:
            json.dump(as_dict(bm), sys.stdout, indent=2)
            sys.stdout.write("\n")
        elif args.map:
            print(ascii_map(bm))
        elif args.objects:
            dump_objects(bm)
        else:
            summarize(bm)

    if args.check or args.png or len(paths) > 1:
        LOG.info("parsed %d/%d .lev files, %d failure(s)",
                 parsed, len(paths), len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
