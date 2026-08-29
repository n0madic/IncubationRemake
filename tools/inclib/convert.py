"""One mission and its transitive assets, as portable data.

This is the conversion boundary of ``docs/92`` §3.2, narrowed to what the first
vertical slice needs: the authored grid, the units, the scenery placement, the
geometry those placements name, and the textures that geometry names.

**The container is JSON plus PNG, and it holds no float anywhere.**  ``_C_115``
closes over 53 prototypes, 1176 vertices, 610 faces and 10 of 37 textures -- a
1997 game with a software rasteriser, smaller than one modern character.  At
that size glTF costs a binary writer, a second coordinate convention and an
opaque diff for nothing, and Godot's ``.res`` would pin the player's data to
Godot's serialisation for the same reason ``docs/92`` §7.3 rejects it for saves.
On JSON the two exit criteria of §10.4 -- equivalent canonical data from two
conversions, and diffing the portable logical data -- become ``sha256`` and
``diff``.

Determinism is built in rather than tested for afterwards.  Vertices are whole
world units, UVs are the raw 8.7 fixed-point the record carries, colours are the
raw ``u16`` plus a decoded RGB triple, heights are ``i32``.  No float is ever
formatted, so no formatting can drift.

**Polygons stay polygons.**  Triangulation is a rendering decision and lives in
``game/``; a triangulated cache would stop being "decoded, engine-independent
data".
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from . import lev as levmod
from . import prototyp as protomod
from . import visn as visnmod
from .cache import SourceReader, Staging
from .info import BalanceTables, load_info_file
from .script import (GUI_TEXT_DIR, load_script, script_document,
                     text_catalogue)
from .png import write_rgb_png

MAP_SCHEMA = "incubation.map/1"
GEOMETRY_SCHEMA = "incubation.geometry/1"
TEXTURE_SCHEMA = "incubation.textures/1"

#: ``docs/30`` §2.5 -- the loader shifts ``.3DW`` positions and angles by 4 and
#: permutes the axes.  The cache stores the result, so nothing downstream has to
#: rediscover it.
DW_POSITION_SHIFT = 4
DW_ANGLE_SHIFT = 4
DW_Y_SCALE = -16

#: ``docs/10`` §7 -- one map field, and the metre.
WORLD_UNITS_PER_FIELD = 3200
WORLD_UNITS_PER_METRE = 1600
#: ``docs/10`` -- a full turn in the engine's angle units.
ANGLE_FULL_TURN = 4096

#: ``docs/10`` §6.4 -- every file uses exactly one prototype for its whole
#: lattice, the floor tile ``aInitCtrlMap`` creates from this model name.  It is
#: an octagon 320 world units across, an editor marker for the cell centre, not
#: a 3200-wide terrain tile: the visible ground is the ``.3DW`` clones and the
#: lattice only carries the height.  The record's own ``+0x08`` is a stale
#: runtime index, so it is resolved by name.
LATTICE_PROTOTYPE = "S003_00X.3DI"
#: The prototype the ``.lev`` parks at ``z = -1600000``; it is never drawn.
MARKER_PROTOTYPE = "CLS.3DI"
#: ``docs/92`` §10 -- 30 of the 36 ``SetUnitInfo`` rows name this four-vertex
#: ground marker rather than a body.  The bodies come through Charisma, which
#: is outside the slice, so the converter emits the marker and the real models
#: of the inanimate types that are actually placed.
UNIT_MARKER_MODEL = "A_MK_0B.3DI"


class ConvertError(Exception):
    """Raised when a mission cannot be converted."""


@dataclass
class Conversion:
    """What one conversion produced, for the manifest and for reporting."""

    missions: list[str] = field(default_factory=list)
    world_sets: list[str] = field(default_factory=list)
    prototypes: int = 0
    textures: int = 0
    text_entries: int = 0
    warnings: list[str] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Paths inside the installation
# ---------------------------------------------------------------------------

def _find(root: Path, *parts: str) -> Path:
    """Case-insensitive lookup: the shipped tree mixes cases freely."""
    current = root
    for part in parts:
        if (current / part).exists():
            current = current / part
            continue
        lower = part.lower()
        for entry in sorted(current.iterdir()):
            if entry.name.lower() == lower:
                current = entry
                break
        else:
            raise ConvertError(f"{current / part} not found")
    return current


def mission_path(root: Path, name: str) -> Path:
    return _find(root, "Missions", f"{name}.lev")


def mission_script_path(root: Path, name: str) -> Path:
    """The ``.lcl`` beside the ``.lev``; docs/20 -- the mission's own program."""
    return _find(root, "Missions", f"{name}.lcl")


