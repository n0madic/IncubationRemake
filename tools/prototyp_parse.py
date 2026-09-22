#!/usr/bin/env python3
"""Parser and CLI for the Eng3d ``prototyp.bin`` geometry container.

The record layout and the command-stream grammar are documented in
``docs/31-prototyp-geometry.md`` and implemented in ``tools/inclib/prototyp.py``.

Usage::

    # corpus validation over every prototyp.bin below a data root
    python3 tools/prototyp_parse.py --check --root gog_incubation

    # list the records of one container
    python3 tools/prototyp_parse.py --list gog_incubation/WorldSet/World_A00/Objects/prototyp.din

    # structured dump of one record
    python3 tools/prototyp_parse.py --json --name A_50A.3DI \\
        gog_incubation/WorldSet/World_A00/Objects/prototyp.din

    # export geometry
    python3 tools/prototyp_parse.py --name A_50A.3DI --obj tools/out/meshes/a_50a.obj \\
        --png tools/out/meshes/a_50a.png \\
        gog_incubation/WorldSet/World_A00/Objects/prototyp.din
"""

from __future__ import annotations

import argparse
import collections
import json
import logging
import math
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import overdraw as overdrawmod  # noqa: E402
from inclib.binio import ParseError  # noqa: E402
from inclib.prototyp import (  # noqa: E402
    LATTICE_PROTOTYPE,
    DRAW_KINDS,
    OPCODES,
    Container,
    Prototype,
    face_out_of_plane,
    face_shape,
    find_containers,
    load_container,
    newell_normal,
    render_png,
    to_obj,
)

LOG = logging.getLogger("prototyp_parse")

#: A triangle fan from vertex 0 is a correct triangulation only for a convex
#: polygon that names no vertex twice.  These three counts are corpus facts,
#: pinned rather than asserted to zero: the shipped geometry really does carry
#: reflex quads and pentagons, mostly in the dialogue and sequence models but
#: 81 of them in ``World_A00`` alone, so a renderer that fans every face draws
#: those wrong.  ``godot/game/mesh_builder.gd`` ear-clips instead, which is
#: what these numbers exist to justify.
EXPECTED_NON_CONVEX = 1572
EXPECTED_REPEATED_INDEX = 129
#: Faces whose Newell normal is zero: no area in any plane, so nothing to draw
#: and nothing to triangulate.
EXPECTED_ZERO_AREA = 700
#: Faces the index guard skips before the shape pass -- an index past the end
#: of the placed-vertex list.  Pinned so that a decoder change quietly moving
#: faces out of the shape pass shows up as a count, rather than as three
#: bucket totals that all shrink together and still add up.
EXPECTED_UNSHAPED = 0
#: docs/31 section 4.2 -- every face names a plane and the leaf walker draws
#: it only from the side the plane normal points to (``Eng3d.dll``
#: ``0x405203``..``0x405230``: drawn when ``plane_value - plane_d < 0``, with
#: ``plane_value`` the normal dotted with the object's position minus the
#: camera's, ``0x404BF4``).  The stored vertex winding has its Newell normal
#: **against** the plane normal on every face that has an area -- except one,
#: a sliver in a dialogue head whose Newell normal is ``(-9, 50, 7)`` on a
#: plane of magnitude 16384.  That relation is what lets a renderer use the
#: indices as they come and cull the back face, so it is pinned by name.
EXPECTED_WOUND_WITH_PLANE = ["MODEL_D02_RUTHERFORD_KOPF"]
#: ``plane_d == -n.v / 16384`` for the face's own vertices **in the frame the
#: engine tests it in**: a face inside a ``part_push`` scope keeps its plane
#: in the part's own coordinates, because ``joint_place`` (``Eng3d.dll``
#: ``0x004060F0``) adds the rotated part translation into the position the
#: side test dots the normal with (``0x00414064``).  Measured that way the
#: stored normal puts ``plane_d`` inside the vertex span, within two units of
#: rounding, on 230 940 faces.  The stored normal is the exact one **truncated
#: to 14 bits** -- its magnitude is 16 381..16 384 and never above -- and
#: ``plane_d`` was computed before the truncation: every one of the remaining
#: 5 921 faces lands in the span under a rotation of the stored normal of at
#: most ``PLANE_NORMAL_SLACK_DEG``, which is what a truncation error at a
#: radius of up to 5.5 million units looks like.  The worst miss in units is
#: pinned too, so the remake's cull on the face's own plane is bounded
#: against the engine's rather than described.
PLANE_D_SLACK = 2
EXPECTED_PLANE_D_IN_SPAN = 230940
EXPECTED_PLANE_D_BY_NORMAL_PRECISION = 5921
PLANE_NORMAL_SLACK_DEG = 0.02
#: The largest ``plane_d`` miss, in world units, across those 5 921 faces:
#: on the 5.5-million-unit space sphere of the sequence models, where a
#: hundredth of a degree is that many units.
EXPECTED_PLANE_D_WORST_MISS = 908
#: Every stored plane normal has this magnitude or one below it -- the exact
#: normal scaled to 16 384 and truncated, so the four magnitudes it lands on
#: are a corpus fact and are pinned per face.
PLANE_NORMAL_MAGNITUDE = 16384
EXPECTED_PLANE_NORMAL_MAGNITUDES = {16381: 7153, 16382: 53657,
                                    16383: 170216, 16384: 5835}
