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

**Animation does not weaken that rule; it extends it.**  Bind matrices and
animation keys are genuinely ``f32``, and they reach the cache as their own
IEEE-754 bit patterns -- a ``u32`` for a single value, base64 of little-endian
``f32`` for an array (:mod:`inclib.charisma_cache`).  The invariant the rule
wanted is kept literally: no float is ever formatted.  The round trip is exact
by construction and is checked over the corpus, not assumed.

**Polygons stay polygons.**  Triangulation is a rendering decision and lives in
``game/``; a triangulated cache would stop being "decoded, engine-independent
data".
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from . import charisma as chamod
from . import charisma_cache as chacache
from . import charisma_tables as chatables
from . import eng3d
from . import lev as levmod
from . import liblib
from . import prototyp as protomod
from . import sound as soundmod
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
LATTICE_PROTOTYPE = protomod.LATTICE_PROTOTYPE
#: The prototype the ``.lev`` parks at ``z = -1600000``; it is never drawn.
MARKER_PROTOTYPE = "CLS.3DI"
#: ``docs/92`` §10 -- 30 of the 36 ``SetUnitInfo`` rows name this four-vertex
#: ground marker rather than a body.  The bodies come through Charisma, which
#: is outside the slice, so the converter emits the marker and the real models
#: of the inanimate types that are actually placed.
UNIT_MARKER_MODEL = "A_MK_0B.3DI"
#: The contact blip -- ``docs/22`` §9.1's ``+0x4F == 1``, drawn where a unit is
#: detected but not seen.  ``a3DObjects.cpp`` line 3838 resolves this name
#: through ``aGetNumberOfPrototype`` (``0x00407056``), and the geometry says
#: what it is: 28 vertices spanning z 730..6337 in a 1550-wide footprint, a
#: beam about 3.5 m tall.  Like the unit marker it is named by no placement --
#: the engine holds it by name and draws it wherever the fog pass leaves a
#: contact -- so the closure below has to ask for it.
CONTACT_MARKER_MODEL = "A_BLIB.3DI"

#: ``docs/40`` §7.2 -- the bodies themselves come from Charisma, chosen by four
#: routines in ``Incubation.exe``.  The converter reads them through
#: :mod:`inclib.charisma_tables` rather than re-deriving the player prefixes,
#: the hero rewrite or the neutral player's refusal, so those routines have one
#: reading in this repository and not two.
GAME_EXE = "Incubation.exe"
#: The world set the shared unit meshes are parsed from.  Any of the nine would
#: do -- ``charisma_tables --check`` proves all 1 877 unit meshes are present in
#: every one -- but the choice has to be written down, and the converter checks
#: cross-set identity for the meshes it actually emits rather than trusting it.
UNIT_GEOMETRY_SOURCE_SET = "A00"

#: ``docs/60`` §5 -- the game's four proportional bitmap fonts.  Each holds 224
#: elements, one per cp1252 code point from 32 to 255, so the element index is
#: ``codepoint - FONT_FIRST_CODEPOINT``.
FONT_NAMES = ("font_0", "font_1", "font_2", "font_3")
FONT_FIRST_CODEPOINT = 32
FONT_SCHEMA = "incubation.fonts/1"
#: One transparent column between glyphs in the atlas, so that a renderer
#: sampling with any filtering cannot bleed a neighbour in.
FONT_ATLAS_GAP = 1


#: ``docs/28`` -- the sound layer's own source directories.  Waves are copied
#: unchanged; music is the GOG release's Ogg substitution for the CD audio the
#: engine asks MCI for, which is packaging rather than engine (``28`` §6).
WAVES_DIR = "Waves"
MUSIC_DIR = "music"
#: The atlas every sprite effect is drawn from: one VISN record named ``anim``,
#: present in all nine world sets and byte-identical in each.  It reaches the
#: cache through the ordinary texture path, so the identity is *checked* rather
#: than assumed and no second container reader exists for it.
ATLAS_TEXTURE = "anim"


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
    waves: int = 0
    tracks: int = 0
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


