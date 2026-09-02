#!/usr/bin/env python3
"""Reference per-tick runtime for the 78 Incubation blob kinds.

This module is deliberately independent from Godot.  It is the executable
counterpart of the ``aBlob_Update`` reconstruction in ``docs/28``: the common
delay/life/dispatch wrapper and every jump-table arm are implemented here.

The original routine calls a few services that are not part of a blob record
(the unit map, model lookup, orientation helpers and several constructors).
Those services are expressed as :class:`BlobHooks`.  The default hooks are
deterministic and record calls, which makes this file useful as a headless
reference and as a trace oracle for a future ``core`` implementation.

The implementation uses the original field widths: coordinates and velocity
words are signed 32-bit values; rotations, atlas columns and joint angles are
unsigned 16-bit values; kind, life, delay and class are bytes.  Arithmetic is
wrapped at the same boundary as the x86 stores instead of relying on Python's
unbounded integers.

Static source: ``gog_incubation/Incubation.exe`` (SHA-256
``b07aa2478fbfaf252a585cff180d03b468d5141e0fdb5606bd09f0891024fcc9``).
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field, fields
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib.eng3d import direction_vector  # noqa: E402
from inclib.rng import ARandom  # noqa: E402


I32_MASK = 0xFFFFFFFF
U16_MASK = 0xFFFF
U8_MASK = 0xFF


def i32(value: int) -> int:
    """Return *value* as a signed x86 32-bit integer."""

    value &= I32_MASK
    return value - (1 << 32) if value & 0x80000000 else value


def u16(value: int) -> int:
    return value & U16_MASK


def u8(value: int) -> int:
    return value & U8_MASK


def trunc_div(value: int, divisor: int) -> int:
    """C/x86 signed integer division (truncate toward zero)."""

    if divisor == 0:
        raise ZeroDivisionError("blob integer division by zero")
    sign = -1 if (value < 0) ^ (divisor < 0) else 1
    return sign * (abs(value) // abs(divisor))


def add_word(value: int, delta: int) -> int:
    return u16(value + delta)


def set_aux(blob: "Blob", value: int) -> None:
    blob.aux = u8(value)


def add_aux(blob: "Blob", delta: int) -> None:
    set_aux(blob, blob.aux + delta)


@dataclass
class Blob:
    """The update-visible part of the 88-byte original blob record.

    ``rot_y`` is also the atlas column for the model-less class-2/3 blobs;
    ``aux`` is +0x54 and is a size, target id or constructor-specific value.
    ``slot_tag`` is the low byte of the record pointer used by kinds 25 and 56
    to choose a mirrored animation branch.
    """

    in_use: bool = True
    x: int = 0
    y: int = 0
    z: int = 0
    rot_x: int = 0
    rot_y: int = 0
    rot_z: int = 0
    angle0: int = 0
    angle1: int = 0
    angle2: int = 0
    angle3: int = 0
    angle4: int = 0
    angle5: int = 0
    vx: int = 0
    vy: int = 0
    vz: int = 0
    aux: int = 0
    kind: int = 0
    life: int = 0
    delay: int = 0
    class_id: int = 0
    model: int = -1
    slot_tag: int = 0
    alive: bool = True

    def __post_init__(self) -> None:
        self.x, self.y, self.z = (i32(v) for v in (self.x, self.y, self.z))
        self.vx, self.vy, self.vz = (i32(v) for v in (self.vx, self.vy, self.vz))
        self.rot_x = u16(self.rot_x)
        self.rot_y = u16(self.rot_y)
        self.rot_z = u16(self.rot_z)
        for name in ("angle0", "angle1", "angle2", "angle3", "angle4", "angle5"):
            setattr(self, name, u16(getattr(self, name)))
        # +0x54 is a byte even when an arm treats it as a counter/target id.
        self.aux = u8(self.aux)
        self.kind = u8(self.kind)
        self.life = u8(self.life)
        self.delay = u8(self.delay)
        self.class_id = u8(self.class_id)
        self.slot_tag = u8(self.slot_tag)


@dataclass
class SpawnEvent:
    creator: int
    args: Tuple[Any, ...]
    source_kind: int
    succeeded: bool


@dataclass
class TickResult:
    """Observable result of one call to :func:`tick_blob`."""

    ran: bool = False
    delayed: bool = False
    dispatched: bool = False
    deleted: bool = False
    delete_requested: bool = False
    global_signal: bool = False
    target_missing: bool = False
    model_missing: bool = False
    events: List[Tuple[str, Any]] = field(default_factory=list)
    spawns: List[SpawnEvent] = field(default_factory=list)

    def event(self, name: str, *values: Any) -> None:
        self.events.append((name, *values))


class BlobHooks:
    """Services called by update arms.

    Subclass the hooks in a game/runtime adapter.  Returning ``False`` from
    :meth:`spawn` reproduces a failed constructor; returning ``None`` from
    :meth:`target_position` makes a seeker retain its current velocity and
    records a missing-target event.
    """

    def __init__(self, seed: float = 0.0, tables: Any = None) -> None:
        #: The engine's own geometry, when a game root has been read.
        #:
        #: ``docs/28`` §12 item 1's orientation helper is **measured** now
        #: (``tools/blob_gold.py``'s ``hooks`` phase, ``inclib.eng3d``), and
        #: with these tables in hand :meth:`orient` is the retail routine
        #: rather than a stand-in for it.  Without them it falls back to the
        #: documented substitute and the emitted fixture says which, so a
        #: root-free run still produces a usable oracle instead of a wrong one.
        self.tables = tables
        self.rng = ARandom(seed)
        self.spawn_calls: List[SpawnEvent] = []
        self.model_calls: List[str] = []
        self.target_calls: List[int] = []

    def random(self, base: int, span: int) -> int:
        return self.rng(base, span)

    def random_float(self, base: int, span: int) -> float:
        return self.rng.raw(base, span)

    def spawn(self, creator: int, args: Sequence[Any], source: Blob) -> bool:
        """Create a child effect; the default adapter only records it."""

        event = SpawnEvent(creator, tuple(args), source.kind, True)
        self.spawn_calls.append(event)
        return True

    def lookup_model(self, name: str) -> int:
        self.model_calls.append(name)
        return -1

    def target_position(self, blob: Blob) -> Optional[Tuple[int, int, int]]:
        self.target_calls.append(blob.aux)
        return None

    def direction(self, blob: Blob,
                  target: Sequence[int]) -> Tuple[float, float, float]:
        """`0x0046D400` -- the service the three seekers steer on.

        Unlike :meth:`orient` this one needs **no table**: it is two ratios
        over ``max(|dx|, |dy|)`` and a height over the truncated 2D distance,
        so every adapter can answer it exactly and the seekers are not gated
        on a game root.  The ``1`` the arms pass reaches only the vertical
        (`docs/28` §7.4.2), and it is instruction evidence -- a `push 1` at
        `0x0041F9A8`, `0x0041FC03` and `0x00420383` -- rather than something
        the capture could separate, because `_ftol` collapses the difference
        on every recorded step.
        """

        return direction_vector((blob.x, blob.y, blob.z), target, 1)

    def rotate(self, vector: Sequence[int],
               angles: Sequence[int]) -> Tuple[int, int, int]:
        """`0x004039A0` -- a vector through Eng3d's three-angle matrix.

        Two arms reach it (kinds 14 and 37, `docs/97` §20.2) and both spin a
        horizontal delta about the vertical.  With :attr:`tables` this is the
        measured routine, `_E3D_init_matrix_RzRxRy` and its column-read
        transform; without them it is a float stand-in, and the emitted
        fixture's ``"orient": "substitute"`` covers this service too, since
        both need the same tables.
        """

        if self.tables is not None:
            x, y, z = self.tables.rotate(tuple(vector), tuple(angles))
            return i32(x), i32(y), i32(z)
        a, b, c = (math.radians(v * 360.0 / 4096.0) for v in angles)
        sa, ca = math.sin(-a), math.cos(-a)
        sb, cb = math.sin(-b), math.cos(-b)
        sc, cc = math.sin(-c), math.cos(-c)
        m = (cb * cc - sa * sb * sc, ca * sc, sb * cc + sa * cb * sc,
             -(cb * sc + sa * sb * cc), ca * cc, sa * cb * cc - sb * sc,
             -ca * sb, -sa, ca * cb)
        return tuple(  # type: ignore[return-value]
            i32(int(math.floor(m[row] * vector[0] + m[row + 3] * vector[1]
                               + m[row + 6] * vector[2])))
            for row in range(3))

    def orient(self, source: Sequence[int],
               target: Tuple[int, int, int]) -> Tuple[int, int, int]:
        """``0x00403AA0``'s ``(pitch, 0, yaw)``, measured where possible.

        With :attr:`tables` this is the retail routine: the yaw straight out
        of the horizontal delta in ``docs/70``'s **4096-unit circle**, the
        delta turned flat by a Q14 matrix, and the pitch from what survives
        minus a quarter turn.  Twenty of twenty captured pairs.

        Without them it is the older substitute -- an ``atan2`` over a
        0..0xFFFF turn -- which is wrong in the unit and in the pitch and is
        kept only so a run with no game root still has *something* both twins
        can implement identically.
        """

        if self.tables is not None:
            pitch, yaw = self.tables.orient(tuple(source), target)
            return u16(pitch), 0, u16(yaw)
        dx = target[0] - source[0]
        dy = target[1] - source[1]
        dz = target[2] - source[2]
        horizontal = math.hypot(dx, dy)
        yaw = int(round(math.atan2(dy, dx) * (65536.0 / (2.0 * math.pi)))) & U16_MASK
        pitch = int(round(math.atan2(dz, horizontal) * (65536.0 / (2.0 * math.pi)))) & U16_MASK
        # The retail helper stores the horizontal heading in the third word
        # (+0x28) and leaves the middle word untouched on these arms.
        return pitch, 0, yaw


def _move(blob: Blob, *, z: bool = True) -> None:
    blob.x = i32(blob.x + blob.vx)
    blob.y = i32(blob.y + blob.vy)
    if z:
        blob.z = i32(blob.z + blob.vz)


def _move_quarter(blob: Blob, *, z: bool = True) -> None:
    blob.x = i32(blob.x + trunc_div(blob.vx, 4))
    blob.y = i32(blob.y + trunc_div(blob.vy, 4))
    if z:
        blob.z = i32(blob.z + trunc_div(blob.vz, 4))


def _random(hooks: BlobHooks, base: int, span: int) -> int:
    return i32(hooks.random(base, span))


def _request_delete(blob: Blob, result: TickResult) -> None:
    # 0x4fe63c is the arm's delete/signal flag.  The caller owns removal.
    result.global_signal = True
    result.delete_requested = True
    result.event("delete_signal", blob.kind)


def _explicit_delete(blob: Blob, result: TickResult) -> None:
    """Call the retail pool-deletion routine -- the **wrapper's**, only.

    No jump-table arm reaches `0x0041E320`; every one of them returns and the
    wrapper removes the record on the next tick that finds `life == 0`. This
    helper had a second caller until a kind-11 record was stepped inside the
    engine and kept moving (`docs/28` §7.7).
    """

    blob.in_use = False
    blob.alive = False
    result.deleted = True
    result.delete_requested = True
    result.event("delete", blob.kind)


def _mark_free(blob: Blob, result: TickResult) -> None:
    """Reproduce kind 14's direct ``mov dword [blob+0], 0`` store."""

    blob.in_use = False
    blob.alive = False
    result.deleted = True
    result.delete_requested = True
    result.event("mark_free", blob.kind)


