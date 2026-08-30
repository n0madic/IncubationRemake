"""Shared primitives for the Charisma engine object/animation streams.

Charisma is the 3D engine used by Incubation (Blue Byte, 1997).  Its
serialised objects live in ``.cho`` (Charisma Object / model) and ``.cha``
(Charisma Animation) files under ``CHData/`` and ``Video/``.

The grammar implemented here is not inferred from the bytes: it is transcribed
from the ``Load`` methods of ``Incubation.exe`` (see
``docs/40-charisma-model-animation.md`` for the function addresses that prove
each field).  Every ``*Desc`` class writes its own fields first and then
delegates to its base class, so a record on disk is the concatenation of one
``u16 version`` + body per level of the C++ inheritance chain.

Stream primitives, from ``Incubation.exe``:

===========================  ==========  ====================================
function                     address     meaning
===========================  ==========  ====================================
``ReadU16``                  0x004af7c8  2 bytes, little endian
``ReadU32``                  0x004af7ec  4 bytes, little endian
``ReadF32``                  0x004af810  4 bytes, IEEE-754 single
``ReadString``               0x004af837  ``u32 length`` + length bytes, no NUL
``LoadStorableObject(s)``    0x004af4ed  ``ReadString`` then the call below
``LoadStorableObject(s,n)``  0x004af552  registry lookup by name, then Load
===========================  ==========  ====================================

All integers are little-endian.
"""

from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field
from typing import Callable

from .binio import ParseError, Reader, read_file

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# The two class registries
# ---------------------------------------------------------------------------
#
# Charisma keeps two disjoint name->factory tables, both populated at start-up
# (``StdCharisma::RegisterComponentClass`` @ 0x00498b3b).  The RTTI of
# Incubation.exe spells both out as ``StorableClass<T>`` / ``ComponentClass<T>``
# template instantiations, so the two lists below are exhaustive, not guessed.

# IStorable classes.  These - and only these - can appear as a class-name
# record in the stream; ``StorableManager::LoadStorableObject`` reads the name
# and looks it up here.
STORABLE_CLASSES: frozenset[str] = frozenset(
    {
        "BezierFloatKey",
        "BezierFloatMovementDesc",
        "BezierRotationKey",
        "BezierRotationMovementDesc",
        "BezierVectorKey",
        "BezierVectorMovementDesc",
        "KeyFramedAnimationDesc",
        "LinearFloatKey",
        "LinearFloatMovementDesc",
        "LinearRotationKey",
        "LinearRotationMovementDesc",
        "LinearVectorKey",
        "LinearVectorMovementDesc",
        "SkeletonDesc",
        "SkeletonNode",
        "V100ModelDesc",
        "V100PartDesc",
    }
)

# IComponent classes.  These are *never* serialised.  A descriptor stores the
# name of the runtime component it should build as a plain string field of
# StdComponentDesc (see :class:`ComponentDesc`), and the engine instantiates it
# through this second registry.  That is why V100Camera, StdAnimation and the
# External*Movement classes have no record layout at all.
COMPONENT_CLASSES: frozenset[str] = frozenset(
    {
        "BezierFloatMovement",
        "BezierRotationMovement",
        "BezierVectorMovement",
        "ExternalFloatMovement",
        "ExternalRotationMovement",
        "ExternalVectorMovement",
        "KeyFramedAnimation",
        "LinearFloatMovement",
        "LinearRotationMovement",
        "LinearVectorMovement",
        "StdAnimation",
        "V100Camera",
        "V100Model",
        "V100Part",
    }
)

# Kept for callers that just want "any name the engine knows".
KNOWN_CLASSES: frozenset[str] = STORABLE_CLASSES | COMPONENT_CLASSES

# The storable classes that derive from IComponentDesc, i.e. the only ones a
# StdComponentDesc child slot accepts.  Proven from the child loop at
# 0x0049aab6: each element goes through LoadStorableObject (name first) and is
# then handed to __RTDynamicCast with target type descriptor 0x004f6a10 =
# ".?AVIComponentDesc@@" (source 0x004f6a30 = ".?AVIStorable@@"); a failed cast
# aborts the load.  Keys, SkeletonDesc and SkeletonNode are therefore excluded.
COMPONENT_DESC_CLASSES: frozenset[str] = frozenset(
    {
        "BezierFloatMovementDesc",
        "BezierRotationMovementDesc",
        "BezierVectorMovementDesc",
        "KeyFramedAnimationDesc",
        "LinearFloatMovementDesc",
        "LinearRotationMovementDesc",
        "LinearVectorMovementDesc",
        "V100ModelDesc",
        "V100PartDesc",
    }
)

# Populated by cho_parse / cha_parse at import time: class name -> reader that
# consumes the record *after* its class-name record has been read.  Used only
# for StdComponentDesc children, which are polymorphic.
DESC_READERS: dict[str, Callable[["Reader"], object]] = {}


def register_desc_reader(name: str, reader: Callable[["Reader"], object]) -> None:
    """Register a ``*Desc`` body reader so nested children can be parsed."""
    if name not in COMPONENT_DESC_CLASSES:
        raise ValueError(f"{name!r} is not an IComponentDesc class")
    DESC_READERS[name] = reader


