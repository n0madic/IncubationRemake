"""``0x0042F410`` -- which control-map cells stand under a placed object.

``aPlayCrushWallAnimation`` (``docs/42`` §8.2) finds the wall's object and
calls ``0x0042F410(object, 1, 0, 1)``.  That routine sweeps the whole control
map and, for every cell, casts **four probes** from the cell's own symbol
object -- ``x`` and ``y`` each 200 either way, from ``z = 100000`` -- against
the object (``0x00403E90`` builds the ray, ``0x0042F300`` intersects it).  A
cell any probe hits has its height set to 0 and its field type to 1.

The footprint used to be called underivable from the shipped files
(``docs/97`` §41.7, ``docs/42`` §8.2 as first written): the object the search
answers with is a **standard object**, the array at ``[0x004FA80C]``, and that
array was read as something the engine builds when it expands the scene.  It
is not -- ``docs/99`` §10.1 already says ``0x00406F20`` walks the
special-object table and nothing else, and a ``.lev``'s special objects are
exactly what is in it.  So the wall piece is a ``.lev`` record naming a
prototype, its mesh is in ``prototyp.bin``, and the sweep is arithmetic.  All
nine shipped ``CrushWall`` footprints come out of this module cell for cell
(``docs/42`` §8.2's table).

The probe is **vertical**, so "the ray meets the object" is "the probe's
``(x, y)`` lies inside the ``xy`` projection of one of its faces".  No BSP
walk and no plane arithmetic is needed for that, and it is exact rather than
a bounding box.
"""

from __future__ import annotations

from typing import Any, Iterable, Sequence

from . import eng3d, prototyp as protomod

#: ``docs/10`` §7 -- one map field.
WORLD_UNITS_PER_FIELD = 3200
#: ``0x0042F410`` -- ``81 c2 c8 00 00 00`` / ``81 e9 c8 00 00 00``, twice each.
PROBE_OFFSET = 200
#: ``0x0042F410`` -- ``c7 44 24 24 a0 86 01 00``, the z the ray starts from.
PROBE_HEIGHT = 100000

#: The four probes, as offsets from the cell's own symbol object -- the
#: **cross**, read off the listing on 2026-09-12: each probe loads one
#: coordinate of the symbol object (``+0x10`` x, ``+0x14`` y) and offsets it
#: while the other is loaded plain, in the order x-200, x+200, y-200, y+200
#: (``presentation_tables`` ``special.probe.{1..4}_*``).  The corners would
#: have given the same nine footprints -- every wall piece is 1500 units deep
#: against a 400-unit probe span -- which is why the order of the four
#: mattered to nothing measured and had to be read instead.
PROBE_OFFSETS: tuple[tuple[int, int], ...] = (
    (-PROBE_OFFSET, 0), (PROBE_OFFSET, 0),
    (0, -PROBE_OFFSET), (0, PROBE_OFFSET),
)


def object_polygons(proto: protomod.Prototype, x: int, y: int,
                    rotation: Sequence[int],
                    tables: eng3d.Tables) -> list[list[tuple[int, int]]]:
    """The object's faces as ``xy`` polygons in world units.

    Each vertex goes through the engine's own three-angle matrix
    (:func:`eng3d.rotate`, ``0x004039A0``) and is then translated by the
    record's position.  ``z`` is dropped: the probe is vertical.

    The vertices are the **placed** ones -- a part's rest translation applied,
    the same list the converter draws -- and not the part-local store.  The
    wall pieces have no parts so the nine footprints cannot tell the two
    apart; ``L026ED00``, the bridge, does, and its three placements lose a
    cell on the part-local reading.  A part's rest *angle* is not applied
    (``docs/30`` 2.12: it lives in the runtime object), which is the same
    limit the drawn geometry has.
    """
    vertices = proto.placed_vertices
    polygons: list[list[tuple[int, int]]] = []
    for face in proto.faces:
        polygon: list[tuple[int, int]] = []
        for index in face.indices:
            turned = eng3d.rotate(tables, vertices[index], rotation)
            polygon.append((turned[0] + x, turned[1] + y))
        polygons.append(polygon)
    return polygons


def _inside(point: tuple[int, int],
            polygon: Sequence[tuple[int, int]]) -> bool:
    """Crossing number, on the half-open rule that shares an edge cleanly.

    Integer throughout: whether the probe is left of the edge is the sign of
    a cross product, so there is no division and no float to decide a probe
    that lands exactly on an edge.  None of the nine measured footprints puts
    one there -- edges fall at a cell's 3200 plus 1583 or minus 4817, probes at
    3200 plus or minus 200 -- but a rule that cannot be off by an ulp is the
    one to write.
    """
    px, py = point
    hit = False
    count = len(polygon)
    for i in range(count):
        x1, y1 = polygon[i]
        x2, y2 = polygon[(i + 1) % count]
        if (y1 > py) == (y2 > py):
            continue
        # `px < x1 + (py - y1) * (x2 - x1) / (y2 - y1)`, multiplied through by
        # `y2 - y1` with the sign of that denominator carried explicitly.
        cross = (px - x1) * (y2 - y1) - (py - y1) * (x2 - x1)
        if cross < 0 if y2 > y1 else cross > 0:
            hit = not hit
    return hit