#: The same worst miss over the world prototypes alone -- every container
#: outside ``Video/`` -- so the bound that matters in play is its own number.
EXPECTED_PLANE_D_WORST_MISS_WORLD = 60
#: The ground lattice's plane, read off every one of its faces: straight up,
#: and ``plane_d`` is minus its own height of 80.  A floor is seen from above,
#: which fixes the sign of the whole side test without a renderer.
LATTICE_NORMAL = (0, 0, 16383)
LATTICE_PLANE_D = -80
#: The premise of the face-tree walk, docs/31 section 4.1: the far child of
#: an interior node holds the front side of its plane, so the walker -- which
#: takes the far child first with the camera in front -- goes front to back.
#: Over the part-less prototypes' interior nodes, by the mean signed distance
#: of each child's vertices; the ties and the four exceptions are all in the
#: sequence models.  The builder split no polygon: on the fourth count a
#: near-side vertex lies past a far-side one.
EXPECTED_WALK_FAR_FRONT = 22111
EXPECTED_WALK_FAR_BACK = 4
EXPECTED_WALK_TIE = 11
EXPECTED_WALK_STRADDLING = 4954
#: Coplanar faces of one prototype that overlap in area (``inclib.overdraw``),
#: opaque kinds only.  Read off ``Eng3d.dll``, the span buffer skips the
#: depth test between spans of one ``draw_faces`` program (``0x40DAF0``,
#: ``je 0x40dc43`` on the tag ``[0x44FBBC]``) and the face drawn first wins;
#: watched, the original draws a face that lies wholly inside an earlier one
#: **on top** of it (the iris of ``LEVEL09A.005``, docs/31 section 4.7), and
#: the derivation follows the observation there and the reading elsewhere.
#: The counts are where the pairs sit: in one leaf, in two leaves whose lowest
#: common ancestor splits on their own plane (a static order either way), and
#: in two leaves split by some other plane, where the walk order follows the
#: camera and the remake's static order is an approximation; then how many
#: pairs are one face inside another, and how many faces the converter marks
#: with a non-zero ``overdraw``.
EXPECTED_OVERDRAW_SAME_LEAF = 361
EXPECTED_OVERDRAW_CROSS_LEAF_ON_PLANE = 14
EXPECTED_OVERDRAW_CROSS_LEAF_OTHER = 47
EXPECTED_OVERDRAW_CONTAINED = 6
EXPECTED_OVERDRAW_FACES = 218


def _resolve_container(path: str) -> Container:
    """Accept a .din, a .bin or the directory that holds them."""
    if os.path.isdir(path):
        lower = {f.lower(): f for f in os.listdir(path)}
        if "prototyp.din" not in lower:
            raise ParseError(f"{path}: no prototyp.din here")
        return load_container(os.path.join(path, lower["prototyp.din"]))
    if path.lower().endswith(".bin"):
        base = os.path.splitext(path)[0]
        for cand in (base + ".din", base + ".DIN"):
            if os.path.exists(cand):
                return load_container(cand, path)
        raise ParseError(f"{path}: no sibling .din")
    return load_container(path)


