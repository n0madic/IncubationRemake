"""Decoder for the Eng3d ``prototyp.bin`` geometry container.

``prototyp.bin`` holds one *prototype* record per entry of the sibling
``prototyp.din`` index (see ``docs/30-eng3d-ascii-formats.md``).  A record is a
fixed 0x32-byte header followed by three self-relative **command streams** that
the engine executes directly out of the memory-mapped file, plus the payload
blocks those commands point at.

The layout below was derived from ``Eng3d.dll`` (Ghidra + radare2), not from
byte pattern matching; ``docs/31-prototyp-geometry.md`` cites the exact
addresses for every field.

Record header (all little-endian, byte offsets are from the record start)::

    0x00 i32  cull_radius        bounding-sphere radius (FUN_00404bd0 culling,
                                 FUN_0040508c buffer selection); this is the
                                 value mirrored in prototyp.dir column 4
    0x04 i32  bbox_min_x         \\
    0x08 i32  bbox_max_x          |
    0x0c i32  bbox_min_y          |  read as two vec3 by FUN_004063d8
    0x10 i32  bbox_max_y          |
    0x14 i32  bbox_min_z          |
    0x18 i32  bbox_max_z         /
    0x1c i32  depth_bias         added to the rotated Z before the sort-key
                                 squaring in FUN_00404bd0 (UNVERIFIED name)
    0x20 u16  flags              bit0 -> queue in the second draw list,
                                 bit1 -> also traverse the clone's sub-objects,
                                 bit2 -> use the alternate collision box test
    0x22 i32  height             returned by _E3D_get_clone_height; equals
                                 -bbox_min[2] in 26072/26072 shipped records
    0x26 i32  collision_radius   returned by _E3D_get_prototype_collision_radius
    0x2a i32  collision_program  self-relative offset (from 0x2a) to the
                                 world-space/collision command stream, or 0 for
                                 "no collision geometry" (read at 0x4067ac)
    0x2e i32  partinfo_program   self-relative offset (from 0x2e) to the
                                 _E3D_get_part_info command stream
    0x32 ...  render command stream (executed in place by FUN_0040508c)

After the face tree the record holds, in order: the collision command stream,
an i32 self-relative back-pointer to the face-tree root (read at 0x4067d1 once
the collision stream terminates), and the part-info stream, which runs to the
end of the record.

Command stream (FUN_0040508c @ 0x405147, FUN_00406370 @ 0x4063a0)::

    while ((op = *(i16 *)p) >= 0) {
        operand = *(i32 *)(p + 2);      // meaning depends on op
        handler[op](p + 2 + operand);   // dispatch through 0x41408c
        p += 6;
    }
    p += 2;                             // the terminating i16 only

Only a handful of the 40 dispatch slots occur in the shipped data; see
:data:`OPCODES`.
"""

from __future__ import annotations

import logging
import os
import struct
from dataclasses import dataclass, field
from typing import Any, Iterator, Sequence

from .binio import ParseError

LOG = logging.getLogger("prototyp")

HEADER_SIZE = 0x32
COMMAND_SIZE = 6

