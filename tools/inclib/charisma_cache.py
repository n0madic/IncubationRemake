"""Bodies and clips as portable data: the Charisma half of the cache.

``convert.py`` states the container rule categorically -- *the cache holds no
float anywhere*, so no float is ever formatted and no formatting can drift.
Animation is a float domain, and this module keeps that invariant rather than
weakening it: every float reaches the cache as its own **IEEE-754 single
bit pattern**, either as a ``u32`` integer (one value) or as a base64 blob of
little-endian ``f32`` (an array).

That is exact, not merely careful.  A ``.cha`` key is an ``f32`` in the file;
the parser widens it to a Python ``float`` (a ``double``, losslessly), and
``struct.pack("<f", v)`` rounds it back to the identical four bytes.  The cache
therefore carries the file's own bits, two conversions of the same input are
byte-identical for the same reason every other document is, and
``remake_convert.py --check``'s "no floats" assertion still holds literally.

The blob is also smaller than the alternative: a rotation key is 5 floats, 20
bytes, 27 base64 characters against roughly 60 characters of decimal text.

**Times stay integers, not blobs.**  A note's time and a clip's duration are
single values and are written as ``u32`` bit patterns, so a document remains
greppable -- ``BREAK`` and the note carrying it are still visible in a diff.

What is *not* done here, deliberately:

* **tracks with no matching part are not pruned.**  ``docs/40`` §7 measures 17
  such tracks across the gameplay set -- ``Banner``, ``Line00``, spare Biped
  bones -- and the rule a runtime must follow is to *ignore* them.  Stripping
  them in the converter would mean the exported build never exercises that path
  on shipped data, and "a track without a part is ignored rather than fatal"
  would become untestable except synthetically;
* **nothing is triangulated and no mesh is transformed.**  Same reason the map
  documents keep polygons: a rendering decision belongs in ``game/``.
"""

from __future__ import annotations

import base64
import struct
from typing import Any, Iterable

MODEL_SCHEMA = "incubation.charisma-model/1"
ANIMATION_SCHEMA = "incubation.charisma-animation/1"
MODEL_INDEX_SCHEMA = "incubation.charisma-models/1"
ANIMATION_INDEX_SCHEMA = "incubation.charisma-animations/1"
SELECTOR_SCHEMA = "incubation.charisma-selectors/1"
UNIT_GEOMETRY_SCHEMA = "incubation.unit-geometry/1"

#: A ``SkeletonNode``'s bind matrix: 16 floats, row-major ``M * v``
#: (``docs/40`` §5.1), stored parent-relative (§5.2).
MATRIX_FLOATS = 16


def f32_bits(value: float) -> int:
    """One float as the ``u32`` its ``f32`` encoding is."""
    return int(struct.unpack("<I", struct.pack("<f", value))[0])


def f32_blob(values: Iterable[float]) -> str:
    """A float array as base64 of little-endian ``f32``."""
    data = b"".join(struct.pack("<f", float(v)) for v in values)
    return base64.b64encode(data).decode("ascii")


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

def model_document(name: str, model: Any) -> dict[str, Any]:
    """One ``.cho`` as portable data: the parts and the bind pose.

    ``parts`` keeps file order, because that is the order the engine builds
    them in and the order the part-to-bone binding is stated in; ``mesh`` is
    empty for a pure bone.  ``skeleton.nodes`` likewise keeps file order, which
    is what makes a parent name resolvable without a second pass -- ``docs/40``
    §3.2 records that a node's parent always precedes it.
    """
    if model.skeleton is None:
        raise ValueError(f"{name}: a body without a skeleton cannot be posed")
    return {
        "schema": MODEL_SCHEMA,
        "name": name,
        "parts": [{"name": part.name, "mesh": part.mesh}
                  for part in model.parts],
        "skeleton": {
            "nodes": [{"name": node.name, "parent": node.parent,
                       "matrix": f32_blob(node.matrix)}
                      for node in model.skeleton.nodes],
        },
    }


# ---------------------------------------------------------------------------
# Animations
# ---------------------------------------------------------------------------

