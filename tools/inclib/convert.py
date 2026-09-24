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

import hashlib
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from . import charisma as chamod
from . import charisma_cache as chacache
from . import charisma_tables as chatables
from . import eng3d
from . import footprint as footprintmod
from . import language
from . import lev as levmod
from . import liblib
from . import overdraw as overdrawmod
from . import prototyp as protomod
from . import sound as soundmod
from . import visn as visnmod
from .cache import SourceReader, Staging
from .pe import PEFile
from .info import BalanceTables, load_info_file
from .script import (GUI_TEXT_DIR, load_script, script_document,
                     text_catalogue)
from .png import rgb_png_bytes, write_indexed_png, write_rgb_png

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
#: The ten victory-point markers ``0x00431E30`` stands on cells whose action
#: point is 80..89 (docs/42 §9.3), by ``action point - 0x50``.  Every world set
#: carries all ten, and every mission asks for all ten because a capture can
#: turn any ``A`` into any player's ``A``.  ``A_MK_0B`` is also what 30 of the
#: 36 ``SetUnitInfo`` rows name as their model, which the remake does not draw
#: under a body (docs/92 §7.1, 2026-09-07).
VICTORY_MARKER_MODELS = tuple(f"A_MK_{player}{band}.3DI"
                              for band in "AB" for player in range(5))
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
#: elements, one per **byte** from 32 to 255 of the release's code page, so
#: the element index is ``byte - FONT_FIRST_BYTE``.  The cache writes both the
#: byte and the Unicode code point it stands for (``inclib.language``), so a
#: Cyrillic release's glyphs register under Cyrillic code points.
FONT_NAMES = ("font_0", "font_1", "font_2", "font_3")
FONT_FIRST_BYTE = 32
FONT_SCHEMA = "incubation.fonts/1"
FONT_INDEX = "fonts/index.json"
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
    #: The campaign layer -- docs/27, docs/24, docs/60.
    campaign_missions: int = 0
    briefings: int = 0
    #: ``Events.txt`` labels -- the pickup messages, docs/26 section 3.
    info_labels: int = 0
    plates: int = 0
    briefing_pictures: int = 0
    ui_libraries: int = 0
    ui_sprites: int = 0
    #: The cutscenes and the front end -- docs/41, docs/92 section 7.19.
    sequence_pairs: int = 0
    sequence_tracks: int = 0
    voice_overs: int = 0
    warnings: list[str] = field(default_factory=list)
    #: The documents a language pack is converted against -- ``gui``,
    #: ``sound``, ``frontend`` -- kept so the pack never re-derives a file
    #: list of its own (docs/92 §7.6).
    documents: dict[str, Any] = field(default_factory=dict)
    #: Per pack name: what :func:`convert_language_pack` wrote and dropped.
    packs: dict[str, dict[str, Any]] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Paths inside the installation
# ---------------------------------------------------------------------------

def _find(root: Path, *parts: str) -> Path:
    """Case-insensitive lookup: the shipped tree mixes cases freely."""
    current = root
    for part in parts:
        lower = part.lower()
        entries = sorted(current.iterdir(), key=lambda entry: entry.name)
        exact = next((entry for entry in entries if entry.name == part), None)
        matches = [entry for entry in entries if entry.name.lower() == lower]
        if exact is not None:
            current = exact
        elif len(matches) == 1:
            current = matches[0]
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


def gui_text_paths(root: Path, directory: str) -> list[Path]:
    """The interface-string programs under ``DATA/TXT/<directory>/GUI``, in
    a stable order."""
    base = _find(root, "DATA", "TXT", directory, GUI_TEXT_DIR)
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

def parse_3dw_clones(path: Path) -> list[dict[str, Any]]:
    """Clone blocks from a ``.3DW``.

    ``3dw_parse`` is a sibling CLI whose module name starts with a digit, so it
    cannot be imported by name.  Moving it into ``inclib`` is a separate task.

    Separate from :func:`_parse_3dw` so that a reader who is not converting --
    ``interaction_tables.py`` asks which cells the scene's own geometry stands
    on -- does not have to invent a :class:`SourceReader` to get at it.
    """
    import importlib.util

    tools = Path(__file__).resolve().parent.parent
    spec = importlib.util.spec_from_file_location(
        "_dw_parse", tools / "3dw_parse.py")
    if spec is None or spec.loader is None:
        raise ConvertError("cannot load tools/3dw_parse.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.parse_3dw(str(path)).clones


def _parse_3dw(reader: SourceReader, path: Path) -> list[dict[str, Any]]:
    """:func:`parse_3dw_clones`, with the file recorded in the manifest."""
    reader.record(path)
    return parse_3dw_clones(path)


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
                     source: dict[str, Any],
                     footprints: list[list[int]] | None = None
                     ) -> dict[str, Any]:
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
                # docs/28 §7.2 -- the joint triples of parts 6 and 12, which
                # the `.lev` authors and a door's leaves are posed by
                # (docs/26 §3.4).  Since 0.24.0.
                "joints": [list(j) for j in o.joints],
                # `0x0042F410`'s four-probe sweep, run here once so that
                # neither runtime has to hold a mesh (`inclib.footprint`).
                # This is `CrushWall`'s footprint -- docs/42 §8.2.  Since
                # 0.40.0.
                "cells": list(cells),
            }
            for o, cells in zip(bm.special, footprints
                                if footprints is not None
                                else [[]] * len(bm.special))
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

def _face_document(face: protomod.Face, overdraw: int = 0) -> dict[str, Any]:
    document: dict[str, Any] = {
        "draw_kind": face.draw_kind,
        "draw_name": face.draw_name,
        "texture": -1 if face.texture is None else face.texture,
        "colour": face.colour,
        "rgb": list(protomod.colour_rgb(face.colour)),
        "indices": list(face.indices),
        # The raw 8.7 fixed point the record carries, 0..32767, not a ratio.
        "uvs": [] if face.uvs is None else [list(uv) for uv in face.uvs],
    }
    if overdraw:
        # How many layers of earlier-drawn coplanar faces the engine's span
        # buffer paints over this one (`inclib.overdraw`).  Since 0.44.0;
        # absent on the 236 643 faces nothing overlaps.
        document["overdraw"] = overdraw
    return document


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
    overdraw = {id(f): rank
                for f, rank in zip(proto.faces, overdrawmod.overdraw_ranks(proto))}
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
        "faces": [_face_document(f, overdraw.get(id(f), 0))
                  for f in _iter_faces(proto.tree)],
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

#: One process, one decode per distinct VISN record.
#:
#: A record decodes to exactly one PNG: :func:`visn.decode_record` and the
#: writer are both pure functions of the record's bytes.  ``--check`` runs
#: **three** whole conversions in one process and a published cache shares
#: texture sets between world sets and cutscene directories, so the same
#: records were being decoded and re-compressed several times over -- twenty
#: of the thirty-four seconds one conversion takes (``docs/92`` §7.13 D9).
#: Keyed by the record's own bytes, so two sets that ship the same texture
#: share the entry and a set that does not is unaffected.
_TEXTURE_PNGS: dict[bytes, tuple[int, int, bytes]] = {}