#: Dispatch slots of the interpreter table at ``Eng3d.dll:0x41408c``.
#:
#: ``op`` in the stream is the *byte* offset into that table, so the slot index
#: is ``op // 4``.  ``operand`` tells how the command's ``i32`` argument is used:
#:
#: * ``payload``  - self-relative offset to a data block inside the record
#: * ``anim``     - byte offset into the *clone*'s joint-angle buffer
#: * ``imm``      - plain immediate
#: * ``unused``   - the handler never reads it
OPCODES: dict[int, tuple[str, str]] = {
    0: ("load_vertices", "payload"),        # 0x41139e / 0x4114b4
    1: ("load_planes", "payload"),          # 0x410ea7
    2: ("load_shades", "payload"),          # 0x410f7b   lit i16 per entry into
                                            #            0x48cf48 (unused)
    3: ("load_uvbase", "payload"),          # 0x410ffa   environment-map u,v into
                                            #            0x48d71c (unused)
    4: ("stub_4", "payload"),               # 0x4110ea   a single `ret` (unused)
    5: ("draw_faces", "payload"),           # 0x405199
    6: ("matrix_identity", "unused"),       # 0x405f7e
    7: ("matrix_set_a8ac", "unused"),       # 0x405fb7
    8: ("joint_rotate_1", "anim"),          # 0x405fcd
    9: ("joint_rotate_3", "anim"),          # 0x405ffc
    10: ("joint_rotate_3_alt", "anim"),     # 0x406071
    11: ("matrix_none", "unused"),          # 0x405eb0
    12: ("matrix_set_a8ac_b", "unused"),    # 0x405ed6
    13: ("matrix_from_angle", "anim"),      # 0x405eec: one angle, as
                                            #  (0, 0, a), into 0x41a888
    14: ("matrix_from_angles_b", "anim"),   # 0x405f1a
    15: ("matrix_from_angles", "anim"),     # 0x405f4c
    16: ("part_push", "payload"),           # 0x4062ad
    17: ("part_pop", "payload"),            # 0x406313
    18: ("joint_place", "anim"),            # 0x4060f0
    19: ("lod_switch_0", "payload"),        # 0x40621b -> 0x4061dc, table 0x4142b0
    20: ("lod_switch_1", "payload"),        # 0x406222 -> 0x4061dc, table 0x4142c0
    21: ("lod_switch_2", "payload"),        # 0x406229 -> 0x4061dc, table 0x4142d0
    22: ("lod_switch_3", "payload"),        # 0x406230 -> 0x4061dc, table 0x4142e0
    23: ("distance_cull_0", "unused"),      # 0x40624e -> 0x406237, table 0x4142b0
    24: ("distance_cull_1", "unused"),      # 0x406255 -> 0x406237, table 0x4142c0
    25: ("distance_cull_2", "unused"),      # 0x40625c -> 0x406237, table 0x4142d0
    26: ("distance_cull_3", "unused"),      # 0x406263 -> 0x406237, table 0x4142e0
    27: ("emit_part_transform", "imm"),     # 0x406287
    28: ("select_detail", "unused"),        # 0x40619f: depth vs 4x/5x cull_radius
                                            # picks span-filler bank 0x407d01 /
                                            # 0x407d34 / 0x407d67
    29: ("draw_flat_bank", "unused"),       # 0x40616e -> 0x405170: adds 0xb0 to
                                            # the draw-table pointer once, moving
                                            # to the all-flat twin table
    30: ("switch_prototype", "imm"),        # 0x406173: operand is a prototype
                                            # index; execution continues in that
                                            # prototype's stream at its 0x32
    31: ("select_late_pass", "unused"),     # 0x4061d2 -> 0x407d9a: non-occluding
                                            # span fillers; Glide moves the same
                                            # prototypes into the late flat pass
    32: ("nop", "unused"),                  # 0x4052ee (ret)
    33: ("world_vertices", "payload"),      # 0x4060eb -> 0x4116ff
    34: ("world_planes", "payload"),        # 0x4060e6 -> 0x4117f3
    35: ("matrix_clone", "unused"),         # 0x405ebb
    36: ("matrix_clone_compose", "unused"), # 0x405f89
    37: ("select_bank_4", "unused"),        # 0x4061d7 -> 0x407dcd; Glide: ret
    38: ("matrix_none_b", "unused"),        # 0x405ee1: current matrix := 0x41a8d0
    39: ("matrix_none_c", "unused"),        # 0x405fc2: current matrix := 0x41a8d0
}

#: Face draw slots: the ``u16`` at face+0x00 is a *byte* offset into whichever
#: draw-routine table is active.  Four tables of 11 entries live at ``0x41413c``,
#: ``0x414168``, ``0x414194`` and ``0x4141c0``; ``FUN_0040508c`` @ ``0x405106``
#: indexes the pointer array at ``0x41412c`` with ``byte [clone + 0x10]``, which
#: ``_E3D_object_3d_check_in`` sets to a *clipping requirement* mask (bit 0 at
#: ``0x404d51`` = screen-x clip, bit 1 at ``0x404e13`` = depth clip).  So the
#: four tables are no-clip / 2D-clip / 3D-clip / both, and the payload layout is
#: a property of the slot alone.  Each table also has a ``+0xb0`` twin
#: (``0x4141ec`` ...) in which every entry is that clip variant's flat routine;
#: opcode 29 switches to it, i.e. "draw this prototype untextured".
#:
#: Layout codes: ``uv`` = ``i16 u, i16 v`` per vertex plus a trailing ``u32``
#: texture id; ``tex`` = a trailing ``u32`` texture id only; ``shade`` = one
#: ``i16`` per vertex plus a trailing ``u16`` colour ramp index; ``flat`` =
#: nothing after the index array.
#:
#: The third element is the rasteriser semantics, recovered from the software
#: fillers *and* from ``ENG3DFX.DLL``'s Glide state blocks; see
#: ``docs/31-prototyp-geometry.md`` section 4.4 for the addresses.
DRAW_KINDS: dict[int, tuple[str, str, str]] = {
    #      name           layout   semantics
    0x00: ("flat_00", "flat",
           "opaque flat RGB565 fill, drawn immediately"),        # 0x40f050
    0x04: ("gouraud_04", "shade",
           "ramp-shaded fill: per-vertex i16 indexes a colour "
           "ramp chosen by the trailing u16"),                   # 0x40f1d6
    0x08: ("texture_08", "uv",
           "opaque textured, always affine"),                    # 0x40f3f4
    0x0C: ("flat_0c", "flat",
           "50% translucent flat fill (dst>>1 + colour>>1), "
           "deferred to the transparent pass"),                  # 0x410837
    0x10: ("texture_10", "uv",
           "opaque textured, perspective-corrected within "
           "4x cull_radius, affine beyond"),                     # 0x41061b
    0x14: ("texture_14", "uv",
           "colour-keyed texture (texel 0x0000 = hole), "
           "deferred to the transparent pass"),                  # 0x40f86e
    0x18: ("texture_18", "uv",
           "distance-switched; its textured branch calls a "
           "filler pointer the DLL never sets (a bare ret), so "
           "only the flat fallback paints; 0 shipped faces"),    # 0x41037d
    0x1C: ("texture_1c", "uv",
           "saturating additive texture (texel 0x0000 skipped), "
           "deferred to the transparent pass"),                  # 0x40fc67
    0x20: ("texture_20", "uv",
           "saturating subtractive texture (texel 0x0000 "
           "skipped), deferred to the transparent pass"),        # 0x40fff2
    0x24: ("texture_24", "tex",
           "environment-mapped: carries no u,v of its own, the "
           "u,v come from the array load_uvbase builds"),        # 0x40f622
    0x28: ("none_28", "flat", "bare ret, draws nothing"),        # 0x410b12
}

