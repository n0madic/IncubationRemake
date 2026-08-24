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
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.binio import ParseError  # noqa: E402
from inclib.prototyp import (  # noqa: E402
    DRAW_KINDS,
    OPCODES,
    Container,
    Prototype,
    find_containers,
    load_container,
    render_png,
    to_obj,
)

LOG = logging.getLogger("prototyp_parse")


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
          and radius_pair_ok == parsed and trailing_bytes == 0)
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
