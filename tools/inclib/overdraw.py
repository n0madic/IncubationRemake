"""Which of two coplanar faces of one prototype the engine shows.

The software renderer has no z-buffer.  It walks a prototype's face tree
**front to back** (``docs/31`` section 4.1: the inline child of every node
holds the geometry on the back side of the node's plane, and the walker
visits the far child first when the camera is on the front side) and fills
through a span buffer, ``0x40DAF0`` in ``Eng3d.dll``, whose nodes carry
``{x0, x1, z0, z1, next, prev, tag}``.  ``tag`` is ``[0x44FBBC]``, bumped
once per ``draw_faces`` program (``0x405199``), and when an incoming span
meets a stored span with the **same tag** the depth test is skipped
(``je 0x40dc43``): the stored span hides the new one wherever they overlap.
Read that way, among the coplanar faces of one draw program the face drawn
first wins.

**The shipped picture says otherwise where one face lies inside another.**
The iris of ``LEVEL09A.005`` lists two blade faces, then the square backing
that contains all five blades, then the other three; first-wins would show
two blades over a dark disc, and the original -- watched on 2026-09-21 --
shows all five over the backing's black texels.  No sequential order with
any first- or last-wins rule produces that, so the reading above misses a
mechanism (``docs/31`` section 9 item 8).  This module therefore layers by
observation where there is one and by the reading where there is none: a
face wholly inside an earlier coplanar face is a **decal** and sits on top
of it; two faces that overlap only in part are layered by the walk order,
first in front.  Per face it answers how many layers lie over it
(:func:`overdraw_ranks`), and the remake's mesh builder pushes a face back
by that many steps (``godot/game/mesh_builder.gd``).

Only the opaque kinds take part.  The deferred kinds (``0x0c``, ``0x14``,
``0x1c``, ``0x20``) insert no span and so hide nothing, and the remake draws
them with the depth write off, where two coplanar additive flames simply
add; 867 of the corpus's 1 291 overlapping pairs are the sequence models'
additive flame quads.  Kind ``0x28`` draws nothing at all.

Coplanarity is the engine's own key, ``(plane_index, plane_d)``, exact: the
25 overlapping pairs whose ``plane_d`` differ by 1..8 units all sit in the
sequence models, where a five-million-unit radius rounds the plane.  Overlap
is polygon intersection in the plane with an area above
:data:`OVERLAP_MIN_AREA`, so tiles that merely share an edge do not count,
and containment is an overlap of at least :data:`CONTAINED_FRACTION` of the
smaller face's own area.

The walk order between two coplanar faces is static unless the two lie in
different leaves whose lowest common ancestor splits on some *other* plane;
:func:`census` counts those pairs, and :func:`overdraw_ranks` orders them as
the tree lists them, which is what the walker does with the camera on the
back side of that ancestor.
"""

from __future__ import annotations

import collections
from dataclasses import dataclass
from typing import Iterable, Sequence

from . import prototyp as protomod
from .binio import ParseError

#: Square world units below which two coplanar polygons are taken to touch
#: rather than overlap: an 8 x 8 unit patch, one two-hundredth of a map
#: field's side, well under a texel at any distance the game draws from.
OVERLAP_MIN_AREA = 64.0

#: A face is *inside* another when this much of its own area is shared: the
#: iris blades sit on their backing at 1.0 exactly, and the slack is for the
#: clipper's floating point on a shared edge.
CONTAINED_FRACTION = 0.98

#: The normal's fixed-point unit (docs/31 section 4.2).
_PLANE_UNIT = 16384.0

#: The kinds that neither hide nor are hidden by a coplanar neighbour: the
#: four deferred kinds of docs/31 section 4.4 and the bare ``ret``.
_UNRANKED_KINDS = frozenset((0x0C, 0x14, 0x1C, 0x20, 0x28))

Point2 = tuple[float, float]


@dataclass(frozen=True)
class Census:
    """Overlapping coplanar face pairs of one prototype, by where they sit."""

    same_leaf: int = 0
    cross_leaf_on_lca_plane: int = 0
    cross_leaf_other: int = 0
    #: Pairs where one face lies wholly inside the other -- the decal rule.
    contained: int = 0

    def __add__(self, other: "Census") -> "Census":
        return Census(self.same_leaf + other.same_leaf,
                      self.cross_leaf_on_lca_plane + other.cross_leaf_on_lca_plane,
                      self.cross_leaf_other + other.cross_leaf_other,
                      self.contained + other.contained)


# ---------------------------------------------------------------------------
# Plane geometry
# ---------------------------------------------------------------------------