VERTEX_STRIDE = 12  # i32 x, i32 y, i32 z
PLANE_STRIDE = 6    # i16 nx, i16 ny, i16 nz  (1/16384 fixed point)
FACE_HEADER_SIZE = 0x0E
PART_PAYLOAD_SIZE = 24


@dataclass
class Command:
    """One entry of a prototype command stream."""

    pos: int
    op: int
    name: str
    operand: int
    operand_kind: str
    payload: int | None  # absolute record offset, only for operand_kind "payload"


@dataclass
class Face:
    """One polygon of the render face tree."""

    pos: int
    draw_kind: int
    draw_name: str
    plane_index: int          # signed, 1-based into `planes`; 0 == always drawn
    plane_d: int
    size: int
    colour: int               # u16 read from record+0x0a by every draw routine
    indices: tuple[int, ...]  # global vertex slots (part base already applied)
    uvs: tuple[tuple[int, int], ...] | None
    texture: int | None
    trailing: bytes           # bytes not accounted for by the known layout


@dataclass
class BspNode:
    """Interior node of the face tree (FUN_004051b8)."""

    pos: int
    plane_index: int
    plane_d: int
    near: "BspNode | Leaf"
    far: "BspNode | Leaf"


@dataclass
class Leaf:
    """Linear run of faces (FUN_004051fc)."""

    pos: int
    faces: list[Face]


@dataclass
class Part:
    """A ``part_push`` scope: an index base plus a translation."""

    pos: int
    translation: tuple[int, int, int]
    vertex_base: int
    plane_base: int
    shade_base: int


@dataclass
class Prototype:
    """A fully decoded ``prototyp.bin`` record."""

    name: str
    index: int
    offset: int
    size: int

    cull_radius: int
    bbox_min: tuple[int, int, int]
    bbox_max: tuple[int, int, int]
    depth_bias: int
    flags: int
    height: int
    collision_radius: int
    collision_program: int
    partinfo_program: int

    render_cmds: list[Command] = field(default_factory=list)
    collision_cmds: list[Command] = field(default_factory=list)
    partinfo_cmds: list[Command] = field(default_factory=list)

    vertices: list[tuple[int, int, int]] = field(default_factory=list)
    #: Index into :attr:`parts` for each vertex slot, or -1 for the root scope.
    vertex_part: list[int] = field(default_factory=list)
    planes: list[tuple[int, int, int]] = field(default_factory=list)
    parts: list[Part] = field(default_factory=list)
    faces: list[Face] = field(default_factory=list)
    tree: "BspNode | Leaf | None" = None
    face_tree_pointer: int | None = None

    uncovered_bytes: int = 0
    overlapped_bytes: int = 0

    @property
    def placed_vertices(self) -> list[tuple[int, int, int]]:
        """Vertices with their enclosing part's translation applied.

        Sub-object vertices are stored in part-local space; at rest the engine
        places them with ``joint_place`` (op 18), whose translation comes from
        the ``part_push`` payload.  Non-zero joint angles come from the joint
        buffer inside the runtime ``object_3d`` (``docs/30`` 2.12), not from
        this container, so this is the rest pose only.
        """
        out: list[tuple[int, int, int]] = []
        for v, pi in zip(self.vertices, self.vertex_part):
            if pi < 0:
                out.append(v)
            else:
                t = self.parts[pi].translation
                out.append((v[0] + t[0], v[1] + t[1], v[2] + t[2]))
        return out

    @property
    def vertex_bbox(self) -> tuple[tuple[int, int, int], tuple[int, int, int]] | None:
        """Axis-aligned bounds of the placed vertices, or None if empty."""
        verts = self.placed_vertices
        if not verts:
            return None
        xs = [v[0] for v in verts]
        ys = [v[1] for v in verts]
        zs = [v[2] for v in verts]
        return (min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs))

    def to_json(self, with_geometry: bool = True) -> dict[str, Any]:
        """Return a JSON-serialisable view of the record."""
        out: dict[str, Any] = {
            "name": self.name,
            "index": self.index,
            "offset": self.offset,
            "size": self.size,
            "cull_radius": self.cull_radius,
            "bbox_min": list(self.bbox_min),
            "bbox_max": list(self.bbox_max),
            "depth_bias": self.depth_bias,
            "flags": self.flags,
            "height": self.height,
            "collision_radius": self.collision_radius,
            "collision_program": self.collision_program,
            "partinfo_program": self.partinfo_program,
            "vertex_count": len(self.vertices),
            "plane_count": len(self.planes),
            "face_count": len(self.faces),
            "part_count": len(self.parts),
            "uncovered_bytes": self.uncovered_bytes,
            "overlapped_bytes": self.overlapped_bytes,
            "render_program": [
                {"pos": c.pos, "op": c.op, "name": c.name, "operand": c.operand,
                 "payload": c.payload}
                for c in self.render_cmds
            ],
        }
        if with_geometry:
            out["vertices"] = [list(v) for v in self.vertices]
            out["planes"] = [list(p) for p in self.planes]
            out["faces"] = [
                {
                    "draw_kind": f.draw_kind,
                    "draw_name": f.draw_name,
                    "plane_index": f.plane_index,
                    "plane_d": f.plane_d,
                    "colour": f.colour,
                    "indices": list(f.indices),
                    "uvs": [list(uv) for uv in f.uvs] if f.uvs else None,
                    "texture": f.texture,
                    "trailing": f.trailing.hex() or None,
                }
                for f in self.faces
            ]
        return out