# Component category written by StdComponentDesc (u16 at 0x0049a9c4).  This is
# not authored data: each abstract base's constructor stores a literal, and
# Load simply overwrites it with the same value read back from the file.  The
# five assignment sites in Incubation.exe are
#
#   StdComponentDesc  ctor 0x0049a6ab -> 7   (base default, never reaches a file)
#   StdModelDesc      ctor 0x004a00bc -> 0
#   V100PartDesc      ctor 0x004a708a -> 1
#   StdAnimationDesc  ctor 0x0049ca43 -> 2
#   StdMovementDesc   ctor 0x0049b462 -> 3
#
# (iDesigner.exe has the identical five at 0x004576ec, 0x00463b29/0x00464d55,
# 0x0045e6ca, 0x00454073 and 0x00452a92.)  The labels below are ours; the
# engine carries no strings for them.
COMPONENT_KIND_NAMES: dict[int, str] = {
    0: "model",
    1: "part",
    2: "animation",
    3: "movement",
    7: "unspecified",
}

# Size in bytes of one key record on disk, *including* the leading u16 version.
# Proven from each key class's Load method: it reads a u16 version and then a
# fixed number of f32s.
#
#   LinearFloatKey::Load      @ 0x004a879c   u16 + 2 f32
#   LinearVectorKey::Load     @ 0x004a9683   u16 + 4 f32
#   LinearRotationKey::Load   @ 0x004aa59a   u16 + 5 f32
#   BezierFloatKey::Load      @ 0x004ab4f6   u16 + 4 f32
#   BezierVectorKey::Load     @ 0x004ac57d   u16 + 10 f32
#   BezierRotationKey::Load   @ 0x004ad83e   u16 + 5 f32
KEY_STRIDE: dict[str, int] = {
    "LinearFloatKey": 10,
    "LinearVectorKey": 18,
    "LinearRotationKey": 22,
    "BezierFloatKey": 18,
    "BezierVectorKey": 42,
    "BezierRotationKey": 22,
}

# Number of f32 values carried by one key *after* the time stamp.
KEY_COMPONENTS: dict[str, int] = {
    "LinearFloatKey": 1,
    "LinearVectorKey": 3,
    "LinearRotationKey": 4,
    "BezierFloatKey": 3,
    "BezierVectorKey": 9,
    "BezierRotationKey": 4,
}


class CharismaError(ParseError):
    """Raised when a Charisma stream does not match the documented grammar."""


# ---------------------------------------------------------------------------
# Stream primitives
# ---------------------------------------------------------------------------

def read_storable_name(r: Reader, expected: str | None = None) -> str:
    """Read the class-name record that introduces a polymorphic storable.

    This is ``LoadStorableObject`` @ 0x004af4ed: a ``u32 length`` + ASCII name,
    looked up in the IStorable registry.

    Args:
        r: cursor positioned on the length prefix.
        expected: if given, the name must equal this string.

    Raises:
        CharismaError: if the name is not a registered storable class.
    """
    off = r.pos
    name = r.lpstring()
    if expected is not None and name != expected:
        raise CharismaError(f"at 0x{off:x}: expected class {expected!r}, got {name!r}")
    if name not in STORABLE_CLASSES:
        raise CharismaError(f"at 0x{off:x}: {name!r} is not a registered storable class")
    return name


def read_version(r: Reader, cls: str, allowed: tuple[int, ...]) -> int:
    """Read a ``u16`` schema version and reject values the engine rejects."""
    off = r.pos
    version = r.u16()
    if version not in allowed:
        raise CharismaError(
            f"at 0x{off:x}: {cls} version {version} is not one of {allowed}")
    return version


# ---------------------------------------------------------------------------
# StdComponentDesc - the innermost base of every descriptor
# ---------------------------------------------------------------------------

@dataclass
class ComponentDesc:
    """The ``StdComponentDesc`` part of a descriptor record.

    ``StdComponentDesc::Load`` @ 0x0049a9c4 reads::

        u16      version          # rejected unless 0
        lpstring componentClass   # name in the ComponentClass registry
        lpstring instanceName     # node / track / model name
        u16      kind             # component category, see COMPONENT_KIND_NAMES
        u32      childCount
        childCount x LoadStorableObject()   # nested IComponentDesc children

    This tail is what earlier drafts of the documentation mistook for a
    separate "component record": ``componentClass`` is a *string field*, not a
    class-name record, and ``kind`` is a ``u16`` followed by a ``u32`` count,
    not a ``u32`` followed by a ``u16`` padding.

    ``childCount`` is 0 in all 482 shipped files.  The children are read one by
    one through ``LoadStorableObject`` (name first), so their type is
    self-describing; the loader then requires each to dynamic-cast to
    ``IComponentDesc`` (see :data:`COMPONENT_DESC_CLASSES`).  They are parsed
    into :attr:`children`.
    """

    version: int
    component_class: str
    instance_name: str
    kind: int
    child_count: int = 0
    children: list = field(default_factory=list)

    @property
    def kind_name(self) -> str:
        return COMPONENT_KIND_NAMES.get(self.kind, f"kind{self.kind}")

    def to_json(self) -> dict:
        return {
            "version": self.version,
            "component_class": self.component_class,
            "instance_name": self.instance_name,
            "kind": self.kind,
            "kind_name": self.kind_name,
            "child_count": self.child_count,
            "children": [c.to_json() for c in self.children],
        }