def _spawn(blob: Blob, hooks: BlobHooks, result: TickResult, creator: int,
           *args: Any) -> bool:
    ok = bool(hooks.spawn(creator, args, blob))
    event = SpawnEvent(creator, tuple(args), blob.kind, ok)
    result.spawns.append(event)
    result.event("spawn", creator, tuple(args), ok)
    if not ok:
        result.event("spawn_failed", creator)
    return ok


def _set_model(blob: Blob, hooks: BlobHooks, result: TickResult, name: str) -> None:
    model = hooks.lookup_model(name)
    if model < 0:
        result.model_missing = True
        result.event("model_missing", name)
        return
    blob.model = model
    result.event("model", name, model)


def _orient(blob: Blob, hooks: BlobHooks, result: TickResult,
            target: Tuple[int, int, int], *, write_y: bool = True,
            zero_y: bool = False) -> None:
    pitch, yaw, roll = (u16(v) for v in
                        hooks.orient((blob.x, blob.y, blob.z), target))
    blob.rot_x = pitch
    if write_y:
        blob.rot_y = yaw
    if zero_y:
        blob.rot_y = 0
    blob.rot_z = roll
    result.event("orient", target)


#: `[0x004B1238]`, the double every seeker multiplies the direction service's
#: answer by.  It is **negative**, and the arm subtracts the product, so the
#: two signs cancel and a seeker accelerates *toward* its target.
SEEK_PULL = -240.0
#: The half-width of the box that counts as a hit, on each axis separately.
SEEK_HIT = 0x640


def _ftol(value: float) -> int:
    """`0x004AE7B6` -- MSVC's `_ftol`, which is `fistp qword` and truncates.

    It stores **64 bits** and returns the pair in `edx:eax`; every caller here
    keeps `eax`, so the answer is the *low dword* of the truncation.  That
    matters for the invalid conversion: x87's 64-bit integer indefinite is
    `0x8000000000000000`, whose low dword is **zero**, so a NaN steers a
    seeker by nothing at all rather than by `INT_MIN`.

    Measured, not reasoned: the poked kind-27 record of `docs/97` §20 sits
    exactly on its target's column, the direction service answers `NaN, NaN,
    inf` (the `hooks` phase has those three deltas), and the engine's record
    comes back damped by a sixth with **no** steering term.
    """

    if math.isnan(value) or math.isinf(value) or not -2**63 <= value < 2**63:
        return 0
    return i32(int(value) & I32_MASK)


def _seek(blob: Blob, hooks: BlobHooks, result: TickResult,
          *, z_offset: int = 0) -> Optional[bool]:
    """Kinds 26, 27 and 61 -- `docs/28` §7.7.1.  ``None`` when there is no target.

    The arm asks the unit map for the record of the unit its own ``+0x54``
    names, takes that unit's *object* id from ``+0x4B``, asks
    `aGetStdObjectPosition` where that object is, and steers with
    `0x0046D400` -- the **direction service**, whose first two components are
    divided by whichever of ``|dx|`` and ``|dy|`` is larger and whose third is
    divided by the truncated 2D distance.  It is *not* a normalised vector,
    and the older model here divided by the true distance instead: a shape
    that looks right and is wrong, which is why the two seekers were the only
    stepped arms that disagreed with the engine.

    Two more corrections came out of the same reading.  The orientation call
    takes the **step** -- the position the record is about to have -- not the
    target, so a seeker points where it is going rather than where it is
    aiming; and the hit sets ``life`` to zero and nothing else, the global
    signal belonging to each arm's own ``life == 0`` branch.
    """

    target = hooks.target_position(blob)
    if target is None:
        result.target_missing = True
        result.event("target_missing", blob.aux)
        return None
    target = (i32(target[0]), i32(target[1]), i32(target[2] + z_offset))
    steer = hooks.direction(blob, target)
    blob.vx = i32(blob.vx - trunc_div(blob.vx, 6) - _ftol(steer[0] * SEEK_PULL))
    blob.vy = i32(blob.vy - trunc_div(blob.vy, 6) - _ftol(steer[1] * SEEK_PULL))
    blob.vz = i32(blob.vz - trunc_div(blob.vz, 6) - _ftol(steer[2] * SEEK_PULL))
    step = (i32(blob.x + blob.vx), i32(blob.y + blob.vy), i32(blob.z + blob.vz))
    _orient(blob, hooks, result, step, write_y=False, zero_y=True)
    _move(blob)
    if all(abs(a - b) < SEEK_HIT for a, b in zip(step, target)):
        blob.life = 0
        result.event("seek_hit", blob.aux)
        return True
    return False


# Constructor entry points recovered from the jump arms.  Keeping addresses
# in the trace makes it possible to compare a remake run with a static trace.
CREATE_ZOOM_BOB = 0x423720
CREATE_PARA_BOMB = 0x42B150
CREATE_BARREL_DEBRIS = 0x42B300
CREATE_HITTING_BLOBS = 0x42A410
CREATE_HITTING_BLOBS_2 = 0x42A480
CREATE_HITTING_BLOBS_3 = 0x42A7A0
CREATE_SPORE_SPARKS = 0x428E30
CREATE_PLASMA_SPARKS = 0x428ED0
CREATE_PLASMA_SPARKS_2 = 0x428F70
CREATE_STING_SPARKS = 0x429430
CREATE_SPORES = 0x429390
CREATE_LASER_HIT = 0x42A9D0
CREATE_EMITTER = 0x420950
BLOB_NAME_SCRATCH = 0x4FA524