def _read_stream(rec: bytes, start: int, cover: bytearray | None) -> tuple[list[Command], int]:
    """Decode one command stream, returning the commands and its end offset."""
    cmds: list[Command] = []
    p = start
    while True:
        if p + 2 > len(rec):
            raise ParseError(f"command stream at 0x{start:x} runs past the record")
        op = struct.unpack_from("<h", rec, p)[0]
        if op < 0:
            if cover is not None:
                _mark(cover, p, 2)
            p += 2
            break
        if op % 4 or op // 4 >= 40:
            raise ParseError(f"invalid opcode 0x{op:x} at 0x{p:x}")
        if p + COMMAND_SIZE > len(rec):
            raise ParseError(f"truncated command at 0x{p:x}")
        operand = struct.unpack_from("<i", rec, p + 2)[0]
        slot = op // 4
        name, kind = OPCODES.get(slot, (f"op_{slot}", "unknown"))
        payload = p + 2 + operand if kind == "payload" else None
        if payload is not None and not 0 <= payload < len(rec):
            raise ParseError(f"payload of {name} at 0x{p:x} points outside the record")
        cmds.append(Command(p, slot, name, operand, kind, payload))
        if cover is not None:
            _mark(cover, p, COMMAND_SIZE)
        p += COMMAND_SIZE
    return cmds, p


def _mark(cover: bytearray, start: int, length: int) -> None:
    end = min(len(cover), start + length)
    for i in range(max(0, start), end):
        cover[i] += 1


def read_commands(record: bytes, start: int = HEADER_SIZE) -> list[Command]:
    """Decode only the command stream that begins at *start*.

    ``parse_record`` decodes the whole record; callers that just want to see
    which opcodes a prototype uses -- the transform family, the ``anim``
    operands -- do not need the geometry and should not pay for it.
    """
    cmds, _end = _read_stream(record, start, bytearray(len(record)))
    return cmds