def _texture_png(record: bytes) -> tuple[int, int, bytes]:
    """The decoded PNG for one VISN record, decoding it at most once."""
    key = hashlib.sha256(record).digest()
    made = _TEXTURE_PNGS.get(key)
    if made is None:
        image = visnmod.decode_record(record)
        made = (image.width, image.height,
                rgb_png_bytes(image.width, image.height, image.to_rgb888()))
        _TEXTURE_PNGS[key] = made
    return made


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
        width, height, png = _texture_png(record)
        rel = f"textures/{world_set}/{entry.index}.png"
        path = staging.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(png)
        staging.files[rel] = "written"
        index.append({
            "id": entry.index,
            "name": entry.name,
            "width": width,
            "height": height,
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

def convert_fonts(root: Path, reader: SourceReader, staging: Staging,
                  code_page: str | None = "cp1252",
                  index_rel: str = FONT_INDEX) -> dict[str, Any]:
    """The four bitmap fonts as one atlas each, plus their metrics.

    *code_page* is the release's (``inclib.language``): it decides which
    Unicode code point each of the 224 byte slots is registered under.
    *index_rel* is where the index lands, so a language pack can write its
    fonts beside the neutral ones under its own prefix.

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
            byte = FONT_FIRST_BYTE + index
            glyphs.append({
                "byte": byte,
                "codepoint": language.codepoint(byte, code_page),
                "x": x,
                "width": element.width,
                "height": element.height,
                # The ascent, and the left side bearing -- 0 for every glyph
                # except the two blank ones, space and NBSP, which carry 3.
                "ascent": element.delta_y,
                "bearing": element.delta_x,
            })
            x += element.width + FONT_ATLAS_GAP
        rel = f"{Path(index_rel).parent.as_posix()}/{name}.png"
        target = staging.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        write_rgb_png(str(target), max(width, 1), max(height, 1), bytes(pixels))
        staging.files[rel] = "written"
        fonts.append({
            "name": name,
            "file": f"{name}.png",
            "atlas_width": max(width, 1),
            "atlas_height": max(height, 1),
            "first_byte": FONT_FIRST_BYTE,
            "glyphs": glyphs,
            # Stated, not assumed: a font whose glyphs disagreed about it would
            # show up here as more than one value rather than as a wrong
            # baseline nobody noticed.
            "descents": sorted(descents),
            "source": reader.rel(path),
        })
    document: dict[str, Any] = {"schema": FONT_SCHEMA,
                                "code_page": code_page, "fonts": fonts}
    staging.write_json(index_rel, document)
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
    ten victory-point markers and the contact blip.
    """
    names = {clone["prototype"] for clone in document["scene_clones"]}
    names |= {obj["prototype"] for obj in document["special_objects"]}
    names.add(lattice)
    names.update(VICTORY_MARKER_MODELS)
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

#: The seats a converted unit can be handed to: the shooter's player byte,
#: which for the one converting weapon is a human seat.
CONVERTIBLE_TO: tuple[int, ...] = tuple(range(4))


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
      over the default alone would work until the first weapon toggle;
    * **every human seat is closed over as well.**  Weapon 47 -- the
      Enhanced Laser's second mode -- hands its target to the shooter
      (``0x0046BDAD``, ``docs/22`` §7.3), so an alien can present under a
      human player's byte mid-mission.  The selector answers such a key with
      the alien's own body, but a cache without the key drew the fallback
      capsule in its place.
    """
    return {
        chatables.SelectorKey(unit["type_id"], weapon, player)
        for unit in document["units"]
        for player in {unit["player"], *CONVERTIBLE_TO}
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

    # ``docs/40`` §7.2's fourth row: ``fcn.004055e0``'s ``kind == 4`` reaches a
    # fixed literal instead of a selector, so no selector's closure names it and
    # the cache used to be without it.  It is the clip the upgrade bases' own
    # marines march on (``docs/27`` §2.7.1), and a cache that lacks it draws the
    # landing pad empty.
    kind4 = chatables.PEFile(str(exe)).cstring(chatables.KIND4_LITERAL_VA)
    if kind4:
        animation_names.add(kind4)

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
    document = tables.sound_document(str(root), reader.record)

    for lower, shipped in sorted(document["waves"].items()):
        source = _find(root, WAVES_DIR, shipped)
        staging.write_bytes(f"audio/waves/{lower}", reader.read_bytes(source))

    # docs/28 §4.3 -- the speech tree.  Copied whole rather than by closure:
    # the original builds `Speech\\<dir>\\<prefix><category><index>.wav` and
    # asks the filesystem, so which names it can reach is a property of the
    # directory and not of a table, and a name that resolves to nothing is
    # silence.  Case is resolved here for the same reason it is for the flat
    # waves -- three of the ten directories are shipped in a case the binary's
    # own literals do not match, and one of those is a directory name.
    speech = document["speech"]["files"]
    for lower, shipped in sorted(speech.items()):
        source = _find(root, WAVES_DIR, soundmod.SPEECH_DIRECTORY,
                       *shipped.split("/"))
        staging.write_bytes(f"audio/waves/speech/{lower}",
                            reader.read_bytes(source))

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
    # The front end's own programs -- the menu, the credits, mission control
    # and the debriefing (``seq_parse.FRONTEND``) -- name ``Arack`` tracks
    # 2..8, which a six-mission slice's scripts may not, so they join the
    # wanted set under their own keys.  Same family as the missions': it is
    # the shipped shim that plays them (``docs/28`` 6.1).
    frontend = _tool_module("seq_parse").FRONTEND["cd_programs"]
    for name, (program, _va, _call) in sorted(frontend.items()):
        playlists[f"frontend/{name}"] = soundmod.playlist(program)
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
    shipped = eng3d.load(str(root), reader.record)
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



# ---------------------------------------------------------------------------
# The sequences and the front end -- docs/41, docs/92 section 7.19
# ---------------------------------------------------------------------------

SEQUENCE_DIR_SCHEMA = "incubation.sequence-directory/1"
#: ``Video/<dir>/`` -- twelve directories, 130 model/animation pairs.
VIDEO_DIR = "Video"
#: Where the briefing voice-overs and the static extro's wave live.
BRIEFING_WAVE_DIR = "Briefing"
#: ``%smb%daif.wav`` (``0x004CA8D8``) with ``%d`` the ``_C_1xx`` id, in the
#: case the shipped tree happens to use for each file.
VOICE_OVER_PREFIX = "mb"
VOICE_OVER_SUFFIX = "aif.wav"
EXTRO_WAVE = "extro.wav"


def convert_sequences(root: Path, reader: SourceReader, staging: Staging,
                      result: Conversion) -> dict[str, Any]:
    """The cutscenes: per directory the models, the clips, the geometry and the
    textures, plus ``tables/sequences.json`` -- the manifest ``seq_parse.py``
    reads out of ``aSetSeqPlayerVideoPart``.

    **Only the 130 selected files, never a directory listing** (``docs/41``
    section 2): ``Dialog_16`` ships nine zero-padded models the engine never
    names and ``Seq_3`` two misspelled clips.  Each directory carries its own
    ``Objects/Prototyp.*`` and ``Textures/Texture.*``, so the geometry and the
    textures are per directory too, under a ``video_<dir>`` texture set.
    """
    seq = _tool_module("seq_parse")
    exe = reader.record(_find(root, GAME_EXE))
    pe = PEFile(exe)
    manifest = seq.manifest_document(pe)
    video = _find(root, VIDEO_DIR)

    by_directory: dict[str, list[Any]] = {}
    for part in seq.parts():
        by_directory.setdefault(part.directory, []).append(part)

    directories: list[dict[str, Any]] = []
    for directory in sorted(by_directory):
        base = _find(video, directory)
        model_names: dict[str, Path] = {}
        animation_names: dict[str, Path] = {}
        for part in by_directory[directory]:
            for stem in part.stems:
                model_names[part.model(stem)[:-4]] = _find(base, part.model(stem))
                animation_names[part.animation(stem)[:-4]] = _find(
                    base, part.animation(stem))

        mesh_names: set[str] = set()
        for name, path in sorted(model_names.items()):
            model = chamod.parse_model_file(str(reader.record(path)))
            document = chacache.model_document(name, model)
            staging.write_json(f"sequences/{directory}/models/{name}.json",
                               document)
            mesh_names.update(p["mesh"] for p in document["parts"] if p["mesh"])
        for name, path in sorted(animation_names.items()):
            animation = chamod.parse_animation_file(str(reader.record(path)))
            staging.write_json(
                f"sequences/{directory}/animations/{name}.json",
                chacache.animation_document(name, animation))

        din = reader.record(_find(base, "Objects", "Prototyp.din"))
        bin_path = reader.record(_find(base, "Objects", "Prototyp.bin"))
        container = protomod.load_container(str(din), str(bin_path))
        texture_set = f"video_{directory}"
        geometry, textures = geometry_document(texture_set, sorted(mesh_names),
                                               container, {
            "din": reader.rel(din), "bin": reader.rel(bin_path),
            "sha256": reader.seen[reader.rel(bin_path)],
        })
        if geometry["missing"]:
            result.warnings.append(
                f"{VIDEO_DIR}/{directory}: meshes named by a model but absent "
                f"from Prototyp.din: " + ", ".join(geometry["missing"]))
        staging.write_json(f"sequences/{directory}/geometry.json", geometry)
        index = convert_textures(reader, staging, texture_set,
                                 _find(base, "Textures", "Texture.lib"),
                                 _find(base, "Textures", "Texture.din"),
                                 textures)
        staging.write_json(f"textures/{texture_set}/index.json", index)
        result.textures += len(index["textures"])
        staging.write_json(f"sequences/{directory}/index.json", {
            "schema": SEQUENCE_DIR_SCHEMA,
            "directory": directory,
            "texture_set": texture_set,
            "models": sorted(model_names),
            "animations": sorted(animation_names),
            "meshes": sorted(mesh_names),
        })
        directories.append({
            "directory": directory, "texture_set": texture_set,
            "models": len(model_names), "animations": len(animation_names),
            "meshes": len(geometry["prototypes"]),
            "textures": len(index["textures"]),
        })
        result.sequence_pairs += len(animation_names)

    manifest["directories"] = directories
    manifest["source"] = {"exe": reader.rel(exe),
                          "sha256": reader.seen[reader.rel(exe)]}
    staging.write_json("tables/sequences.json", manifest)
    return manifest


def convert_frontend(root: Path, reader: SourceReader, staging: Staging,
                     result: Conversion, *, music: bool) -> dict[str, Any]:
    """``tables/frontend.json``, the briefing voice-overs, the extro wave and
    the ``Track`` family's tracks 9..19 the cutscenes name.

    The voice-overs are speech and go in unconditionally; the cutscene music
    is behind the same ``--no-music`` flag as the missions' (``docs/28``).  It
    is a **separate namespace**, ``audio/music/track/<n>.ogg``: the shipped
    build plays the ``Arack`` family for the missions and that family stops at
    14, so the cutscenes' 9..19 can only come from ``Track`` -- a decision
    recorded in ``docs/92`` section 7.19, not a reading of the engine.
    """
    seq = _tool_module("seq_parse")
    exe = reader.record(_find(root, GAME_EXE))
    document = seq.frontend_document(PEFile(exe))

    voices: dict[str, str] = {}
    wave_dir = _find(root, BRIEFING_WAVE_DIR)
    for path in sorted(wave_dir.iterdir()):
        lower = path.name.lower()
        if not (lower.startswith(VOICE_OVER_PREFIX)
                and lower.endswith(VOICE_OVER_SUFFIX)):
            continue
        digits = lower[len(VOICE_OVER_PREFIX):-len(VOICE_OVER_SUFFIX)]
        if not digits.isdigit():
            continue
        mission = f"_c_{int(digits)}"
        staging.write_bytes(f"audio/briefing/{mission}.wav",
                            reader.read_bytes(path))
        voices[mission] = reader.rel(path)
    extro = _find(wave_dir, EXTRO_WAVE)
    staging.write_bytes(f"audio/briefing/{EXTRO_WAVE}", reader.read_bytes(extro))
    document["voice_overs"] = sorted(voices)
    result.voice_overs = len(voices)

    copied: list[int] = []
    tracks = sorted({seq.cd_track_of(part.cd_program) for part in seq.parts()
                     if part.cd_program})
    if music:
        for track in tracks:
            source = root / seq.MUSIC_DIR / (seq.CD_FILE_FORMAT % track)
            if not source.is_file():
                result.warnings.append(
                    f"{seq.MUSIC_DIR}: no {source.name} for a sequence that "
                    "names it")
                continue
            staging.write_bytes(f"audio/music/track/{track}.ogg",
                                reader.read_bytes(source))
            copied.append(track)
    document["cd_family"] = seq.CD_FAMILY
    document["track_family_tracks"] = copied
    document["music_converted"] = music
    staging.write_json("tables/frontend.json", document)
    result.sequence_tracks = len(copied)
    return document


def convert(root: Path, missions: list[str], staging: Staging,
            reader: SourceReader, language_name: str,
            *, music: bool = True) -> Conversion:
    """Convert every named mission and everything it reaches into `staging`.

    *language_name* is the base tree's language (``inclib.language``); the
    packs laid over it are :func:`convert_language_pack`'s.
    """
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

    # `0x0042F410`'s sweep needs the world set's meshes, and the world-set
    # pass below runs after every mission is read -- so the containers are
    # opened here, once each, and that pass reuses them.
    containers: dict[str, protomod.Container] = {}
    angles = eng3d.load(str(root), reader.record)

    for name in missions:
        path = reader.record(mission_path(root, name))
        bm = levmod.load_lev(str(path))
        paths = world_paths(root, bm.world_set, bm.world_scene)
        clones = scene_clones(_parse_3dw(reader, paths["dw"]))
        if bm.world_set not in containers:
            containers[bm.world_set] = protomod.load_container(
                str(paths["din"]), str(paths["bin"]))
        footprints = footprintmod.special_object_cells(
            bm, containers[bm.world_set], angles)
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
        }, footprints)
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
        container = containers.get(world_set) or protomod.load_container(
            str(paths["din"]), str(paths["bin"]))
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

    try:
        spec = language.spec(language_name)
    except language.LanguageError as exc:
        raise ConvertError(str(exc)) from exc
    convert_fonts(root, reader, staging, spec.code_page)
    result.documents["sound"] = convert_audio(root, reader, staging, scripts,
                                              result, music=music)

    catalogue = convert_gui_text(root, reader, staging, spec)
    result.documents["gui"] = catalogue
    result.text_entries = sum(len(v) for v in catalogue["gui"].values())

    # The campaign layer.  It is not per-mission: the location graph, the
    # briefings and the interface art are the same whichever missions were
    # asked for, so a six-mission slice and a full bake carry the same tables
    # and the campaign screens work in both.
    result.campaign_missions = convert_campaign(
        root, reader, staging, campaign_tables_document(root))
    result.briefings = convert_briefings(root, reader, staging, spec.directory,
                                         result, code_page=spec.code_page)
    result.documents["events"] = convert_info_events(
        root, reader, staging, spec.directory, result, code_page=spec.code_page)
    result.info_labels = len(result.documents["events"]["blocks"])
    result.info_labels += convert_info_data(root, reader, staging,
                                            spec.directory, result,
                                            code_page=spec.code_page)
    art = convert_art(root, reader, staging, result)
    # The cutscenes and the screens between them: not per-mission either.
    convert_sequences(root, reader, staging, result)
    result.documents["frontend"] = convert_frontend(root, reader, staging,
                                                    result, music=music)
    result.plates = art["plates"]
    result.briefing_pictures = art["briefing"]
    result.ui_libraries = art["libraries"]
    result.ui_sprites = art["sprites"]
    return result


#: The neutral interface-string catalogue.  It was ``text/<language>.json``
#: while the cache held one language; a pack mirrors the neutral paths under
#: ``lang/<Name>/`` and a path that carried the language twice would resolve
#: to nothing, so the file is named for what it is.
GUI_TEXT_DOCUMENT = "text/gui.json"


def convert_gui_text(root: Path, reader: SourceReader, staging: Staging,
                     spec: language.LanguageSpec,
                     stems: list[str] | None = None,
                     missing: list[str] | None = None) -> dict[str, Any]:
    """``text/gui.json`` -- the ``DATA/TXT/<dir>/GUI`` programs' text entries.

    *stems* overrides the directory listing with the **base** tree's stems, so
    a pack's catalogue has the base's banks and no others; a stem the tree
    lacks goes into *missing* rather than raising.
    """
    # Each bank is keyed by the **base's** stem when one is given: the pack
    # file's own spelling may differ in case, and `Localization` asks for the
    # bank by the neutral catalogue's name.
    if stems is None:
        paths = [(gui_path.stem, gui_path)
                 for gui_path in gui_text_paths(root, spec.directory)]
    else:
        paths = []
        for stem in stems:
            try:
                paths.append((stem, _find(root, "DATA", "TXT", spec.directory,
                                          GUI_TEXT_DIR, f"{stem}.lcl")))
            except ConvertError:
                if missing is None:
                    raise
                missing.append(f"DATA/TXT/{spec.directory}/{GUI_TEXT_DIR}/"
                               f"{stem}.lcl")
    programs = {}
    text_source: dict[str, Any] = {}
    encoding = spec.code_page or "latin-1"
    for stem, gui_path in paths:
        reader.record(gui_path)
        programs[stem] = load_script(gui_path, encoding)
        text_source[stem] = reader.rel(gui_path)
    catalogue = text_catalogue(programs, spec.name, {"files": text_source})
    catalogue["code_page"] = spec.code_page
    staging.write_json(GUI_TEXT_DOCUMENT, catalogue)
    return catalogue


def interaction_tables_document(exe: Path) -> dict[str, Any]:
    """Which action point shows which ``Events.txt`` label, and which speaks.

    Read out of ``Incubation.exe`` by ``interaction_tables.py``'s own decoder
    rather than transcribed: the arm that hands two characters to the pickup
    sequence ``0x00410780`` is what names the label, and the arm that calls
    ``0x0047B660`` is what has a voice line.  A hand-written table on either
    side of the cache would be a second copy that could disagree by a swapped
    pair and pass both checks.

    Records, not an object keyed by the id: ``docs/92`` D12 -- a JSON object's
    key is a string and the cache carries integers.
    """
    module = _tool_module("interaction_tables")
    tables = module.InteractionTables(chatables.PEFile(str(exe)))
    out: list[dict[str, Any]] = []
    for action_point, case in sorted(tables.cases().items()):
        if "text" not in case:
            continue
        out.append({
            "action_point": action_point,
            "label": case["text"],
            # ``docs/26`` section 3: twelve of the thirteen arms also play
            # speech event 9, and *Found nothing* is the one that does not.
            "speech": case.get("speech", -1),
        })
    return {"pickups": out}


def _tool_module(name: str):
    """One of ``tools/*.py``, imported by path.

    The tools live beside ``tools/inclib/`` rather than inside it, so an
    ordinary import would depend on how the caller set ``sys.path``.
    ``campaign_tables_document`` established this route (``docs/27`` section
    8.2): the alternative is a second decoder of the same tables.
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        name, Path(__file__).resolve().parent.parent / f"{name}.py")
    if spec is None or spec.loader is None:
        raise ConvertError(f"cannot locate tools/{name}.py")
    import sys

    if name in sys.modules:
        return sys.modules[name]
    module = importlib.util.module_from_spec(spec)
    # Registered **before** it runs: a module that declares a `dataclass`
    # under `from __future__ import annotations` resolves its field types
    # through `sys.modules[cls.__module__]`, and an unregistered module fails
    # there with an `AttributeError` on `None`.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def campaign_tables_document(root: Path) -> dict[str, Any]:
    """``campaign_tables.py``'s decoding, imported rather than re-derived.

    The tool lives in ``tools/`` and this library in ``tools/inclib/``, so the
    import is by path: the alternative is a second decoder of the same switch
    tables, which is exactly what ``docs/27`` §8.2 says a converter should not
    write.
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "campaign_tables",
        Path(__file__).resolve().parent.parent / "campaign_tables.py")
    if spec is None or spec.loader is None:
        raise ConvertError("cannot locate tools/campaign_tables.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.tables_document(str(root))


# --- the campaign layer -- docs/27, docs/24, docs/60 -------------------------

#: ``campaign_tables.py`` decodes these out of ``Incubation.exe``; the
#: converter bakes the result rather than re-deriving it (``docs/27`` §8.2).
CAMPAIGN_SCHEMA = "incubation.campaign/1"
BRIEFING_SCHEMA = "incubation.briefing/1"
ART_SCHEMA = "incubation.art/1"

#: ``docs/24`` -- the three blocks a briefing screen shows.
BRIEFING_BLOCKS = ("A0", "B0", "C0")
BRIEFING_DIR = "Briefing"
INFO_SCHEMA = "incubation.info/1"
#: ``DATA/TXT/<lang>/Info`` -- the info files ``aActivateInfo`` opens by name.
INFO_DIR = "Info"
#: ``docs/24`` §7.2 enumerates the four info files and finds that ``Errors``
#: and ``Campaign`` are unreachable in this build.  ``Events`` is the pickup
#: sequence's (``0x00410780``); ``Data`` is baked too, by
#: :func:`convert_info_data`, and a mission does show it -- the battle
#: interface's magnifying glass opens a unit's page out of it
#: (``docs/43`` §5.2.1).
INFO_EVENTS = "Events"
#: The item, weapon and unit descriptions the Upgrade Menu's *i* opens.
#: `0x00432B20/70/D0` name the file `Data` and pass a label of one letter plus
#: a digit -- 0 for a unit, 1 for equipment, 2 for a weapon -- and the letter
#: is the record's own `key` column (`SetEquipInfo`'s and `SetWeaponInfo2`'s
#: last string), with `#` meaning the record has no page.
INFO_DATA = "Data"
#: The screen plates, and where the briefing pictures live.
PLATE_DIR = ("Graphics", "GUI")
BRIEFING_ART_DIR = ("Graphics", "Briefing")
#: The five top-level screens, which sit beside those two directories rather
#: than in either.  They are 640x480 8-bit BMPs like every other plate, so they
#: are baked through the same writer and land in ``art/plates`` beside the
#: seven framed ones -- ``Title`` is the shell's backdrop and ``Credits`` its
#: optional roll; ``Bluebyte``, ``Ship`` and ``MsgScr`` come along because the
#: loop is one loop, and have no consumer yet.
ROOT_PLATE_DIR = ("Graphics",)
ROOT_PLATES = ("Title", "Credits", "Ship", "MsgScr", "Bluebyte")
#: The expansion's installer carries its own title picture outside
#: ``Graphics``.  It is not a screen plate -- the remake uses it as the second
#: campaign card -- but it is the same indexed BMP format and belongs beside
#: the base game's ``Graphics/Title.bmp`` in the converted art cache.
WILDERNESS_TITLE = ("Install", "Title.bmp")
#: The interface libraries.  The four fonts are excluded: `convert_fonts`
#: already writes them as atlases with their metrics.
UI_LIB_DIR = "Libs"
UI_ITEM_DIR = "Items"


def campaign_document(root: Path, tables: dict[str, Any],
                      missions: dict[str, Any], source: dict[str, Any],
                      ) -> dict[str, Any]:
    """``tables/campaign.json`` -- the location graph plus the chain.

    Every id-keyed table is emitted as a **list of records** (D12): a JSON
    object's key is a string, and the cache has to carry integers.  The
    precedent is `inclib/info.py`, and the trap it avoids is the one
    `tables/balance.json` already carries -- `equipment` has no id 2, so a
    position is not an id.
    """
    from . import campaign as cammod

    location = cammod.LocationTables.from_json(tables)
    document: dict[str, Any] = {
        "schema": CAMPAIGN_SCHEMA,
        "source": source,
        **location.to_records(),
    }
    # What campaign_tables does not carry: the chain, read from the headers.
    document["missions"] = [
        {
            "name": name,
            "mission_id": battle.mission_id,
            "next_map": battle.next_map,
            "campaign": _campaign_of(battle.mission_id),
            "deployment_cells": sorted(
                [c.x, c.y] for c in battle.cells
                if c.action_point == cammod.LOCATION_BIAS - 49),
            "ships_a_squad": any(u.placed and u.player == 0
                                 for u in battle.units),
        }
        for name, battle in sorted(missions.items())
    ]
    document["campaigns"] = [
        {
            "number": number,
            "first_mission": cammod.CAMPAIGN_FIRST_MISSION[number],
            "map": cammod.CAMPAIGN_MAP[number],
            "seeds_a_squad": number == 1,
        }
        for number in sorted(cammod.CAMPAIGN_FIRST_MISSION)
    ]
    # The three cut locations and the two nothing opens, so a screen that
    # meets one knows it is shipped data rather than a converter bug.
    document["cut_locations"] = [
        {"location": loc, "mission": _CUT_MISSIONS[loc]}
        for loc in sorted(_CUT_MISSIONS)]
    document["unreachable_locations"] = sorted(_UNREACHABLE_LOCATIONS)
    document["economy"] = {
        "recruit_markup": cammod.RECRUIT_MARKUP,
        "equipment_point_cap": cammod.EQUIPMENT_POINT_CAP,
        "resale_scale": cammod.RESALE_SCALE,
        "ep_per_rank": cammod.EP_PER_RANK,
        "difficulty_multiplier": list(cammod.DIFFICULTY_MULTIPLIER),
        "result_base_score": list(cammod.RESULT_BASE_SCORE),
        "start_equipment_points": cammod.CAMPAIGN_START_EQUIPMENT_POINTS,
        "start_tech_level": cammod.CAMPAIGN_START_TECH_LEVEL,
        "start_skill_level": cammod.CAMPAIGN_START_SKILL_LEVEL,
        "pool_slots": cammod.POOL_USABLE_SLOTS,
    }
    # The Recruit window's rows (docs/27 section 3.2): preset ids, each a
    # ready-made type-0 soldier `0x00476260` builds -- a `Txtmod_h` name, a
    # weapon, equipment, EP and FP, and the markup its price adds to the
    # items' costs. Emitted as records because the ids are not contiguous.
    document["recruits"] = [
        {
            "id": int(preset),
            "name_id": row["name_id"],
            "weapon": row["weapon"],
            "equipment": list(row["equipment"]),
            "ep": row["ep"],
            "fp": row["fp"],
            "markup": row["markup"],
        }
        for preset, row in sorted(tables.get("recruit_presets", {}).items(),
                                  key=lambda kv: int(kv[0]))
    ]
    document["squad_seed"] = [
        {"record": record, "offset": offset, "value": value}
        for (record, offset), value in sorted(
            _squad_fields(tables).items())
    ]
    return document


#: ``docs/27`` §2.2 -- table entries naming missions the release does not ship.
_CUT_MISSIONS = {85: "_C_134", 86: "_C_135", 87: "_C_136"}
#: ``_C_XXX``'s *TEST EXTRO* and *<<Invalid Location>>*.
_UNREACHABLE_LOCATIONS = (21, 50)


def _squad_fields(tables: dict[str, Any]) -> dict[tuple[int, int], int]:
    """``campaign_tables``' ``"record:0xNN"`` keys, back to integers."""
    out: dict[tuple[int, int], int] = {}
    for key, value in tables.get("squad_fields", {}).items():
        record, offset = key.split(":")
        out[(int(record), int(offset, 16))] = int(value)
    return out


def _campaign_of(mission_id: int) -> int:
    """Which chain a mission id belongs to -- ``docs/27`` §6.6."""
    if 1 <= mission_id <= 34:
        return 1
    if 40 <= mission_id <= 79:
        return 2
    return 0


def convert_campaign(root: Path, reader: SourceReader, staging: Staging,
                     tables: dict[str, Any]) -> int:
    """Bake ``tables/campaign.json`` and return how many missions it names."""
    exe = reader.record(_find(root, GAME_EXE))
    missions: dict[str, Any] = {}
    for path in sorted((root / "Missions").glob("_C_*.lev")):
        # ``_C_XXX`` is campaign 1's map and nothing else.  ``_C_YYY`` is
        # campaign 2's map **and** the mission ``_C_133`` hands over to: its
        # header carries mission id 255, which ``0x00456FC0`` reads as the
        # animated extro, so it is a row here the way ``_C_180`` (id 180, the
        # static extro) already is (``docs/27`` section 6.6, corrected
        # 2026-09-08).
        if path.stem.upper() == "_C_XXX":
            continue
        missions[path.stem] = levmod.load_lev(str(reader.record(path)))
    document = campaign_document(root, tables, missions, {
        "exe": reader.rel(exe),
        "sha256": reader.seen[reader.rel(exe)],
    })
    staging.write_json("tables/campaign.json", document)
    return len(missions)


def _decode_text(data: bytes, code_page: str | None) -> str:
    """A ``DATA/TXT`` file's bytes as text: de-obfuscated, then every byte
    through :func:`language.codepoint` -- the one byte-to-glyph rule the
    fonts use, so a briefing byte and the glyph it is drawn with cannot
    disagree.  The markup itself is ASCII plus ``§`` (0xA7), which both
    shipped code pages place at the same code point."""
    from .lcl import decode
    return language.decode_bytes(decode(data), code_page)


def briefing_files(root: Path, directory: str) -> list[tuple[str, Path]]:
    """``(stem, path)`` of every briefing text under ``DATA/TXT/<directory>``.

    `glob("*.txt")` is case-sensitive on macOS and Linux, and five shipped
    files are `.TXT` -- the same trap `liblib._existing` exists for.
    """
    base = _find(root, "DATA", "TXT", directory, BRIEFING_DIR)
    return [(p.stem, p) for p in sorted(base.iterdir())
            if p.suffix.lower() == ".txt"]


def convert_briefings(root: Path, reader: SourceReader, staging: Staging,
                      directory: str, result: Conversion, *,
                      code_page: str | None = "cp1252",
                      files: list[tuple[str, Path]] | None = None) -> int:
    """``text/briefing/<mission>.json`` -- ``docs/24``'s three blocks.

    The markup is written as **structure** (``docs/92`` §3.2): a block is a
    list of spans carrying their font and colour ramp, so the consumer renders
    rather than re-parses.  The picture programme rides along, because a
    briefing screen shows text and pictures from the same file.

    *directory* is the ``DATA/TXT`` component and *code_page* the release's
    (``inclib.language``).  *files* overrides the directory listing with
    ``(stem, path)`` pairs -- a language pack is written under the **base**
    tree's stems so that one resolver serves both.
    """
    from . import brieftext as briefmod

    if files is None:
        files = briefing_files(root, directory)
    written = 0
    for stem, path in files:
        recorded = reader.record(path)
        try:
            text = _decode_text(recorded.read_bytes(), code_page)
        except Exception as exc:                       # noqa: BLE001
            result.warnings.append(f"{path.name}: unreadable briefing ({exc})")
            continue
        blocks: dict[str, Any] = {}
        for key in BRIEFING_BLOCKS:
            offset = briefmod.find_label(text, key)
            if offset is None:
                continue
            blocks[key] = [span.to_dict()
                           for span in briefmod.spans(text, offset)]
        if not blocks:
            # Not a failure: docs/24 records that not every file carries all
            # three, and a briefing with none is one the screen shows empty.
            result.warnings.append(
                f"{path.name}: none of {'/'.join(BRIEFING_BLOCKS)}")
        pictures = [
            {"row": entry.row, "picture": entry.picture,
             "x": entry.x, "y": entry.y,
             "descriptions": list(entry.descriptions)}
            for entry in briefmod.program(text, briefmod.BRIEFING_BASE_ROW)
        ]
        tips = [
            {"row": entry.row, "picture": entry.picture,
             "x": entry.x, "y": entry.y,
             "descriptions": list(entry.descriptions)}
            for entry in briefmod.program(text, briefmod.TIP_BASE_ROW)
        ]
        staging.write_json(f"text/briefing/{stem}.json", {
            "schema": BRIEFING_SCHEMA,
            "mission": stem,
            "code_page": code_page,
            "source": {"txt": reader.rel(recorded),
                       "sha256": reader.seen[reader.rel(recorded)]},
            "blocks": blocks,
            "pictures": pictures,
            "tips": tips,
        })
        written += 1
    return written


def convert_info_events(root: Path, reader: SourceReader, staging: Staging,
                        directory: str, result: Conversion, *,
                        code_page: str | None = "cp1252",
                        tables: dict[str, Any] | None = None) -> dict[str, Any]:
    """``text/info/events.json`` -- what a pickup says (docs/26 section 3).

    ``aExecuteUse``'s thirteen pickup arms hand a two-character label to the
    shared pickup sequence ``0x00410780``, which opens ``Events`` and draws it
    through ``aActivateInfo`` ``0x0043E740``.  The labels are **read out of the
    file** rather than listed here: ``interaction_tables.EXPECTED_TEXT`` is the
    check that the shipped set is ``E0``..``EC``, and a second copy of it here
    would be a table the emitter could not disagree with.

    The markup is written as structure, exactly as :func:`convert_briefings`
    writes a briefing block, so the consumer renders rather than re-parses
    (``docs/92`` section 3.2), and the action-point-to-label map rides along
    from :func:`interaction_tables_document` so that the game side has no
    table of its own to disagree with.

    *tables* is that map when the caller already has it -- a language pack
    reuses the base's rather than opening an executable its own tree does
    not carry; ``None`` reads it out of ``Incubation.exe`` under *root*.
    """
    from . import brieftext as briefmod

    base = _find(root, "DATA", "TXT", directory, INFO_DIR)
    path = _find(base, f"{INFO_EVENTS}.txt")
    recorded = reader.record(path)
    source: dict[str, Any] = {"txt": reader.rel(recorded),
                              "sha256": reader.seen[reader.rel(recorded)]}
    if tables is None:
        exe = reader.record(_find(root, GAME_EXE))
        source["exe"] = reader.rel(exe)
        source["exe_sha256"] = reader.seen[reader.rel(exe)]
        tables = interaction_tables_document(exe)
    try:
        text = _decode_text(recorded.read_bytes(), code_page)
    except Exception as exc:                           # noqa: BLE001
        result.warnings.append(f"{path.name}: unreadable info text ({exc})")
        return {"blocks": {}}
    blocks: dict[str, Any] = {}
    for label in briefmod.labels(text):
        # The first definition of a label wins, which is `aFindGUITextBoxTag`'s
        # own rule: it takes the first match and never looks further.
        if label.key in blocks:
            continue
        blocks[label.key] = [span.to_dict()
                             for span in briefmod.spans(text, label.value)]
    if not blocks:
        result.warnings.append(f"{path.name}: no {{:xy}} label at all")
    document: dict[str, Any] = {
        "schema": INFO_SCHEMA,
        "name": INFO_EVENTS,
        "code_page": code_page,
        "source": source,
        "blocks": blocks,
    }
    # Which action point shows which of those blocks, and which one speaks --
    # decoded out of the switch rather than listed here or in the consumer.
    document.update(tables)
    staging.write_json(f"text/info/{INFO_EVENTS.lower()}.json", document)
    return document


#: The keys :func:`convert_info_events` writes itself; everything else in its
#: document is :func:`interaction_tables_document`'s, which a language pack
#: copies from the base document rather than re-reading the executable.
INFO_EVENTS_OWN_KEYS = ("schema", "name", "code_page", "source", "blocks")


def convert_info_data(root: Path, reader: SourceReader, staging: Staging,
                      directory: str, result: Conversion, *,
                      code_page: str | None = "cp1252") -> int:
    """``text/info/data.json`` -- what the Upgrade Menu's *i* shows, and the
    magnifying glass with it.

    The button toggles `0x00510A54`; at 1 the item window stops loading its
    picture (`0x00458BFE`) and `aPrintInfo` `0x0043ECF0` draws an info page
    instead. Which page is decided by `0x00432B70` for equipment and
    `0x00432BD0` for a weapon: both read a **letter out of the record**
    (`+0x29` of the 42-byte equipment record, `+0x40` of the 65-byte weapon
    one -- `inclib.info` already parses it as `key`), refuse when it is `#`,
    and open `Data` with that letter plus a digit naming the family: `0` a
    unit, `1` equipment, `2` a weapon. So `Scan Module`'s `A` is block `A1`.

    The blocks are written as markup structure, exactly as a briefing is, and
    the digits are **not** listed on the game side: the document carries the
    family map so the consumer composes a label rather than knowing one.

    The `units` family is the fourth call site, `0x00432B20`, which is the
    battle interface's magnifying glass rather than a screen (`docs/43`
    §5.2.1). It reads the same column out of `SetUnitInfo` and, unlike the
    two item paths, makes no test for `#` at all.
    """
    from . import brieftext as briefmod

    base = _find(root, "DATA", "TXT", directory, INFO_DIR)
    path = _find(base, f"{INFO_DATA}.txt")
    recorded = reader.record(path)
    try:
        text = _decode_text(recorded.read_bytes(), code_page)
    except Exception as exc:                           # noqa: BLE001
        result.warnings.append(f"{path.name}: unreadable info text ({exc})")
        return 0
    blocks: dict[str, Any] = {}
    for label in briefmod.labels(text):
        if label.key in blocks:
            continue
        blocks[label.key] = [span.to_dict()
                             for span in briefmod.spans(text, label.value)]
    if not blocks:
        result.warnings.append(f"{path.name}: no {{:xy}} label at all")
    document: dict[str, Any] = {
        "schema": INFO_SCHEMA,
        "name": INFO_DATA,
        "code_page": code_page,
        "source": {"txt": reader.rel(recorded),
                   "sha256": reader.seen[reader.rel(recorded)]},
        # `0x00432B20`, `0x00432B70`, `0x00432BD0` -- the digit each family
        # appends to the record's own letter.
        "families": {"units": "0", "equipment": "1", "weapons": "2"},
        #: `0x00432B86` / `0x00432BE4`: this letter means "no page".
        "no_page": "#",
        "blocks": blocks,
    }
    staging.write_json(f"text/info/{INFO_DATA.lower()}.json", document)
    return len(blocks)


def _write_sprites(reader: SourceReader, staging: Staging, root: Path,
                   lib_path: Path, prefix: str,
                   result: Conversion) -> dict[str, Any] | None:
    """One shape library as a directory of indexed PNGs plus its index."""
    recorded = reader.record(lib_path)
    try:
        library = liblib.load_lib(str(recorded))
    except liblib.LibError as exc:
        result.warnings.append(f"{lib_path.name}: {exc}")
        return None
    palette, source = liblib.find_palette(str(recorded), str(root), reader.record)
    # Index 0 is the key colour only where the library actually uses it; a
    # library with none is written opaque, as `lib_extract` does.
    keyed = (liblib.TRANSPARENT_INDEX
             if liblib.uses_transparent_index(library) else None)
    stem = lib_path.stem.lower()
    if source is None and stem not in liblib.UNREFERENCED_LIBRARIES:
        result.warnings.append(
            f"{lib_path.name}: no palette companion, written greyscale")
    sprites = []
    for index, element in enumerate(library.elements):
        rel = f"{prefix}/{stem}/{index:03d}.png"
        if element.is_empty:
            sprites.append({"index": index, "width": element.width,
                            "height": element.height, "file": None,
                            "x": element.delta_x, "y": element.delta_y})
            continue
        target = staging.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        write_indexed_png(str(target), element.width, element.height,
                          bytes(element.pixels), palette, keyed)
        staging.files[rel] = "written"
        sprites.append({"index": index, "width": element.width,
                        "height": element.height,
                        "file": f"{index:03d}.png",
                        "x": element.delta_x, "y": element.delta_y})
    return {
        "name": stem,
        "palette": None if source is None else reader.rel(Path(source)),
        "unreferenced": stem in liblib.UNREFERENCED_LIBRARIES,
        "sprites": sprites,
    }


#: The cache names of the two title pictures a `--plate` override may supply.
PLATE_TITLE = "title"
PLATE_WILDERNESS = "wilderness_title"


def art_listing(root: Path) -> dict[str, list[str]]:
    """What :func:`convert_art` bakes out of *root*, by name.

    Listed once and handed to every tree the art is read from: a language
    pack is converted against the **base** tree's listing, so a pack file the
    base does not have is never baked and a case-drifted pack filename still
    lands under the base's cache name.
    """
    plate_dir = _find(root, *PLATE_DIR)
    picture_dir = _find(root, *BRIEFING_ART_DIR)
    lib_dir = _find(root, UI_LIB_DIR)
    libraries = [p.name for p in sorted(lib_dir.iterdir())
                 if p.suffix.lower() == ".lib"
                 and not p.stem.lower().startswith("font_")
                 and p.stem.lower() not in liblib.UNREFERENCED_LIBRARIES]
    item_dir = lib_dir / UI_ITEM_DIR
    if item_dir.is_dir():
        libraries += [f"{UI_ITEM_DIR}/{p.name}" for p in sorted(item_dir.iterdir())
                      if p.suffix.lower() == ".lib"]
    return {
        "plates": [p.name for p in sorted(plate_dir.iterdir())
                   if p.suffix.lower() == ".bmp"],
        "briefing": [p.name for p in sorted(picture_dir.iterdir())
                     if p.suffix.lower() == ".bmp"],
        "libraries": libraries,
    }


def convert_art(root: Path, reader: SourceReader, staging: Staging,
                result: Conversion, *,
                plates: dict[str, Path] | None = None,
                listing: dict[str, list[str]] | None = None,
                missing: list[str] | None = None) -> dict[str, int]:
    """The screen plates, the briefing pictures and the interface sprites.

    The plates and pictures are 8-bit BMPs (``inclib/bmp.py``); the interface
    is shape libraries drawn with the palette ``liblib.find_palette`` resolves.

    *plates* overrides where a named title picture is read from
    (:data:`PLATE_TITLE`, :data:`PLATE_WILDERNESS`) for a tree that lacks it
    -- the 1C release has no ``Install/Title.bmp``.  *listing* is
    :func:`art_listing`'s answer for the tree the names come from, and
    *missing*, when given, turns a file that listing names and *root* lacks
    from an error into an entry in that list: a language pack is allowed to
    be thinner than the base, the base is not.
    """
    from . import bmp as bmpmod

    counts = {"plates": 0, "briefing": 0, "libraries": 0, "sprites": 0}
    if listing is None:
        listing = art_listing(root)
    overrides = plates or {}

    def locate(*parts: str) -> Path | None:
        try:
            return _find(root, *parts)
        except ConvertError:
            if missing is None:
                raise
            missing.append("/".join(parts))
            return None

    def write_bmp(path: Path, rel: str, name: str | None = None,
                  override: str | None = None) -> dict[str, Any] | None:
        # An overriding plate may live outside the tree; it is fingerprinted
        # under the command-line name that supplied it.
        recorded = reader.record(path) if override is None \
            else reader.record_external(path, f"--plate/{override}")
        try:
            image = bmpmod.parse(recorded.read_bytes())
        except bmpmod.BmpError as exc:
            result.warnings.append(f"{path.name}: {exc}")
            return None
        target = staging.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        # A plate is opaque: unlike a sprite, index 0 is an ordinary colour.
        image.write_png(str(target), None)
        staging.files[rel] = "written"
        return {"name": name or Path(rel).stem, "file": Path(rel).name,
                "width": image.width, "height": image.height}

    plate_entries = []
    for name in listing["plates"]:
        path = locate(*PLATE_DIR, name)
        if path is None:
            continue
        entry = write_bmp(path, f"art/plates/{Path(name).stem.lower()}.png")
        if entry is not None:
            plate_entries.append(entry)
            counts["plates"] += 1

    # The five that live one level up.  Named rather than globbed: the
    # directory also holds `GUI/` and `Briefing/`, and a glob that grew a sixth
    # file would bake it without anyone deciding to.
    for stem in ROOT_PLATES:
        override = overrides.get(stem.lower())
        path = override or locate(*ROOT_PLATE_DIR, f"{stem}.bmp")
        if path is None:
            continue
        entry = write_bmp(path, f"art/plates/{stem.lower()}.png",
                          override=stem.lower() if override else None)
        if entry is not None:
            plate_entries.append(entry)
            counts["plates"] += 1

    # The expansion title has the same basename as the base game's title, so
    # its cache name is explicit.  Reading it through ``SourceReader`` also
    # makes it part of the source fingerprint: an installation without the
    # expansion cannot silently publish a campaign card with no picture.
    override = overrides.get(PLATE_WILDERNESS)
    wilderness = override or locate(*WILDERNESS_TITLE)
    if wilderness is not None:
        entry = write_bmp(wilderness, f"art/plates/{PLATE_WILDERNESS}.png",
                          PLATE_WILDERNESS,
                          override=PLATE_WILDERNESS if override else None)
        if entry is not None:
            plate_entries.append(entry)
            counts["plates"] += 1

    pictures = []
    for name in listing["briefing"]:
        path = locate(*BRIEFING_ART_DIR, name)
        if path is None:
            continue
        entry = write_bmp(path, f"art/briefing/{Path(name).stem.lower()}.png")
        if entry is not None:
            pictures.append(entry)
            counts["briefing"] += 1

    libraries = []
    for name in listing["libraries"]:
        path = locate(UI_LIB_DIR, *name.split("/"))
        if path is None:
            continue
        entry = _write_sprites(reader, staging, root, path, "ui", result)
        if entry is None:
            continue
        libraries.append(entry)
        counts["libraries"] += 1
        counts["sprites"] += sum(1 for s in entry["sprites"] if s["file"])

    staging.write_json("art/index.json", {
        "schema": ART_SCHEMA,
        "plates": plate_entries,
        "briefing": pictures,
        "libraries": libraries,
    })
    return counts


# ---------------------------------------------------------------------------
# Language packs
# ---------------------------------------------------------------------------

NAMES_SCHEMA = "incubation.names/1"
#: Where a pack's files land, mirroring the neutral relative paths beneath.
LANG_DIR = "lang"
#: `docs/10` -- the unit record's one runtime-scratch byte the guard ignores:
#: `+0x56` is a stale Charisma animation handle (177 shipped records carry
#: one), and two releases of the same map differ in it without differing in
#: the map.  Every other non-name byte has to match.
UNIT_SCRATCH_OFFSETS = (0x56,)
#: The `Info.lcl` columns that are text in the release's language; every other
#: column of :meth:`BalanceTables.to_dict` has to match the base's.  `key` is
#: **not** one of them: the 1C release keeps the base's `Data.txt` page
#: letters, checked by hand on 2026-09-13.
BALANCE_NAME_COLUMNS = {"ctrlmap": "name", "equipment": "name",
                        "units": "description", "weapons": "name"}


def _pack_find(root: Path, missing: list[str], *parts: str) -> Path | None:
    """:func:`_find`, with an absent file recorded rather than raised."""
    try:
        return _find(root, *parts)
    except ConvertError:
        missing.append("/".join(parts))
        return None


def lev_name_overlay(base: bytes, pack: bytes, encoding: str,
                     ) -> tuple[dict[str, str], list[int], int]:
    """The unit names a pack's ``.lev`` may lend the base's.

    Returns ``(names by slot, skipped slots, differing bytes)``.  **The name
    is overlaid only onto a record that is otherwise byte-identical**: the
    two files' unit records are compared with the name field and
    :data:`UNIT_SCRATCH_OFFSETS` zeroed, and a slot whose record differs
    keeps the base's name.  The 1C release ships eight maps in an older
    authored state than the GOG patches (`_C_140`, `_C_142`, `_C_144`,
    `_C_149`, `_C_159`, `_C_166`, `_C_167`, `_M_019`); this is what keeps
    their cells, objects and stats out while their names still come through,
    and it is why the pack's ``.lev`` is never read for anything but names.
    A pack file of another size is no counterpart at all: nothing is overlaid.
    """
    if len(base) != len(pack):
        return {}, [], -1
    spans = levmod.unit_name_spans(base)
    names: dict[str, str] = {}
    skipped: list[int] = []
    differing = 0
    for slot, (start, _end) in enumerate(spans):
        a = bytearray(base[start:start + levmod.UNIT_SIZE])
        b = bytearray(pack[start:start + levmod.UNIT_SIZE])
        name_a = bytes(a[:levmod.UNIT_NAME_SIZE]).split(b"\0", 1)[0]
        name_b = bytes(b[:levmod.UNIT_NAME_SIZE]).split(b"\0", 1)[0]
        for record in (a, b):
            record[:levmod.UNIT_NAME_SIZE] = bytes(levmod.UNIT_NAME_SIZE)
            for offset in UNIT_SCRATCH_OFFSETS:
                record[offset] = 0
        if a != b:
            differing += sum(1 for x, y in zip(a, b) if x != y)
            if name_a or name_b:
                skipped.append(slot)
            continue
        if name_b and name_b != name_a:
            names[str(slot)] = name_b.decode(encoding, errors="replace")
    # Bytes outside the unit block -- cells, objects, header -- count too, so
    # the warning says how far the two files are apart even when every
    # record matched.
    unit_start = spans[0][0]
    unit_end = spans[-1][0] + levmod.UNIT_SIZE
    differing += sum(1 for i in range(len(base))
                     if not unit_start <= i < unit_end and base[i] != pack[i])
    return names, skipped, differing


def balance_name_overlay(base: dict[str, Any], pack: dict[str, Any],
                         file_name: str) -> dict[str, dict[str, str]]:
    """The names a pack's ``Info.lcl`` lends the base's, after the guard.

    Both are :meth:`BalanceTables.to_dict`.  Every column but the four in
    :data:`BALANCE_NAME_COLUMNS` has to be equal row for row, or the pack is
    refused with the file and the first differing field named: a balance
    table is gameplay, and a localisation that changed one is not a
    localisation (docs/92 §7.6).
    """
    out: dict[str, dict[str, str]] = {}
    for table, column in BALANCE_NAME_COLUMNS.items():
        rows_a = base.get(table, [])
        rows_b = pack.get(table, [])
        if len(rows_a) != len(rows_b):
            raise ConvertError(
                f"{file_name}: {table} has {len(rows_b)} rows, the base "
                f"{len(rows_a)}; a language pack may change names only")
        names: dict[str, str] = {}
        for row_a, row_b in zip(rows_a, rows_b):
            for field_name in row_a:
                if field_name == column:
                    continue
                if row_a[field_name] != row_b.get(field_name):
                    key = row_a.get("id", row_a.get("index"))
                    raise ConvertError(
                        f"{file_name}: {table}[{key}].{field_name} is "
                        f"{row_b.get(field_name)!r}, the base "
                        f"{row_a[field_name]!r}; a language pack may change "
                        "names only")
            if row_b[column] != row_a[column]:
                names[str(row_a.get("id", row_a.get("index")))] = row_b[column]
        out[table] = names
    return out


#: The three tables of ``art/index.json`` and the key each is looked up by.
ART_INDEX_TABLES = ("plates", "briefing", "libraries")


def _complete_art_index(parent: Staging, sub: Staging) -> None:
    """Fill a pack's ``art/index.json`` with the neutral entries it lacks.

    The art is **index-driven**: `Art` reads one index and asks for a plate,
    a picture or a library by name out of it, so a pack index that listed
    only what the pack tree had would lose -- not fall back on -- every plate
    or library the pack lacks.  The neutral entry names the same cache-relative
    file, which the resolver then serves from the neutral tree, exactly as it
    does for every other per-file miss.  Appended in the neutral order, so a
    pack that lacks nothing is written byte for byte as before.
    """
    rel = "art/index.json"
    neutral = json.loads((parent.root / rel).read_text(encoding="utf-8"))
    document = json.loads((sub.root / rel).read_text(encoding="utf-8"))
    for table in ART_INDEX_TABLES:
        have = {entry["name"] for entry in document.get(table, [])}
        for entry in neutral.get(table, []):
            if entry["name"] not in have:
                document.setdefault(table, []).append(entry)
    sub.write_json(rel, document)


def _merge_pack(parent: Staging, sub: Staging, prefix: str) -> tuple[int, int]:
    """Move a pack staging's entries under *prefix* in the parent's `files`,
    dropping every file whose bytes equal the neutral one -- an unchanged
    library or wave costs nothing and resolves to the neutral copy anyway.
    Returns ``(kept, dropped)``."""
    kept = dropped = 0
    for rel in sorted(sub.files):
        path = sub.root / rel
        neutral = parent.root / rel
        if rel in parent.files and neutral.is_file() \
                and neutral.read_bytes() == path.read_bytes():
            path.unlink()
            dropped += 1
            continue
        parent.files[prefix + rel] = sub.files[rel]
        kept += 1
    # Directories a dedup emptied.
    for directory in sorted((p for p in sub.root.rglob("*") if p.is_dir()),
                            key=lambda p: len(p.parts), reverse=True):
        if not any(directory.iterdir()):
            directory.rmdir()
    if sub.root.is_dir() and not any(sub.root.iterdir()):
        sub.root.rmdir()
    return kept, dropped


def convert_language_pack(base_root: Path, pack_root: Path, name: str,
                          staging: Staging, result: Conversion, *,
                          missions: list[str],
                          plates: dict[str, Path] | None = None,
                          ) -> dict[str, Any]:
    """Lay one localisation over the neutral cache under ``lang/<Name>/``.

    **The base root is the only source of gameplay data** (docs/92 §7.6).  A
    pack contributes the language-dependent subset and nothing else: the GUI
    banks, the briefings and info pages, the four fonts, the plates and
    interface libraries, the briefing voice-overs and the waves, and the unit,
    weapon, equipment and cell-type *names* out of its ``Info.lcl`` and
    ``.lev`` files -- after :func:`balance_name_overlay` and
    :func:`lev_name_overlay` have compared everything that is not a name with
    the base.  It never opens a mission script, a world set, ``CHData``, a
    texture library, an executable or the music.

    **Every file list is the base's.**  The stems, plate names, library names
    and wave names come from what the base conversion wrote; the pack tree is
    only asked for a counterpart of each, and one it lacks is a warning.  So
    a pack file the base does not have is never baked, and a case-drifted
    pack filename still lands under the neutral cache name, which is what
    lets one resolver serve every language.

    Every pack file byte-identical to its neutral twin is dropped again
    (:func:`_merge_pack`).  Returns the manifest's entry for the pack.
    """
    spec = language.spec(name)
    if pack_root.resolve() == base_root.resolve():
        raise ConvertError(
            f"language pack {name}: its root is the base root; a pack is a "
            "second tree laid over the base, not the base again")
    if spec.code_page is None:
        raise ConvertError(
            f"language pack {name}: no single-byte code page; the two-byte "
            "text path is not implemented (docs/24 section 4.4)")
    encoding = spec.code_page
    prefix = f"{LANG_DIR}/{name}/"
    reader = SourceReader(root=pack_root, prefix=prefix)
    sub = Staging(root=staging.root / LANG_DIR / name)
    sub.root.mkdir(parents=True, exist_ok=True)
    missing: list[str] = []
    stats: dict[str, Any] = {"language": name, "code_page": encoding}

    def warn(message: str) -> None:
        result.warnings.append(f"{name} pack: {message}")

    # --- the guard runs first: a pack whose balance table is not the base's
    # is refused before anything of it is written.
    base_balance = load_info_file(str(_find(base_root, "DATA", "Info.lcl")))
    info_path = _pack_find(pack_root, missing, "DATA", "Info.lcl")
    balance_names: dict[str, dict[str, str]] = {}
    if info_path is not None:
        pack_balance = load_info_file(str(reader.record(info_path)), encoding)
        balance_names = balance_name_overlay(base_balance.to_dict(),
                                             pack_balance.to_dict(),
                                             f"{name} pack Info.lcl")

    mission_names: dict[str, dict[str, str]] = {}
    lev_notes: list[str] = []
    for mission in missions:
        base_lev = mission_path(base_root, mission)
        pack_lev = _pack_find(pack_root, missing, "Missions", f"{mission}.lev")
        if pack_lev is None:
            continue
        names, skipped, differing = lev_name_overlay(
            base_lev.read_bytes(), reader.read_bytes(pack_lev), encoding)
        if differing < 0:
            lev_notes.append(f"{mission}.lev: another size, no names taken")
            continue
        if differing:
            lev_notes.append(
                f"{mission}.lev: {differing} byte(s) differ beyond unit "
                f"names; {len(names)} name(s) overlaid, slots "
                f"{skipped} kept the base's")
        if names:
            mission_names[mission] = names
    if lev_notes:
        warn("maps in another authored state than the base (the pack's "
             "cells, objects and stats are never read): "
             + "; ".join(lev_notes))
    sub.write_json("names.json", {
        "schema": NAMES_SCHEMA,
        "language": name,
        "code_page": encoding,
        "balance": balance_names,
        "missions": mission_names,
    })

    # --- text: the GUI banks, the briefings, the two info pages.
    base_gui = result.documents["gui"]
    catalogue = convert_gui_text(pack_root, reader, sub, spec,
                                 stems=sorted(base_gui["gui"]), missing=missing)
    short: list[str] = []
    for bank, entries in sorted(base_gui["gui"].items()):
        theirs = catalogue["gui"].get(bank, {})
        gone = sorted((int(k) for k in entries if k not in theirs))
        if gone:
            short.append(f"{bank}: {len(gone)} id(s) "
                         f"{gone[0]}..{gone[-1]}")
    if short:
        warn("bank ids the base has and the pack lacks (the game falls back "
             "to the base's text per id): " + "; ".join(short))
    stats["text_entries"] = sum(len(v) for v in catalogue["gui"].values())

    base_briefings = briefing_files(base_root, language.spec(
        result.documents["gui"]["language"]).directory)
    files: list[tuple[str, Path]] = []
    for stem, _path in base_briefings:
        counterpart = _pack_find(pack_root, missing, "DATA", "TXT",
                                 spec.directory, BRIEFING_DIR, f"{stem}.txt")
        if counterpart is not None:
            files.append((stem, counterpart))
    stats["briefings"] = convert_briefings(pack_root, reader, sub,
                                           spec.directory, result,
                                           code_page=encoding, files=files)
    base_events = result.documents.get("events", {})
    tables = {k: v for k, v in base_events.items()
              if k not in INFO_EVENTS_OWN_KEYS}
    for label, converter in ((INFO_EVENTS, convert_info_events),
                             (INFO_DATA, convert_info_data)):
        if _pack_find(pack_root, missing, "DATA", "TXT", spec.directory,
                      INFO_DIR, f"{label}.txt") is None:
            continue
        if converter is convert_info_events:
            stats["info_events"] = len(convert_info_events(
                pack_root, reader, sub, spec.directory, result,
                code_page=encoding, tables=tables)["blocks"])
        else:
            stats["info_data"] = convert_info_data(
                pack_root, reader, sub, spec.directory, result,
                code_page=encoding)

    # --- the fonts, and the art.
    if all(_pack_find(pack_root, missing, "Libs", f"{font}.LIB") is not None
           for font in FONT_NAMES):
        convert_fonts(pack_root, reader, sub, encoding)
    art = convert_art(pack_root, reader, sub, result, plates=plates,
                      listing=art_listing(base_root), missing=missing)
    _complete_art_index(staging, sub)
    stats.update({"plates": art["plates"], "briefing_pictures": art["briefing"],
                  "ui_libraries": art["libraries"]})

    # --- the speech: briefing voice-overs and the tables' waves, by the
    # names the base documents list.
    voices = 0
    frontend = result.documents.get("frontend", {})
    for mission in frontend.get("voice_overs", []):
        digits = mission[len("_c_"):]
        path = _pack_find(pack_root, missing, BRIEFING_WAVE_DIR,
                          f"{VOICE_OVER_PREFIX}{digits}{VOICE_OVER_SUFFIX}")
        if path is None:
            continue
        sub.write_bytes(f"audio/briefing/{mission}.wav", reader.read_bytes(path))
        voices += 1
    extro = _pack_find(pack_root, missing, BRIEFING_WAVE_DIR, EXTRO_WAVE)
    if extro is not None:
        sub.write_bytes(f"audio/briefing/{EXTRO_WAVE}", reader.read_bytes(extro))
    stats["voice_overs"] = voices
    sound = result.documents.get("sound", {})
    waves = 0
    for lower, shipped in sorted(sound.get("waves", {}).items()):
        path = _pack_find(pack_root, missing, WAVES_DIR, shipped)
        if path is None:
            continue
        sub.write_bytes(f"audio/waves/{lower}", reader.read_bytes(path))
        waves += 1
    for lower, shipped in sorted(sound.get("speech", {}).get("files", {}).items()):
        path = _pack_find(pack_root, missing, WAVES_DIR,
                          soundmod.SPEECH_DIRECTORY, *shipped.split("/"))
        if path is None:
            continue
        sub.write_bytes(f"audio/waves/speech/{lower}", reader.read_bytes(path))
        waves += 1
    stats["waves"] = waves

    if missing:
        warn(f"{len(missing)} file(s) the base has and the pack lacks (the "
             "neutral copy serves): " + ", ".join(missing[:12])
             + (" ..." if len(missing) > 12 else ""))
    kept, dropped = _merge_pack(staging, sub, prefix)
    stats.update({
        "files": kept,
        "identical_dropped": dropped,
        "missing": len(missing),
        "source_root_digest": reader.digest(),
        "sources": reader.fingerprint(),
    })
    result.packs[name] = stats
    return stats