def _basis(normal: Sequence[int]) -> tuple[list[float], list[float]]:
    """Two unit axes spanning the plane with this normal."""
    n = [c / _PLANE_UNIT for c in normal]
    axis = max(range(3), key=lambda i: abs(n[i]))
    u = [0.0, 0.0, 0.0]
    u[(axis + 1) % 3] = 1.0
    d = sum(u[i] * n[i] for i in range(3))
    u = [u[i] - d * n[i] for i in range(3)]
    length = sum(x * x for x in u) ** 0.5
    u = [x / length for x in u]
    v = [n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2],
         n[0] * u[1] - n[1] * u[0]]
    return u, v


def _flatten(vertices: Sequence[tuple[int, int, int]], indices: Sequence[int],
             u: Sequence[float], v: Sequence[float]) -> list[Point2]:
    return [(sum(vertices[i][k] * u[k] for k in range(3)),
             sum(vertices[i][k] * v[k] for k in range(3))) for i in indices]


def _area(poly: Sequence[Point2]) -> float:
    n = len(poly)
    return 0.5 * sum(poly[i][0] * poly[(i + 1) % n][1]
                     - poly[(i + 1) % n][0] * poly[i][1] for i in range(n))


def _cross(o: Point2, a: Point2, b: Point2) -> float:
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def _ear_clip(poly: Sequence[Point2]) -> list[tuple[Point2, Point2, Point2]]:
    """Triangles covering a simple polygon, counter-clockwise."""
    points = list(poly)
    if _area(points) < 0:
        points.reverse()
    remaining = list(range(len(points)))
    triangles: list[tuple[Point2, Point2, Point2]] = []
    guard = 0
    while len(remaining) > 3 and guard < 4 * len(points):
        guard += 1
        clipped = False
        for k in range(len(remaining)):
            i0 = remaining[k - 1]
            i1 = remaining[k]
            i2 = remaining[(k + 1) % len(remaining)]
            a, b, c = points[i0], points[i1], points[i2]
            if _cross(a, b, c) <= 0:
                continue
            if any(_cross(a, b, points[j]) >= 0 and _cross(b, c, points[j]) >= 0
                   and _cross(c, a, points[j]) >= 0
                   for j in remaining if j not in (i0, i1, i2)):
                continue
            triangles.append((a, b, c))
            del remaining[k]
            clipped = True
            break
        if not clipped:
            break
    if len(remaining) == 3:
        triangles.append((points[remaining[0]], points[remaining[1]],
                          points[remaining[2]]))
    return triangles


def _intersect(s: Point2, e: Point2, a: Point2, b: Point2) -> Point2:
    d1 = (e[0] - s[0], e[1] - s[1])
    d2 = (b[0] - a[0], b[1] - a[1])
    den = d1[0] * d2[1] - d1[1] * d2[0]
    if den == 0:
        return e
    t = ((a[0] - s[0]) * d2[1] - (a[1] - s[1]) * d2[0]) / den
    return (s[0] + t * d1[0], s[1] + t * d1[1])


def _clip(subject: Sequence[Point2], clipper: Sequence[Point2]) -> list[Point2]:
    """Sutherland-Hodgman: ``subject`` clipped to the convex ``clipper``."""
    output = list(subject)
    for i in range(len(clipper)):
        a, b = clipper[i], clipper[(i + 1) % len(clipper)]
        if not output:
            break
        current, output = output, []
        previous = current[-1]
        for point in current:
            inside = _cross(a, b, point) >= 0
            if inside:
                if _cross(a, b, previous) < 0:
                    output.append(_intersect(previous, point, a, b))
                output.append(point)
            elif _cross(a, b, previous) >= 0:
                output.append(_intersect(previous, point, a, b))
            previous = point
    return output


def overlap_area(a: Sequence[Point2], b: Sequence[Point2]) -> float:
    """Area shared by two simple polygons in the same plane."""
    total = 0.0
    for x in _ear_clip(a):
        for y in _ear_clip(b):
            c = _clip(list(x), list(y))
            if len(c) >= 3:
                total += abs(_area(c))
    return total


# ---------------------------------------------------------------------------
# Tree order
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class _Placed:
    """One face with its leaf and the node path above it."""

    face: protomod.Face
    leaf: int
    path: tuple[protomod.BspNode, ...]


def _place(node: protomod.BspNode | protomod.Leaf | None,
           path: tuple[protomod.BspNode, ...], leaf_counter: list[int],
           out: list[_Placed]) -> None:
    if node is None:
        return
    if isinstance(node, protomod.Leaf):
        leaf = leaf_counter[0]
        leaf_counter[0] += 1
        out.extend(_Placed(f, leaf, path) for f in node.faces)
        return
    _place(node.near, path + (node,), leaf_counter, out)
    _place(node.far, path + (node,), leaf_counter, out)