def parse_record(data: bytes, name: str = "", index: int = -1, offset: int = 0) -> Prototype:
    """Decode a single ``prototyp.bin`` record.

    Args:
        data: The exact bytes of the record (offset .. next offset).
        name: Prototype name from ``prototyp.din``, for diagnostics.
        index: Record index inside the container.
        offset: Byte offset of the record in ``prototyp.bin``.

    Returns:
        The decoded :class:`Prototype`.

    Raises:
        ParseError: The record does not match the documented layout.
    """
    if len(data) < HEADER_SIZE + 2:
        raise ParseError(f"{name}: record of {len(data)} bytes is shorter than the header")

    cull_radius = struct.unpack_from("<i", data, 0x00)[0]
    bx0, bx1, by0, by1, bz0, bz1 = struct.unpack_from("<6i", data, 0x04)
    depth_bias = struct.unpack_from("<i", data, 0x1C)[0]
    flags = struct.unpack_from("<H", data, 0x20)[0]
    height = struct.unpack_from("<i", data, 0x22)[0]
    collision_radius = struct.unpack_from("<i", data, 0x26)[0]
    collision_program = struct.unpack_from("<i", data, 0x2A)[0]
    partinfo_program = struct.unpack_from("<i", data, 0x2E)[0]

    proto = Prototype(
        name=name, index=index, offset=offset, size=len(data),
        cull_radius=cull_radius,
        bbox_min=(bx0, by0, bz0), bbox_max=(bx1, by1, bz1),
        depth_bias=depth_bias, flags=flags, height=height,
        collision_radius=collision_radius,
        collision_program=collision_program,
        partinfo_program=partinfo_program,
    )

    cover = bytearray(len(data))
    _mark(cover, 0, HEADER_SIZE)

    proto.render_cmds, _ = _read_stream(data, HEADER_SIZE, cover)

    # Vertex / plane slots are keyed by the base set by the enclosing part_push,
    # exactly like the engine's DAT_00414040 / DAT_00414044 globals.
    vslots: dict[int, tuple[int, int, int]] = {}
    vowner: dict[int, int] = {}
    pslots: dict[int, tuple[int, int, int]] = {}
    vbase = 0
    pbase = 0
    part_index = -1
    base_stack: list[tuple[int, int, int]] = []
    face_root: int | None = None

    for cmd in proto.render_cmds:
        if cmd.name == "load_vertices":
            assert cmd.payload is not None
            count = struct.unpack_from("<H", data, cmd.payload)[0]
            need = 2 + count * VERTEX_STRIDE
            if cmd.payload + need > len(data):
                raise ParseError(f"{name}: vertex block at 0x{cmd.payload:x} overruns record")
            for k in range(count):
                vslots[vbase + k] = struct.unpack_from(
                    "<3i", data, cmd.payload + 2 + k * VERTEX_STRIDE)
                vowner[vbase + k] = part_index
            _mark(cover, cmd.payload, need)
        elif cmd.name == "load_planes":
            assert cmd.payload is not None
            count = struct.unpack_from("<H", data, cmd.payload)[0]
            need = 2 + count * PLANE_STRIDE
            if cmd.payload + need > len(data):
                raise ParseError(f"{name}: plane block at 0x{cmd.payload:x} overruns record")
            for k in range(count):
                pslots[pbase + k] = struct.unpack_from(
                    "<3h", data, cmd.payload + 2 + k * PLANE_STRIDE)
            _mark(cover, cmd.payload, need)
        elif cmd.name == "part_push":
            assert cmd.payload is not None
            if cmd.payload + PART_PAYLOAD_SIZE > len(data):
                raise ParseError(f"{name}: part block at 0x{cmd.payload:x} overruns record")
            tx, ty, tz, nvb, npb, nsb = struct.unpack_from("<6i", data, cmd.payload)
            base_stack.append((vbase, pbase, part_index))
            vbase, pbase = nvb, npb
            part_index = len(proto.parts)
            proto.parts.append(Part(cmd.payload, (tx, ty, tz), nvb, npb, nsb))
            _mark(cover, cmd.payload, PART_PAYLOAD_SIZE)
        elif cmd.name == "part_pop":
            # part_pop's operand points back at the same block part_push read,
            # so the bytes are already accounted for.
            if base_stack:
                vbase, pbase, part_index = base_stack.pop()
            else:
                vbase = pbase = 0
                part_index = -1
        elif cmd.name == "draw_faces":
            face_root = cmd.payload

    proto.vertices = _densify(vslots, name, "vertex")
    proto.vertex_part = [vowner.get(i, -1) for i in range(len(proto.vertices))]
    proto.planes = _densify(pslots, name, "plane")

    if face_root is not None:
        # The face tree is walked with the base that was in effect at draw time,
        # which is the outermost scope (every part_push is matched by a pop).
        proto.tree = _read_tree(data, face_root, proto, cover)

    # After the face tree the record carries, in order: the world-space
    # (collision) command stream, a self-relative i32 back-pointer to the face
    # tree root, and the _E3D_get_part_info command stream, which runs to EOF.
    partinfo_at = 0x2E + partinfo_program
    if not 0 <= partinfo_at < len(data):
        raise ParseError(f"{name}: partinfo program offset 0x{partinfo_at:x} out of range")

    ptr_at = partinfo_at - 4
    if ptr_at >= HEADER_SIZE:
        rel = struct.unpack_from("<i", data, ptr_at)[0]
        proto.face_tree_pointer = ptr_at + rel
        _mark(cover, ptr_at, 4)

    # The collision stream begins right after the last data block, i.e. at the
    # first byte below the back-pointer that nothing has claimed yet.
    data_end = HEADER_SIZE
    for i in range(min(ptr_at, len(cover)) - 1, -1, -1):
        if cover[i]:
            data_end = i + 1
            break
    if data_end < ptr_at:
        proto.collision_cmds, coll_end = _read_stream(data, data_end, cover)
        if coll_end != ptr_at:
            raise ParseError(
                f"{name}: collision stream at 0x{data_end:x} ends at 0x{coll_end:x}, "
                f"expected 0x{ptr_at:x}")
        if collision_program and 0x2A + collision_program != data_end:
            raise ParseError(
                f"{name}: header field 0x2a points at 0x{0x2A + collision_program:x} "
                f"but the collision stream starts at 0x{data_end:x}")

    proto.partinfo_cmds, end = _read_stream(data, partinfo_at, cover)
    if end != len(data):
        raise ParseError(
            f"{name}: partinfo stream ends at 0x{end:x}, record is 0x{len(data):x} bytes")

    proto.uncovered_bytes = sum(1 for c in cover if c == 0)
    proto.overlapped_bytes = sum(1 for c in cover if c > 1)
    return proto


