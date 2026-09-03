#!/usr/bin/env python3
"""The engine's fixed-point geometry, as the blob arms reach it.

``docs/28`` §12 item 1 named five services an update arm calls that live
outside its 88-byte record, and said their **return data** had never been
measured.  ``tools/blob_gold.py``'s ``hooks`` phase now calls all five inside a
running ``Incubation.exe``; this module is the portable half of what that
capture found.

Three of the five are argument-pure and are reproduced here exactly:

``angle(a, b)``
    ``[0x004FA4E0]`` -- the two-argument engine helper both orientation
    routines call.  A 4096-unit circle measured from ``+b`` toward ``+a``, out
    of the shipped ``ATN.IMG``.  20/20 against the capture.

``orient(source, target)``
    ``0x00403AA0`` -- ``(pitch, yaw)``, and the routine the remake's
    ``BlobHooks.orient`` stood in for with an invented ``atan2`` over a
    0..0xFFFF turn.  The unit was wrong and so was the pitch: the real one
    yaws the delta flat with a Q14 matrix and takes a **second** angle from
    what is left, minus a quarter turn.  20/20 against the capture.

``direction(source, target, shift)``
    ``0x0046D400`` -- three doubles, and not a normalised vector: the first
    two are divided by whichever of ``|dx|`` and ``|dy|`` is larger, the third
    by the **truncated integer** 2D distance.  It divides by zero without a
    guard, so ``NaN`` and ``±inf`` are ordinary results.  40/40.

``rotate(vector, angles)``
    ``0x004039A0`` -- a vector through Eng3d's own three-angle matrix.  It was
    the one service this module recorded and did not reproduce, because no
    ordering of ``Rz Rx Ry`` built from :meth:`Tables.matrix`'s arithmetic
    matched all eight captured cases.  Three separate things were wrong, and
    all three are in the DLL rather than in the caller: the builder **negates**
    each angle before it indexes the table, its products are 64-bit and shifted
    with ``shrd`` (floor) where ``0x004039F0``'s are 32-bit and truncated
    toward zero, and the transform reads the matrix **by column**.  8/8.

The other two are lookups whose tables only exist once a mission is loaded --
``0x00405100`` (object position) and ``0x00477AE0`` (unit record) -- and their
strides and gates are pinned in ``blob_gold.py`` against the same capture.

The five runtime function pointers the two ``0x004039x0`` routines call
through are ordinals of ``Eng3d.dll``, identified by finding each captured
thunk's own bytes in the shipped DLL and matching the offset against its
export table:

===========  =========================  =======  ================================
Global       Thunk RVA                  Ordinal  Export
===========  =========================  =======  ================================
0x004FA4E4   0x20AC                     13       ``_E3D_init_matrix_RzRxRy``
0x004F84D4   0x20E4                     15       ``_E3D_c_rotate_coordinate``
0x004FA4E0   0x2208                     27       ``_E3D_calc_angle_dx_dy``
0x004F84D8   0x221C                     28       ``_E3D_fsin``
0x004FA4DC   0x222C                     29       ``_E3D_fcos``
===========  =========================  =======  ================================

Ordinal 14 is ``_E3D_init_matrix_RyRxRz`` and **nothing reaches it**, which is
the export table saying in its own words what `docs/30` §2.5 item 7 concluded
from the joint opcodes.

Static source: ``gog_incubation/Incubation.exe`` (``0x004039F0``,
``0x004039A0``, ``0x00403AA0``, ``0x0046D400``), ``gog_incubation/Eng3d.dll``
(``_E3D_init_matrix_RzRxRy`` at file offset 0x11BF6, ``_E3D_c_rotate_coordinate``
at 0x1123C) plus the shipped ``TRIG.IMG`` / ``ATN.IMG``, which
``tools/img_tables.py`` shows are one content across all 21 world sets.  The
DLL carries **space** for the sine table at ``0x0048E6C0`` and not the table:
all 5120 entries are zero in the file, so ``TRIG.IMG`` is what the running
engine indexes.
"""

from __future__ import annotations

import glob
import math
import os
import struct
from typing import Sequence

__all__ = [
    "ANGLE_UNITS", "ATAN_INPUT_SCALE", "SINE_SCALE", "Q14_SHIFT",
    "Eng3dError", "Tables", "load", "angle", "matrix", "matrix3",
    "transform", "orient", "rotate", "direction", "distance_2d",
]

#: A full turn.  `docs/70` -- binary degrees, not 65536ths.
ANGLE_UNITS = 4096
#: ``ATN.IMG`` is indexed by ``(min/max) * 1024``.
ATAN_INPUT_SCALE = 1024
#: ``TRIG.IMG``'s peak.  **16383, not 16384**, which is why the engine's
#: identity rotation returns 999 for 1000 rather than 1000.
SINE_SCALE = 16383
#: The fixed-point denominator every product is divided by.
Q14_SHIFT = 14
Q14_ONE = 1 << Q14_SHIFT