def model_path(root: Path, name: str) -> Path:
    """One Charisma body; ``docs/40`` §7.1 -- the name is the file stem."""
    return _find(root, "CHData", "Objects", f"{name}.cho")


def animation_path(root: Path, name: str) -> Path:
    """One Charisma clip."""
    return _find(root, "CHData", "Animations", f"{name}.cha")


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
            # `+0x12` and `+0x13` -- the glow's phase and state (docs/42
            # §9.1).  `+0x12` is 1 on 44 of the 184162 shipped cells and 0 on
            # the rest; with `+0x13` at 255 everywhere they are inert
            # leftovers, but they are the columns `SetGroundFire` writes.
            "effect4": [c.raw[0x12] for c in cells],
            "effect5": [c.raw[0x13] for c in cells],
            # Immutable -- MapResource keeps these.
            "land": [c.land for c in cells],
            "start_index": [-1 if c.start_index == levmod.NO_LINK
                            else c.start_index for c in cells],
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
    document: dict[str, Any] = {
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
    parts = _part_documents(proto)
    if parts:
        document["parts"] = parts
    return document


#: ``joint_rotate_3`` (op 9) and ``joint_place`` (op 18) both name a byte
#: offset into the runtime object's joint-angle buffer (``docs/28`` 7.8).  The
#: root's own offset is always 0 in the shipped data and is not emitted; a
#: part's is what a remake needs, because it says *which* angle triple of the
#: live object rotates that part.
_JOINT_PLACE = "joint_place"


def _part_documents(proto: protomod.Prototype) -> list[dict[str, Any]]:
    """The prototype's articulated sub-objects, or ``[]`` when it has none.

    Emitted **only when there are parts**, so the 1 800-odd prototypes that
    have none produce exactly the bytes they produced before.  Each entry
    carries the joint-buffer offset its ``joint_place`` names, the translation
    the ``part_push`` payload gave it, and the vertex slots it owns -- enough
    to rebuild the part as its own node and rotate it about its joint.

    ``vertices`` are indices into the flattened ``vertices`` array above, which
    already has the translation applied; a caller that wants part-local space
    subtracts ``translation``.
    """
    if not proto.parts:
        return []
    # Walk the render stream to pair each part with the `joint_place` inside
    # its own push/pop scope. The parser builds `proto.parts` in push order, so
    # the nth push is the nth part.
    anims: list[int | None] = [None] * len(proto.parts)
    depth: list[int] = []
    seen = 0
    for cmd in proto.render_cmds:
        if cmd.name == "part_push":
            depth.append(seen)
            seen += 1
        elif cmd.name == "part_pop":
            if depth:
                depth.pop()
        elif cmd.name == _JOINT_PLACE and depth:
            anims[depth[-1]] = cmd.operand
    owners: dict[int, list[int]] = {}
    for slot, part in enumerate(proto.vertex_part):
        if part >= 0:
            owners.setdefault(part, []).append(slot)
    out: list[dict[str, Any]] = []
    for index, part in enumerate(proto.parts):
        out.append({
            "anim": anims[index],
            "translation": list(part.translation),
            "vertices": owners.get(index, []),
        })
    return out


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
# Fonts
# ---------------------------------------------------------------------------

def convert_fonts(root: Path, reader: SourceReader,
                  staging: Staging) -> dict[str, Any]:
    """The four bitmap fonts as one atlas each, plus their metrics.

    ``docs/60`` §5: a glyph's ``delta_y`` is its **ascent** -- its top row sits
    at ``baseline - delta_y`` -- and ``height - delta_y`` is a constant per
    font, the descent.  It is 3 in ``font_0``/``font_2`` and 2 in the other
    two, so the descent is derived per font rather than assumed.

    The glyphs are palette **indices**, and the fonts ship without a companion
    ``.pal``: the caller supplies the ramp.  So the atlas is written as
    greyscale-in-RGB -- index value straight into all three channels -- and the
    text colour is the renderer's, which is what the original did by handing
    the font a palette.  Black is transparent, which is what index 0 means for
    every other shape-library sprite too.
    """
    fonts: list[dict[str, Any]] = []
    for name in FONT_NAMES:
        path = reader.record(_find(root, "Libs", f"{name}.LIB"))
        library = liblib.load_lib(str(path))
        # One row, glyph after glyph: 224 glyphs of at most ~17 px is a strip
        # of a few thousand pixels, which no texture size limit minds and which
        # keeps the metrics trivial to state.
        height = max((e.height for e in library.elements), default=1)
        width = sum(e.width + FONT_ATLAS_GAP for e in library.elements)
        pixels = bytearray(max(width, 1) * max(height, 1) * 3)
        glyphs: list[dict[str, Any]] = []
        x = 0
        descents: set[int] = set()
        for index, element in enumerate(library.elements):
            if not element.is_empty:
                descents.add(element.height - element.delta_y)
                for row in range(element.height):
                    src = row * element.width
                    dst = (row * width + x) * 3
                    for column in range(element.width):
                        value = element.pixels[src + column]
                        at = dst + column * 3
                        pixels[at] = value
                        pixels[at + 1] = value
                        pixels[at + 2] = value
            glyphs.append({
                "codepoint": FONT_FIRST_CODEPOINT + index,
                "x": x,
                "width": element.width,
                "height": element.height,
                # The ascent, and the left side bearing -- 0 for every glyph
                # except the two blank ones, space and NBSP, which carry 3.
                "ascent": element.delta_y,
                "bearing": element.delta_x,
            })
            x += element.width + FONT_ATLAS_GAP
        rel = f"fonts/{name}.png"
        target = staging.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        write_rgb_png(str(target), max(width, 1), max(height, 1), bytes(pixels))
        staging.files[rel] = "written"
        fonts.append({
            "name": name,
            "file": f"{name}.png",
            "atlas_width": max(width, 1),
            "atlas_height": max(height, 1),
            "first_codepoint": FONT_FIRST_CODEPOINT,
            "glyphs": glyphs,
            # Stated, not assumed: a font whose glyphs disagreed about it would
            # show up here as more than one value rather than as a wrong
            # baseline nobody noticed.
            "descents": sorted(descents),
            "source": reader.rel(path),
        })
    document: dict[str, Any] = {"schema": FONT_SCHEMA, "fonts": fonts}
    staging.write_json("fonts/index.json", document)
    return document


# ---------------------------------------------------------------------------
# Driving one conversion
# ---------------------------------------------------------------------------

def prototype_names(document: dict[str, Any], tables: BalanceTables,
                    lattice: str) -> list[str]:
    """The transitive closure of one mission's placements.

    ``docs/92`` §10.1 item 2: only the mission and the assets needed to display
    it.  That is the scene's clones, the special objects, the ground lattice,
    and the real models of the inanimate unit types actually placed -- plus the
    one-cell ground marker every living type points at and the contact blip.
    """
    names = {clone["prototype"] for clone in document["scene_clones"]}
    names |= {obj["prototype"] for obj in document["special_objects"]}
    names.add(lattice)
    names.add(UNIT_MARKER_MODEL)
    names.add(CONTACT_MARKER_MODEL)
    for unit in document["units"]:
        if not unit["placed"]:
            continue
        row = tables.units.get(unit["type_id"])
        if row is not None and row.model:
            names.add(row.model)
    return sorted(names)


# ---------------------------------------------------------------------------
# Bodies: the Charisma closure
# ---------------------------------------------------------------------------

def unit_selector_keys(document: dict[str, Any]) -> set[chatables.SelectorKey]:
    """Every ``(type, weapon, player)`` a mission's units can present.

    Two deliberate widenings over :func:`prototype_names`:

    * **unplaced units are included.**  ``prototype_names`` skips them, which is
      right for scenery -- a body that is never placed draws nothing.  It is
      wrong here: reinforcements and script-inserted units are exactly the ones
      that appear later, and a body missing at that moment is a body missing
      when the player is looking;
    * **every weapon is closed over**, not just the type's default.  A unit's
      model changes with its weapon (a marine has 16 bodies), the weapon byte
      is written mid-mission by ``aToggleWeaponModes`` and by scripts, and the
      whole weapon range costs a few hundred lookups and about 25 KB.  Closing
      over the default alone would work until the first weapon toggle.
    """
    return {
        chatables.SelectorKey(unit["type_id"], weapon, unit["player"])
        for unit in document["units"]
        for weapon in range(chatables.WEAPON_LIMIT)
    }


def _masked_faces(document: dict[str, Any]) -> list[dict[str, Any]]:
    """A prototype's faces with the per-world-set texture id removed."""
    return [{k: v for k, v in face.items() if k != "texture"}
            for face in document["faces"]]


def convert_bodies(root: Path, reader: SourceReader, staging: Staging,
                   keys: set[chatables.SelectorKey],
                   result: Conversion) -> set[str]:
    """Emit the bodies, the clips and the selector tables; name the textures.

    Returns the texture **names** the unit meshes reference, for the per-world
    -set texture pass to resolve: a unit body is the same geometry everywhere,
    but a texture *id* is not -- ``caan0000`` is 7 in ``A00`` and 8 in ``E00``.
    """
    exe = reader.record(_find(root, GAME_EXE))
    tables = chatables.SelectorTables(chatables.PEFile(str(exe)), keys)
    staging.write_json("tables/charisma.json", chacache.selector_document(
        tables, {"exe": reader.rel(exe),
                 "sha256": reader.seen[reader.rel(exe)]}, keys))

    model_names: set[str] = set()
    animation_names: set[str] = set()
    for selector in chatables.SELECTORS:
        names = tables.names(selector)
        (model_names if selector == "model" else animation_names).update(names)

    # Bodies.
    mesh_names: set[str] = set()
    model_index: list[dict[str, Any]] = []
    for name in sorted(model_names):
        path = reader.record(model_path(root, name))
        model = chamod.parse_model_file(str(path))
        document = chacache.model_document(name, model)
        staging.write_json(f"models/{name}.json", document)
        meshes = sorted({p["mesh"] for p in document["parts"] if p["mesh"]})
        mesh_names.update(meshes)
        model_index.append({"name": name, "parts": len(document["parts"]),
                            "bones": len(document["skeleton"]["nodes"]),
                            "meshes": meshes})
    staging.write_json("models/index.json", {
        "schema": chacache.MODEL_INDEX_SCHEMA, "models": model_index})

    # Clips.  Tracks whose target matches no part are **kept**: docs/40 §7
    # measures 17 of them across the gameplay set, and the rule a runtime must
    # follow is to ignore them.  Stripping them here would mean the exported
    # build never takes that path on shipped data.
    animation_index: list[dict[str, Any]] = []
    for name in sorted(animation_names):
        path = reader.record(animation_path(root, name))
        animation = chamod.parse_animation_file(str(path))
        document = chacache.animation_document(name, animation)
        staging.write_json(f"animations/{name}.json", document)
        animation_index.append({
            "name": name,
            "duration_bits": document["duration_bits"],
            "tracks": len(document["tracks"]),
            "notes": [n["text"] for n in document["notes"]],
        })
    staging.write_json("animations/index.json", {
        "schema": chacache.ANIMATION_INDEX_SCHEMA,
        "animations": animation_index})

    # Geometry, once for every world set.
    paths = world_paths(root, UNIT_GEOMETRY_SOURCE_SET,
                        _any_scene(root, UNIT_GEOMETRY_SOURCE_SET))
    reader.record(paths["din"])
    reader.record(paths["bin"])
    container = protomod.load_container(str(paths["din"]), str(paths["bin"]))
    prototypes: dict[str, Any] = {}
    missing: list[str] = []
    for name in sorted(mesh_names):
        try:
            index = container.find(name)
        except KeyError:
            missing.append(name)
            continue
        prototypes[name] = prototype_document(container.parse(index))
    if missing:
        result.warnings.append(
            f"unit meshes absent from {UNIT_GEOMETRY_SOURCE_SET}: "
            + ", ".join(missing))

    names_by_id = {entry.index: entry.name
                   for entry in visnmod.read_din_index(str(paths["texture_din"]))}
    document = chacache.unit_geometry_document(
        UNIT_GEOMETRY_SOURCE_SET, prototypes, names_by_id,
        {"din": reader.rel(paths["din"]), "bin": reader.rel(paths["bin"]),
         "sha256": reader.seen[reader.rel(paths["bin"])]})
    staging.write_json("geometry/units.json", document)
    if document["unnamed_textures"]:
        result.warnings.append(
            f"unit meshes reference texture ids with no name in "
            f"{UNIT_GEOMETRY_SOURCE_SET}: {document['unnamed_textures']}")
    result.warnings += _check_cross_set_meshes(root, prototypes)
    return chacache.unit_texture_names(document)


# ---------------------------------------------------------------------------
# Audio and effects
# ---------------------------------------------------------------------------

def _sound_tables():
    """The one reader of ``Incubation.exe``'s sound and effect tables.

    Imported lazily and by module name: ``blob_tables`` is a CLI at the top of
    ``tools/``, which the entry point puts on ``sys.path``.  Duplicating its
    extraction here would give the binary two readings that could drift, which
    is exactly what this repository's rule about corpus checks forbids.
    """
    import blob_tables  # noqa: PLC0415 -- see the docstring
    return blob_tables


def convert_audio(root: Path, reader: SourceReader, staging: Staging,
                  programs: dict[str, Any], result: Conversion,
                  *, music: bool = True) -> dict[str, Any]:
    """Copy the waves the tables can name, the music the missions ask for, and
    write the two documents that say what to play and what to draw.

    The wanted set is the tables' own closure, never the directory: the ten
    ambience files and the four unreferenced waves (``docs/28`` §6) are named
    by nothing in the image, so a cache that carried them would carry sound the
    game cannot reach.  Case is resolved here, once -- every file is written in
    lower case under the name the document uses -- so the runtime never does a
    case-insensitive search on a case-sensitive filesystem (``docs/28`` §2.2).
    """
    tables = _sound_tables()
    document = tables.sound_document(str(root))

    for lower, shipped in sorted(document["waves"].items()):
        source = _find(root, WAVES_DIR, shipped)
        staging.write_bytes(f"audio/waves/{lower}", reader.read_bytes(source))

    # Exactly one name in the closure resolves to nothing, and it is a
    # recorded defect rather than a broken corpus: ``docs/28`` §3.1.
    for name in document["unresolved"]:
        result.warnings.append(
            f"Waves: '{name}' names no shipped file -- Info.lcl's "
            f"SetWeaponInfo2 ({document['weapon_missing_sound']}) typo, "
            "reproduced by default (docs/28 3.1)")

    playlists: dict[str, list[int]] = {}
    for name, program in sorted(programs.items()):
        for instr in program.flat:
            if instr.name != "CDTrackProgram":
                continue
            for arg in instr.args:
                if arg.kind == "string":
                    playlists[name] = soundmod.playlist(arg.value)
    document["playlists"] = playlists

    tracks = sorted({track for entry in playlists.values() for track in entry})
    copied: list[int] = []
    if music:
        for track in tracks:
            source = root / MUSIC_DIR / (soundmod.MUSIC_FORMAT % track)
            if not source.is_file():
                result.warnings.append(
                    f"{MUSIC_DIR}: no {source.name} for a playlist that "
                    "names it")
                continue
            staging.write_bytes(f"audio/music/{track}.ogg",
                                reader.read_bytes(source))
            copied.append(track)
    else:
        result.warnings.append(
            f"music: not converted (--no-music); {len(tracks)} track(s) the "
            "missions name are absent from the cache")
    document["tracks"] = copied
    document["music_converted"] = music

    staging.write_json("tables/sound.json", document)
    staging.write_json("tables/blobs.json", tables.blob_document(str(root)))
    # **The engine's own sine and arctangent tables**, shipped in every world
    # set's `IMG/` and byte-identical across all 21 (`docs/70`).  They are in
    # the cache rather than regenerated in GDScript because `docs/70`'s open
    # question 1 is that the generation rounding is unknown: `img_tables.py`
    # can only show the formula agrees to within one unit, and one unit of a
    # 4096-unit circle is one unit of every angle built on it.  `docs/28`
    # 12.1's orientation hook is exact against the engine only with these.
    shipped = eng3d.load(str(root))
    staging.write_json("tables/trig.json",
                       {"trig": shipped.trig, "atn": shipped.atn,
                        "angle_units": eng3d.ANGLE_UNITS,
                        "sine_scale": eng3d.SINE_SCALE,
                        "q14_shift": eng3d.Q14_SHIFT})
    result.waves = len(document["waves"])
    result.tracks = len(copied)
    return document


def effect_models(root: Path) -> list[str]:
    """The thirty ``.3DI`` names the blob constructor calls pass.

    They are ordinary world-object prototypes, so they join the mission's own
    closure and resolve through the same ``prototyp.dir`` chain (``docs/28``
    §7.5).  Four of them exist in one or two world sets only; a set that lacks
    one is not an error -- the original's constructor returns ``-1`` and the
    effect does not appear -- so the pairing is recorded as a constraint.
    """
    return _sound_tables().blob_models(_sound_tables().Binary(str(root)))


#: ``docs/42`` §9.1 -- the seven models the four cell placers name.  They are
#: ordinary world-object prototypes and resolve through the same chain the
#: blob models do, with the same consequence for a set that lacks one: the
#: constructor answers -1 and the placer writes nothing.  **Only ``D00`` has
#: the two glows**, and both missions that use ``SetGroundFire`` are in it.
SPECIAL_OBJECT_MODELS = ("A_FIRE1.3DI", "A_FIRE2.3DI", "A_FIRE3.3DI",
                         "A_MINE.3DI", "A_SHILD.3DI", "GLOW1.3DI", "GLOW2.3DI")
SPECIAL_OBJECT_MODELS_RARE = {"GLOW1.3DI": ("D00",), "GLOW2.3DI": ("D00",)}


def rare_effect_models(root: Path) -> dict[str, tuple[str, ...]]:
    """``model -> the world sets that have it``, for the four that are rare."""
    out = dict(_sound_tables().BLOB_MODELS_RARE)
    out.update(SPECIAL_OBJECT_MODELS_RARE)
    return out


def _any_scene(root: Path, world_set: str) -> str:
    """Any scene of a world set -- only the Objects/ paths are wanted."""
    base = _find(root, "WorldSet", f"World_{world_set}", "Worlds")
    for entry in sorted(base.iterdir()):
        if entry.suffix.upper() == ".3DW":
            return entry.stem
    raise ConvertError(f"World_{world_set} has no .3DW scene")


def _check_cross_set_meshes(root: Path,
                            prototypes: dict[str, Any]) -> list[str]:
    """The claim the shared unit geometry rests on, checked where it is used.

    Emitting bodies once instead of nine times is only sound if a unit mesh is
    the same geometry in every world set.  ``charisma_tables --check`` proves
    every unit mesh is *present* in all nine; that a mesh is also *identical*
    once the per-set texture id is masked is what makes one copy enough, and
    the converter is where that has consequences, so it is checked here rather
    than assumed from a measurement made elsewhere.
    """
    complaints: list[str] = []
    base = _find(root, "WorldSet")
    others = [entry.name.split("_", 1)[1] for entry in sorted(base.iterdir())
              if entry.is_dir() and entry.name.startswith("World_")
              and entry.name != f"World_{UNIT_GEOMETRY_SOURCE_SET}"]
    for world_set in others:
        paths = world_paths(root, world_set, _any_scene(root, world_set))
        container = protomod.load_container(str(paths["din"]), str(paths["bin"]))
        for name, document in prototypes.items():
            try:
                index = container.find(name)
            except KeyError:
                complaints.append(f"{name} absent from {world_set}")
                continue
            other = prototype_document(container.parse(index))
            if _masked_faces(other) != _masked_faces(document) \
                    or other["vertices"] != document["vertices"]:
                complaints.append(
                    f"{name} differs between {UNIT_GEOMETRY_SOURCE_SET} and "
                    f"{world_set} by more than its texture ids")
    return complaints


def convert(root: Path, missions: list[str], staging: Staging,
            reader: SourceReader, language: str,
            *, music: bool = True) -> Conversion:
    """Convert every named mission and everything it reaches into `staging`."""
    result = Conversion()
    info_path = reader.record(_find(root, "DATA", "Info.lcl"))
    tables = load_info_file(str(info_path))
    staging.write_json("tables/balance.json", tables.to_dict())

    wanted_by_set: dict[str, set[str]] = {}
    scenes_by_set: dict[str, set[str]] = {}
    selector_keys: set[chatables.SelectorKey] = set()
    scripts: dict[str, Any] = {}
    # The effects reach the same prototype index as the scenery, so they join
    # every set's closure rather than getting a container reader of their own.
    effects = effect_models(root)
    rare = rare_effect_models(root)

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
        scripts[name] = program
        wanted_by_set.setdefault(bm.world_set, set()).update(
            prototype_names(document, tables, _lattice_prototype(bm)))
        wanted_by_set[bm.world_set].update(effects)
        wanted_by_set[bm.world_set].update(SPECIAL_OBJECT_MODELS)
        scenes_by_set.setdefault(bm.world_set, set()).add(bm.world_scene)
        selector_keys |= unit_selector_keys(document)

    # The bodies come before the world-set pass because they decide which
    # textures each set has to decode: the shared unit geometry names its
    # textures and every set resolves those names to its own ids.
    unit_textures = convert_bodies(root, reader, staging, selector_keys, result)

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
        result.prototypes += len(document["prototypes"])
        # An effect model that a world set does not have is the original's own
        # behaviour, not a broken closure: the constructor reports it and
        # returns -1, and the effect simply does not appear (docs/28 §7.5).
        # Recording it as a constraint keeps a real missing prototype visible.
        absent_effects = [n for n in document["missing"]
                          if n in rare and world_set not in rare[n]]
        genuinely_missing = [n for n in document["missing"]
                             if n not in absent_effects]
        document["absent_effects"] = absent_effects
        # The placer models this set actually has -- `MapState` gates on it,
        # because a `SetGroundFire` outside `World_D00` writes nothing.
        document["special_models"] = [n for n in SPECIAL_OBJECT_MODELS
                                      if n in document["prototypes"]]
        if absent_effects:
            result.warnings.append(
                f"{world_set}: effect models this set does not have, so the "
                "effect is cancelled rather than drawn (docs/28 7.5): "
                + ", ".join(absent_effects))
        if genuinely_missing:
            result.warnings.append(
                f"{world_set}: prototypes named but absent from prototyp.din: "
                + ", ".join(genuinely_missing))
        staging.write_json(f"geometry/{world_set}.json", document)
        # The unit bodies' textures, resolved from name to this set's own ids.
        ids_by_name = {entry.name: entry.index for entry
                       in visnmod.read_din_index(str(paths["texture_din"]))}
        unresolved = sorted(unit_textures - set(ids_by_name))
        if unresolved:
            result.warnings.append(
                f"{world_set}: unit textures with no record: "
                + ", ".join(unresolved))
        textures |= {ids_by_name[name] for name in unit_textures
                     if name in ids_by_name}
        # The sprite atlas is named by no face, so the closure has to ask for
        # it: every class-2 and class-3 blob is a tile out of this one record.
        atlas_id = ids_by_name.get(ATLAS_TEXTURE)
        if atlas_id is None:
            result.warnings.append(
                f"{world_set}: no '{ATLAS_TEXTURE}' texture -- every sprite "
                "effect in this set would draw nothing")
        else:
            textures.add(atlas_id)
        index = convert_textures(reader, staging, world_set,
                                 paths["texture_lib"], paths["texture_din"],
                                 textures)
        staging.write_json(f"textures/{world_set}/index.json", index)
        result.textures += len(index["textures"])
        result.world_sets.append(world_set)

    convert_fonts(root, reader, staging)
    convert_audio(root, reader, staging, scripts, result, music=music)

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