def _densify(slots: dict[int, tuple[int, int, int]], name: str, what: str) -> list[tuple[int, int, int]]:
    """Turn the sparse slot map the command stream fills into a dense list.

    A missing slot is a **parse failure**, not something to paper over. It used
    to substitute ``(0, 0, 0)`` and log at DEBUG, i.e. invisibly: a gap became a
    phantom vertex at the origin, and the corpus check had no counter for it, so
    26072/26072 would still have been reported over records carrying fabricated
    geometry. Measured over the whole corpus -- all 21 containers, 26072
    records, 52144 calls -- **no slot is ever missing**, so raising costs
    nothing and closes the hole.
    """
    if not slots:
        return []
    top = max(slots) + 1
    missing = [i for i in range(top) if i not in slots]
    if missing:
        raise ParseError(
            f"{name}: {what} slots {missing[:8]} never filled "
            f"({len(missing)} of {top})")
    return [slots[i] for i in range(top)]


def _read_tree(data: bytes, pos: int, proto: Prototype, cover: bytearray,
               depth: int = 0) -> "BspNode | Leaf":
    if depth > 128:
        raise ParseError(f"{proto.name}: face tree deeper than 128 levels")
    if pos + 2 > len(data):
        raise ParseError(f"{proto.name}: face tree node at 0x{pos:x} out of range")
    tag = struct.unpack_from("<h", data, pos)[0]
    _mark(cover, pos, 2)
    if tag < 0:
        if pos + 10 > len(data):
            raise ParseError(f"{proto.name}: truncated BSP node at 0x{pos:x}")
        plane_index = struct.unpack_from("<h", data, pos + 2)[0]
        plane_d = struct.unpack_from("<i", data, pos + 4)[0]
        far_rel = struct.unpack_from("<h", data, pos + 8)[0]
        _mark(cover, pos + 2, 8)
        near = _read_tree(data, pos + 10, proto, cover, depth + 1)
        far = _read_tree(data, pos + 2 + far_rel, proto, cover, depth + 1)
        return BspNode(pos, plane_index, plane_d, near, far)

    leaf = Leaf(pos, [])
    q = pos + 2
    for _ in range(tag):
        leaf.faces.append(_read_face(data, q, proto, cover))
        q += leaf.faces[-1].size
    proto.faces.extend(leaf.faces)
    return leaf


def _read_face(data: bytes, q: int, proto: Prototype, cover: bytearray) -> Face:
    if q + FACE_HEADER_SIZE > len(data):
        raise ParseError(f"{proto.name}: truncated face at 0x{q:x}")
    draw_kind = struct.unpack_from("<H", data, q)[0]
    plane_index = struct.unpack_from("<h", data, q + 2)[0]
    plane_d = struct.unpack_from("<i", data, q + 4)[0]
    size = struct.unpack_from("<H", data, q + 8)[0]
    colour = struct.unpack_from("<H", data, q + 0x0A)[0]
    count = struct.unpack_from("<H", data, q + 0x0C)[0]
    if size < FACE_HEADER_SIZE + 2 * count or q + size > len(data):
        raise ParseError(
            f"{proto.name}: face at 0x{q:x} declares size {size} for {count} vertices")
    indices = struct.unpack_from(f"<{count}H", data, q + FACE_HEADER_SIZE)
    rest = data[q + FACE_HEADER_SIZE + 2 * count:q + size]

    kind_name, kind_layout, _ = DRAW_KINDS.get(
        draw_kind, (f"draw_{draw_kind:#x}", "unknown", ""))
    uvs: tuple[tuple[int, int], ...] | None = None
    texture: int | None = None
    trailing = rest
    if kind_layout == "uv" and len(rest) >= 4 * count + 4:
        uvs = tuple(struct.unpack_from("<2h", rest, 4 * k) for k in range(count))
        texture = struct.unpack_from("<I", rest, 4 * count)[0]
        trailing = rest[4 * count + 4:]
    elif kind_layout == "tex" and len(rest) >= 4:
        # 0x40f622 rewinds over the index array (0x40f662) and takes u,v from
        # the load_uvbase array, so only the texture id follows the indices.
        texture = struct.unpack_from("<I", rest, 0)[0]
        trailing = rest[4:]
    elif kind_layout == "shade" and len(rest) >= 2 * count + 2:
        # i16 intensity per vertex, then a u16 selecting the colour ramp that
        # 0x40f236 looks up in 0x43b088.  No shipped face uses this kind.
        trailing = rest[2 * count + 2:]
    elif kind_layout == "flat":
        trailing = rest

    _mark(cover, q, size)
    return Face(q, draw_kind, kind_name, plane_index, plane_d, size, colour,
                tuple(indices), uvs, texture, trailing)


# --------------------------------------------------------------------------
# container access
# --------------------------------------------------------------------------