ATAN_ENTRIES = 1025
TRIG_ENTRIES = 5120
TRIG_PERIOD = 4096
COSINE_OFFSET = 1024


#: A 32-bit two's-complement mask, for the truncations below.
I32_MASK = 0xFFFFFFFF


class Eng3dError(Exception):
    """Raised instead of returning a partial or invented table."""


def ftol(value: float) -> int:
    """``_ftol`` ``0x004AE7B6`` -- MSVC's, which is ``fistp qword``.

    It stores **64 bits** and returns the pair in ``edx:eax``; every caller in
    this project keeps ``eax``, so the answer is the *low dword* of the
    truncation.  That matters for the invalid conversion: x87's 64-bit integer
    indefinite is ``0x8000000000000000``, whose low dword is **zero**, so a
    NaN converts to nothing at all rather than to ``INT_MIN``.

    Measured, not reasoned: the poked kind-27 record of ``docs/97`` §20 sits
    exactly on its target's column, the direction service answers
    ``NaN, NaN, inf`` (the `hooks` phase has those three deltas), and the
    engine's record comes back damped by a sixth with **no** steering term.

    It lives here rather than in a caller because both callers need it --
    :mod:`tools.blob_runtime`'s update arms and
    :mod:`inclib.blob_creators`'s creator programs -- and because
    ``godot/game/fx/eng3d_geometry.gd`` is already this module's twin.
    """
    if math.isnan(value) or math.isinf(value) or not -2**63 <= value < 2**63:
        return 0
    value = int(value) & I32_MASK
    return value - 0x100000000 if value >= 0x80000000 else value


def _trunc_shift(value: int) -> int:
    """``cdq / and edx, 0x3FFF / add / sar 14`` -- divide, toward zero.

    The idiom the **matrix builder** uses on every entry.  It is not the same
    rounding the transform uses, and the difference is visible: with a plain
    shift, ``0x00403AA0`` answers 512 for a delta of ``(-1, -1, -1)`` and with
    this one it answers 0.  Both appear in the same call.
    """
    return -((-value) >> Q14_SHIFT) if value < 0 else value >> Q14_SHIFT


def _floor_shift(value: int) -> int:
    """``sar 14`` -- divide, toward negative infinity.

    What Eng3d's vector transform does, measured: a product of ``-16383`` and
    a coordinate of 1 comes back as ``-1`` where truncation would give 0.
    """
    return value >> Q14_SHIFT