def read_component_desc(r: Reader, expected_class: str | None = None) -> ComponentDesc:
    """Parse the ``StdComponentDesc`` tail of a descriptor (0x0049a9c4)."""
    version = read_version(r, "StdComponentDesc", (0,))
    off = r.pos
    component_class = r.lpstring()
    if component_class not in COMPONENT_CLASSES:
        raise CharismaError(
            f"at 0x{off:x}: {component_class!r} is not a registered component class")
    if expected_class is not None and component_class != expected_class:
        raise CharismaError(
            f"at 0x{off:x}: expected component {expected_class!r}, got {component_class!r}")
    instance_name = r.lpstring()
    kind = r.u16()
    child_count = r.u32()
    children = []
    for _ in range(child_count):
        off = r.pos
        name = read_storable_name(r)
        if name not in COMPONENT_DESC_CLASSES:
            raise CharismaError(
                f"at 0x{off:x}: {name!r} is a storable class but does not derive from "
                "IComponentDesc, so the engine's dynamic_cast at 0x0049aabf rejects it")
        reader = DESC_READERS.get(name)
        if reader is None:
            raise CharismaError(
                f"at 0x{off:x}: no reader registered for child descriptor {name!r}; "
                "import cho_parse and cha_parse before parsing nested components")
        children.append(reader(r))
    return ComponentDesc(version, component_class, instance_name, kind,
                         child_count, children)


# ---------------------------------------------------------------------------
# SkeletonDesc / SkeletonNode
# ---------------------------------------------------------------------------

@dataclass
class SkeletonNode:
    """One bone of the bind-pose skeleton.

    ``SkeletonNode::Load`` @ 0x0048432c reads ``u16 version`` (rejected unless
    0), ``lpstring name``, ``lpstring parent`` and then 16 floats with an
    explicit ``for row in 0..3: for col in 0..3`` loop over
    ``Matrix::operator()(row, col)`` (0x00482a72, which indexes
    ``flat[row * 4 + col]``).  The storage is therefore **row-major**.

    The matrix is a **parent-relative local transform** used as ``M * v`` on
    column vectors: the point transform 0x004826d0 computes
    ``out[i] = m[4i]*x + m[4i+1]*y + m[4i+2]*z + m[4i+3]``, so the translation
    lives in ``flat[3]``, ``flat[7]``, ``flat[11]`` and the bottom row is
    ``(0, 0, 0, 1)``.
    """

    version: int
    name: str
    parent: str
    matrix: tuple[float, ...]

    @property
    def translation(self) -> tuple[float, float, float]:
        """Bone offset relative to its parent."""
        return (self.matrix[3], self.matrix[7], self.matrix[11])

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "parent": self.parent,
            "matrix": list(self.matrix),
            "translation": list(self.translation),
            "version": self.version,
        }


@dataclass
class Skeleton:
    """``SkeletonDesc`` - the bind-pose bone hierarchy."""

    version: int
    nodes: list[SkeletonNode] = field(default_factory=list)

    def node_map(self) -> dict[str, SkeletonNode]:
        return {n.name: n for n in self.nodes}

    def root(self) -> SkeletonNode | None:
        """The single node whose parent is not another node (parent 'ROOT')."""
        names = {n.name for n in self.nodes}
        for node in self.nodes:
            if node.parent not in names:
                return node
        return None

    def to_json(self) -> dict:
        return {"version": self.version, "nodes": [n.to_json() for n in self.nodes]}


def read_skeleton_node(r: Reader) -> SkeletonNode:
    """Parse one ``SkeletonNode`` body (the class name is hoisted, see below)."""
    version = read_version(r, "SkeletonNode", (0,))
    name = r.lpstring()
    parent = r.lpstring()
    matrix = tuple(r.f32() for _ in range(16))
    return SkeletonNode(version, name, parent, matrix)


def read_skeleton(r: Reader) -> Skeleton:
    """Parse a ``SkeletonDesc`` record, cursor on its class-name length.

    ``SkeletonDesc::Load`` @ 0x0048471d::

        u16 version
        version 0: u32 count ; count x LoadStorableObject()       # name per node
        version 1: u32 count ; if count: lpstring elementClass    # name hoisted
                               count x <node body>

    All 482 shipped files use version 1.  Version 0 is implemented too - it
    costs nothing and is what the engine does.
    """
    read_storable_name(r, expected="SkeletonDesc")
    version = read_version(r, "SkeletonDesc", (0, 1))
    nodes: list[SkeletonNode] = []
    if version == 0:
        count = r.u32()
        for _ in range(count):
            read_storable_name(r, expected="SkeletonNode")
            nodes.append(read_skeleton_node(r))
    else:
        count = r.u32()
        if count:
            read_storable_name(r, expected="SkeletonNode")
            for _ in range(count):
                nodes.append(read_skeleton_node(r))
    return Skeleton(version, nodes)


def read_optional_skeleton(r: Reader) -> tuple[int, Skeleton | None]:
    """Read the ``u16 hasSkeleton`` flag and, if set, the ``SkeletonDesc``.

    Both ``StdModelDesc::Load`` (0x004a021f) and ``StdAnimationDesc::Load``
    (0x0049cba6) guard the skeleton with this flag; it is 1 in all 482 files.
    """
    flag = r.u16()
    if not flag:
        return flag, None
    return flag, read_skeleton(r)


# ---------------------------------------------------------------------------
# Matrix / quaternion helpers - transcribed from the engine
# ---------------------------------------------------------------------------

Mat4 = list[float]

IDENTITY: tuple[float, ...] = (
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
)


def mat_identity() -> Mat4:
    """4x4 identity in the engine's row-major layout (0x00482784)."""
    return list(IDENTITY)