def cmd_list(container: Container) -> None:
    print(f"{container.bin_path}: {len(container)} records, {len(container.data)} bytes")
    print(f"{'idx':>5} {'offset':>9} {'size':>7} {'verts':>6} {'faces':>6} "
          f"{'radius':>8} name")
    for i in range(len(container)):
        try:
            proto = container.parse(i)
        except ParseError as exc:
            print(f"{i:>5} {'':>9} {'':>7} {'ERROR':>6} {'':>6} {'':>8} "
                  f"{container.names[i]}  ({exc})")
            continue
        print(f"{i:>5} {proto.offset:>9} {proto.size:>7} {len(proto.vertices):>6} "
              f"{len(proto.faces):>6} {proto.cull_radius:>8} {proto.name}")


def _texture_count(din_path: str) -> int | None:
    """Number of entries in the texture.din that belongs to this world set."""
    parent = os.path.dirname(os.path.dirname(din_path))
    for name in os.listdir(parent) if os.path.isdir(parent) else []:
        if name.lower() != "textures":
            continue
        tex_dir = os.path.join(parent, name)
        lower = {f.lower(): f for f in os.listdir(tex_dir)}
        if "texture.din" not in lower:
            continue
        with open(os.path.join(tex_dir, lower["texture.din"]), "rb") as fh:
            head = fh.read(8)
        if head[:4] == b"DBIN":
            return int.from_bytes(head[4:8], "little")
    return None


