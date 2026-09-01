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

The other two are lookups whose tables only exist once a mission is loaded --
``0x00405100`` (object position) and ``0x00477AE0`` (unit record) -- and their
strides and gates are pinned in ``blob_gold.py`` against the same capture.

The one service that is **measured but not reproduced** is Eng3d's own
three-angle matrix builder behind ``0x004039A0``.  Its two-angle sibling
``0x004039F0`` *is* here, because ``orient`` is built on it; the three-angle
one composes differently and no ordering of ``Rz Rx Ry`` with either rounding
reproduces all eight captured cases.  The capture holds them; the arithmetic
does not, and saying so is the point.

Static source: ``gog_incubation/Incubation.exe`` (``0x004039F0``,
``0x00403AA0``, ``0x0046D400``) plus the shipped ``TRIG.IMG`` / ``ATN.IMG``,
which ``tools/img_tables.py`` shows are one content across all 21 world sets.
"""

from __future__ import annotations

import glob
import math
import os
import struct
from typing import Sequence

__all__ = [
    "ANGLE_UNITS", "ATAN_INPUT_SCALE", "SINE_SCALE", "Q14_SHIFT",
    "Eng3dError", "Tables", "load", "angle", "matrix", "transform",
    "orient", "direction", "distance_2d",
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


class Eng3dError(Exception):
    """Raised instead of returning a partial or invented table."""


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

    # -- Eng3d's `[0x004F84D4]` --------------------------------------------

    @staticmethod
    def transform(m: Sequence[int], v: Sequence[int]) -> list[int]:
        """``m * v`` in Q14, rounded the way the engine's transform rounds."""
        return [_floor_shift(m[3 * row] * v[0] + m[3 * row + 1] * v[1]
                             + m[3 * row + 2] * v[2]) for row in range(3)]

    # -- `0x00403AA0` -------------------------------------------------------

    def orient(self, source: Sequence[int],
               target: Sequence[int]) -> tuple[int, int]:
        """``(pitch, yaw)`` in 4096ths, exactly as the arms receive them.

        The routine takes the yaw straight from the horizontal delta, rotates
        the whole delta by that yaw so it lies flat, and takes the pitch from
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
        flat = self.transform(self.matrix(0, yaw), delta)
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


def transform(m: Sequence[int], v: Sequence[int]) -> list[int]:
    return Tables.transform(m, v)


def orient(tables: Tables, source: Sequence[int],
           target: Sequence[int]) -> tuple[int, int]:
    return tables.orient(source, target)


def direction(tables: Tables, source: Sequence[int], target: Sequence[int],
              shift: int = 0) -> tuple[float, float, float]:
    return tables.direction(source, target, shift)