def mat_mul(a: Mat4 | tuple[float, ...], b: Mat4 | tuple[float, ...]) -> Mat4:
    """``a * b`` in the engine's row-major layout (0x00482ab3)."""
    out = [0.0] * 16
    for i in range(4):
        for j in range(4):
            out[i * 4 + j] = sum(a[i * 4 + k] * b[k * 4 + j] for k in range(4))
    return out


def mat_transform_point(m: Mat4 | tuple[float, ...],
                        v: tuple[float, float, float]) -> tuple[float, float, float]:
    """``M * v`` for a column vector with implicit w = 1 (0x004826d0)."""
    x, y, z = v
    return (
        m[0] * x + m[1] * y + m[2] * z + m[3],
        m[4] * x + m[5] * y + m[6] * z + m[7],
        m[8] * x + m[9] * y + m[10] * z + m[11],
    )


def mat_translation(m: Mat4 | tuple[float, ...]) -> tuple[float, float, float]:
    """Translation column of a row-major ``M * v`` matrix (0x004828cd)."""
    return (m[3], m[7], m[11])


def mat_with_translation(m: Mat4 | tuple[float, ...],
                         t: tuple[float, float, float]) -> Mat4:
    """Copy of *m* whose translation column is replaced by *t* (0x004828e7)."""
    out = list(m)
    out[3], out[7], out[11] = t
    return out


def quat_to_matrix(q: tuple[float, float, float, float]) -> Mat4:
    """Build a rotation matrix from a stored rotation key (0x004827b0).

    ``q`` is the four floats exactly as they appear in the file, i.e.
    ``(x, y, z, w)``.  The component order is settled by this function alone:
    the three diagonal terms are ``1 - s*(y^2+z^2)``, ``1 - s*(x^2+z^2)`` and
    ``1 - s*(x^2+y^2)``, so ``q[3]`` is the component that never appears in a
    diagonal term - the scalar ``w``.  ``(w, x, y, z)`` would put ``w`` on the
    diagonal and is impossible.

    The result is the **transpose** of the textbook ``R(q)`` under the engine's
    own row-major ``M * v`` convention - equivalently, it is ``R(q*)``.  A
    remake must use this formula and not a stock quaternion-to-matrix routine,
    or every bone will rotate the wrong way.
    """
    a, b, c, d = q
    n = a * a + b * b + c * c + d * d
    s = 0.0 if n == 0.0 else 2.0 / n
    m = mat_identity()
    m[0] = 1.0 - (s * c * c + s * b * b)
    m[1] = s * b * a + d * s * c
    m[2] = s * c * a - d * s * b
    m[4] = s * b * a - d * s * c
    m[5] = 1.0 - (s * c * c + s * a * a)
    m[6] = s * a * d + s * c * b
    m[8] = d * s * b + s * c * a
    m[9] = s * c * b - s * a * d
    m[10] = 1.0 - (s * b * b + s * a * a)
    return m


def quat_slerp(p: tuple[float, ...], q: tuple[float, ...],
               t: float) -> tuple[float, float, float, float]:
    """Spherical linear interpolation (0x004aedc7).

    This is Shoemake's ``SlerpQuat`` from Graphics Gems verbatim, including the
    ``(x, y, z, w)`` component order and the perpendicular-construction branch
    for nearly opposite quaternions.
    """
    cosom = sum(x * y for x, y in zip(p, q))
    if 1.0 + cosom <= 1e-6:
        # Nearly opposite: rotate through an arbitrary perpendicular.
        half_pi = math.pi / 2.0
        s0 = math.sin((1.0 - t) * half_pi)
        s1 = math.sin(t * half_pi)
        return (s0 * p[0] - s1 * p[1],
                s0 * p[1] + s1 * p[0],
                s0 * p[2] - s1 * p[3],
                s0 * p[3] + s1 * p[2])
    if 1.0 - cosom <= 1e-6:
        s0, s1 = 1.0 - t, t
    else:
        omega = math.acos(max(-1.0, min(1.0, cosom)))
        sinom = math.sin(omega)
        s0 = math.sin((1.0 - t) * omega) / sinom
        s1 = math.sin(t * omega) / sinom
    return (s0 * p[0] + s1 * q[0], s0 * p[1] + s1 * q[1],
            s0 * p[2] + s1 * q[2], s0 * p[3] + s1 * q[3])


# ---------------------------------------------------------------------------
# Quaternion algebra used by BezierRotationMovement (squad)
# ---------------------------------------------------------------------------
#
# Every one of the five *Movement::GetValue implementations opens with the same
# two comparisons against these two float constants, so they are properties of
# the interpolator layer and not of one channel:
#
#   0x004b38e0 = 0.25   segment length below which no interpolation happens
#   0x004b38f4 = 0.5    which end of such a held segment is returned
#
# Verified at 0x004a8bb1/0x004a8c5b (LinearVector), 0x004a9af4/0x004a9b4e
# (LinearRotation), 0x004aaa24/0x004aaadf (BezierFloat), 0x004ab95d/0x004aba93
# (BezierVector) and 0x004acad4/0x004acb48 (BezierRotation).  Both comparisons
# are inclusive on the "hold" side: `dt <= 0.25` holds, `u <= 0.5` picks key 0.

HOLD_DT = 0.25
HOLD_PICK = 0.5

# 0x004b3c58, a double: the guard below which quat_exp returns the identity
# scaling factor instead of sin(s)/s.
_QEXP_EPS = 1e-05