@dataclass
class Container:
    """A ``prototyp.din`` / ``prototyp.bin`` pair."""

    din_path: str
    bin_path: str
    names: list[str]
    offsets: list[int]
    data: bytes

    def __len__(self) -> int:
        return len(self.names)

    def record_bytes(self, index: int) -> bytes:
        start = self.offsets[index]
        end = self.offsets[index + 1] if index + 1 < len(self.offsets) else len(self.data)
        return self.data[start:end]

    def parse(self, index: int) -> Prototype:
        return parse_record(self.record_bytes(index), self.names[index], index,
                            self.offsets[index])

    def find(self, name: str) -> int:
        upper = name.upper()
        for i, n in enumerate(self.names):
            if n.upper() == upper:
                return i
        raise KeyError(name)

    def __iter__(self) -> Iterator[Prototype]:
        for i in range(len(self.names)):
            yield self.parse(i)


def load_container(din_path: str, bin_path: str | None = None) -> Container:
    """Load a ``prototyp.din``/``prototyp.bin`` pair.

    Args:
        din_path: Path to ``prototyp.din`` (any case).
        bin_path: Path to the sibling ``prototyp.bin``; derived when omitted.
    """
    if bin_path is None:
        bin_path = _sibling(din_path, ".bin")
    names, offsets = _read_din(din_path)
    with open(bin_path, "rb") as fh:
        data = fh.read()
    for i, off in enumerate(offsets):
        if not 0 <= off < len(data):
            raise ParseError(f"{din_path}: record {i} offset {off} outside {bin_path}")
    return Container(din_path, bin_path, names, offsets, data)


def _sibling(path: str, suffix: str) -> str:
    base = os.path.splitext(path)[0]
    for cand in (base + suffix, base + suffix.upper()):
        if os.path.exists(cand):
            return cand
    return base + suffix


def _read_din(path: str) -> tuple[list[str], list[int]]:
    """Read ``prototyp.din``: u32 len, name, NUL, u32 offset until EOF."""
    with open(path, "rb") as fh:
        raw = fh.read()
    names: list[str] = []
    offsets: list[int] = []
    p = 0
    while p < len(raw):
        if p + 4 > len(raw):
            raise ParseError(f"{path}: truncated name length at 0x{p:x}")
        n = struct.unpack_from("<I", raw, p)[0]
        p += 4
        if n == 0 or p + n + 5 > len(raw):
            raise ParseError(f"{path}: implausible name length {n} at 0x{p - 4:x}")
        name = raw[p:p + n].decode("cp1252", errors="replace")
        p += n
        if raw[p] != 0:
            raise ParseError(f"{path}: missing NUL after name {name!r}")
        p += 1
        offsets.append(struct.unpack_from("<I", raw, p)[0])
        p += 4
        names.append(name)
    return names, offsets


def find_containers(root: str) -> list[tuple[str, str]]:
    """Find every ``prototyp.din``/``prototyp.bin`` pair below `root`."""
    out: list[tuple[str, str]] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        lower = {f.lower(): f for f in filenames}
        if "prototyp.din" in lower and "prototyp.bin" in lower:
            out.append((os.path.join(dirpath, lower["prototyp.din"]),
                        os.path.join(dirpath, lower["prototyp.bin"])))
    return sorted(out)


# --------------------------------------------------------------------------
# export helpers
# --------------------------------------------------------------------------


def to_obj(proto: Prototype, swap_yz: bool = True, scale: float = 1.0) -> str:
    """Render a prototype as a Wavefront OBJ document.

    In prototype-local space the third component is the vertical axis (up is
    positive): ``height`` equals ``-bbox_min[2]`` in 26072/26072 records, and
    projecting X against component 2 produces upright objects.  OBJ viewers
    expect Y up, so `swap_yz` emits ``(x, z, y)``; that mirrors handedness, so
    the face winding is reversed to keep normals pointing outwards.
    """
    lines = [
        f"# Incubation prototype {proto.name}",
        f"# {len(proto.vertices)} vertices, {len(proto.faces)} faces",
        f"# cull_radius={proto.cull_radius} height={proto.height} "
        f"collision_radius={proto.collision_radius}",
        "# axes: model (x, y_forward, z_up)"
        + (" -> obj (x, y_up, z_forward)" if swap_yz else " emitted verbatim"),
    ]
    for x, y, z in proto.placed_vertices:
        if swap_yz:
            lines.append(f"v {x * scale:.6g} {z * scale:.6g} {y * scale:.6g}")
        else:
            lines.append(f"v {x * scale:.6g} {y * scale:.6g} {z * scale:.6g}")
    has_uv = any(f.uvs for f in proto.faces)
    uv_index: dict[tuple[int, int], int] = {}
    if has_uv:
        for f in proto.faces:
            for uv in f.uvs or ():
                if uv not in uv_index:
                    uv_index[uv] = len(uv_index) + 1
                    # UVs are 8.7 fixed point in texels on a 256x256 page
                    # (observed range 0..32767).  OBJ wants 0..1 with V up.
                    lines.append(f"vt {uv[0] / 32768.0:.6g} "
                                 f"{1.0 - uv[1] / 32768.0:.6g}")
    current: int | None = None
    for f in proto.faces:
        group = f.texture if f.texture is not None else -1
        label = "tex%d" % group if group >= 0 else "flat"
        if group != current:
            current = group
            lines.append(f"g {label}")
            lines.append(f"usemtl {label}")
        if f.uvs:
            parts = [f"{i + 1}/{uv_index[uv]}" for i, uv in zip(f.indices, f.uvs)]
        else:
            parts = [str(i + 1) for i in f.indices]
        if swap_yz:
            parts = list(reversed(parts))
        lines.append("f " + " ".join(parts))
    return "\n".join(lines) + "\n"