def cmd_check(root: str) -> int:
    """Parse every record in every container and report hard coverage numbers."""
    containers = find_containers(root)
    if not containers:
        LOG.error("no prototyp.din/prototyp.bin pairs under %s", root)
        return 2

    total = 0
    parsed = 0
    failures: list[str] = []
    exact_cover = 0
    overlap = 0
    uncovered_total = 0
    bbox_exact = 0
    bbox_within_2 = 0
    bbox_worse: list[str] = []
    bad_index: list[str] = []
    bad_plane: list[str] = []
    tree_ptr_ok = 0
    tree_ptr_bad = 0
    alt_ok = 0
    alt_bad = 0
    opcode_hist: collections.Counter[str] = collections.Counter()
    draw_hist: collections.Counter[str] = collections.Counter()
    tex_max = -1
    tex_out_of_range: list[str] = []
    vert_total = 0
    face_total = 0
    vmin = vmax = 0
    bbox_contains = 0
    height_ok = 0
    radius_pair_ok = 0
    depth_bias_nonzero = 0
    trailing_bytes = 0
    gap_records: list[str] = []
    fan_ok = 0
    exact_planar = 0
    worst_out_of_plane = 0.0
    worst_face = ""
    non_convex: list[str] = []
    degenerate = 0
    repeated: list[str] = []
    #: Faces the index guard skipped, so they never reached `face_shape`.
    unshaped = 0
    #: Faces that fell into no shape bucket, or into more than one.  The three
    #: pinned counts used to be checked by `fan_ok + non_convex + degenerate ==
    #: face_total`, which is an identity over three sets that were never
    #: disjoint by construction: a *convex* face naming a vertex twice is in
    #: none of them (`fan_ok` excludes it, `non_convex` needs `not convex`),
    #: and a face with fewer than three indices is counted as both fannable
    #: and degenerate.  Neither occurs today, so the identity held -- and when
    #: one does occur, the run says only `SOME CHECKS FAILED` with no line
    #: naming which face or which condition.  These lists name them.
    unclassified: list[str] = []
    double_counted: list[str] = []
    face_sizes: collections.Counter[int] = collections.Counter()
    #: The side test of docs/31 section 4.2, face by face.
    plane_zero = 0
    wound_against = 0
    wound_zero = 0
    wound_with: list[str] = []
    plane_d_in_span = 0
    plane_d_by_precision = 0
    plane_d_unexplained: list[str] = []
    plane_d_worst_miss = 0.0
    plane_d_worst_face = ""
    plane_d_worst_world_miss = 0.0
    plane_normal_magnitudes: collections.Counter[int] = collections.Counter()
    plane_normal_too_long: list[str] = []
    lattice_faces = 0
    lattice_bad: list[str] = []
    overdraw_census = overdrawmod.Census()
    overdraw_faces = 0
    walk = overdrawmod.WalkCensus()

    for din, binp in containers:
        container = load_container(din, binp)
        rel = os.path.relpath(din, root)
        ntex = _texture_count(din)
        for i in range(len(container)):
            total += 1
            try:
                proto = container.parse(i)
            except ParseError as exc:
                failures.append(f"{rel}[{i}] {container.names[i]}: {exc}")
                continue
            parsed += 1
            uncovered_total += proto.uncovered_bytes
            if proto.uncovered_bytes == 0:
                exact_cover += 1
            else:
                gap_records.append(
                    f"{rel}[{i}] {proto.name}: {proto.uncovered_bytes} bytes")
            if proto.overlapped_bytes:
                overlap += 1
            if proto.tree is not None:
                walk = walk + overdrawmod.walk_census(proto)
                overdraw_census = overdraw_census + overdrawmod.census(proto)
                overdraw_faces += sum(
                    1 for r in overdrawmod.overdraw_ranks(proto) if r)

            for cmd in proto.render_cmds:
                opcode_hist["render:" + cmd.name] += 1
            for cmd in proto.collision_cmds:
                opcode_hist["collision:" + cmd.name] += 1
            for cmd in proto.partinfo_cmds:
                opcode_hist["partinfo:" + cmd.name] += 1

            vert_total += len(proto.vertices)
            face_total += len(proto.faces)

            hdr = (proto.bbox_min[0], proto.bbox_max[0], proto.bbox_min[1],
                   proto.bbox_max[1], proto.bbox_min[2], proto.bbox_max[2])
            vb = proto.vertex_bbox
            if vb is not None:
                got = (vb[0][0], vb[1][0], vb[0][1], vb[1][1], vb[0][2], vb[1][2])
                dev = max(abs(a - b) for a, b in zip(hdr, got))
                if dev == 0:
                    bbox_exact += 1
                if dev <= 2:
                    bbox_within_2 += 1
                else:
                    bbox_worse.append(f"{rel}[{i}] {proto.name}: deviation {dev}")
                if all(h <= g for h, g in zip(hdr[::2], got[::2])) and \
                        all(h >= g for h, g in zip(hdr[1::2], got[1::2])):
                    bbox_contains += 1
                for v in proto.placed_vertices:
                    vmin = min(vmin, min(v))
                    vmax = max(vmax, max(v))
            if proto.height == -proto.bbox_min[2]:
                height_ok += 1
            if proto.collision_radius == proto.cull_radius:
                radius_pair_ok += 1
            if proto.depth_bias:
                depth_bias_nonzero += 1

            nv = len(proto.vertices)
            np_ = len(proto.planes)
            for f in proto.faces:
                draw_hist[f.draw_name] += 1
                trailing_bytes += len(f.trailing)
                if f.texture is not None:
                    tex_max = max(tex_max, f.texture)
                    if ntex is not None and f.texture >= ntex:
                        tex_out_of_range.append(
                            f"{rel}[{i}] {proto.name}: texture {f.texture} >= {ntex}")
                if any(k >= nv for k in f.indices):
                    bad_index.append(f"{rel}[{i}] {proto.name} face@0x{f.pos:x}")
                    break
            placed = proto.placed_vertices
            for f in proto.faces:
                face_sizes[len(f.indices)] += 1
                if any(k >= len(placed) for k in f.indices):
                    unshaped += 1
                    continue
                shape = face_shape(placed, f.indices)
                if shape.degenerate:
                    degenerate += 1
                if shape.fan_ok:
                    fan_ok += 1
                if shape.planar:
                    exact_planar += 1
                where = f"{rel}[{i}] {proto.name} face@0x{f.pos:x} " \
                        f"({len(f.indices)} verts)"
                deviation = face_out_of_plane(placed, f.indices)
                if deviation > worst_out_of_plane:
                    worst_out_of_plane = deviation
                    worst_face = where
                if not shape.convex and not shape.degenerate:
                    non_convex.append(where)
                if f.plane_index == 0:
                    plane_zero += 1
                elif abs(f.plane_index) <= np_:
                    normal = proto.planes[abs(f.plane_index) - 1]
                    if f.plane_index < 0:
                        normal = (-normal[0], -normal[1], -normal[2])
                    corners = [placed[k] for k in f.indices]
                    wound = newell_normal(corners)
                    turn = sum(a * b for a, b in zip(wound, normal))
                    if turn < 0:
                        wound_against += 1
                    elif turn > 0:
                        wound_with.append(f"{where}: newell {wound}")
                    else:
                        wound_zero += 1
                    # The plane's own frame: a part face is placed by the
                    # part translation at draw time and its plane is not.
                    frame = [proto.vertices[k] for k in f.indices] \
                        if any(proto.vertex_part[k] >= 0
                               for k in f.indices) else corners
                    spans = [-sum(a * b for a, b in zip(normal, p)) / 16384
                             for p in frame]
                    if min(spans) - PLANE_D_SLACK <= f.plane_d \
                            <= max(spans) + PLANE_D_SLACK:
                        plane_d_in_span += 1
                    else:
                        miss = max(min(spans) - f.plane_d,
                                   f.plane_d - max(spans))
                        radius = max(math.sqrt(p[0] * p[0] + p[1] * p[1]
                                               + p[2] * p[2]) for p in frame)
                        # The smallest rotation of the stored normal that
                        # would put plane_d back in the span.
                        if radius and math.degrees(miss / radius) \
                                <= PLANE_NORMAL_SLACK_DEG:
                            plane_d_by_precision += 1
                            if miss > plane_d_worst_miss:
                                plane_d_worst_miss = miss
                                plane_d_worst_face = where
                            if not rel.startswith("Video") \
                                    and miss > plane_d_worst_world_miss:
                                plane_d_worst_world_miss = miss
                        else:
                            plane_d_unexplained.append(
                                f"{where}: plane_d {f.plane_d} misses the "
                                f"span by {miss:.1f} at radius {radius:.0f}")
                    magnitude = math.sqrt(sum(a * a for a in normal))
                    plane_normal_magnitudes[round(magnitude)] += 1
                    if magnitude > PLANE_NORMAL_MAGNITUDE + 0.5:
                        plane_normal_too_long.append(f"{where}: {normal}")
                    if proto.name.upper() == LATTICE_PROTOTYPE:
                        lattice_faces += 1
                        if normal != LATTICE_NORMAL \
                                or f.plane_d != LATTICE_PLANE_D:
                            lattice_bad.append(
                                f"{where}: normal {normal} d {f.plane_d}")
                if shape.repeated:
                    repeated.append(where)
                # Exactly one of the three pinned buckets, or it is named.
                in_bucket = sum((shape.degenerate,
                                 shape.fan_ok,
                                 not shape.convex and not shape.degenerate))
                if in_bucket == 0:
                    unclassified.append(
                        f"{where}: convex={shape.convex} "
                        f"repeated={shape.repeated} "
                        f"degenerate={shape.degenerate}")
                elif in_bucket > 1:
                    double_counted.append(
                        f"{where}: in {in_bucket} buckets "
                        f"(convex={shape.convex} repeated={shape.repeated} "
                        f"degenerate={shape.degenerate})")
            for f in proto.faces:
                if abs(f.plane_index) > np_:
                    bad_plane.append(f"{rel}[{i}] {proto.name} face@0x{f.pos:x}")
                    break

            root_pos = next((c.payload for c in proto.render_cmds
                             if c.name == "draw_faces"), None)
            if proto.face_tree_pointer is not None and root_pos is not None:
                if proto.face_tree_pointer == root_pos:
                    tree_ptr_ok += 1
                else:
                    tree_ptr_bad += 1

            vpay = [c.payload for c in proto.render_cmds if c.name == "load_vertices"]
            ppay = [c.payload for c in proto.render_cmds if c.name == "load_planes"]
            wv = [c.payload for c in proto.collision_cmds if c.name == "world_vertices"]
            wp = [c.payload for c in proto.collision_cmds if c.name == "world_planes"]
            for got, want in ((wv, vpay), (wp, ppay)):
                if got == want:
                    alt_ok += len(got)
                else:
                    alt_bad += max(len(got), len(want))

    print(f"corpus: {len(containers)} prototyp.bin containers under {root}")
    print(f"records parsed:              {parsed}/{total}")
    print(f"byte-exact record coverage:  {exact_cover}/{parsed} "
          f"({uncovered_total} bytes unaccounted in total)")
    print(f"records with overlaps:       {overlap}")
    print(f"face vertex indices in range:{parsed - len(bad_index)}/{parsed}")
    print(f"face plane indices in range: {parsed - len(bad_plane)}/{parsed}")
    print(f"header bbox == vertex bbox:  {bbox_exact}/{parsed} exact, "
          f"{bbox_within_2}/{parsed} within +/-2 units")
    print(f"face-tree back-pointer ok:   {tree_ptr_ok} (mismatch {tree_ptr_bad})")
    print(f"collision stream reuses the render vertex/plane blocks: "
          f"{alt_ok} ok, {alt_bad} mismatched")
    print(f"header bbox contains verts:  {bbox_contains}/{parsed}")
    print(f"height == -bbox_min[2]:      {height_ok}/{parsed}")
    print(f"collision_radius==cull_radius{radius_pair_ok:>8}/{parsed}")
    print(f"depth_bias non-zero:         {depth_bias_nonzero}/{parsed}")
    print(f"texture ids within texture.din count: "
          f"{face_total - len(tex_out_of_range)}/{face_total}")
    print(f"unexplained bytes inside faces: {trailing_bytes}")
    # A triangle fan from vertex 0 is a correct triangulation exactly when the
    # polygon is planar, convex and names no vertex twice.  This is the check
    # that retires the manual `--obj` cross-check the remake's mesh builder
    # used to depend on.
    print(f"faces a triangle fan triangulates correctly: "
          f"{fan_ok}/{face_total} "
          f"(non-convex {len(non_convex)}, repeated index {len(repeated)}, "
          f"zero-area {degenerate})")
    print(f"faces exactly planar in integer world units: "
          f"{exact_planar}/{face_total}; worst deviation "
          f"{worst_out_of_plane:.1f} units on {worst_face}")
    # docs/31 section 4.2's side test, which is what makes the remake's faces
    # one-sided: every face has a plane, and the winding's Newell normal runs
    # against it, so the visible side is the front face as the indices stand.
    print(f"faces naming a side plane:   {face_total - plane_zero}/{face_total} "
          f"(plane index 0, 'always draw', on {plane_zero})")
    print(f"winding against the plane normal: {wound_against}; with it "
          f"{len(wound_with)}; no area {wound_zero}")
    print(f"plane_d == -n.v/16384 within the face's own span (a part face in "
          f"its part's frame): {plane_d_in_span}/{face_total}; the rest "
          f"within {PLANE_NORMAL_SLACK_DEG} deg of the 14-bit normal: "
          f"{plane_d_by_precision}, worst miss {plane_d_worst_miss:.0f} "
          f"units on {plane_d_worst_face}, {plane_d_worst_world_miss:.0f} "
          f"outside Video/; unexplained {len(plane_d_unexplained)}")
    print("plane normal magnitudes: "
          + ", ".join(f"{k}:{v}" for k, v in sorted(plane_normal_magnitudes.items())))
    print(f"ground lattice {LATTICE_PROTOTYPE}: {lattice_faces} faces, "
          f"normal {LATTICE_NORMAL} and plane_d {LATTICE_PLANE_D} on "
          f"{lattice_faces - len(lattice_bad)}")
    print(f"face tree walk: far child on the plane's front side at "
          f"{walk.far_front} nodes, back at {walk.far_back}, tie {walk.tie}; "
          f"{walk.straddling} nodes hold an unsplit straddling face")
    print(f"overlapping coplanar face pairs: {overdraw_census.same_leaf} in one "
          f"leaf, {overdraw_census.cross_leaf_on_lca_plane} across leaves on "
          f"their own split plane, {overdraw_census.cross_leaf_other} across "
          f"leaves on another plane, {overdraw_census.contained} with one face "
          f"inside the other; {overdraw_faces} faces get a non-zero overdraw")
    print("face vertex counts: "
          + ", ".join(f"{k}:{v}" for k, v in sorted(face_sizes.items())))
    print(f"totals: {vert_total} vertices, {face_total} faces, "
          f"coordinate range [{vmin}, {vmax}], max texture id {tex_max}")
    print("opcodes:")
    for k, v in sorted(opcode_hist.items()):
        print(f"  {k:<34} {v}")
    print("face draw kinds:")
    for k, v in sorted(draw_hist.items(), key=lambda t: -t[1]):
        print(f"  {k:<20} {v}")
    for label, items in (("PARSE FAILURES", failures),
                         ("BBOX DEVIATION > 2", bbox_worse),
                         ("VERTEX INDEX OUT OF RANGE", bad_index),
                         ("PLANE INDEX OUT OF RANGE", bad_plane),
                         ("TEXTURE ID OUT OF RANGE", tex_out_of_range),
                         ("UNEXPECTED NON-CONVEX FACE COUNT", non_convex
                          if len(non_convex) != EXPECTED_NON_CONVEX else []),
                         ("UNEXPECTED REPEATED-INDEX FACE COUNT", repeated
                          if len(repeated) != EXPECTED_REPEATED_INDEX else []),
                         ("FACES IN NO SHAPE BUCKET", unclassified),
                         ("UNEXPECTED FACE WOUND WITH ITS PLANE NORMAL",
                          wound_with if [w.split(" ")[1] for w in wound_with]
                          != EXPECTED_WOUND_WITH_PLANE else []),
                         ("GROUND LATTICE FACE OFF ITS PLANE", lattice_bad),
                         ("PLANE_D OFF THE FACE BEYOND THE NORMAL'S PRECISION",
                          plane_d_unexplained),
                         ("PLANE NORMAL LONGER THAN 16384",
                          plane_normal_too_long),
                         ("FACES IN MORE THAN ONE SHAPE BUCKET",
                          double_counted),
                         ("NOTE: records with unreferenced slack bytes",
                          gap_records)):
        if items:
            print(f"\n{label} ({len(items)}):")
            for line in items[:20]:
                print("  " + line)
            if len(items) > 20:
                print(f"  ... and {len(items) - 20} more")

    ok = (not failures and not bad_index and not bad_plane
          and not bbox_worse and not tex_out_of_range
          and overlap == 0 and tree_ptr_bad == 0 and alt_bad == 0
          and bbox_contains == parsed and height_ok == parsed
          and radius_pair_ok == parsed and trailing_bytes == 0
          and len(non_convex) == EXPECTED_NON_CONVEX
          and len(repeated) == EXPECTED_REPEATED_INDEX
          and degenerate == EXPECTED_ZERO_AREA
          # Every face is fannable, reflex, or has no area at all -- and now
          # that is checked per face rather than inferred from a sum, so a
          # face in no bucket or in two is named instead of turning the whole
          # run red without a reason.
          and not unclassified and not double_counted
          and fan_ok + len(non_convex) + degenerate == face_total - unshaped
          and unshaped == EXPECTED_UNSHAPED
          # The side test: no face is 'always drawn', the one face wound
          # with its plane is the known sliver, the three winding buckets
          # cover every shaped face, and the lattice fixes the sign.
          and plane_zero == 0
          and [w.split(" ")[1] for w in wound_with] == EXPECTED_WOUND_WITH_PLANE
          and wound_against + len(wound_with) + wound_zero
          == face_total - unshaped
          and wound_zero == EXPECTED_ZERO_AREA
          # plane_d is the face's own plane in its own frame, computed before
          # the normal lost its precision: the two counts are pinned, the
          # worst miss is bounded, and no normal is longer than 16384.
          and plane_d_in_span == EXPECTED_PLANE_D_IN_SPAN
          and plane_d_by_precision == EXPECTED_PLANE_D_BY_NORMAL_PRECISION
          and not plane_d_unexplained
          and round(plane_d_worst_miss) == EXPECTED_PLANE_D_WORST_MISS
          and round(plane_d_worst_world_miss)
          == EXPECTED_PLANE_D_WORST_MISS_WORLD
          and dict(plane_normal_magnitudes) == EXPECTED_PLANE_NORMAL_MAGNITUDES
          and not plane_normal_too_long
          and lattice_faces > 0 and not lattice_bad
          # The coplanar overdraw derivation the cache carries, pinned so a
          # change to the walk order or the overlap test shows as a count.
          and walk.far_front == EXPECTED_WALK_FAR_FRONT
          and walk.far_back == EXPECTED_WALK_FAR_BACK
          and walk.tie == EXPECTED_WALK_TIE
          and walk.straddling == EXPECTED_WALK_STRADDLING
          and overdraw_census.same_leaf == EXPECTED_OVERDRAW_SAME_LEAF
          and overdraw_census.cross_leaf_on_lca_plane
          == EXPECTED_OVERDRAW_CROSS_LEAF_ON_PLANE
          and overdraw_census.cross_leaf_other
          == EXPECTED_OVERDRAW_CROSS_LEAF_OTHER
          and overdraw_census.contained == EXPECTED_OVERDRAW_CONTAINED
          and overdraw_faces == EXPECTED_OVERDRAW_FACES)
    print("\n" + ("all checks passed" if ok else "SOME CHECKS FAILED"))
    return 0 if ok else 1