def quat_mul(a: tuple[float, ...],
             b: tuple[float, ...]) -> tuple[float, float, float, float]:
    """Hamilton product ``a * b`` on ``(x, y, z, w)`` quaternions (0x004aecb0)."""
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by + ay * bw + az * bx - ax * bz,
        aw * bz + az * bw + ax * by - ay * bx,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def quat_inverse(q: tuple[float, ...]) -> tuple[float, float, float, float]:
    """Multiplicative inverse ``q* / |q|^2`` (0x004aed3f).

    The engine divides by the squared norm rather than assuming unit length -
    which matters here, because 0.16 % of the shipped rotation keys are not
    unit (see the norm census in the .cha section).  A norm of exactly zero
    short-circuits to the bare conjugate to avoid the division.
    """
    x, y, z, w = q
    n = x * x + y * y + z * z + w * w
    if n == 0.0:
        return (-x, -y, -z, w)
    return (-x / n, -y / n, -z / n, w / n)


def quat_log(q: tuple[float, ...]) -> tuple[float, float, float, float]:
    """The engine's quaternion logarithm (0x004aefd1).

    **This is not the textbook logarithm.**  The disassembly contains no
    ``fsqrt``: the routine computes ``s = x^2 + y^2 + z^2`` and then scales the
    vector part by ``atan2(s, w) / s`` where the textbook form uses
    ``atan2(|v|, w) / |v|``.  For the small rotations between adjacent keys the
    two agree to first order (``atan2(s, w)/s -> 1`` and ``|v| ~ theta``), which
    is why the resulting spline still looks right, but a remake that "fixes"
    the formula will not match the engine.  Reproduced verbatim.
    """
    x, y, z, w = q
    s = x * x + y * y + z * z
    t = math.atan2(s, w)
    if s > 0.0:
        s = t / s
    return (x * s, y * s, z * s, 0.0)


def quat_exp(v: tuple[float, ...]) -> tuple[float, float, float, float]:
    """The engine's quaternion exponential (0x004af04b).

    Mirror image of :func:`quat_log`: ``s = x^2 + y^2 + z^2`` is used where the
    textbook uses ``|v|``, so the result is ``(v * sin(s)/s, cos(s))``.  No
    ``fsqrt`` appears in the disassembly.  ``s <= 1e-05`` (the double at
    0x004b3c58) takes the scale factor to be 1.
    """
    x, y, z = v[0], v[1], v[2]
    s = x * x + y * y + z * z
    k = math.sin(s) / s if s > _QEXP_EPS else 1.0
    return (x * k, y * k, z * k, math.cos(s))


def quat_spline_control(prev: tuple[float, ...], q: tuple[float, ...],
                        nxt: tuple[float, ...]) -> tuple[float, float, float, float]:
    """Shoemake's inner spline control quaternion (0x004af0d1).

    ``s = q * exp(-0.25 * (log(q^-1 * prev) + log(q^-1 * nxt)))`` - the -0.25
    is the float at 0x004b3c84.  ``quat_log``/``quat_exp`` are the engine's own
    (squared-norm) variants, so this is not identical to the textbook control
    point.
    """
    qinv = quat_inverse(q)
    l_next = quat_log(quat_mul(qinv, nxt))
    l_prev = quat_log(quat_mul(qinv, prev))
    inner = tuple(-0.25 * (l_prev[i] + l_next[i]) for i in range(4))
    return quat_mul(q, quat_exp(inner))


def bezier_rotation_controls(
        quats: list[tuple[float, ...]]) -> list[tuple[float, float, float, float]]:
    """Per-key control quaternion for a BezierRotation track (0x004ad53e).

    The loop walks the key array once, handing each key its predecessor and
    successor quaternion.  Its two boundary rules are:

    * the first key uses its successor as its predecessor;
    * the last key uses its predecessor as its successor.

    A single-key track sees ``(0, 0, 0, 0)`` on both sides (the loop's
    zero-initialised locals), which ``quat_log``/``quat_exp`` turn into the
    identity, so the control equals the key.

    ``0x004ad7ab`` writes the same value into *both* control slots of the key
    (+0x18 and +0x28), i.e. ``a[i] == b[i]``; this returns that one value per
    key.
    """
    n = len(quats)
    out: list[tuple[float, float, float, float]] = []
    prev: tuple[float, ...] = (0.0, 0.0, 0.0, 0.0)
    for i in range(n):
        if i != 0:
            prev = quats[i - 1]
        nxt = prev if i == n - 1 else quats[i + 1]
        if i == 0:
            prev = nxt
        out.append(quat_spline_control(prev, quats[i], nxt))
    return out


def quat_squad(p: tuple[float, ...], a: tuple[float, ...],
               b: tuple[float, ...], q: tuple[float, ...],
               u: float) -> tuple[float, float, float, float]:
    """Shoemake's ``squad`` (0x004aef75).

    ``slerp(slerp(p, q, u), slerp(a, b, u), 2*u*(1-u))``; the 1.0 and 2.0 are
    the floats at 0x004b3c78 and 0x004b3c80.
    """
    h = (1.0 - u) * u * 2.0
    return quat_slerp(quat_slerp(p, q, u), quat_slerp(a, b, u), h)


def bezier_scalar(v0: float, out0: float, v1: float, in1: float,
                  dt: float, u: float) -> float:
    """Cubic Bezier segment as the engine evaluates it (0x004aa9df, 0x004ab918).

    ``v0``/``v1`` are the segment end values, ``out0`` is the *out* tangent of
    the first key and ``in1`` the *in* tangent of the second, ``dt`` is
    ``time1 - time0`` and ``u`` the normalised parameter.  The control points
    are ``v0 + out0 * dt/3`` and ``v1 + in1 * dt/3``, i.e. the tangents are
    slopes in value units per time unit, not pre-scaled offsets.
    """
    third = dt / 3.0
    w = 1.0 - u
    c1 = v0 + out0 * third
    c2 = v1 + in1 * third
    return v1 * u * u * u + 3.0 * c2 * u * u * w + 3.0 * c1 * u * w * w + v0 * w * w * w


# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

def expect_eof(r: Reader, path: str) -> None:
    """Assert that the whole file was consumed - the proof of a total grammar."""
    if not r.eof():
        raise CharismaError(
            f"{path}: {r.remaining} trailing byte(s) at 0x{r.pos:x}: "
            f"{r.data[r.pos:r.pos + 32].hex(' ')}"
        )


def read_file_version(r: Reader) -> int:
    """Read the 4-byte stream header that opens every .cho and .cha file."""
    version = r.u32()
    if version != 1:
        logger.warning("unexpected stream header %d (expected 1)", version)
    return version


# --------------------------------------------------------------------------
# Corpus helpers
# --------------------------------------------------------------------------

def iter_corpus(root: str, suffix: str) -> list[str]:
    """Return every file under *root* whose name ends with *suffix* (sorted).

    The comparison is case-insensitive on both sides. Lowercasing only the
    filename meant a caller passing ``".CHO"`` silently matched nothing and the
    check then "passed" over an empty list.
    """
    import os

    suffix = suffix.lower()
    out: list[str] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.lower().endswith(suffix):
                out.append(os.path.join(dirpath, fn))
    return sorted(out)


def run_check(paths: list[str], parse: Callable[[str], object],
              inspect: Callable[[object, dict], None]) -> int:
    """Parse every file in *paths*, aggregate stats, and report failures.

    Args:
        paths: files to parse.
        parse: callable taking a path and returning the parsed document.
        inspect: callable given ``(document, stats)`` to accumulate checks.

    Returns:
        Process exit code (0 on full coverage).
    """
    if not paths:
        # A check that examined nothing is not a check that passed. A mistyped
        # root, a partial install or a glob regression used to come out green
        # here, which is the one failure mode a corpus gate must not have.
        print("no files to check -- that is a failure, not a pass")
        return 1
    stats: dict = {}
    failures: list[tuple[str, str]] = []
    for path in paths:
        try:
            doc = parse(path)
        except Exception as exc:  # noqa: BLE001 - report every failure kind
            failures.append((path, f"{type(exc).__name__}: {exc}"))
            continue
        inspect(doc, stats)
    print(f"parsed {len(paths) - len(failures)}/{len(paths)} files")
    for path, msg in failures:
        print(f"  FAIL {path}: {msg}")
    return 0 if not failures else 1


# --------------------------------------------------------------------------
# ``.cho`` -- the model record
#
# The record parsers live here rather than in the CLIs over them because
# ``inclib`` does not import upwards and the converter needs to read a body.
# ``tools/cho_parse.py`` and ``tools/cha_parse.py`` are the thin CLIs
# ``CLAUDE.md`` describes; this is the library half they were always meant to
# sit on.
# --------------------------------------------------------------------------

@dataclass
class Part:
    """One ``V100PartDesc`` record (``V100PartDesc::Load`` @ 0x004a70fd).

    Layout::

        u16      version          # rejected unless 0
        lpstring mesh             # geometry name, "" for a pure bone
        StdComponentDesc          # component class "V100Part", instance name

    ``mesh`` is the name of the geometry chunk this part draws (empty for a
    pure bone); the geometry itself lives in the Eng3d containers.  The
    component instance name is the animation binding key: it matches a
    ``SkeletonNode`` name and a movement target in the ``.cha`` files.
    """

    version: int
    mesh: str
    component: ComponentDesc

    @property
    def name(self) -> str:
        return self.component.instance_name

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "mesh": self.mesh,
            "version": self.version,
            "component": self.component.to_json(),
        }


@dataclass
class Model:
    """A parsed ``.cho`` file."""

    path: str
    stream_version: int
    desc_version: int
    base_version: int
    parts: list[Part] = field(default_factory=list)
    has_skeleton: int = 0
    skeleton: Skeleton | None = None
    component: ComponentDesc | None = None

    @property
    def name(self) -> str | None:
        return self.component.instance_name if self.component else None

    def to_json(self) -> dict:
        return {
            "path": self.path,
            "stream_version": self.stream_version,
            "desc_version": self.desc_version,
            "base_version": self.base_version,
            "name": self.name,
            "part_count": len(self.parts),
            "parts": [p.to_json() for p in self.parts],
            "has_skeleton": self.has_skeleton,
            "skeleton": self.skeleton.to_json() if self.skeleton else None,
            "component": self.component.to_json() if self.component else None,
        }


def parse_part_body(r: Reader) -> Part:
    """Parse one ``V100PartDesc`` *after* its class-name record (0x004a70fd)."""
    version = read_version(r, "V100PartDesc", (0,))
    mesh = r.lpstring()
    component = read_component_desc(r, expected_class="V100Part")
    return Part(version, mesh, component)


def parse_part(r: Reader) -> Part:
    """Parse one ``V100PartDesc`` (cursor on its class-name length)."""
    read_storable_name(r, expected="V100PartDesc")
    return parse_part_body(r)