def _track_document(movement: Any) -> dict[str, Any]:
    arity = len(movement.keys[0].values) if movement.keys else 0
    if any(len(key.values) != arity for key in movement.keys):
        raise ValueError(
            f"{movement.target}/{movement.channel}: keys of mixed arity")
    # Time first, then the key's values: one record of `1 + arity` floats.
    flat: list[float] = []
    for key in movement.keys:
        flat.append(key.time)
        flat.extend(key.values)
    return {
        "target": movement.target,
        "channel": movement.channel,
        "key_class": movement.key_class,
        "arity": arity,
        "count": len(movement.keys),
        "keys": f32_blob(flat),
    }


def animation_document(name: str, animation: Any) -> dict[str, Any]:
    """One ``.cha`` as portable data: the notes and the tracks.

    ``docs/40`` §9: a note's text is a small newline-separated command script
    written by hand, and one shipped note is the empty string.  It is carried
    verbatim and parsed in ``game/`` -- ``BREAK`` is the only verb gameplay
    needs, but deciding that here would bake a reading of free text into the
    container.
    """
    return {
        "schema": ANIMATION_SCHEMA,
        "name": name,
        "duration_bits": f32_bits(animation.duration),
        "notes": [{"time_bits": f32_bits(note.time), "text": note.text}
                  for note in animation.notes],
        "tracks": [_track_document(m) for m in animation.movements],
    }


# ---------------------------------------------------------------------------
# The selector tables
# ---------------------------------------------------------------------------

def selector_document(tables: Any, source: dict[str, Any]) -> dict[str, Any]:
    """The four decision tables, as ``tools/charisma_tables.py`` read them.

    The converter does not re-derive the player prefixes, the hero rewrite or
    the neutral player's refusal: it copies out what the interpreter produced,
    so there is one reading of those routines in the repository and not two.

    The document deliberately keeps the shape that carries **absences**.  Nine
    unit types get fewer than three clips and two get none at all
    (``docs/40`` §7.2 as amended), and a runtime that met those as a missing key
    could not tell "the engine plays nothing here" from "the converter dropped
    it".  The one randomised arm is carried as its condition -- the draw's
    bounds and the threshold -- rather than as a probability, so the remake can
    reproduce the choice instead of inventing one.
    """
    document = tables.to_dict()
    document["schema"] = SELECTOR_SCHEMA
    document["source"] = source
    return document


# ---------------------------------------------------------------------------
# Unit geometry
# ---------------------------------------------------------------------------

def unit_geometry_document(world_set: str, prototypes: dict[str, Any],
                           texture_names: dict[int, str],
                           source: dict[str, Any]) -> dict[str, Any]:
    """The bodies' meshes, once, with textures named rather than numbered.

    A unit body is the same geometry in every world set, but a texture **id**
    is not: ``caan0000`` is 7 in ``A00`` and 8 in ``E00``, and only 9 of the 29
    shared names keep their id.  So the shared document names its textures and
    the loader resolves the name against whichever set the mission uses.  The
    id this conversion happened to see is carried beside it as
    ``texture_source``, for a diff to have something to point at -- nothing
    reads it.
    """
    out: dict[str, Any] = {}
    unnamed: set[int] = set()
    for name, document in sorted(prototypes.items()):
        faces = []
        for face in document["faces"]:
            face = dict(face)
            texture = face["texture"]
            if texture >= 0:
                resolved = texture_names.get(texture)
                if resolved is None:
                    unnamed.add(texture)
                face["texture_name"] = resolved or ""
                face["texture_source"] = texture
            else:
                face["texture_name"] = ""
                face["texture_source"] = -1
            # The id is per world set and this document is shared, so it must
            # not survive: a loader that found one would resolve it against the
            # wrong set without noticing.
            del face["texture"]
            faces.append(face)
        out[name] = dict(document, faces=faces)
    return {
        "schema": UNIT_GEOMETRY_SCHEMA,
        "source_world_set": world_set,
        "source": source,
        "unnamed_textures": sorted(unnamed),
        "prototypes": out,
    }


def unit_texture_names(document: dict[str, Any]) -> set[str]:
    """Every texture name the shared unit geometry references."""
    return {face["texture_name"]
            for proto in document["prototypes"].values()
            for face in proto["faces"]
            if face["texture_name"]}