def _node_on_plane(node: protomod.BspNode, plane_index: int, plane_d: int) -> bool:
    """Whether the node splits on the face plane, either way round."""
    if abs(node.plane_index) != abs(plane_index):
        return False
    if node.plane_index == plane_index:
        return node.plane_d == plane_d
    return node.plane_d == -plane_d


def _walk_order(node: protomod.BspNode | protomod.Leaf | None,
                plane_index: int, plane_d: int,
                out: list[protomod.Face]) -> None:
    """The faces of one plane in the order the walker draws them when they
    are visible.

    The faces are drawn only with the camera on the side their normal points
    to; a node that splits on that very plane therefore has a known side, and
    the walker visits its far child first when the node's normal agrees with
    the faces' and its inline child first when it is the negation.  Every
    other node is taken as listed.
    """
    if node is None:
        return
    if isinstance(node, protomod.Leaf):
        out.extend(f for f in node.faces
                   if f.plane_index == plane_index and f.plane_d == plane_d)
        return
    first, second = node.near, node.far
    if _node_on_plane(node, plane_index, plane_d) and node.plane_index == plane_index:
        first, second = node.far, node.near
    _walk_order(first, plane_index, plane_d, out)
    _walk_order(second, plane_index, plane_d, out)


def _groups(proto: protomod.Prototype) -> dict[tuple[int, int, int], list[_Placed]]:
    """Faces by ``(scope, plane_index, plane_d)``, groups of two or more."""
    placed: list[_Placed] = []
    _place(proto.tree, (), [0], placed)
    groups: dict[tuple[int, int, int], list[_Placed]] = collections.defaultdict(list)
    for entry in placed:
        f = entry.face
        if f.plane_index == 0 or len(f.indices) < 3:
            continue
        if f.draw_kind in _UNRANKED_KINDS:
            continue
        if abs(f.plane_index) > len(proto.planes):
            continue
        if any(i >= len(proto.vertices) for i in f.indices):
            continue
        scope = proto.vertex_part[f.indices[0]] if proto.vertex_part else -1
        groups[(scope, f.plane_index, f.plane_d)].append(entry)
    return {k: v for k, v in groups.items() if len(v) >= 2}


@dataclass(frozen=True)
class _Overlap:
    """Two coplanar faces sharing area; ``inner`` is the one wholly inside
    the other, or ``None`` when the overlap is partial."""

    a: _Placed
    b: _Placed
    inner: _Placed | None


def _overlapping_pairs(proto: protomod.Prototype, key: tuple[int, int, int],
                       members: Sequence[_Placed]) -> list[_Overlap]:
    u, v = _basis(proto.planes[abs(key[1]) - 1])
    polys = [_flatten(proto.vertices, m.face.indices, u, v) for m in members]
    areas = [abs(_area(p)) for p in polys]
    pairs: list[_Overlap] = []
    for i, a in enumerate(members):
        for j in range(i + 1, len(members)):
            shared = overlap_area(polys[i], polys[j])
            if shared <= OVERLAP_MIN_AREA:
                continue
            inner: _Placed | None = None
            a_inside = shared >= CONTAINED_FRACTION * areas[i]
            b_inside = shared >= CONTAINED_FRACTION * areas[j]
            if a_inside and not b_inside:
                inner = a
            elif b_inside and not a_inside:
                inner = members[j]
            pairs.append(_Overlap(a, members[j], inner))
    return pairs


def census(proto: protomod.Prototype) -> Census:
    """Count the overlapping coplanar pairs of one prototype."""
    same = on_plane = other = contained = 0
    for key, members in _groups(proto).items():
        for pair in _overlapping_pairs(proto, key, members):
            a, b = pair.a, pair.b
            if pair.inner is not None:
                contained += 1
            if a.leaf == b.leaf:
                same += 1
                continue
            lca: protomod.BspNode | None = None
            for x, y in zip(a.path, b.path):
                if x is not y:
                    break
                lca = x
            if lca is not None and _node_on_plane(lca, key[1], key[2]):
                on_plane += 1
            else:
                other += 1
    return Census(same, on_plane, other, contained)