def colour_rgb(colour: int) -> tuple[int, int, int]:
    """Expand the per-face u16 colour as RGB565.

    Verified: the flat filler loads the value into ``0x445088`` and, when the
    screen is 15-bit, converts it with ``and 0xffc0ffc0 / and 0x1f001f / shr 1``
    (``Eng3d.dll:0x4088f3``) - the standard 565 -> 555 squeeze.
    """
    r = (colour >> 11) & 0x1F
    g = (colour >> 5) & 0x3F
    b = colour & 0x1F
    return (r * 255 // 31, g * 255 // 63, b * 255 // 31)


def render_png(proto: Prototype, path: str, size: int = 512,
               axis: str = "xy", wireframe: bool = False) -> None:
    """Write an orthographic preview of the mesh to `path`.

    Faces are painted back-to-front by depth and flat-shaded from their stored
    plane normal, which makes an obviously-wrong parse obviously wrong.
    """
    from .png import write_rgb_png

    if not proto.vertices or not proto.faces:
        raise ParseError(f"{proto.name}: nothing to render")

    ax = {"x": 0, "y": 1, "z": 2}
    a0, a1 = ax[axis[0]], ax[axis[1]]
    depth_axis = 3 - a0 - a1

    verts = proto.placed_vertices
    pts = [(v[a0], -v[a1]) for v in verts]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    span = max(max(xs) - min(xs), max(ys) - min(ys), 1)
    margin = size * 0.06
    k = (size - 2 * margin) / span
    ox = margin - min(xs) * k + (size - 2 * margin - (max(xs) - min(xs)) * k) / 2
    oy = margin - min(ys) * k + (size - 2 * margin - (max(ys) - min(ys)) * k) / 2
    screen = [(p[0] * k + ox, p[1] * k + oy) for p in pts]

    buf = bytearray(b"\x18" * (size * size * 3))

    def put(x: int, y: int, rgb: tuple[int, int, int]) -> None:
        if 0 <= x < size and 0 <= y < size:
            o = (y * size + x) * 3
            buf[o:o + 3] = bytes(rgb)

    def line(p0: tuple[float, float], p1: tuple[float, float],
             rgb: tuple[int, int, int]) -> None:
        steps = int(max(abs(p1[0] - p0[0]), abs(p1[1] - p0[1]))) + 1
        for s in range(steps + 1):
            t = s / steps
            put(int(p0[0] + (p1[0] - p0[0]) * t), int(p0[1] + (p1[1] - p0[1]) * t), rgb)

    def fill(poly: Sequence[tuple[float, float]], rgb: tuple[int, int, int]) -> None:
        ymin = max(0, int(min(p[1] for p in poly)))
        ymax = min(size - 1, int(max(p[1] for p in poly)))
        for y in range(ymin, ymax + 1):
            xs_hit: list[float] = []
            for i in range(len(poly)):
                (x0, y0), (x1, y1) = poly[i], poly[(i + 1) % len(poly)]
                if (y0 <= y < y1) or (y1 <= y < y0):
                    xs_hit.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
            xs_hit.sort()
            for i in range(0, len(xs_hit) - 1, 2):
                for x in range(max(0, int(xs_hit[i])), min(size - 1, int(xs_hit[i + 1])) + 1):
                    put(x, y, rgb)

    order = []
    for f in proto.faces:
        if len(f.indices) < 3 or any(i >= len(proto.vertices) for i in f.indices):
            continue
        depth = sum(verts[i][depth_axis] for i in f.indices) / len(f.indices)
        order.append((depth, f))
    order.sort(key=lambda t: -t[0])

    for _depth, f in order:
        poly = [screen[i] for i in f.indices]
        base = colour_rgb(f.colour) if f.colour else (170, 170, 175)
        shade = 1.0
        if f.plane_index and abs(f.plane_index) <= len(proto.planes):
            n = proto.planes[abs(f.plane_index) - 1]
            norm = max(1.0, (n[0] ** 2 + n[1] ** 2 + n[2] ** 2) ** 0.5)
            shade = 0.35 + 0.65 * abs(n[depth_axis]) / norm
        rgb = tuple(min(255, int(c * shade) + 25) for c in base)
        if not wireframe:
            fill(poly, rgb)  # type: ignore[arg-type]
        for i in range(len(poly)):
            line(poly[i], poly[(i + 1) % len(poly)], (20, 20, 20) if not wireframe
                 else (220, 220, 220))

    write_rgb_png(path, size, size, bytes(buf))