def _kind_0(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    # **0x1000 here, and 0xFFF only in kind 8's arm.**  The three arms below
    # push `0x1000`; `0x004204F4`'s push `0xFFF`.  A pass that had stepped
    # kind 8 and not these copied the literal across all four, which stepping
    # *these* -- with a donor record's kind byte rewritten, since no creator
    # fills them -- caught (`docs/97` §20).
    blob.rot_x = u16(_random(hooks, 0, 0x1000))
    blob.rot_y = u16(_random(hooks, 0, 0x1000))
    blob.rot_z = u16(_random(hooks, 0, 0x1000))
    _move(blob)
    blob.vz = i32(blob.vz - 0x64)


def _kind_1(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    if blob.life == 0:
        _request_delete(blob, result)
    _move(blob)


def _kind_2(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    # **0x1000 here, and 0xFFF only in kind 8's arm.**  The three arms below
    # push `0x1000`; `0x004204F4`'s push `0xFFF`.  A pass that had stepped
    # kind 8 and not these copied the literal across all four, which stepping
    # *these* -- with a donor record's kind byte rewritten, since no creator
    # fills them -- caught (`docs/97` §20).
    blob.rot_x = u16(_random(hooks, 0, 0x1000))
    blob.rot_y = u16(_random(hooks, 0, 0x1000))
    blob.rot_z = u16(_random(hooks, 0, 0x1000))
    # The dead arm falls through the same tail as kind 49 when its decremented
    # life reaches zero; keep it executable even though no shipped creator
    # can select kind 2.
    if blob.life == 0:
        _request_delete(blob, result)
        blob.vx = _random(hooks, 0, 0x190)
        blob.vy = _random(hooks, 0, 0x190)
        blob.vz = _random(hooks, 0xC8, 0x190)
        blob.life = 6
        blob.kind = 7
        result.event("morph", 7)


def _kind_3(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_z = add_word(blob.rot_z, 0x12C)
    blob.rot_x = add_word(blob.rot_x, 0x32)
    blob.rot_y = add_word(blob.rot_y, 0x32)
    _move(blob)
    blob.vz = i32(blob.vz - 0x50)
    if blob.life == 1:
        _spawn(blob, hooks, result, CREATE_BARREL_DEBRIS, blob.x, blob.y, blob.z)


def _kind_4(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x0A)


def _kind_5(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.rot_x = add_word(blob.rot_x, 0x64)
    blob.rot_y = add_word(blob.rot_y, 0x64)
    blob.rot_z = add_word(blob.rot_z, 0x64)
    blob.vz = i32(blob.vz - 0x5A)


def _kind_6(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _spawn(blob, hooks, result, CREATE_ZOOM_BOB, blob.x, blob.y, blob.z, 4, 0x0A, 8)
    _move(blob)
    blob.rot_x = add_word(blob.rot_x, 0x64)
    blob.rot_y = add_word(blob.rot_y, 0xC8)
    blob.rot_z = add_word(blob.rot_z, 0x12C)
    blob.vz = i32(blob.vz - 0x28)


def _kind_7(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    add_aux(blob, 1)


def _kind_8(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.x = i32(blob.x + _random(hooks, -100, 200))
    blob.y = i32(blob.y + _random(hooks, -100, 200))
    blob.z = i32(blob.z + _random(hooks, -100, 200))
    # **0xFFF, not 0x1000.**  The three rotation draws push the literal
    # `0xFFF` (`0x00420543`, `0x0042055B`, `0x00420576`); this model had 0x1000
    # and was one unit high on about a quarter of the draws.  Stepping a
    # kind-8 record inside `Incubation.exe` is what found it -- a difference
    # of one in a rotation word no structural check could ever see.
    blob.rot_x = u16(_random(hooks, 0, 0xFFF))
    blob.rot_y = u16(_random(hooks, 0, 0xFFF))
    blob.rot_z = u16(_random(hooks, 0, 0xFFF))


def _kind_9(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x140)
    blob.rot_y = u16(7 - (blob.life >> 1))


def _kind_10(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    if blob.life < 9:
        blob.rot_y = u16(7 - (blob.life >> 1))


def _kind_11(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x64)
    blob.rot_x = add_word(blob.rot_x, 0x0A)
    blob.rot_y = add_word(blob.rot_y, 0x0A)
    blob.rot_z = add_word(blob.rot_z, 0x0A)
    # **It does not delete.**  `docs/28` §7.7's table listed kind 11 as the
    # one self-deleting arm and this transcription followed it; the engine
    # says otherwise.  `0x004207B6` ends `mov eax, 1 / ret`, and the
    # `aDeleteBlobObject` call at `0x004207F8` two instructions later is the
    # **wrapper's** expiry path, which every arm falls past and none of them
    # enters.  Stepping a kind-11 record inside `Incubation.exe` for eight
    # ticks found it moving, gravity-bitten and spinning where this model had
    # already removed it (`tools/blob_gold.py`'s `arms_` phase).


def _kind_12(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_y = add_word(blob.rot_y, _random(hooks, 0, 0x1000))


def _kind_13(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.x = i32(blob.x + blob.vx)
    blob.y = i32(blob.y + blob.vy)
    # `0x66666667` with `sar edx, 3` is a divide by **20**, not by 10: the
    # magic is the same for 5, 10 and 20 and only the shift separates them.
    blob.vx = i32(blob.vx - trunc_div(blob.vx, 20))
    blob.vy = i32(blob.vy - trunc_div(blob.vy, 20))


def _kind_14(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    """`0x0041ED5A` -- the one arm that **spins** its delta before applying it.

    The velocity slots hold a point rather than a velocity here: the record
    closes on `(vx, vy)` by a tenth of the remaining distance per tick, and
    the remainder is turned about the vertical by an angle read off `life`
    before it is added back.  That turn is `0x004039A0`, Eng3d's three-angle
    matrix, and this model had no turn at all -- which nothing could notice,
    because no creator fills kind 14 (`docs/97` §20.2).
    """

    dx = i32(blob.vx - blob.x)
    dy = i32(blob.vy - blob.y)
    if blob.life > 3:
        dx = i32(dx - trunc_div(dx, 10))
        dy = i32(dy - trunc_div(dy, 10))
    if blob.life == 1:
        _mark_free(blob, result)
    # The angle is a **word**: 20 per point of life while the record is not
    # rising, and ten per point past 22 while it is.
    turn = u16(blob.life * 20) if blob.vz == 0 else u16((blob.life - 22) * 10)
    spun = hooks.rotate((dx, dy, 0), (0, 0, turn))
    result.event("rotate", turn)
    blob.x = i32(spun[0] + blob.vx)
    blob.y = i32(spun[1] + blob.vy)
    pitch, _yaw, roll = (u16(v) for v in
                         hooks.orient((blob.vx, blob.vy, 0),
                                      (blob.x, blob.y, 0)))
    blob.rot_x = pitch
    blob.rot_z = roll
    result.event("orient", (blob.x, blob.y, 0))


def _kind_15(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    if blob.life == 0:
        _request_delete(blob, result)
        _spawn(blob, hooks, result, CREATE_ZOOM_BOB, blob.x, blob.y, blob.z,
               1, _random(hooks, 5, 15))


def _kind_16(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.z = i32(blob.z + 0x64)
    if blob.life == 2:
        _set_model(blob, hooks, result, "A_HIT2.3DI")


def _kind_17(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x32)
    if blob.life == 5:
        _set_model(blob, hooks, result, "A_BLUT5.3DI")
    if blob.life == 3:
        _set_model(blob, hooks, result, "A_BLUT6.3DI")


def _kind_18(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_x = add_word(blob.rot_x, 0x8C)
    blob.rot_y = add_word(blob.rot_y, 0x8C)
    blob.rot_z = add_word(blob.rot_z, 0x8C)
    _move(blob)
    blob.vz = i32(blob.vz - 0x64)


def _kind_19(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    # `sar edx, 1` after the same magic: a fifth, not a tenth.
    blob.vx = i32(blob.vx - trunc_div(blob.vx, 5))
    blob.vy = i32(blob.vy - trunc_div(blob.vy, 5))
    blob.vz = i32(blob.vz - trunc_div(blob.vz, 5))
    if blob.life == 0:
        _spawn(blob, hooks, result, CREATE_HITTING_BLOBS, blob.x, blob.y, blob.z, 1)


def _kind_20(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x28)


def _kind_21(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x32)


def _kind_22(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x50)
    blob.rot_y = add_word(blob.rot_y, 1) if blob.rot_y < 8 else 0
    _spawn(blob, hooks, result, CREATE_SPORE_SPARKS, blob.x, blob.y, blob.z, 0x0A, 0x10)


def _kind_23(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x32)
    blob.rot_y = u16(7 - (blob.life >> 1))


def _kind_25(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.rot_z = add_word(blob.rot_z, 0x55 if (blob.slot_tag & 1) else -0x55)
    if blob.life == 0:
        _request_delete(blob, result)
        _spawn(blob, hooks, result, CREATE_BARREL_DEBRIS, blob.x, blob.y, i32(blob.z - 0x3200))


def _kind_26(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    # `0x0041FAF7` reads `life` back **after** the hit test, so a seeker that
    # simply ran out of life signals and spawns exactly like one that arrived.
    if _seek(blob, hooks, result) is None:
        return
    if blob.life == 0:
        _request_delete(blob, result)
        _spawn(blob, hooks, result, CREATE_ZOOM_BOB, blob.x, blob.y, blob.z, 0, 30, 16)
        _spawn(blob, hooks, result, CREATE_HITTING_BLOBS_3, blob.x, blob.y, blob.z, 1)


def _kind_27(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    # The one seeker that aims 0x640 **above** its target, and the one whose
    # signal is inside the hit branch (`0x0041FD68`) rather than after it: a
    # kind-27 record that merely expires writes nothing global.
    if _seek(blob, hooks, result, z_offset=0x640):
        _request_delete(blob, result)


def _kind_28(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    if blob.life == 0:
        _request_delete(blob, result)


def _kind_29(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    # **0x1000 here, and 0xFFF only in kind 8's arm.**  The three arms below
    # push `0x1000`; `0x004204F4`'s push `0xFFF`.  A pass that had stepped
    # kind 8 and not these copied the literal across all four, which stepping
    # *these* -- with a donor record's kind byte rewritten, since no creator
    # fills them -- caught (`docs/97` §20).
    blob.rot_x = u16(_random(hooks, 0, 0x1000))
    blob.rot_y = u16(_random(hooks, 0, 0x1000))
    blob.rot_z = u16(_random(hooks, 0, 0x1000))
    _move(blob)
    blob.vz = i32(blob.vz - 0x0A)


def _kind_30(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x32)


def _kind_31(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz + 0x190)


def _kind_32(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.rot_y = u16(_random(hooks, 1, 10))
    set_aux(blob, _random(hooks, 5, 0x28))
    if blob.life == 0:
        _request_delete(blob, result)
        _spawn(blob, hooks, result, CREATE_STING_SPARKS, blob.x, blob.y, blob.z,
               blob.vx, blob.vy)


def _kind_33(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.rot_y = u16(7 - (blob.life >> 1))
    add_aux(blob, 1)


def _kind_34(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 1)


def _kind_35(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_z = add_word(blob.rot_z, 0x32)


def _kind_36(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.x = i32(blob.x + blob.vx)
    blob.y = i32(blob.y + blob.vy)
    blob.z = i32(blob.z - 0xA0)
    _spawn(blob, hooks, result, CREATE_HITTING_BLOBS_2, blob.x, blob.y, blob.z, 5)


def _kind_37(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    """`0x0041EF0E` -- kind 14's turn with a fixed angle and the sign flipped.

    Same shape: the velocity slots are a point, the delta to it is turned by
    `0x004039A0`, and the record is placed at the point *minus* the turned
    delta rather than at the delta plus it.  The angle is the literal `0x66`.
    """

    spun = hooks.rotate((i32(blob.vx - blob.x), i32(blob.vy - blob.y), 0),
                        (0, 0, 0x66))
    result.event("rotate", 0x66)
    blob.x = i32(blob.vx - spun[0])
    blob.y = i32(blob.vy - spun[1])
    pitch, _yaw, roll = (u16(v) for v in
                         hooks.orient((blob.vx, blob.vy, 0),
                                      (blob.x, blob.y, 0)))
    blob.rot_x = pitch
    blob.rot_z = roll
    result.event("orient", (blob.x, blob.y, 0))


def _kind_38(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.rot_y = add_word(blob.rot_y, 0x66)


def _kind_39(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_x = add_word(blob.rot_x, 0x80)
    blob.rot_z = add_word(blob.rot_z, 0x80)
    blob.rot_y = add_word(blob.rot_y, 0x66)
    _move(blob)
    blob.vz = i32(blob.vz - 0x64)


def _kind_41(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    # **The guard is this port's, not the engine's.**  `0x0041E55A` is four
    # instructions -- `mov eax, 0x200 / cdq / idiv [esi+0x48] / add
    # [esi+0x28], ax` -- with nothing in front of the divide, so a record
    # whose `vx` is zero raises #DE and takes the process with it.  That is
    # measured, not deduced: a poked record with `vx` written to zero killed
    # `Incubation.exe` at the fourth call of its plan, after the three arms
    # before it had already been compared (`docs/97` §21.2).  The engine
    # never builds such a record -- every creator that fills kind 41 draws a
    # non-zero `vx` -- so this branch is a **deliberate divergence**: the
    # original faults where the port carries on.  The event is a *Python-side
    # diagnostic only*; `TickResult` in `blob_kinds.gd` carries eight named
    # flags and no free-form list, so the GDScript twin returns quietly and
    # the two agree in every compared field.
    if blob.vx == 0:
        result.event("division_by_zero", 0x200)
        return
    blob.rot_z = add_word(blob.rot_z, trunc_div(0x200, blob.vx))


def _kind_42(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.angle1 = u16(0x400 if _random(hooks, 0, 100) < 50 else 0x1000)
    blob.angle0 = u16(blob.rot_x)
    blob.angle2 = u16(blob.rot_z)


def _kind_43(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - (0x20 if blob.life <= 10 else 0x280))
    if blob.life == 10:
        blob.vx = _random(hooks, -0xA0, 0x140)
        blob.vy = _random(hooks, -0xA0, 0x140)


def _kind_44(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x3C)
    blob.rot_y = u16(7 - (blob.life >> 1))
    if blob.life == 0:
        _spawn(blob, hooks, result, CREATE_PLASMA_SPARKS, blob.x, blob.y, blob.z, 10, 10)


def _kind_45(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move_quarter(blob)
    blob.rot_y = u16(7 - (blob.life >> 1))
    result.event("global_signal_clear")


def _kind_46(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move_quarter(blob)
    add_aux(blob, 1)
    blob.rot_y = u16(7 - blob.life)


def _kind_47(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.x = i32(blob.x + blob.vx)
    blob.y = i32(blob.y + blob.vy)
    blob.vx = i32(blob.vx - trunc_div(blob.vx, 7))
    blob.vy = i32(blob.vy - trunc_div(blob.vy, 7))
    blob.rot_y = u16(7 - (blob.life >> 1))
    if blob.life == 0:
        _request_delete(blob, result)
        _spawn(blob, hooks, result, CREATE_SPORES, blob.x, blob.y, blob.z, 20)


def _kind_49(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.rot_y = u16(min(4, 7 - (blob.life >> 1)))
    add_aux(blob, 1)
    if blob.life == 0:
        _request_delete(blob, result)
        blob.vx = _random(hooks, 0, 0x190)
        blob.vy = _random(hooks, 0, 0x190)
        blob.vz = _random(hooks, 0xC8, 0x190)
        blob.life = 6
        blob.kind = 7
        result.event("morph", 7)


def _kind_50(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_y = u16(7 - blob.life)


def _kind_51(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_y = u16(7 - (blob.life >> 1))


def _kind_52(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_y = add_word(blob.rot_y, 3)
    _move(blob)
    blob.vx = i32(blob.vx + 0x32)
    blob.vy = i32(blob.vy + 0x32)
    if _random(hooks, 0, 8) == 0:
        _spawn(blob, hooks, result, CREATE_PARA_BOMB, blob.x, blob.y, blob.z)


def _kind_53(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    # Kind 53 shares the successful epilogue arm with 48 in the jump table.
    return


def _kind_54(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.angle2 = u16(_random(hooks, 0, 0x1000))
    blob.angle5 = u16(_random(hooks, 0, 0x1000))


def _kind_55(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_z = add_word(blob.rot_z, 0x33)


def _kind_56(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    delta = 0x28 if (blob.slot_tag & 1) else -0x3C
    blob.rot_x = add_word(blob.rot_x, delta)
    blob.rot_y = add_word(blob.rot_y, delta)
    blob.rot_z = add_word(blob.rot_z, delta)
    _move(blob)
    blob.vz = i32(blob.vz - 0x64)
    if blob.life == 0:
        _spawn(blob, hooks, result, CREATE_ZOOM_BOB, blob.x, blob.y, blob.z,
               1, _random(hooks, 2, 5))


def _kind_57(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_z = u16(_random(hooks, 0, 0x1000))


def _kind_58(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    add_aux(blob, 1)
    if blob.life < 9:
        blob.rot_y = u16(7 - (blob.life >> 1))


def _kind_59(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.z = i32(blob.z + 0x258)
    blob.vz = _random(hooks, 5, 15)
    # 0x461e80 returns a mode byte in the original.  The hook is represented
    # by the optional ``emitter_mode`` attribute; absent means the ordinary
    # (non-special) path.
    mode = getattr(hooks, "emitter_mode", 0)
    if mode == 3:
        r1 = _random(hooks, 5, 10)
        r2 = _random(hooks, -100, 200)
        r3 = _random(hooks, -100, 200)
        _spawn(blob, hooks, result, CREATE_EMITTER,
               BLOB_NAME_SCRATCH, 2, blob.x, blob.y, blob.z,
               1, 0, 0, 60, 8, r3, r2, r1, 0, 0)
    size = _random(hooks, 5, 20)
    rz = _random(hooks, -1000, 2000)
    ry = _random(hooks, -1000, 2000)
    rx = _random(hooks, -1000, 2000)
    _spawn(blob, hooks, result, CREATE_EMITTER,
           BLOB_NAME_SCRATCH, 2, blob.x, blob.y, blob.z,
           1, 0, 0, 60, 8,
           rx, ry, rz, size, 0)


def _kind_60(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_y = u16(7 - blob.life)
    _move(blob)
    # `0x55555556` with **no** shift is a third.  The seeker's damping next
    # door uses the negated magic and is a sixth; the two are one instruction
    # apart and were transcribed as the same number.
    blob.vx = i32(blob.vx - trunc_div(blob.vx, 3))
    blob.vy = i32(blob.vy - trunc_div(blob.vy, 3))
    blob.vz = i32(blob.vz - trunc_div(blob.vz, 3))


def _kind_61(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    if _seek(blob, hooks, result) is None:
        return
    if blob.life == 0:
        _request_delete(blob, result)


def _kind_62(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_y = u16(blob.life)
    blob.z = i32(blob.z - 0xA0)
    # The x87 comparison is against the literal 5.0: C0/C3 skip the branch,
    # so the spark burst is taken for rolls strictly greater than five.
    if hooks.random_float(0, 10) > 5.0:
        rz = _random(hooks, -1000, 2000)
        ry = _random(hooks, -1000, 2000)
        rx = _random(hooks, -1000, 2000)
        _spawn(blob, hooks, result, CREATE_PLASMA_SPARKS,
               i32(blob.x + rx), i32(blob.y + ry), i32(blob.z + rz), 1, 10)
    if blob.life == 0:
        _spawn(blob, hooks, result, CREATE_EMITTER,
               BLOB_NAME_SCRATCH, 2, blob.x, blob.y, blob.z,
               4, 0, 0, 10, 10, 0x320, 0x14, 0, 0, 0)


def _kind_63(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)


def _kind_64(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)


def _kind_65(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    set_aux(blob, _random(hooks, 3, 10))
    if blob.life >= 0x28:
        return
    if blob.life == 10:
        blob.vx = _random(hooks, -0x640, 0xC80)
        blob.vy = _random(hooks, -0x640, 0xC80)
        blob.vz = _random(hooks, -0x640, 0xC80)
    if blob.life <= 10:
        blob.x = i32(blob.x - blob.vx)
        blob.y = i32(blob.y - blob.vy)
        blob.z = i32(blob.z - blob.vz)
        blob.rot_y = 0
        return
    else:
        # The three coordinate words are the target for this non-ballistic
        # arm; only the far-enough branch moves one quarter of the remaining
        # delta.  The close branch draws a fresh size and leaves position.
        dx = i32(blob.x - blob.vx)
        dy = i32(blob.y - blob.vy)
        dz = i32(blob.z - blob.vz)
        if abs(dx) > 0x32 and abs(dy) > 0x32 and abs(dz) > 0x32:
            blob.x = i32(blob.x - trunc_div(dx, 4))
            blob.y = i32(blob.y - trunc_div(dy, 4))
            blob.z = i32(blob.z - trunc_div(dz, 4))
            blob.rot_y = 3
            set_aux(blob, 5)
        else:
            blob.rot_y = 0
            set_aux(blob, _random(hooks, 3, 10))


def _kind_66(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    set_aux(blob, _random(hooks, 3, 10))


def _kind_67(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.z = i32(blob.z + 0x190)
    blob.rot_y = u16(_random(hooks, 0, 7))
    set_aux(blob, min(blob.life, 20))
    if blob.life == 0:
        rz = _random(hooks, -1000, 2000)
        ry = _random(hooks, -1000, 2000)
        rx = _random(hooks, -1000, 2000)
        _spawn(blob, hooks, result, CREATE_PLASMA_SPARKS,
               i32(blob.x + rx), i32(blob.y + ry), i32(blob.z + rz), 1, 10)


def _kind_68(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_y = u16(_random(hooks, 0, 7))
    set_aux(blob, _random(hooks, 6, 12))
    _move(blob)
    blob.vz = i32(blob.vz - 0x64)


def _kind_69(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    set_aux(blob, _random(hooks, 1, 10))
    if blob.life == 0:
        _request_delete(blob, result)
        _spawn(blob, hooks, result, CREATE_ZOOM_BOB, blob.x, blob.y, blob.z,
               6, _random(hooks, 5, 15))


def _kind_71(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _request_delete(blob, result)
    _spawn(blob, hooks, result, CREATE_LASER_HIT, blob.x, blob.y, i32(blob.z + 0x640), 0)


def _kind_72(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x90)
    _orient(blob, hooks, result,
            (i32(blob.x + blob.vx), i32(blob.y + blob.vy), i32(blob.z + blob.vz)),
            write_y=False)


def _kind_73(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    if blob.life == 0:
        _spawn(blob, hooks, result, CREATE_ZOOM_BOB, blob.x, blob.y, blob.z,
               1, _random(hooks, 5, 15))
        _spawn(blob, hooks, result, CREATE_PLASMA_SPARKS_2, blob.x, blob.y, blob.z, 20, 30)


def _kind_74(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    if blob.life == 0 and blob.aux == 10:
        _request_delete(blob, result)
        _spawn(blob, hooks, result, CREATE_PLASMA_SPARKS_2, blob.x, blob.y, blob.z, 20, 30)


def _kind_75(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.vz = i32(blob.vz - 0x20)
    blob.rot_y = add_word(blob.rot_y, 1)
    if blob.life == 0 and blob.aux > 2:
        for _ in range(4):
            delta = i32(blob.aux - trunc_div(blob.aux, 3))
            rz = _random(hooks, -0xA0, 0x140)
            ry = _random(hooks, -0x140, 0x280)
            rx = _random(hooks, -0x140, 0x280)
            size = _random(hooks, 3, 10)
            _spawn(blob, hooks, result, CREATE_EMITTER,
                   BLOB_NAME_SCRATCH, 2, blob.x, blob.y, blob.z,
                   0, 0, 0, 75, size,
                   i32(blob.x + rx), i32(blob.y + ry), i32(blob.z + rz),
                   delta, 0)
    elif blob.life == 0:
        _spawn(blob, hooks, result, CREATE_PLASMA_SPARKS, blob.x, blob.y, blob.z, 5, 5)


def _kind_76(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _move(blob)
    blob.rot_y = u16(_random(hooks, 0, 7))
    set_aux(blob, _random(hooks, 5, 15))
    # **It moves twice while it lives.**  The `ja` at `0x0041EB79` leaves for
    # `0x0041EBCB`, which is a second plain move and a return; only the last
    # four ticks take the halved step below.
    if blob.life > 4:
        _move(blob)
        return
    if blob.life <= 4:
        blob.x = i32(blob.x + trunc_div(blob.vx, 2))
        blob.y = i32(blob.y + trunc_div(blob.vy, 2))
        # `0x55555555` followed by `sub edx, ecx` is a divide by **minus**
        # three -- the magic is one below `0x55555556` and the subtraction is
        # the correction that flips the sign, so the record sinks by a third
        # of its rise rather than climbing by it.  And the constant 2 goes
        # into `+0x24`, the **pitch**, not into `+0x28`.
        blob.z = i32(blob.z - trunc_div(blob.vz, 3))
        blob.rot_x = 2


def _kind_77(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    # Three nearby random offsets are drawn before the ordinary ballistic
    # step; the first draw is the constructor's sprite/size argument.
    size = _random(hooks, 5, 10)
    rz = _random(hooks, -20, 40)
    ry = _random(hooks, -20, 40)
    rx = _random(hooks, -20, 40)
    _spawn(blob, hooks, result, CREATE_ZOOM_BOB,
           i32(blob.x + rx), i32(blob.y + ry), i32(blob.z + rz), 5, size)
    _move(blob)
    blob.rot_x = add_word(blob.rot_x, 0x64)
    blob.rot_y = add_word(blob.rot_y, 0x64)
    blob.rot_z = add_word(blob.rot_z, 0x64)
    blob.vz = i32(blob.vz - 0x28)


# One function per jump-table arm.  Aliases are intentionally explicit: the
# binary has 78 values but only 74 distinct destinations.
HANDLERS: Dict[int, Callable[[Blob, BlobHooks, TickResult], None]] = {
    0: _kind_0, 1: _kind_1, 2: _kind_2, 3: _kind_3, 4: _kind_4,
    5: _kind_5, 6: _kind_6, 7: _kind_7, 8: _kind_8, 9: _kind_9,
    10: _kind_10, 11: _kind_11, 12: _kind_12, 13: _kind_13, 14: _kind_14,
    15: _kind_15, 16: _kind_16, 17: _kind_17, 18: _kind_18, 19: _kind_19,
    20: _kind_20, 21: _kind_21, 22: _kind_22, 23: _kind_23, 24: _kind_21,
    25: _kind_25, 26: _kind_26, 27: _kind_27, 28: _kind_28, 29: _kind_29,
    30: _kind_30, 31: _kind_31, 32: _kind_32, 33: _kind_33, 34: _kind_34,
    35: _kind_35, 36: _kind_36, 37: _kind_37, 38: _kind_38, 39: _kind_39,
    40: _kind_23, 41: _kind_41, 42: _kind_42, 43: _kind_43, 44: _kind_44,
    45: _kind_45, 46: _kind_46, 47: _kind_47, 48: _kind_53, 49: _kind_49,
    50: _kind_50, 51: _kind_51, 52: _kind_52, 53: _kind_53, 54: _kind_54,
    55: _kind_55, 56: _kind_56, 57: _kind_57, 58: _kind_58, 59: _kind_59,
    60: _kind_60, 61: _kind_61, 62: _kind_62, 63: _kind_63, 64: _kind_64,
    65: _kind_65, 66: _kind_66, 67: _kind_67, 68: _kind_68, 69: _kind_69,
    70: _kind_66, 71: _kind_71, 72: _kind_72, 73: _kind_73, 74: _kind_74,
    75: _kind_75, 76: _kind_76, 77: _kind_77,
}


def tick_blob(blob: Blob, hooks: Optional[BlobHooks] = None) -> TickResult:
    """Execute one original-style update tick for *blob*.

    The wrapper is ordered exactly like ``aBlob_Update``: delay is consumed
    before life/z expiry, finite life is decremented before dispatch, and the
    jump-table arm sees the decremented value.
    """

    hooks = hooks or BlobHooks()
    result = TickResult(ran=True)
    if not blob.alive:
        result.event("dead_input")
        return result
    if blob.delay:
        blob.delay = u8(blob.delay - 1)
        result.delayed = True
        result.event("delay", blob.delay)
        return result
    if blob.life == 0 or blob.z < 0:
        _explicit_delete(blob, result)
        return result
    if blob.life != 0xFF:
        blob.life = u8(blob.life - 1)
    handler = HANDLERS.get(blob.kind, _kind_53)
    result.dispatched = True
    handler(blob, hooks, result)
    return result


_ARM_MUTATIONS = (
    'x,y,z,rot_x,rot_y,rot_z,vz', 'x,y,z', 'x,y,z,rot_x,rot_y,rot_z',
    'x,y,z,rot_x,rot_y,rot_z,vz', 'x,y,z,vz', 'x,y,z,rot_x,rot_y,rot_z,vz',
    'x,y,z,rot_x,rot_y,rot_z,vz', 'x,y,z,aux', 'x,y,z,rot_x,rot_y,rot_z',
    'x,y,z,rot_y,vz', 'x,y,z', 'x,y,z,rot_x,rot_y,rot_z,vz',
    'rot_y', 'x,y,vx,vy', 'x,y,rot_x,rot_z', 'x,y,z', 'z', 'x,y,z,vz',
    'x,y,z,rot_x,rot_y,rot_z,vz', 'x,y,z,vx,vy,vz', 'x,y,z,vz', 'x,y,z,vz',
    'x,y,z,rot_y,vz', 'x,y,z,rot_y,vz', 'x,y,z,vz', 'x,y,z,rot_z',
    'x,y,z,rot_x,rot_y,rot_z,vx,vy,vz', 'x,y,z,rot_x,rot_y,rot_z,vx,vy,vz',
    '', 'x,y,z,rot_x,rot_y,rot_z,vz', 'x,y,z,vz', 'x,y,z,vz',
    'x,y,z,rot_y,aux', 'x,y,z,rot_y,aux', 'x,y,z,vz', 'rot_z', 'x,y,z',
    'x,y,rot_x,rot_z', 'x,y,z,rot_y', 'x,y,z,rot_x,rot_y,rot_z,vz',
    'x,y,z,rot_y,vz', 'rot_z', 'angle0,angle1,angle2', 'x,y,z,vz',
    'x,y,z,rot_y,vz', 'x,y,z,rot_y', 'x,y,z,rot_y,aux', 'x,y,rot_y,vx,vy',
    '', 'x,y,z,rot_y,aux', 'rot_y', 'rot_y', 'x,y,z,rot_y,vx,vy', '',
    'angle2,angle5', 'rot_z', 'x,y,z,rot_x,rot_y,rot_z,vz', 'rot_z',
    'x,y,z,aux', 'z,vz', 'x,y,z,rot_y,vx,vy,vz',
    'x,y,z,rot_x,rot_y,rot_z,vx,vy,vz', 'z,rot_y', 'x,y,z', 'x,y,z',
    'x,y,z,rot_y,aux', 'aux', 'z,rot_y,aux', 'x,y,z,rot_y,vz,aux',
    'x,y,z,aux', 'aux', '', 'x,y,z,rot_x,rot_z,vz', 'x,y,z', 'x,y,z',
    'x,y,z,rot_y,vz', 'x,y,z,rot_y,aux', 'x,y,z,rot_x,rot_y,rot_z,vz',
)

_ARM_RNG_CALLS = (
    3, 0, 3, 0, 0, 0, 0, 0, 6, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2, 0, 0, 1, 0, 5,
    0, 0, 1, 0, 0, 1, 1, 1, 2, 1, 1, 0, 0, 0, 0, 0, 2, 4,
)

_ARM_SPAWNS = {
    6: (CREATE_ZOOM_BOB,),
    22: (CREATE_SPORE_SPARKS,),
    36: (CREATE_HITTING_BLOBS_2,),
    52: (CREATE_PARA_BOMB,),
    59: (CREATE_EMITTER,),
    71: (CREATE_LASER_HIT,),
    77: (CREATE_ZOOM_BOB,),
}


class _SelftestHooks(BlobHooks):
    def target_position(self, blob: Blob) -> Optional[Tuple[int, int, int]]:
        return 2000, 3000, 4000


class _SeekHooks(BlobHooks):
    """The unit the captured seeker phases steer at.

    `tools/blob_gold.py` established the whole chain by elimination: the
    record's ``+0x54`` names a unit-map slot, that unit's ``+0x4B`` names an
    object, and the object at id 1 is the only one of the fifteen the save
    actually holds that reproduces the engine's next record -- on all eighteen
    transitions where an arm ran.
    """

    TARGET = (57600, 12800, 160)

    def target_position(self, blob: Blob) -> Optional[Tuple[int, int, int]]:
        self.target_calls.append(blob.aux)
        return self.TARGET


class _ScriptedHooks(_SelftestHooks):
    def __init__(self, values: Sequence[float]) -> None:
        super().__init__()
        self.values = list(values)
        self.calls = 0

    def _next(self) -> float:
        assert self.values, "scripted RNG exhausted"
        self.calls += 1
        return self.values.pop(0)

    def random(self, base: int, span: int) -> int:
        return int(self._next())

    def random_float(self, base: int, span: int) -> float:
        return self._next()


def _selftest() -> None:
    assert len(HANDLERS) == 78
    assert len({id(handler) for handler in HANDLERS.values()}) == 74
    assert HANDLERS[21] is HANDLERS[24]
    assert HANDLERS[23] is HANDLERS[40]
    assert HANDLERS[48] is HANDLERS[53]
    assert HANDLERS[66] is HANDLERS[70]
    # The two capture families between them reach every arm exactly once.
    assert not set(NATIVE_ARMS) & set(POKED_ARMS)
    assert sorted(NATIVE_ARMS + POKED_ARMS) == list(range(74))
    assert not UNRESOLVED_ARMS

    # Wrapper order and byte/word wrapping.
    b = Blob(kind=0, life=3, delay=2, rot_x=0xFFFF, vx=3, vy=-2, vz=4)
    h = BlobHooks(seed=1)
    r = tick_blob(b, h)
    assert r.delayed and b.delay == 1 and b.life == 3
    r = tick_blob(b, h)
    assert r.delayed and b.delay == 0 and b.life == 3
    r = tick_blob(b, h)
    assert r.dispatched and b.life == 2 and b.rot_x == 118
    assert b.x == 3 and b.y == -2 and b.z == 4 and b.vz == -96

    # One deterministic profile per kind verifies the fields written, RNG call
    # count and constructor targets.  The profile input keeps all 74 distinct
    # arms on a meaningful non-terminal path.
    profile_args = dict(
        x=100, y=-200, z=1000, rot_x=10, rot_y=20, rot_z=30,
        angle0=40, angle1=50, angle2=60, angle3=70, angle4=80, angle5=90,
        vx=300, vy=-400, vz=500, aux=4, life=12, class_id=2,
        model=7, slot_tag=1,
    )
    for kind in range(78):
        b = Blob(kind=kind, **profile_args)
        before = {item.name: getattr(b, item.name) for item in fields(b)}
        h = _SelftestHooks(seed=1)
        r = tick_blob(b, h)
        changed = ','.join(item.name for item in fields(b)
                           if item.name != 'life' and before[item.name] != getattr(b, item.name))
        assert changed == _ARM_MUTATIONS[kind], (kind, changed, _ARM_MUTATIONS[kind])
        assert h.rng.calls == _ARM_RNG_CALLS[kind], (kind, h.rng.calls)
        assert tuple(spawn.creator for spawn in r.spawns) == _ARM_SPAWNS.get(kind, ()), kind

    # **No arm deletes; the wrapper does.**  This assertion used to require
    # kind 11 to remove itself, which is what `docs/28` §7.7's table said and
    # what stepping a kind-11 record inside `Incubation.exe` disproved.  It
    # now asserts the two halves separately: the arm runs and leaves the
    # record alone, and the wrapper removes it on the tick that finds a spent
    # life.
    b = Blob(kind=11, life=2, z=100)
    r = tick_blob(b, BlobHooks())
    assert not r.deleted and b.alive and b.life == 1
    b = Blob(kind=11, life=0, z=100)
    r = tick_blob(b, BlobHooks())
    assert r.deleted and not b.alive
    b = Blob(kind=73, life=1, z=100)
    r = tick_blob(b, BlobHooks(seed=1))
    assert len(r.spawns) == 2 and not r.global_signal
    b = Blob(kind=74, life=1, aux=10, z=100)
    r = tick_blob(b, BlobHooks())
    assert len(r.spawns) == 1 and r.global_signal
    b = Blob(kind=49, life=1, z=100)
    r = tick_blob(b, BlobHooks(seed=1))
    assert r.dispatched and b.kind == 7 and b.life == 6

    # The seeker, pinned to the **engine's own record**.  `blob_gold.py`'s
    # `arms_0x004264A0` phase, round 0 to round 1, slot 0: a kind-61 record
    # steering at the unit whose object sits at (57600, 12800, 160).  Only the
    # position and the velocity are asserted here -- the two rotation words
    # come from `0x00403AA0` and need the shipped tables, so `blob_gold.py`
    # is where they are compared.  The older model, which divided by the true
    # distance instead of by `0x0046D400`'s answer, misses every component.
    b = Blob(kind=61, life=100, aux=1, class_id=0, model=99,
             x=60800, y=19200, z=2400, vx=-960, vy=-1920, vz=-644)
    r = tick_blob(b, _SeekHooks())
    assert (b.x, b.y, b.z) == (59880, 17360, 1788), (b.x, b.y, b.z)
    assert (b.vx, b.vy, b.vz) == (-920, -1840, -612), (b.vx, b.vy, b.vz)
    assert b.life == 99 and not r.global_signal
    # Sixteen steps later the same record is inside the 0x640 box on all three
    # axes, and the arrival is `life = 0` plus the signal and **no** delete.
    for _ in range(60):
        if b.life == 0:
            break
        r = tick_blob(b, _SeekHooks())
    assert b.life == 0 and b.alive and not r.deleted
    assert r.global_signal and ('seek_hit', 1) in r.events

    # Review regressions: constructor ABI, direct +0x00 store and all branches
    # of kind 65.  Scripted values are the already-converted x87 results.
    b = Blob(kind=14, life=2, x=100, y=200, z=300, vx=400, vy=500)
    r = tick_blob(b, _SelftestHooks())
    assert not b.in_use and not b.alive and ('mark_free', 14) in r.events
    assert not any(event[0] == 'delete' for event in r.events)

    b = Blob(kind=22, life=2, z=100)
    r = tick_blob(b, _ScriptedHooks(()))
    assert r.spawns[0].creator == CREATE_SPORE_SPARKS
    assert r.spawns[0].args[-2:] == (10, 16)

    b = Blob(kind=59, life=2, x=100, y=200, z=1000)
    r = tick_blob(b, _ScriptedHooks((7, 9, -900, -800, -700)))
    assert r.spawns[0].args[10:] == (-700, -800, -900, 9, 0)

    b = Blob(kind=62, life=1, x=100, y=-200, z=1000)
    r = tick_blob(b, _ScriptedHooks((6.25, 11, 22, 33)))
    assert r.spawns[0].creator == CREATE_PLASMA_SPARKS
    assert r.spawns[0].args == (133, -178, 851, 1, 10)
    assert r.spawns[1].creator == CREATE_EMITTER

    b = Blob(kind=67, life=1, x=100, y=-200, z=1000)
    r = tick_blob(b, _ScriptedHooks((2, 11, 22, 33)))
    assert r.spawns[0].args == (133, -178, 1411, 1, 10)

    b = Blob(kind=65, life=11, x=400, y=500, z=600, vx=100, vy=100, vz=100)
    HANDLERS[65](b, _ScriptedHooks((4,)), TickResult())
    assert b.rot_y == 3 and b.aux == 5 and (b.x, b.y, b.z) == (325, 400, 475)
    b = Blob(kind=65, life=11, x=100, y=100, z=100, vx=80, vy=80, vz=80, rot_y=9)
    h = _ScriptedHooks((4, 7))
    HANDLERS[65](b, h, TickResult())
    assert b.rot_y == 0 and b.aux == 7 and h.calls == 2


# --------------------------------------------------------------------------
# The fixture the GDScript pool is compared against
# --------------------------------------------------------------------------

#: Bumped when the document's shape changes, so `run_tests.sh` copying a stale
#: file is refused by name instead of quietly shrinking the run.
CASES_SCHEMA = "incubation.blob-cases/1"

#: Every model name an arm can ask for, in a fixed order.  The index is the
#: position, so the adapter is a pure function of the name and the GDScript
#: twin needs no recorded returns to reproduce it.
CASE_MODELS: Tuple[str, ...] = ("A_BLUT5.3DI", "A_BLUT6.3DI", "A_HIT2.3DI")

#: Where the deterministic adapter says a seeker's target is.  Chosen so the
#: distance is not a perfect square and the truncating divisions in `_seek`
#: are actually exercised.
CASE_TARGET: Tuple[int, int, int] = (2000, 3000, 4000)

#: The seed every case starts from.  `1.0` rather than `0.0` because the zero
#: seed is a fixed point of the Lehmer step: a case seeded with it would run
#: every arm against a constant draw and prove nothing about the generator.
CASE_SEED = 1.0


class CaseHooks(BlobHooks):
    """The adapter both the fixture and the GDScript twin implement.

    Each service is a pure function of its arguments and of the two tables
    above, so the comparison is of the seventy-four arms and not of a replay
    of recorded returns.  The orientation helper is the **retail routine**
    when a game root supplied the shipped trig tables (``docs/28`` §7.4.2) and
    the base class's substitute when it did not; the emitted document records
    which, and the GDScript twin configures itself from that field rather than
    assuming either.
    """

    def __init__(self, seed: float = CASE_SEED, *,
                 target: Optional[Tuple[int, int, int]] = CASE_TARGET,
                 models: bool = True, spawns: bool = True,
                 emitter_mode: int = 0, tables: Any = None) -> None:
        super().__init__(seed, tables)
        self.target = target
        self.models = models
        self.spawns_ok = spawns
        #: ``0x00461E80``'s returned byte, which kind 59 branches on.  It is
        #: the **output system's** mode id at ``0x00512A78``, not anything in
        #: the record: the extra emitter exists only under the display
        #: configuration whose surface is made by the runtime-registered
        #: entry rather than by ``aCreateMainDDObject`` (`docs/97` §23.3).
        #: Without a scenario that sets it, both sides would agree about that
        #: branch by never running it, which is not agreement -- so
        #: `blob_gold.py`'s ``mode_59`` plan writes it in the live process
        #: and steps the arm under it.
        self.emitter_mode = emitter_mode

    def spawn(self, creator: int, args: Sequence[Any], source: Blob) -> bool:
        super().spawn(creator, args, source)
        return self.spawns_ok

    def lookup_model(self, name: str) -> int:
        self.model_calls.append(name)
        if not self.models or name not in CASE_MODELS:
            return -1
        return CASE_MODELS.index(name)

    def target_position(self, blob: Blob) -> Optional[Tuple[int, int, int]]:
        self.target_calls.append(blob.aux)
        return self.target


#: The scenario each kind is run under.  The names are what a failing case
#: prints, so they say which branch of the wrapper is under test.
CASE_SCENARIOS: Tuple[Tuple[str, Dict[str, Any], Dict[str, Any], int], ...] = (
    # (name, blob overrides, hook overrides, ticks)
    ("profile", {}, {}, 8),
    ("delayed", {"delay": 3}, {}, 5),
    ("expiring", {"life": 1}, {}, 3),
    ("below_floor", {"z": -1}, {}, 2),
    ("immortal", {"life": 0xFF}, {}, 4),
    ("class_zero", {"class_id": 0, "aux": 200}, {}, 4),
    ("no_target", {}, {"target": None}, 4),
    ("no_model", {}, {"models": False}, 4),
    ("spawn_refused", {}, {"spawns": False}, 4),
    ("mirrored", {"slot_tag": 0}, {}, 4),
    # Two branches the profile cannot reach, and which would otherwise be
    # "agreed" on by neither side running them: kind 59's special emitter, and
    # the zero divisor kind 41 guards against.
    ("emitter_special", {}, {"emitter_mode": 3}, 4),
    ("zero_velocity", {"vx": 0, "vy": 0, "vz": 0}, {}, 4),
)

#: The blob every scenario starts from, before its own overrides.  It is the
#: selftest's profile, so the two agree about what a "meaningful non-terminal
#: path" is and a change to one is visible in the other.
CASE_BLOB: Dict[str, Any] = dict(
    x=100, y=-200, z=1000, rot_x=10, rot_y=20, rot_z=30,
    angle0=40, angle1=50, angle2=60, angle3=70, angle4=80, angle5=90,
    vx=300, vy=-400, vz=500, aux=4, life=12, class_id=2,
    model=7, slot_tag=1,
)

#: The field order the fixture writes and the twin reads back.
CASE_FIELDS: Tuple[str, ...] = (
    "in_use", "x", "y", "z", "rot_x", "rot_y", "rot_z",
    "angle0", "angle1", "angle2", "angle3", "angle4", "angle5",
    "vx", "vy", "vz", "aux", "kind", "life", "delay", "class_id",
    "model", "slot_tag", "alive",
)


def _case_blob(blob: Blob) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for name in CASE_FIELDS:
        value = getattr(blob, name)
        out[name] = int(value) if isinstance(value, bool) else value
    return out


def _case_tick(blob: Blob, hooks: CaseHooks) -> Dict[str, Any]:
    before_spawns = len(hooks.spawn_calls)
    before_models = len(hooks.model_calls)
    result = tick_blob(blob, hooks)
    return {
        "blob": _case_blob(blob),
        "ran": int(result.ran),
        "delayed": int(result.delayed),
        "dispatched": int(result.dispatched),
        "deleted": int(result.deleted),
        "delete_requested": int(result.delete_requested),
        "global_signal": int(result.global_signal),
        "target_missing": int(result.target_missing),
        "model_missing": int(result.model_missing),
        "spawns": [{"creator": spawn.creator,
                    "args": [_case_arg(a) for a in spawn.args],
                    "ok": int(spawn.succeeded)}
                   for spawn in result.spawns],
        "models": hooks.model_calls[before_models:],
        "spawn_calls": len(hooks.spawn_calls) - before_spawns,
        "rng_calls": hooks.rng.calls,
        "rng_seed": hooks.rng.seed,
    }


def _case_arg(value: Any) -> Any:
    """A constructor argument, narrowed to what JSON can carry exactly.

    Every argument the arms pass is already an integer or the scratch-buffer
    address; a float would mean an arm leaked an x87 value into a store, which
    is worth failing on rather than rounding away.
    """
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return value
    raise TypeError("blob spawn argument is not an integer: %r" % (value,))


#: The eight `(vector, angles)` pairs `tools/blob_gold.py`'s `hooks` phase put
#: through `0x004039A0` in a live process.  They are repeated here so the
#: emitted fixture can carry the **model's** answers to them and the GDScript
#: twin can be diffed against the Python one on exactly the inputs the engine
#: itself answered; `blob_gold.py` pins that the two lists are the same list.
#: `0x88` is the literal `0x004228F0` writes before it calls, so one case is
#: the shipped one rather than a sweep's invention.
#: **The arms the engine itself has stepped.**  `tools/blob_gold.py`'s
#: `ticks_`/`arms_` phases populate the pool with a creator inside a running
#: `Incubation.exe`, call the engine's own frame sweep -- or `aBlob_Update`
#: directly, where the sweep's renderer check-in cannot run outside a frame --
#: and read the 88-byte records back between rounds.  These arms reproduced
#: every field of every occupied slot for every round.
#:
#: It does **not** make the layer `native-runtime`: this file is still diffed
#: against its GDScript twin and not against the engine, and the other fifty
#: arms are not populated by any creator a weapon switch selects, so nothing
#: has stepped them at all.  What it does make is a *transitive* claim for
#: these twenty-four -- engine against Python here, Python against GDScript in
#: the suite -- and the fixture carries the list so the suite can say which.
#: `blob_gold.py` pins that this list is the one its capture produced.
NATIVE_ARMS: Tuple[int, ...] = (
    5, 6, 8, 9, 11, 12, 15, 20, 21, 22, 25, 33, 42, 44, 45, 48, 49, 58, 60,
    61, 63, 68, 71, 73,
)
#: **The other fifty**, stepped the only way they can be.  No creator a weapon
#: switch selects fills them, so `blob_gold.py`'s `poked_*` phases borrow a
#: donor pool and rewrite each record's `+0x44` -- the jump-table index -- and
#: call `aBlob_Update` once per record per round inside the engine.  Every one
#: reproduces the engine's record field for field.
#:
#: It is a weaker claim than :data:`NATIVE_ARMS` in one specific way and no
#: other: the record an arm is handed is a donor's, so the *arm* is measured
#: and the arguments a creator would have given it are not.
#:
#: Ten of these fifty did not reproduce it until this file was corrected, and
#: that is what the experiment was for -- `docs/97` §20 lists them.
POKED_ARMS: Tuple[int, ...] = (0, 1, 2, 3, 4, 7, 10, 13, 14, 16, 17, 18, 19, 23, 24, 26, 27, 28, 29, 30, 31, 32, 34, 35, 36, 37, 38, 39, 40, 41, 43, 46, 47, 50, 51, 52, 53, 54, 55, 56, 57, 59, 62, 64, 65, 66, 67, 69, 70, 72)
#: Stepped and **not** reproduced: none, of all seventy-four.  The two seekers
#: were here until the reading in :func:`_seek` replaced the invented
#: normalisation with `0x0046D400`'s own answer.
UNRESOLVED_ARMS: Tuple[int, ...] = ()


CASE_ROTATIONS: Tuple[Tuple[Tuple[int, int, int], Tuple[int, int, int]], ...] = (
    ((1000, 0, 0), (0, 0, 0)),
    ((1000, 0, 0), (0, 0, 1024)),
    ((1000, 0, 0), (0, 1024, 0)),
    ((1000, 0, 0), (1024, 0, 0)),
    ((0, 0, 1000), (2048, 0, 0)),
    ((1000, 500, 250), (100, 200, 300)),
    ((-700, 300, -900), (4000, 3000, 2000)),
    ((1000, 0, 0), (0, 0, 0x88)),
)


def emit_cases(out: str, root: Optional[str] = None) -> int:
    """Write the per-tick trace `godot/tests/test_blob.gd` replays.

    *root* is optional and changes exactly one thing: with it the orientation
    service is the **measured** ``0x00403AA0`` and the shipped trig tables ride
    along in the document so the GDScript twin reads the same numbers; without
    it both sides use the older substitute.  Everything else here -- the
    seventy-four arms, the wrapper, the generator -- is a transcription of
    ``aBlob_Update`` and reads nothing.
    """

    tables = None
    if root:
        from inclib import eng3d
        tables = eng3d.load(root)
    cases: List[Dict[str, Any]] = []
    for kind in range(len(HANDLERS)):
        for name, blob_over, hook_over, ticks in CASE_SCENARIOS:
            fields_in = dict(CASE_BLOB, kind=kind, **blob_over)
            blob = Blob(**fields_in)
            hooks = CaseHooks(tables=tables, **hook_over)
            trace = [_case_tick(blob, hooks) for _ in range(ticks)]
            cases.append({
                "kind": kind,
                "scenario": name,
                "seed": CASE_SEED,
                "target": list(hooks.target) if hooks.target else None,
                "models": int(hooks.models),
                "spawns_ok": int(hooks.spawns_ok),
                "emitter_mode": hooks.emitter_mode,
                "blob": _case_blob(Blob(**fields_in)),
                "ticks": trace,
            })

    arms: Dict[int, int] = {}
    order: List[int] = []
    for kind in range(len(HANDLERS)):
        key = id(HANDLERS[kind])
        if key not in order:
            order.append(key)
        arms[kind] = order.index(key)

    payload = {
        "schema": CASES_SCHEMA,
        "oracle": "executable-Python (tools/blob_runtime.py).  This diff is "
                  "a transcription against a transcription; the boundary is "
                  "NOT raised by what follows.  All five services of docs/28 "
                  "section 12 item 1 are measured and reproduced "
                  "(tools/blob_gold.py's hooks phase), and **all 74 arms** "
                  "have additionally been stepped inside a running "
                  "Incubation.exe and agree field for field: 24 with records "
                  "a creator built (native_arms) and the other 50 with a "
                  "donor record whose kind byte was rewritten (poked_arms), "
                  "which measures the arm and not the arguments a creator "
                  "would have passed it.  unresolved_arms is empty.  How "
                  "much of each arm that reached is measured rather than "
                  "assumed: the sweep is run at more than one point of the "
                  "input space, and 383 of the 385 transcribed arm lines are "
                  "executed by the comparison itself.  The two that are "
                  "not are named in tools/blob_gold.py's "
                  "COVERAGE_UNCOVERED, and both are one deliberate "
                  "divergence: the original divides by zero and this port "
                  "refuses to (docs/97 section 21.2).  Kind 59's other six "
                  "used to be here too; they are reached now by writing the "
                  "output-system mode the branch reads (docs/97 "
                  "section 23.3).",
        "arm_lines_covered": 383,
        "arm_lines_total": 385,
        "native_arms": list(NATIVE_ARMS),
        "poked_arms": list(POKED_ARMS),
        "unresolved_arms": list(UNRESOLVED_ARMS),
        "orient": "native" if tables is not None else "substitute",
        "eng3d": ({"trig": tables.trig, "atn": tables.atn,
                   "rotations": [[list(v), list(a), tables.rotate(v, a)]
                                 for v, a in CASE_ROTATIONS]}
                  if tables is not None else None),
        "kinds": len(HANDLERS),
        "arms": len(order),
        "arm_of_kind": {str(k): v for k, v in sorted(arms.items())},
        "aliases": [[21, 24], [23, 40], [48, 53], [66, 70]],
        "unreachable": [2, 4, 21, 28, 30, 35, 45, 48, 53, 56, 76],
        "gravity": {"split": 10, "high": -640, "low": -32},
        "immortal_life": 0xFF,
        "models": list(CASE_MODELS),
        "target": list(CASE_TARGET),
        "seed": CASE_SEED,
        "fields": list(CASE_FIELDS),
        "scenarios": [name for name, _b, _h, _t in CASE_SCENARIOS],
        "cases": cases,
    }
    path = Path(out)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n",
                    encoding="utf-8")
    ticks = sum(len(case["ticks"]) for case in cases)
    print("wrote %s (%d kinds, %d cases, %d ticks)"
          % (out, len(HANDLERS), len(cases), ticks))
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true", help="run runtime invariants")
    parser.add_argument("--emit-cases", metavar="OUT",
                        help="write the per-tick trace the Godot suite replays")
    parser.add_argument("--root", metavar="GAME_ROOT",
                        help="use the measured orientation helper and carry "
                             "the shipped trig tables into the fixture; "
                             "without it both twins use the substitute")
    args = parser.parse_args(argv)
    if not (args.selftest or args.emit_cases):
        parser.error("use --selftest or --emit-cases (the module is a "
                     "library/reference runtime)")
    if args.emit_cases:
        return emit_cases(args.emit_cases, args.root)
    _selftest()
    print("blob_runtime: selftest passed (78 kinds, 74 arms)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