def cells_under(polygons: Iterable[Sequence[tuple[int, int]]],
                width: int, height: int) -> list[int]:
    """The control-map cells the four probes reach, as row-major indices.

    The sweep is the whole map in the engine; here it is bounded by the
    polygons' own extent first, which cannot change the answer -- a probe
    outside the extent is inside no polygon -- and turns a 900-cell scan per
    object into a handful.
    """
    polygons = [p for p in polygons if len(p) >= 3]
    if not polygons:
        return []
    xs = [px for polygon in polygons for px, _ in polygon]
    ys = [py for polygon in polygons for _, py in polygon]
    span = max(offset for offset, _ in PROBE_OFFSETS)
    first_x = max(0, (min(xs) - span) // WORLD_UNITS_PER_FIELD)
    last_x = min(width - 1, (max(xs) + span) // WORLD_UNITS_PER_FIELD)
    first_y = max(0, (min(ys) - span) // WORLD_UNITS_PER_FIELD)
    last_y = min(height - 1, (max(ys) + span) // WORLD_UNITS_PER_FIELD)
    cells: list[int] = []
    for grid_y in range(first_y, last_y + 1):
        for grid_x in range(first_x, last_x + 1):
            cell_x = grid_x * WORLD_UNITS_PER_FIELD
            cell_y = grid_y * WORLD_UNITS_PER_FIELD
            if any(_inside((cell_x + dx, cell_y + dy), polygon)
                   for dx, dy in PROBE_OFFSETS for polygon in polygons):
                cells.append(grid_y * width + grid_x)
    return cells


def special_object_cells(bm: Any, container: protomod.Container,
                         tables: eng3d.Tables) -> list[list[int]]:
    """One cell list per record of ``bm.special``, in the same order.

    A record whose prototype the world set does not carry answers with an
    empty list rather than raising: the engine would find no object either.
    """
    parsed: dict[str, protomod.Prototype | None] = {}
    out: list[list[int]] = []
    for record in bm.special:
        name = record.prototype_name(bm.world_set)
        if name not in parsed:
            try:
                parsed[name] = container.parse(container.find(name))
            except KeyError:
                parsed[name] = None
        proto = parsed[name]
        if proto is None:
            out.append([])
            continue
        out.append(cells_under(
            object_polygons(proto, record.x, record.y, record.rotation,
                            tables),
            bm.width, bm.height))
    return out


def footprint_index(cell_lists: Iterable[Sequence[int]]) -> dict[int, list[int]]:
    """``cell -> the whole run it belongs to``, for every covered cell.

    ``CrushWall`` names one cell and the engine's ``0x00406F20`` finds the
    object standing near it, so the run has to be reachable from any cell of
    it, not only from the record's own.

    Where two objects cover one cell the **first** placed wins.  That is a
    tie-break of this index and not the engine's rule: ``0x00406F20`` matches
    record *positions* inside a box, which is a different predicate from
    footprint coverage, and the two are shown equal only on the nine pinned
    calls, where the record stands on the cell the call names.  Overlaps do
    occur on the shipped maps -- railings and pillars that share a field, ten
    cells on ``_C_129`` and nine on ``_O_061`` -- but never on a wall piece and
    never on a cell any ``CrushWall`` names
    (``corpus.crush_wall_cells_carry_one_object``), so no footprint in play is
    decided by it.
    """
    index: dict[int, list[int]] = {}
    for cells in cell_lists:
        run = list(cells)
        for cell in run:
            index.setdefault(cell, run)
    return index


def index_for_mission(root: Any, bm: Any) -> dict[int, list[int]]:
    """``cell -> run`` for one mission, opening its world set's container.

    The one line a caller that has the game root needs, so that a model built
    from a ``.lev`` carries the same footprints the converter emits.

    Nothing is swallowed: a world set that cannot be opened raises, because a
    model that silently fell back to one cell would pass every check while
    ``core`` on the same mission crushed the run.  The one map that names a
    world set the release does not ship -- ``_I_001``, ``World_Z00`` -- places
    no special object at all, so the empty answer is exact there and the
    container is never asked for.
    """
    from pathlib import Path

    from .convert import world_paths

    if not bm.special:
        return {}
    paths = world_paths(Path(root), bm.world_set, bm.world_scene)
    container = protomod.load_container(str(paths["din"]), str(paths["bin"]))
    return footprint_index(
        special_object_cells(bm, container, eng3d.load(str(root))))