def parse_model_body(r: Reader, path: str) -> Model:
    """Parse a ``V100ModelDesc`` *after* its class-name record (0x004a77bd)."""
    desc_version = read_version(r, "V100ModelDesc", (0,))
    base_version = read_version(r, "StdModelDesc", (0,))
    model = Model(path, 1, desc_version, base_version)
    for _ in range(r.u32()):
        model.parts.append(parse_part(r))
    model.has_skeleton, model.skeleton = read_optional_skeleton(r)
    model.component = read_component_desc(r, expected_class="V100Model")
    return model


def parse_model_file(path: str) -> Model:
    """Parse a ``.cho`` file, consuming it to the byte."""
    r = Reader(read_file(path))
    stream_version = read_file_version(r)
    read_storable_name(r, expected="V100ModelDesc")
    model = parse_model_body(r, path)
    model.stream_version = stream_version
    expect_eof(r, path)
    return model


# StdComponentDesc children are polymorphic IComponentDesc records; register
# the two this module can read (0x0049aab6, see COMPONENT_DESC_CLASSES).
register_desc_reader("V100PartDesc", parse_part_body)
register_desc_reader("V100ModelDesc", lambda r: parse_model_body(r, "<child>"))




# --------------------------------------------------------------------------
# ``.cha`` -- the animation record
# --------------------------------------------------------------------------

MOVEMENT_DESC_CLASSES = frozenset(
    f"{interp}{channel}MovementDesc"
    for interp in ("Linear", "Bezier")
    for channel in ("Vector", "Rotation", "Float")
)

# The component class each descriptor builds, and the key class it holds.
DESC_TO_COMPONENT = {c: c[: -len("Desc")] for c in MOVEMENT_DESC_CLASSES}
DESC_TO_KEY = {c: c[: -len("MovementDesc")] + "Key" for c in MOVEMENT_DESC_CLASSES}

# Channel names, from the three globals initialised at 0x004a6807's owner
# (``Position`` / ``Rotation matrix`` / ``Visibility``, DAT_005242e0..f0).
CHANNEL_NAMES = ("Position", "Rotation matrix", "Visibility")


@dataclass
class Note:
    """A timed event marker.

    Layout is bare ``f32 time`` + ``lpstring text``.  ``Note`` is not a
    storable class (it lives in a ``BBDList<Note>``), so it carries neither a
    class name nor a version - the loaders at 0x004a1dde and 0x004a26d5 read
    the two fields inline.
    """

    time: float
    text: str

    def to_json(self) -> dict:
        return {"time": self.time, "text": self.text}


@dataclass
class Key:
    """One keyframe: a time stamp plus 1..9 floats of channel data."""

    version: int
    time: float
    values: tuple[float, ...]

    def to_json(self) -> dict:
        return {"time": self.time, "values": list(self.values)}


@dataclass
class Movement:
    """One animated channel of one part.

    ``desc_version`` is the most-derived ``*MovementDesc`` version (0 or 1);
    ``base_version`` is the ``KeyFramedMovementDesc`` version (0..3) that
    decides where the key array is written and whether a per-track note list
    follows it.  ``weight``, ``target``, ``channel`` and ``attributes`` come
    from ``StdMovementDesc``; ``component`` is the ``StdComponentDesc`` tail.
    """

    desc_class: str
    desc_version: int
    base_version: int
    key_class: str
    keys: list[Key]
    track_notes: list[Note]
    weight: int
    target: str
    channel: str
    attributes: list[tuple[str, str]]
    component: ComponentDesc

    def to_json(self) -> dict:
        return {
            "desc_class": self.desc_class,
            "desc_version": self.desc_version,
            "base_version": self.base_version,
            "key_class": self.key_class,
            "key_count": len(self.keys),
            "keys": [k.to_json() for k in self.keys],
            "track_notes": [n.to_json() for n in self.track_notes],
            "weight": self.weight,
            "target": self.target,
            "channel": self.channel,
            "attributes": [list(a) for a in self.attributes],
            "component": self.component.to_json(),
        }

    @property
    def duration(self) -> float:
        return self.keys[-1].time if self.keys else 0.0


@dataclass
class Animation:
    """A parsed ``.cha`` file."""

    path: str
    stream_version: int
    desc_version: int
    base_version: int = 0
    notes: list[Note] = field(default_factory=list)
    movements: list[Movement] = field(default_factory=list)
    has_skeleton: int = 0
    skeleton: Skeleton | None = None
    component: ComponentDesc | None = None

    @property
    def name(self) -> str | None:
        return self.component.instance_name if self.component else None

    @property
    def duration(self) -> float:
        """Length of the animation in key-time units (frames; see the docs)."""
        return max((m.duration for m in self.movements), default=0.0)

    def to_json(self) -> dict:
        return {
            "path": self.path,
            "stream_version": self.stream_version,
            "desc_version": self.desc_version,
            "base_version": self.base_version,
            "name": self.name,
            "duration": self.duration,
            "notes": [n.to_json() for n in self.notes],
            "movement_count": len(self.movements),
            "movements": [m.to_json() for m in self.movements],
            "has_skeleton": self.has_skeleton,
            "skeleton": self.skeleton.to_json() if self.skeleton else None,
            "component": self.component.to_json() if self.component else None,
        }


# --------------------------------------------------------------------------
# Record readers
# --------------------------------------------------------------------------

def _read_note_list(r: Reader) -> list[Note]:
    """``u32 count`` followed by ``f32 time`` + ``lpstring text`` per note."""
    return [Note(r.f32(), r.lpstring()) for _ in range(r.u32())]