class Tables:
    """``TRIG.IMG`` and ``ATN.IMG``, the shipped ones.

    They are **not** regenerated from the formula.  `docs/70`'s open question 1
    is that the exact generation rounding is unknown, and `img_tables.py` can
    only show the formula agrees to within one unit -- so a regenerated table
    would differ from the engine's in individual entries and the angles built
    on it would differ by one.  These come out of the corpus.
    """

    __slots__ = ("trig", "atn")

    def __init__(self, trig: Sequence[int], atn: Sequence[int]) -> None:
        if len(trig) != TRIG_ENTRIES:
            raise Eng3dError(f"TRIG.IMG: {len(trig)} entries, want {TRIG_ENTRIES}")
        if len(atn) != ATAN_ENTRIES:
            raise Eng3dError(f"ATN.IMG: {len(atn)} entries, want {ATAN_ENTRIES}")
        self.trig = list(trig)
        self.atn = list(atn)

    # -- the two table reads the engine does --------------------------------

    def sin(self, turn: int) -> int:
        return self.trig[turn & (TRIG_PERIOD - 1)]

    def cos(self, turn: int) -> int:
        return self.trig[(turn & (TRIG_PERIOD - 1)) + COSINE_OFFSET]

    # -- `[0x004FA4E0]` -----------------------------------------------------

    def angle(self, a: int, b: int) -> int:
        """The 4096-unit angle of ``(a, b)``, measured from ``+b`` toward ``+a``.

        So ``angle(dx, dy)`` is 0 along ``+y``, 1024 along ``+x``, 2048 along
        ``-y``.  ``angle(0, 0)`` is 0 and ``angle(a, 0)`` for ``a != 0`` is
        1024 -- both are captured cases, not conventions chosen here.
        """
        quadrant = self._first_quadrant(abs(a), abs(b))
        if a >= 0:
            return quadrant if b >= 0 else ANGLE_UNITS // 2 - quadrant
        return (ANGLE_UNITS // 2 + quadrant if b < 0
                else ANGLE_UNITS - quadrant)

    def _first_quadrant(self, a: int, b: int) -> int:
        if b == 0:
            return ANGLE_UNITS // 4 if a else 0
        if a <= b:
            return self.atn[(a * ATAN_INPUT_SCALE) // b]
        return ANGLE_UNITS // 4 - self.atn[(b * ATAN_INPUT_SCALE) // a]

    # -- `0x004039F0` -------------------------------------------------------

    def matrix(self, a: int, b: int) -> list[int]:
        """The two-angle Q14 rotation matrix, row major.

        ``a`` turns about the first axis and ``b`` about the third; every
        entry is a product of two table reads divided by 16384 **toward
        zero**.  With both angles zero the diagonal is 16383, 16382, 16383 --
        the engine's identity is not one, and that is where ``1000`` becomes
        ``999``.
        """
        sa, ca, sb, cb = self.sin(a), self.cos(a), self.sin(b), self.cos(b)
        return [cb, -_trunc_shift(sb * ca), _trunc_shift(sb * sa),
                sb, _trunc_shift(cb * ca), -_trunc_shift(cb * sa),
                0, sa, ca]

    # -- `_E3D_init_matrix_RzRxRy`, `[0x004FA4E4]` --------------------------

    def matrix3(self, a: int, b: int, c: int) -> list[int]:
        """Eng3d's three-angle Q14 matrix, row major, in memory order.

        Three things separate it from :meth:`matrix`, and all three had to be
        right before a single one of the eight captured cases matched:

        * every angle is **negated** before it indexes the table -- the DLL
          opens ``neg ebx / neg ecx / neg edx`` and only then masks to 0xFFF,
          so this builds ``Rz Rx Ry`` of the *opposite* turns;
        * every product is a full 64-bit ``imul`` shifted with
          ``shrd eax, edx, 14``, which floors.  ``0x004039F0`` next door uses a
          32-bit ``imul`` and the ``cdq / and edx, 0x3FFF`` idiom, which
          truncates toward zero.  Two roundings, two builders, one engine;
        * the chained triple products shift **at each step**, not once at the
          end, so ``sh(sh(s*s)*s)`` is not ``sh(s*s*s)``.
        """
        sa, ca = self.sin(-a), self.cos(-a)
        sb, cb = self.sin(-b), self.cos(-b)
        sc, cc = self.sin(-c), self.cos(-c)
        sh = _floor_shift
        return [
            sh(cb * cc) - sh(sh(sa * sb) * sc),
            sh(ca * sc),
            sh(sb * cc) + sh(sh(sa * cb) * sc),
            -(sh(cb * sc) + sh(sh(sa * sb) * cc)),
            sh(ca * cc),
            sh(sh(sa * cb) * cc) - sh(sb * sc),
            -sh(ca * sb),
            -sa,
            sh(ca * cb),
        ]

    # -- `_E3D_c_rotate_coordinate`, `[0x004F84D4]` -------------------------

    @staticmethod
    def transform(m: Sequence[int], v: Sequence[int]) -> list[int]:
        """``v`` through ``m`` in Q14, read the way the engine reads it.

        The multiply is ``v0*m[i] + v1*m[i+3] + v2*m[i+6]``: the three entries
        one output component needs are **three apart** in memory, not
        adjacent.  Getting this backwards is survivable in isolation -- a
        transposed read paired with a transposed build cancels, which is how
        ``orient`` passed twenty cases while both halves were wrong -- and it
        is not survivable the moment a second builder is added.

        The three products accumulate at full 64-bit width and the sum is
        shifted **once**, so this floors rather than truncating.
        """
        return [_floor_shift(m[row] * v[0] + m[row + 3] * v[1]
                             + m[row + 6] * v[2]) for row in range(3)]

    def rotate(self, vector: Sequence[int],
               angles: Sequence[int]) -> list[int]:
        """`0x004039A0` -- *vector* through :meth:`matrix3` of *angles*.

        The wrapper in ``Incubation.exe`` reads the three angles as **signed
        words** out of the caller's structure and does nothing else, so this
        is the whole service.  8/8 against the capture.
        """
        return self.transform(self.matrix3(*angles), vector)

    # -- `0x00403AA0` -------------------------------------------------------

    def orient(self, source: Sequence[int],
               target: Sequence[int]) -> tuple[int, int]:
        """``(pitch, yaw)`` in 4096ths, exactly as the arms receive them.

        The routine takes the yaw straight from the horizontal delta, rotates
        the whole delta by **minus** that yaw -- the ``neg eax`` at
        ``0x00403ACF``, and the reason a transposed read of the matrix looked
        right for twenty cases -- so it lies flat, and takes the pitch from
        the two components that survive -- **minus a quarter turn**, which is
        the ``sub eax, 0x400`` at ``0x00403B21`` and is why level is 0 and
        straight up is -1024.

        ``pitch`` is returned signed and ``yaw`` unsigned, because that is what
        the caller stores: the pitch goes into a word that the arms read back
        as a turn, and every captured value is in ``-1024 .. 1024``.
        """
        delta = [target[0] - source[0], target[1] - source[1],
                 target[2] - source[2]]
        yaw = self.angle(delta[0], delta[1])
        flat = self.transform(self.matrix(0, -yaw), delta)
        return self.angle(flat[1], flat[2]) - ANGLE_UNITS // 4, yaw

    # -- `0x0046D400` -------------------------------------------------------

    def direction(self, source: Sequence[int], target: Sequence[int],
                  shift: int = 0) -> tuple[float, float, float]:
        """The three doubles ``0x0046D400`` writes, ``NaN`` and ``inf`` included.

        Two things about it are easy to get wrong and are captured facts:

        * the **shift flag does not reach the first two components**.  It is
          applied inside the branch that computes the vertical, so a caller
          that passes 1 still gets the unshifted horizontal ratio.
        * a delta with ``z1 == z0`` takes an early exit that stores a hard
          **0.0** rather than dividing, so the only ``NaN`` in the third
          component comes from a non-zero height over a zero distance.

        It needs no table at all -- it is ratios and an integer square root --
        so :func:`direction_vector` carries the arithmetic and callers with no
        :class:`Tables` in hand (``tools/blob_runtime.py``'s seeker arms) can
        reach the same answers.
        """
        return direction_vector(source, target, shift)


def direction_vector(source: Sequence[int], target: Sequence[int],
                     shift: int = 0) -> tuple[float, float, float]:
    """``0x0046D400``'s three doubles, without a :class:`Tables` to hold.

    Split out of :meth:`Tables.direction` because the routine reads neither
    ``TRIG.IMG`` nor ``ATN.IMG``: the three seeker arms of `docs/28` §7.7.1
    steer on it, and their model has no reason to demand a game root for a
    division.
    """
    dx = target[0] - source[0]
    dy = target[1] - source[1]
    wide = max(abs(dx), abs(dy))
    if wide:
        first, second = dx / wide, dy / wide
    else:
        first = second = math.nan
    if target[2] == source[2]:
        return first, second, 0.0
    if shift:
        lo = [v >> 3 for v in source]
        hi = [v >> 3 for v in target]
    else:
        lo, hi = list(source), list(target)
    height = hi[2] - lo[2]
    span = distance_2d(hi[0] - lo[0], hi[1] - lo[1])
    if span == 0:
        return first, second, (math.nan if height == 0
                               else math.copysign(math.inf, height))
    return first, second, height / span


def distance_2d(dx: int, dy: int) -> int:
    """``0x0044AE10`` -- the 2D distance, **truncated** to an integer.

    Measured, not assumed: a delta of ``(5, 3)`` comes back 5 where rounding
    would give 6, and the third component of :meth:`Tables.direction` divides
    by this number rather than by the exact length.
    """
    return math.isqrt(dx * dx + dy * dy)


def _read_table(path: str, entries: int, signed: bool) -> list[int]:
    with open(path, "rb") as handle:
        raw = handle.read()
    if len(raw) != entries * 2:
        raise Eng3dError(f"{path}: {len(raw)} bytes, want {entries * 2}")
    return list(struct.unpack(f"<{entries}{'h' if signed else 'H'}", raw))


def load(root: str) -> Tables:
    """The tables out of a game root, with a hard failure if they are missing.

    Any world set will do -- all 21 ship the same two files byte for byte, and
    ``img_tables.py`` is the check on that -- so the first match wins and a
    root with none raises rather than falling back to the formula.
    """
    trig = sorted(glob.glob(os.path.join(root, "**", "TRIG.IMG"),
                            recursive=True))
    atn = sorted(glob.glob(os.path.join(root, "**", "ATN.IMG"), recursive=True))
    if not trig or not atn:
        raise Eng3dError(f"{root}: no TRIG.IMG/ATN.IMG -- is this the game root?")
    return Tables(_read_table(trig[0], TRIG_ENTRIES, True),
                  _read_table(atn[0], ATAN_ENTRIES, False))


def angle(tables: Tables, a: int, b: int) -> int:
    return tables.angle(a, b)


def matrix(tables: Tables, a: int, b: int) -> list[int]:
    return tables.matrix(a, b)


def matrix3(tables: Tables, a: int, b: int, c: int) -> list[int]:
    return tables.matrix3(a, b, c)


def transform(m: Sequence[int], v: Sequence[int]) -> list[int]:
    return Tables.transform(m, v)


def rotate(tables: Tables, vector: Sequence[int],
           angles: Sequence[int]) -> list[int]:
    return tables.rotate(vector, angles)


def orient(tables: Tables, source: Sequence[int],
           target: Sequence[int]) -> tuple[int, int]:
    return tables.orient(source, target)


def direction(tables: Tables, source: Sequence[int], target: Sequence[int],
              shift: int = 0) -> tuple[float, float, float]:
    return tables.direction(source, target, shift)