def gui_text_paths(root: Path, language: str) -> list[Path]:
    """The interface-string programs of one language, in a stable order."""
    base = _find(root, "DATA", "TXT", language, GUI_TEXT_DIR)
    return sorted(p for p in base.iterdir() if p.is_file())


def world_paths(root: Path, world_set: str, scene: str) -> dict[str, Path]:
    base = _find(root, "WorldSet", f"World_{world_set}")
    return {
        "dw": _find(base, "Worlds", f"{scene.upper()}.3DW"),
        "din": _find(base, "Objects", "prototyp.din"),
        "bin": _find(base, "Objects", "prototyp.bin"),
        "texture_din": _find(base, "TEXTURES", "texture.din"),
        "texture_lib": _find(base, "TEXTURES", "texture.lib"),
    }


# ---------------------------------------------------------------------------
# The mission
# ---------------------------------------------------------------------------

def _parse_3dw(reader: SourceReader, path: Path) -> list[dict[str, Any]]:
    """Clone blocks from a ``.3DW``.

    ``3dw_parse`` is a sibling CLI whose module name starts with a digit, so it
    cannot be imported by name.  Moving it into ``inclib`` is a separate task.
    """
    import importlib.util

    reader.record(path)
    tools = Path(__file__).resolve().parent.parent
    spec = importlib.util.spec_from_file_location(
        "_dw_parse", tools / "3dw_parse.py")
    if spec is None or spec.loader is None:
        raise ConvertError("cannot load tools/3dw_parse.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.parse_3dw(str(path)).clones


def scene_clones(clones: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Clone placements already in engine world units (``docs/30`` §2.5).

    The prototype is the ``[CLO]`` argument, **not** the ``PROTOTYP`` line: the
    loader skips that keyword and its value outright.  In all 1125 shipped
    blocks the two agree, so the difference never shows in the corpus -- which
    is exactly why it has to be written down.
    """
    out: list[dict[str, Any]] = []
    for clone in clones:
        px, py, pz = clone["position"]
        rx, ry, rz = clone["rotation"]
        out.append({
            "prototype": clone["name"],
            "x": px << DW_POSITION_SHIFT,
            "y": pz << DW_POSITION_SHIFT,
            "z": py * DW_Y_SCALE,
            "rot0": (rx << DW_ANGLE_SHIFT) & 0xFFFF,
            "rot1": (ry << DW_ANGLE_SHIFT) & 0xFFFF,
            "yaw": (rz << DW_ANGLE_SHIFT) & 0xFFFF,
        })
    return out


def mission_document(bm: levmod.BattleMap, clones: list[dict[str, Any]],
                     source: dict[str, Any]) -> dict[str, Any]:
    """The portable form of one ``.lev``.

    Cells are a **structure of arrays**, row-major, split by lifetime the way
    ``docs/92`` §7.2 requires: the arrays ``MapState`` owns first, then the ones
    ``MapResource`` keeps immutable.  ``width`` and ``height`` are resolved here
    once -- ``0x357`` is rows and ``0x35B`` is columns -- and nowhere else.
    """
    cells = bm.cells
    warnings: list[str] = []
    if bm.clone_count != len(clones):
        # docs/10 §6.1: four D00 missions disagree with their .3DW.  The engine
        # parses the .3DW itself, so the .3DW is authoritative and the header
        # count is the stale number; it is a warning, never a refusal.
        warnings.append(
            f"header clone_count {bm.clone_count} != {len(clones)} parsed from "
            f"the .3DW; the .3DW is what the engine reads")

    return {
        "schema": MAP_SCHEMA,
        "source": source,
        "header": {
            "name": bm.map_name,
            "next_map": bm.next_map,
            "map_type": bm.map_type,
            "mission_id": bm.mission_id,
            "world_set": bm.world_set,
            "world_scene": bm.world_scene,
            "camera_height": bm.camera_height,
            "equip_points": list(bm.equip_points),
            "skill_level": bm.skill_level,
            "tech_level": bm.tech_level,
        },
        "width": bm.width,
        "height": bm.height,
        "cells": {
            # Mutable at runtime -- MapState owns these (docs/92 §7.2).
            "height": [c.height for c in cells],
            "field_type": [c.field_type for c in cells],
            "action_point": [c.action_point for c in cells],
            "unit": [-1 if c.unit is None else c.unit for c in cells],
            # docs/23 §7.1 and docs/92 §7.2 amendment: +0x0E and +0x10 are
            # values, +0x0F and +0x11 are slot indices into the runtime object
            # array.  All four are carried through and none is interpreted.
            "effect0": [c.raw[0x0E] for c in cells],
            "effect1": [c.raw[0x0F] for c in cells],
            "effect2": [c.raw[0x10] for c in cells],
            "effect3": [c.raw[0x11] for c in cells],
            # Immutable -- MapResource keeps these.
            "land": [c.land for c in cells],
            "start_index": [-1 if c.start_index == levmod.NO_LINK
                            else c.start_index for c in cells],
            "decal0": [c.raw[0x12] for c in cells],
            "decal1": [c.raw[0x13] for c in cells],
        },
        "units": [
            {
                "slot": u.slot,
                "name": u.name,
                "type_id": u.type_id,
                "player": u.player,
                "x": u.x,
                "y": u.y,
                "hit_points": u.hit_points,
                "action_points": u.action_points,
                "ep": u.ep,
                "rank": u.rank,
                "fp": u.fp,
                # docs/10 §5.5 -- the two other inputs to 0x00475160.  Zero in
                # every shipped record and 0/16 respectively, but the formula
                # reads them, so the cache carries them rather than letting the
                # remake assume.
                "rested": u.rested,
                "action_state": u.action_state,
                "tp": u.tp,
                # docs/10 §5.12 and §5 -- the turn, combat and reaction state
                # the second slice reads.  Zero in most shipped records, which
                # is exactly why they are carried: a remake that assumed the
                # zero would be right until the first mid-turn save.
                "acted": u.acted,
                "damage_absorber": u.absorb,
                "armour_front": u.armour_front,
                "armour_rear": u.armour_rear,
                "ammo": u.ammo,
                "heat": u.heat,
                "malfunction": u.malfunction,
                "walked": u.walked,
                "turn_start_x": u.turn_start_x,
                "turn_start_y": u.turn_start_y,
                "stimulant": u.stimulant,
                "ticket": u.ticket,
                "skills": dict(zip(levmod.SKILL_NAMES, u.skills)),
                "equipment_ids": list(u.equipment_ids),
                "weapon": u.weapon,
                "facing": u.facing,
                "order": u.order,
                "order_param": u.order_param,
                "order2": u.order2,
                "order2_param": u.order2_param,
                "group": u.group,
                # docs/20 §7.4 -- `InsertUnit` writes the first and
                # `LinkChrWithGroup` the second.  Nothing in the simulation
                # *reads* either, but a mission script writes both, and a
                # remake that dropped them could not be diffed against the
                # executable model on any script that calls those commands.
                "pool_flag": u.pool_flag,
                "speech": u.speech,
                "visibility": u.visibility,
                "placed": u.placed,
            }
            for u in bm.active_units
        ],
        "land": {
            # The lattice records carry a stale runtime prototype index, so the
            # prototype is named once for the whole block and resolved by name.
            "prototype": _lattice_prototype(bm),
            "x": [o.x for o in bm.land],
            "y": [o.y for o in bm.land],
            "z": [o.z for o in bm.land],
            "yaw": [o.rotation[2] for o in bm.land],
            "grid_x": [o.grid_x for o in bm.land],
            "grid_y": [o.grid_y for o in bm.land],
        },
        "special_objects": [
            {
                "prototype": o.prototype_name(bm.world_set),
                "letter": o.kind,
                "number": o.number,
                "x": o.x, "y": o.y, "z": o.z,
                "yaw": o.rotation[2],
            }
            for o in bm.special
        ],
        "scene_clones": clones,
        "marker": None if bm.marker_object is None else {
            "prototype": MARKER_PROTOTYPE,
            "x": bm.marker_object.x,
            "y": bm.marker_object.y,
            "z": bm.marker_object.z,
        },
        "diagnostics": {
            "clone_count_header": bm.clone_count,
            "clone_count_parsed": len(clones),
            "warnings": warnings,
        },
    }


def _lattice_prototype(_bm: levmod.BattleMap) -> str:
    """The ground-lattice prototype name; the same in every world set."""
    return LATTICE_PROTOTYPE


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

def _face_document(face: protomod.Face) -> dict[str, Any]:
    return {
        "draw_kind": face.draw_kind,
        "draw_name": face.draw_name,
        "texture": -1 if face.texture is None else face.texture,
        "colour": face.colour,
        "rgb": list(protomod.colour_rgb(face.colour)),
        "indices": list(face.indices),
        # The raw 8.7 fixed point the record carries, 0..32767, not a ratio.
        "uvs": [] if face.uvs is None else [list(uv) for uv in face.uvs],
    }


def _iter_faces(node: Any) -> Iterable[protomod.Face]:
    if node is None:
        return
    if isinstance(node, protomod.Leaf):
        yield from node.faces
    elif isinstance(node, protomod.BspNode):
        yield from _iter_faces(node.near)
        yield from _iter_faces(node.far)


def prototype_document(proto: protomod.Prototype) -> dict[str, Any]:
    """One prototype as portable mesh data.

    ``prototyp.bin`` is a bytecode program, not a mesh (``docs/31``), and the
    BSP tree it carries is a draw order.  The slice flattens the tree into a
    face list and keeps the vertices in their rest pose: joint angles come from
    the runtime object, which is outside the slice.
    """
    bbox = proto.vertex_bbox
    return {
        "vertices": [list(v) for v in proto.placed_vertices],
        "bbox": {
            "min": list(proto.bbox_min),
            "max": list(proto.bbox_max),
            "vertex_min": [] if bbox is None else list(bbox[0]),
            "vertex_max": [] if bbox is None else list(bbox[1]),
        },
        "height": proto.height,
        "cull_radius": proto.cull_radius,
        "collision_radius": proto.collision_radius,
        "faces": [_face_document(f) for f in _iter_faces(proto.tree)],
    }


def geometry_document(world_set: str, names: list[str],
                      container: protomod.Container,
                      source: dict[str, Any]) -> tuple[dict[str, Any], set[int]]:
    """Every named prototype, and the set of texture ids they reach."""
    prototypes: dict[str, Any] = {}
    textures: set[int] = set()
    missing: list[str] = []
    for name in sorted(set(names)):
        try:
            index = container.find(name)
        except KeyError:
            missing.append(name)
            continue
        proto = container.parse(index)
        document = prototype_document(proto)
        prototypes[name] = document
        for face in document["faces"]:
            if face["texture"] >= 0:
                textures.add(face["texture"])
    return {
        "schema": GEOMETRY_SCHEMA,
        "world_set": world_set,
        "source": source,
        "missing": sorted(missing),
        "prototypes": prototypes,
    }, textures


# ---------------------------------------------------------------------------
# Textures
# ---------------------------------------------------------------------------

def convert_textures(reader: SourceReader, staging: Staging, world_set: str,
                     lib_path: Path, din_path: Path,
                     wanted: set[int]) -> dict[str, Any]:
    """Decode the wanted VISN records to PNG and write an index beside them."""
    reader.record(lib_path)
    reader.record(din_path)
    entries = visnmod.read_din_index(str(din_path))
    data = lib_path.read_bytes()
    index: list[dict[str, Any]] = []
    for entry in entries:
        if entry.index not in wanted:
            continue
        record = data[entry.offset:entry.offset + entry.size]
        image = visnmod.decode_record(record)
        rel = f"textures/{world_set}/{entry.index}.png"
        path = staging.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        write_rgb_png(str(path), image.width, image.height, image.to_rgb888())
        staging.files[rel] = "written"
        index.append({
            "id": entry.index,
            "name": entry.name,
            "width": image.width,
            "height": image.height,
            "file": f"{entry.index}.png",
        })
    return {
        "schema": TEXTURE_SCHEMA,
        "world_set": world_set,
        "source": {"lib": reader.rel(lib_path), "din": reader.rel(din_path)},
        "textures": index,
    }


# ---------------------------------------------------------------------------
# Driving one conversion
# ---------------------------------------------------------------------------

def prototype_names(document: dict[str, Any], tables: BalanceTables,
                    lattice: str) -> list[str]:
    """The transitive closure of one mission's placements.

    ``docs/92`` §10.1 item 2: only the mission and the assets needed to display
    it.  That is the scene's clones, the special objects, the ground lattice,
    and the real models of the inanimate unit types actually placed -- plus the
    one-cell ground marker every living type points at.
    """
    names = {clone["prototype"] for clone in document["scene_clones"]}
    names |= {obj["prototype"] for obj in document["special_objects"]}
    names.add(lattice)
    names.add(UNIT_MARKER_MODEL)
    for unit in document["units"]:
        if not unit["placed"]:
            continue
        row = tables.units.get(unit["type_id"])
        if row is not None and row.model:
            names.add(row.model)
    return sorted(names)


def convert(root: Path, missions: list[str], staging: Staging,
            reader: SourceReader, language: str) -> Conversion:
    """Convert every named mission and everything it reaches into `staging`."""
    result = Conversion()
    info_path = reader.record(_find(root, "DATA", "Info.lcl"))
    tables = load_info_file(str(info_path))
    staging.write_json("tables/balance.json", tables.to_dict())

    wanted_by_set: dict[str, set[str]] = {}
    scenes_by_set: dict[str, set[str]] = {}

    for name in missions:
        path = reader.record(mission_path(root, name))
        bm = levmod.load_lev(str(path))
        paths = world_paths(root, bm.world_set, bm.world_scene)
        clones = scene_clones(_parse_3dw(reader, paths["dw"]))
        # docs/25 section 4: handing the turn over *runs* the mission script,
        # so the script is not an extra the map happens to have -- it is half
        # of what a mission is, and the cache carries it beside the map.
        script_path = reader.record(mission_script_path(root, name))
        program = load_script(script_path)
        script_source = {
            "lcl": reader.rel(script_path),
            "sha256": reader.seen[reader.rel(script_path)],
        }
        document = mission_document(bm, clones, {
            "lev": reader.rel(path),
            "sha256": reader.seen[reader.rel(path)],
            "dw": reader.rel(paths["dw"]),
            "dw_sha256": reader.seen[reader.rel(paths["dw"])],
            "lcl": script_source["lcl"],
            "lcl_sha256": script_source["sha256"],
        })
        staging.write_json(f"missions/{name}/map.json", document)
        staging.write_json(f"missions/{name}/script.json",
                           script_document(program, script_source))
        result.warnings += [
            f"{name}.lcl:{d.line}:{d.column}: {d.message}"
            for d in program.diagnostics if d.severity == "error"]
        result.missions.append(name)
        result.warnings += document["diagnostics"]["warnings"]
        wanted_by_set.setdefault(bm.world_set, set()).update(
            prototype_names(document, tables, _lattice_prototype(bm)))
        scenes_by_set.setdefault(bm.world_set, set()).add(bm.world_scene)

    for world_set, names in sorted(wanted_by_set.items()):
        paths = world_paths(root, world_set, sorted(scenes_by_set[world_set])[0])
        reader.record(paths["din"])
        reader.record(paths["bin"])
        container = protomod.load_container(str(paths["din"]),
                                            str(paths["bin"]))
        document, textures = geometry_document(world_set, sorted(names),
                                               container, {
            "din": reader.rel(paths["din"]),
            "bin": reader.rel(paths["bin"]),
            "sha256": reader.seen[reader.rel(paths["bin"])],
        })
        staging.write_json(f"geometry/{world_set}.json", document)
        result.prototypes += len(document["prototypes"])
        if document["missing"]:
            result.warnings.append(
                f"{world_set}: prototypes named but absent from prototyp.din: "
                + ", ".join(document["missing"]))
        index = convert_textures(reader, staging, world_set,
                                 paths["texture_lib"], paths["texture_din"],
                                 textures)
        staging.write_json(f"textures/{world_set}/index.json", index)
        result.textures += len(index["textures"])
        result.world_sets.append(world_set)

    gui_paths = gui_text_paths(root, language)
    programs = {}
    text_source: dict[str, Any] = {}
    for gui_path in gui_paths:
        reader.record(gui_path)
        stem = gui_path.stem
        programs[stem] = load_script(gui_path)
        text_source[stem] = reader.rel(gui_path)
    catalogue = text_catalogue(programs, language, {"files": text_source})
    staging.write_json(f"text/{language}.json", catalogue)
    result.text_entries = sum(len(v) for v in catalogue["gui"].values())
    return result