def _read_key_body(r: Reader, key_class: str) -> Key:
    """One key: ``u16 version`` (rejected unless 0) plus time and values."""
    version = read_version(r, key_class, (0,))
    time = r.f32()
    values = tuple(r.f32() for _ in range(KEY_COMPONENTS[key_class]))
    return Key(version, time, values)


def _check_key_class(name: str, off: int) -> str:
    if name not in KEY_STRIDE:
        raise CharismaError(f"at 0x{off:x}: {name!r} is not a keyframe class")
    return name


def _read_hoisted_keys(r: Reader) -> tuple[str, list[Key]]:
    """``u32 count`` + (if non-zero) one hoisted class name + count key bodies.

    This is the shape used by ``*MovementDesc::Load`` version 1 and by
    ``KeyFramedMovementDesc::Load`` versions 1 and 2: the element class name is
    written once for the whole array instead of once per element.
    """
    count = r.u32()
    if not count:
        return "", []
    off = r.pos
    key_class = _check_key_class(read_storable_name(r), off)
    return key_class, [_read_key_body(r, key_class) for _ in range(count)]


def _read_polymorphic_keys(r: Reader) -> tuple[str, list[Key]]:
    """``u32 count`` + one full ``LoadStorableObject`` per key.

    ``KeyFramedMovementDesc::Load`` version 0.  Never used by shipped data.
    """
    count = r.u32()
    keys: list[Key] = []
    key_class = ""
    for _ in range(count):
        off = r.pos
        key_class = _check_key_class(read_storable_name(r), off)
        keys.append(_read_key_body(r, key_class))
    return key_class, keys


def parse_movement(r: Reader) -> Movement:
    """Parse one ``*MovementDesc`` record (cursor on its class-name length)."""
    off = r.pos
    desc_class = read_storable_name(r)
    if desc_class not in MOVEMENT_DESC_CLASSES:
        raise CharismaError(f"at 0x{off:x}: {desc_class!r} is not a movement descriptor")
    return parse_movement_body(r, desc_class)


def parse_movement_body(r: Reader, desc_class: str) -> Movement:
    """Parse one ``*MovementDesc`` *after* its class-name record."""
    desc_version = read_version(r, desc_class, (0, 1))

    key_class = ""
    keys: list[Key] = []
    if desc_version == 1:
        # The derived class reads the array itself and insists on its own key
        # class (e.g. LinearRotationMovementDesc::Load @ 0x004aa0b7 compares
        # the name against "LinearRotationKey").
        key_class, keys = _read_hoisted_keys(r)
        if key_class and key_class != DESC_TO_KEY[desc_class]:
            raise CharismaError(
                f"{desc_class} version 1 holds {key_class!r}, "
                f"expected {DESC_TO_KEY[desc_class]!r}")

    # KeyFramedMovementDesc::Load @ 0x004a26d5.
    base_version = read_version(r, "KeyFramedMovementDesc", (0, 1, 2, 3))
    track_notes: list[Note] = []
    if base_version == 0:
        key_class, keys = _read_polymorphic_keys(r)
        track_notes = _read_note_list(r)
    elif base_version == 1:
        key_class, keys = _read_hoisted_keys(r)
        track_notes = _read_note_list(r)
    elif base_version == 2:
        key_class, keys = _read_hoisted_keys(r)
    # version 3 writes no keys at this level - the derived class already did.

    # StdMovementDesc::Load @ 0x0049b4e7.
    read_version(r, "StdMovementDesc", (0,))
    weight = r.u32()
    target = r.lpstring()
    channel = r.lpstring()
    attributes = [(r.lpstring(), r.lpstring()) for _ in range(r.u32())]

    component = read_component_desc(r, expected_class=DESC_TO_COMPONENT[desc_class])
    return Movement(desc_class, desc_version, base_version, key_class, keys,
                    track_notes, weight, target, channel, attributes, component)


def parse_animation_body(r: Reader, path: str) -> Animation:
    """Parse a ``KeyFramedAnimationDesc`` after its class-name record."""
    desc_version = read_version(r, "KeyFramedAnimationDesc", (0, 1))
    anim = Animation(path, 1, desc_version)
    if desc_version >= 1:
        # The note list only exists from descriptor version 1 onwards; the
        # three version-0 files in the corpus jump straight to the movements.
        anim.notes = _read_note_list(r)

    # StdAnimationDesc::Load @ 0x0049cba6.
    anim.base_version = read_version(r, "StdAnimationDesc", (0,))
    for _ in range(r.u32()):
        anim.movements.append(parse_movement(r))
    anim.has_skeleton, anim.skeleton = read_optional_skeleton(r)
    anim.component = read_component_desc(r)
    if anim.component.component_class not in ("KeyFramedAnimation", "StdAnimation"):
        raise CharismaError(
            f"animation builds component {anim.component.component_class!r}")
    return anim


def parse_animation_file(path: str) -> Animation:
    """Parse a ``.cha`` file, consuming it to the byte."""
    r = Reader(read_file(path))
    stream_version = read_file_version(r)
    read_storable_name(r, expected="KeyFramedAnimationDesc")
    anim = parse_animation_body(r, path)
    anim.stream_version = stream_version
    expect_eof(r, path)
    return anim


# StdComponentDesc children are polymorphic IComponentDesc records
# (0x0049aab6); register every descriptor this module can read.
register_desc_reader("KeyFramedAnimationDesc",
                     lambda r: parse_animation_body(r, "<child>"))
for _cls in MOVEMENT_DESC_CLASSES:
    register_desc_reader(_cls, (lambda c: lambda r: parse_movement_body(r, c))(_cls))