def _select(container: Container, args: argparse.Namespace) -> Prototype:
    if args.name:
        return container.parse(container.find(args.name))
    return container.parse(args.index)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?",
                    help="prototyp.din, prototyp.bin, or the directory holding them")
    ap.add_argument("--check", action="store_true",
                    help="parse every record of every container under --root")
    ap.add_argument("--root", default="gog_incubation",
                    help="data root for --check (default: gog_incubation)")
    ap.add_argument("--list", action="store_true", help="list the container's records")
    ap.add_argument("--json", action="store_true", help="dump one record as JSON")
    ap.add_argument("--name", help="select a record by prototype name")
    ap.add_argument("--index", type=int, default=0, help="select a record by index")
    ap.add_argument("--obj", help="write the selected record as Wavefront OBJ")
    ap.add_argument("--png", help="write an orthographic preview PNG")
    ap.add_argument("--png-axis", default="xy",
                    help="two axes to project on for --png (default xy)")
    ap.add_argument("--png-size", type=int, default=512)
    ap.add_argument("--wireframe", action="store_true")
    ap.add_argument("--opcodes", action="store_true",
                    help="print the opcode and draw-kind tables and exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s")

    if args.opcodes:
        print("command stream opcodes (slot = stream i16 / 4):")
        for slot, (name, kind) in sorted(OPCODES.items()):
            print(f"  {slot:>3}  0x{slot * 4:02x}  {name:<24} operand={kind}")
        print("face draw kinds (byte offset into the draw-routine table):")
        for k, (name, layout, semantics) in sorted(DRAW_KINDS.items()):
            print(f"  0x{k:02x}  {name:<12} payload={layout:<6} {semantics}")
        return 0

    if args.check:
        return cmd_check(args.root)

    if not args.path:
        ap.error("a container path is required unless --check/--opcodes is given")

    container = _resolve_container(args.path)

    if args.list:
        cmd_list(container)
        return 0

    proto = _select(container, args)

    if args.obj:
        os.makedirs(os.path.dirname(os.path.abspath(args.obj)), exist_ok=True)
        with open(args.obj, "w", encoding="utf-8") as fh:
            fh.write(to_obj(proto))
        LOG.info("wrote %s (%d vertices, %d faces)", args.obj,
                 len(proto.vertices), len(proto.faces))
    if args.png:
        os.makedirs(os.path.dirname(os.path.abspath(args.png)), exist_ok=True)
        render_png(proto, args.png, size=args.png_size, axis=args.png_axis,
                   wireframe=args.wireframe)
        LOG.info("wrote %s", args.png)

    if args.json or not (args.obj or args.png):
        payload: dict[str, Any] = proto.to_json(with_geometry=True)
        print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