def overdraw_ranks(proto: protomod.Prototype) -> list[int]:
    """Per face, aligned with ``proto.faces``: how many layers of coplanar
    faces lie over it.

    ``0`` for a face nothing overlaps or that every overlapping face lies
    behind; otherwise one more than the highest rank among the faces in
    front of it.  A face wholly inside another is in front of it; of two
    faces overlapping in part, the one the walk reaches first is in front.
    """
    ranks: dict[int, int] = {}
    for key, members in _groups(proto).items():
        pairs = _overlapping_pairs(proto, key, members)
        if not pairs:
            continue
        ordered: list[protomod.Face] = []
        _walk_order(proto.tree, key[1], key[2], ordered)
        position = {id(f): i for i, f in enumerate(ordered)}
        # (front, back) per pair.
        beats: list[tuple[int, int]] = []
        for pair in pairs:
            if pair.inner is not None:
                outer = pair.b if pair.inner is pair.a else pair.a
                beats.append((id(pair.inner.face), id(outer.face)))
            elif position[id(pair.a.face)] < position[id(pair.b.face)]:
                beats.append((id(pair.a.face), id(pair.b.face)))
            else:
                beats.append((id(pair.b.face), id(pair.a.face)))
        for f in ordered:
            ranks.setdefault(id(f), 0)
        # Longest path over "front beats back".  The decal rule and the
        # walk order can in principle disagree around a triple; the corpus
        # holds no such cycle, and one is an error rather than a face quietly
        # receded by the bound's worth of layers.
        changed = True
        for _ in range(len(ordered) + 1):
            changed = False
            for front, back in beats:
                if ranks[back] <= ranks[front]:
                    ranks[back] = ranks[front] + 1
                    changed = True
            if not changed:
                break
        if changed:
            raise ParseError(f"{proto.name}: coplanar overdraw order has a cycle "
                             f"on plane {key[1]} d={key[2]}")
    return [ranks.get(id(f), 0) for f in proto.faces]


@dataclass(frozen=True)
class WalkCensus:
    """Where each interior node's two children lie against its plane.

    The premise of every order derived here: the far child holds the front
    side.  Measured as the mean signed distance of a child's vertices to the
    node plane, on prototypes without ``part_push`` scopes (a part's vertices
    are in the part's frame).  ``straddling`` counts nodes where some inline
    vertex lies past some far vertex by more than four units -- the builder
    did not split polygons.
    """

    far_front: int = 0
    far_back: int = 0
    tie: int = 0
    straddling: int = 0

    def __add__(self, other: "WalkCensus") -> "WalkCensus":
        return WalkCensus(self.far_front + other.far_front,
                          self.far_back + other.far_back, self.tie + other.tie,
                          self.straddling + other.straddling)


#: Vertex-to-plane slack, in world units, before a node counts as straddling.
_STRADDLE_SLACK = 4.0


def _faces_under(node: protomod.BspNode | protomod.Leaf | None) -> list[protomod.Face]:
    if node is None:
        return []
    if isinstance(node, protomod.Leaf):
        return list(node.faces)
    return _faces_under(node.near) + _faces_under(node.far)


def _distances(proto: protomod.Prototype, node: protomod.BspNode,
               faces: Iterable[protomod.Face]) -> list[float]:
    normal = proto.planes[abs(node.plane_index) - 1]
    sign = -1 if node.plane_index < 0 else 1
    out: list[float] = []
    for f in faces:
        for i in f.indices:
            if i >= len(proto.vertices):
                continue
            v = proto.vertices[i]
            out.append(sign * (normal[0] * v[0] + normal[1] * v[1]
                               + normal[2] * v[2]) / _PLANE_UNIT + node.plane_d)
    return out


def walk_census(proto: protomod.Prototype) -> WalkCensus:
    """Classify every interior node of a part-less prototype."""
    if proto.parts or proto.tree is None:
        return WalkCensus()
    total = WalkCensus()
    stack: list[protomod.BspNode | protomod.Leaf] = [proto.tree]
    while stack:
        node = stack.pop()
        if isinstance(node, protomod.Leaf):
            continue
        stack.append(node.near)
        stack.append(node.far)
        if node.plane_index == 0 or abs(node.plane_index) > len(proto.planes):
            continue
        near = _distances(proto, node, _faces_under(node.near))
        far = _distances(proto, node, _faces_under(node.far))
        if not near or not far:
            continue
        mean_near = sum(near) / len(near)
        mean_far = sum(far) / len(far)
        if mean_far > mean_near:
            total = total + WalkCensus(far_front=1)
        elif mean_far < mean_near:
            total = total + WalkCensus(far_back=1)
        else:
            total = total + WalkCensus(tie=1)
        if max(near) > min(far) + _STRADDLE_SLACK:
            total = total + WalkCensus(straddling=1)
    return total
