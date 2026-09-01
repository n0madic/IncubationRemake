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

    def orient(self, blob: Blob, target: Tuple[int, int, int]) -> Tuple[int, int, int]:
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
            pitch, yaw = self.tables.orient((blob.x, blob.y, blob.z), target)
            return u16(pitch), 0, u16(yaw)
        dx = target[0] - blob.x
        dy = target[1] - blob.y
        dz = target[2] - blob.z
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
    """Call the retail pool-deletion routine used by kind 11/the wrapper."""

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
    pitch, yaw, roll = (u16(v) for v in hooks.orient(blob, target))
    blob.rot_x = pitch
    if write_y:
        blob.rot_y = yaw
    if zero_y:
        blob.rot_y = 0
    blob.rot_z = roll
    result.event("orient", target)


def _seek(blob: Blob, hooks: BlobHooks, result: TickResult,
          *, z_offset: int = 0, finish: bool = True) -> bool:
    target = hooks.target_position(blob)
    if target is None:
        result.target_missing = True
        result.event("target_missing", blob.aux)
        return False
    target = (i32(target[0]), i32(target[1]), i32(target[2] + z_offset))
    dx, dy, dz = target[0] - blob.x, target[1] - blob.y, target[2] - blob.z
    # 26/27/61 use the same normalized vector helper.  The recovered constant
    # at 0x4b1238 is -240.0 and the surrounding magic multiply is signed /6,
    # hence ``old_v - old_v/6 + direction*240`` below.
    distance = math.sqrt(float(dx * dx + dy * dy + dz * dz))
    if distance:
        blob.vx = i32(blob.vx - trunc_div(blob.vx, 6) + trunc_div(round(dx * 240.0), round(distance)))
        blob.vy = i32(blob.vy - trunc_div(blob.vy, 6) + trunc_div(round(dy * 240.0), round(distance)))
        blob.vz = i32(blob.vz - trunc_div(blob.vz, 6) + trunc_div(round(dz * 240.0), round(distance)))
    _orient(blob, hooks, result, target, write_y=False, zero_y=True)
    _move(blob)
    if finish and all(abs(a - b) < 0x640 for a, b in zip((blob.x, blob.y, blob.z), target)):
        blob.life = 0
        result.event("seek_hit", blob.aux)
        _request_delete(blob, result)
    return True


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
    blob.rot_x = u16(_random(hooks, 0, 0x1000))
    blob.rot_y = u16(_random(hooks, 0, 0x1000))
    blob.rot_z = u16(_random(hooks, 0, 0x1000))


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
    _explicit_delete(blob, result)


def _kind_12(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.rot_y = add_word(blob.rot_y, _random(hooks, 0, 0x1000))


def _kind_13(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    blob.x = i32(blob.x + blob.vx)
    blob.y = i32(blob.y + blob.vy)
    blob.vx = i32(blob.vx - trunc_div(blob.vx, 10))
    blob.vy = i32(blob.vy - trunc_div(blob.vy, 10))


def _kind_14(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    dx = i32(blob.vx - blob.x)
    dy = i32(blob.vy - blob.y)
    if blob.life > 3:
        dx = i32(dx - trunc_div(dx, 10))
        dy = i32(dy - trunc_div(dy, 10))
    if blob.life == 1:
        _mark_free(blob, result)
    target = (i32(blob.x + dx), i32(blob.y + dy), blob.z)
    _orient(blob, hooks, result, target, write_y=False)
    blob.x = i32(dx + blob.vx)
    blob.y = i32(dy + blob.vy)


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
    blob.vx = i32(blob.vx - trunc_div(blob.vx, 10))
    blob.vy = i32(blob.vy - trunc_div(blob.vy, 10))
    blob.vz = i32(blob.vz - trunc_div(blob.vz, 10))
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
    if _seek(blob, hooks, result):
        if blob.life == 0:
            _spawn(blob, hooks, result, CREATE_ZOOM_BOB, blob.x, blob.y, blob.z, 0, 30, 16)
            _spawn(blob, hooks, result, CREATE_HITTING_BLOBS_3, blob.x, blob.y, blob.z, 1)


def _kind_27(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _seek(blob, hooks, result, z_offset=0x640)


def _kind_28(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    if blob.life == 0:
        _request_delete(blob, result)


def _kind_29(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
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
    _orient(blob, hooks, result, (blob.vx, blob.vy, blob.z), write_y=False)


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
    blob.vx = i32(blob.vx - trunc_div(blob.vx, 6))
    blob.vy = i32(blob.vy - trunc_div(blob.vy, 6))
    blob.vz = i32(blob.vz - trunc_div(blob.vz, 6))


def _kind_61(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _seek(blob, hooks, result)


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


def _kind_70(blob: Blob, hooks: BlobHooks, result: TickResult) -> None:
    _kind_66(blob, hooks, result)


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
    if blob.life <= 4:
        blob.x = i32(blob.x + trunc_div(blob.vx, 2))
        blob.y = i32(blob.y + trunc_div(blob.vy, 2))
        blob.z = i32(blob.z + trunc_div(blob.vz, 3))
        blob.rot_z = 2


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
    'x,y,z,rot_y,vz', 'x,y,z', 'in_use,x,y,z,rot_x,rot_y,rot_z,vz,alive',
    'rot_y', 'x,y,vx,vy', 'x,y,rot_x,rot_z', 'x,y,z', 'z', 'x,y,z,vz',
    'x,y,z,rot_x,rot_y,rot_z,vz', 'x,y,z,vx,vy,vz', 'x,y,z,vz', 'x,y,z,vz',
    'x,y,z,rot_y,vz', 'x,y,z,rot_y,vz', 'x,y,z,vz', 'x,y,z,rot_z',
    'x,y,z,rot_x,rot_y,rot_z,vx,vy,vz', 'x,y,z,rot_x,rot_y,rot_z,vx,vy,vz',
    '', 'x,y,z,rot_x,rot_y,rot_z,vz', 'x,y,z,vz', 'x,y,z,vz',
    'x,y,z,rot_y,aux', 'x,y,z,rot_y,aux', 'x,y,z,vz', 'rot_z', 'x,y,z',
    'rot_x,rot_z', 'x,y,z,rot_y', 'x,y,z,rot_x,rot_y,rot_z,vz',
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

    b = Blob(kind=11, life=2, z=100)
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
        #: ``0x00461E80``'s returned byte, which kind 59 branches on.  Without
        #: a scenario that sets it, both sides would agree about that branch
        #: by never running it, which is not agreement.
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
        "oracle": "executable-Python (tools/blob_runtime.py).  The "
                  "seventy-four arms are a transcription compared against a "
                  "transcription -- NOT a trajectory against the engine.  The "
                  "orientation service is the exception: with a game root it "
                  "is 0x00403AA0's measured arithmetic (tools/blob_gold.py's "
                  "hooks phase, 20/20), and the other services of docs/28 "
                  "section 12 item 1 remain a deterministic adapter.",
        "orient": "native" if tables is not None else "substitute",
        "eng3d": ({"trig": tables.trig, "atn": tables.atn}
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
