"""Transcriptions of the blob **creators** whose records no recipe explained.

``docs/28`` §7.6.1 fits a *recipe* to a creator: a field, a stride through the
second generator's draws, a scale.  That works for a creator that builds one
kind of record in a fixed loop and fails for one that does anything else --
several kinds in one call, a nested creator, a count computed from the
distance between two tiles.  Ten creators were left with "a residue of fields
with no named mechanism", and the residue was a property of the *fitter*, not
of the engine: the mechanism is in each creator's own instructions.

This module is those instructions, transcribed.  Each function takes the
arguments the capture passed, the inputs the engine read before it drew
anything (:class:`Inputs`), and a draw source, and returns the records the
creator built -- in the order the pool receives them, so the capture's first
twelve are the first twelve here.

``tools/blob_gold.py``'s ``native.creator_program_*`` checks replay each one
against the records the engine actually left, field for field, from the
**measured** seed.  Nothing here is fitted: a wrong constant fails.

The three services every one of them reaches are the ones ``docs/28`` §7.4.2
measured -- ``0x0046D400`` (the direction, *not* normalised), ``0x00403AA0``
(the orientation) and ``0x0044AE10`` (the truncated 2D distance) -- so this is
built on top of a validated layer rather than beside one.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from . import eng3d

#: The constructor's argument order, as `blob_tables.BLOB_CTOR_STORES` reads it
#: out of the stores themselves.
FIELDS = ("model", "class_id", "x", "y", "z", "rot_x", "rot_y", "rot_z",
          "kind", "life", "vx", "vy", "vz", "aux", "delay")
#: The two classes the constructor does **not** look a model up for.
MODELLESS = (2, 3)
#: `0x004FA524` -- the name buffer classes 2 and 3 pass and the constructor
#: ignores, `blob_tables.BLOB_NAME_SCRATCH`.
SCRATCH = "<scratch>"
#: The flat speed three creators multiply the direction service by.
SPARK_SPEED = 1600.0
#: `0x004B12D0` -- the blizzard shard's.
SHARD_SPEED = 1920.0
#: `0x004B12B0` -- the blue beam's dots carry this much velocity.
DOT_SPEED = 80.0
#: `0x004B12E0` and `0x004B12E8` -- the plasma beam orients one step further
#: out than it places, and its heads carry a much larger velocity.
HEAD_STEP = -3200.0
HEAD_SPEED = 4800.0
#: `0x004B1278` -- the spacing between the dots of a beam.  Negative, and the
#: creators **subtract**, which is the same double-negative the seeking arms
#: use (`docs/28` §7.7.1).
BEAM_STEP = -2400.0
#: The beam's own length: `(max(|dx|, |dy|) - 0x0C80) / 0x0960` over the two
#: symbol objects, truncated toward zero as a signed C divide.
BEAM_BASE = 0xC80
BEAM_UNIT = 0x960
#: `0x004B1298` / `0x004B12A0` -- how far apart the two tracers are placed,
#: and `0x004B12A8` / `0x004B12B0` for the casings' sideways speed.  Both are
#: **perpendicular**: the x term reads the y ratio and the y term the x.
TRACER_SPREAD = 640.0
TRACER_LEAN = 200
CASING_SPEED = 80.0
#: The smoke trail's own spacing: `0x004B12C0` and a ring every `0x3C0`.
TRAIL_STEP = -960.0
TRAIL_UNIT = 0x3C0


def _beam_length(inputs: "Inputs") -> int:
    span = max(abs(inputs.source[0] - inputs.target[0]),
               abs(inputs.source[1] - inputs.target[1]))
    value = span - BEAM_BASE
    return -((-value) // BEAM_UNIT) if value < 0 else value // BEAM_UNIT


def _step(source: Tuple[int, int, int], d: Sequence[float], index: int,
          scale: float) -> Tuple[int, int, int]:
    """`source - ftol(index * d * scale)`, per axis."""
    return (source[0] - ftol(index * d[0] * scale),
            source[1] - ftol(index * d[1] * scale),
            source[2] - ftol(index * d[2] * scale))


def ftol(value: float) -> int:
    """`_ftol` `0x004AE7B6`, for a value a creator is known to keep in range."""
    return int(value)


def trunc_div(value: int, divisor: int) -> int:
    """A signed C divide: toward zero, which Python's `//` is not."""
    quotient = abs(value) // abs(divisor)
    return -quotient if (value < 0) != (divisor < 0) else quotient


@dataclass
class Inputs:
    """What a creator reads before it draws: `docs/97` §22.

    Every one of the ten opens the same way -- the tile through
    `aGetCtrlMapElementPtr`, the cell's `+5` through `aGetSymbolObjectPtr` for
    the **placed object**, the cell's `+7` through the unit map and
    `0x0047AD30` for a height -- so the whole of that prologue is three
    numbers per tile.  They are *measured*, by the `origins` phase, and the
    object's coordinates are the record's own `+0x10/+0x14/+0x18` rather than
    `aGetStdObjectPosition`'s answer, which is not the same number.
    """

    source: Tuple[int, int, int]
    source_height: int
    target: Tuple[int, int, int]
    target_height: int
    models: Dict[str, int]
    tables: Any
    #: The low byte of the target cell's unit id, which one creator stores as
    #: the record's `aux` -- the field a seeking arm reads back as a unit-map
    #: slot (`docs/28` §7.7.1).
    target_unit: int = 0

    def handle(self, name: str, class_id: int) -> int:
        if class_id in MODELLESS:
            return -1
        return self.models.get(name, -1)


class Draws:
    """`0x004638E0` -- the uncounted twin of `aRandom`, `docs/22` §3.2."""

    def __init__(self, seed: float) -> None:
        from .rng import ARandom
        self._rng = ARandom(seed)
        self.count = 0

    def __call__(self, base: int, span: int) -> int:
        self.count += 1
        return ftol(base + span * self._rng.raw(0, 1))

    def biased(self, base: int, span: int, addend: int) -> int:
        """A draw with a term added **before** the conversion.

        `0x00429A80` does `call 0x004638E0 / fadd qword [esp+0x2C] / _ftol`,
        where the addend is the ring counter converted with `fild`.  Adding
        it after the truncation gives a different number whenever the
        fraction and the addend cross an integer, so the order is part of the
        mechanism rather than an implementation detail.
        """
        self.count += 1
        return ftol(base + span * self._rng.raw(0, 1) + addend)

    def raw(self) -> float:
        self.count += 1
        return self._rng.raw(0, 1)


class Pool:
    """The records a creator leaves, in the order `0x00420950` fills them."""

    def __init__(self, inputs: Inputs) -> None:
        self.inputs = inputs
        self.records: List[Dict[str, int]] = []
        #: How many records the constructor refused for a zero `life`.
        self.refused = 0

    def spawn(self, name: str, class_id: int, x: int, y: int, z: int,
              rot_x: int, rot_y: int, rot_z: int, kind: int, life: int,
              vx: int, vy: int, vz: int, aux: int, delay: int) -> None:
        # **A record with no life is dropped, silently.**  `0x00420950` opens
        # `mov al, [esp+0x28] / test al, al / je` -- the tenth argument is
        # `life`, and a zero there returns before a slot is even looked for.
        # `0x00427810`'s three heads take `(count & 0xFF) >> 1` for their
        # life, which is 0 for a short beam, so the pool the capture read
        # starts with that creator's *second* loop.  The draws still happen:
        # the refusal is inside the constructor, past them.
        if life & 0xFF == 0:
            self.refused += 1
            return
        self.records.append({
            "model": self.inputs.handle(name, class_id),
            "class_id": class_id, "x": x, "y": y, "z": z,
            "rot_x": rot_x & 0xFFFF, "rot_y": rot_y & 0xFFFF,
            "rot_z": rot_z & 0xFFFF,
            "kind": kind & 0xFF, "life": life & 0xFF,
            "vx": vx, "vy": vy, "vz": vz,
            "aux": aux & 0xFF, "delay": delay & 0xFF,
        })


#: `creator -> (arity, program)`.  The arity is the one `blob_tables`'
#: `creators.arity_table` pins, repeated here so a program cannot be written
#: against a signature the binary does not have.
PROGRAMS: Dict[int, Tuple[int, Callable[..., None]]] = {}


def program(address: int, arity: int
            ) -> Callable[[Callable[..., None]], Callable[..., None]]:
    def register(fn: Callable[..., None]) -> Callable[..., None]:
        PROGRAMS[address] = (arity, fn)
        return fn
    return register


# --------------------------------------------------------------------------
# The programs
# --------------------------------------------------------------------------

@program(0x0042A9D0, 4)
def _c0042A9D0(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateSparks`: one emitter, then fifty sparks along a ray.

    It takes a **position**, not a tile, so it reads nothing before it draws.
    Each spark aims at a point scattered around the origin and takes its
    velocity from the direction service scaled by a flat 1600 -- which is why
    every one of its records carries `|vx|` or `|vy|` of exactly 1600
    (`docs/28` §7.6.1).
    """
    x, y, z, delay = args
    pool.spawn(SCRATCH, 2, x, y, z, 5, 0, 0, 0x33, 0x10, 0, 0, 0, 0x28, delay)
    for _ in range(0x32):
        dx = draw(-0x3200, 0x6400)
        dy = draw(-0x3200, 0x6400)
        dz = draw(-0xC80, 0x2580)
        aim = (x + dx, y + dy, z + dz)
        d = eng3d.direction_vector((x, y, z), aim, 1)
        pitch, yaw = pool.inputs.tables.orient((x, y, z), aim)
        life = draw(4, 0xF)
        pool.spawn("A_SPARK.3DI", 0, x, y, z, pitch, 0, yaw, 0x22, life,
                   ftol(d[0] * SPARK_SPEED), ftol(d[1] * SPARK_SPEED),
                   ftol(d[2] * SPARK_SPEED), 0, delay)


@program(0x0042AF10, 2)
def _c0042AF10(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateBlizzardHit`: a flash and two tumbling shards.

    The three rotation draws reach the constructor in the **reverse** of the
    order they were taken, because MSVC evaluates arguments right to left --
    the same effect `docs/28` §7.6.1 pins for the two solved recipes.
    """
    x, y, _z = pool.inputs.source
    z = pool.inputs.source_height + _z
    pool.spawn("A_PLSMA1.3DI", 0, x, y, z, 0, 0, 0, 8, 0xA, 0, 0, 0, 0, 0)
    for _ in range(2):
        rot_z = draw(0, 0xFFF)
        rot_y = draw(0, 0xFFF)
        rot_x = draw(0, 0xFFF)
        pool.spawn("A_BLIZ01.3DI", 0, x, y, z, rot_x, rot_y, rot_z,
                   8, 0x14, 0, 0, 0, 0, 3)


@program(0x00429A80, 3)
def _c00429A80(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateSmokeColumn`: nine rings of three, rising 0x3C0 a ring.

    The `delay` is the ring index, which is the stagger `docs/28` §7.6.1 names
    as "the loop counter" -- and the rotation word is a **flag** that turns on
    at the fifth ring, not a draw.  `aux` is a third shape again: a draw with
    the ring's own height counter **added inside the conversion**, which is
    why fitting it as a plain `aRandom2(base, span)` was hopeless from the
    fourth record on.
    """
    x, y, z = pool.inputs.source
    step = 0
    ring = 0
    while step <= 0x11:
        for _ in range(3):
            dx = draw(-0x640, 0xC80)
            dy = draw(-0x640, 0xC80)
            dz = draw(0, 0x640)
            aux = draw.biased(5, 0xF, step)
            pool.spawn(SCRATCH, 2, x + dx, y + dy, z + dz,
                       0 if step < 10 else 2, 0, 0,
                       0x32, 8, 0, 0, 0, aux, ring)
        step += 2
        ring += 1
        z += 0x3C0


@program(0x00429180, 4)
def _c00429180(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateLineFire`: `arg3` streaks, each with its own speed.

    Its velocity is **not** a draw and not a fixed speed either: a speed is
    drawn per axis and multiplied by the direction service's answer, which is
    a third shape and the reason no per-record recipe fitted it.
    """
    x, y, z = pool.inputs.source
    for _ in range(args[2] & 0xFF):
        dx = draw(-0xA0, 0x140)
        dy = draw(-0xA0, 0x140)
        dz = draw(0x280, 0x280)
        aim = (x + dx, y + dy, z + dz)
        d = eng3d.direction_vector((x, y, z), aim, 1)
        pitch, yaw = pool.inputs.tables.orient((x, y, z), aim)
        delay = draw(0, 4)
        vz = ftol(draw(0xA0, 0xA0) * d[2])
        vy = ftol(draw(0x1E0, 0x140) * d[1])
        vx = ftol(draw(0x1E0, 0x140) * d[0])
        pool.spawn("A_LINE6.3DI", 0, x, y, z, pitch, 0, yaw, 0x48,
                   draw(0xA, 0xF), vx, vy, vz, 0, delay)


@program(0x004264A0, 5)
def _c004264A0(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateBlizzardShot`: two seeking shards, one behind the other.

    Three shapes in one call, which is why no single recipe fitted it: the
    **name** is chosen by a draw compared as a float *before* the truncation,
    the aim is scattered by two draws that are thrown away when the two tiles
    are close, and the velocity is the direction service scaled by 1920.
    `delay` is the record index.
    """
    inputs = pool.inputs
    x, y, z = inputs.source[0], inputs.source[1], \
        inputs.source[2] + inputs.source_height
    off_x = draw(-0xC80, 0xC80)
    off_y = draw(-0x1F40, 0x1F40)
    if eng3d.distance_2d(args[2] - args[0], args[3] - args[1]) < 6:
        off_x = off_y = 0
    aim = (inputs.target[0] + off_x, inputs.target[1] + off_y,
           inputs.target[2])
    d = eng3d.direction_vector((x, y, z), aim, 1)
    name = "A_BLIZ03.3DI" if draw.raw() * 10 <= 5.0 else "A_BLIZ02.3DI"
    for index in range(2):
        pool.spawn(name, 0, x, y, z, 0, 0, 0, 0x3D, 0x64,
                   ftol(d[0] * SHARD_SPEED), ftol(d[1] * SHARD_SPEED),
                   ftol(d[2] * SHARD_SPEED), inputs.target_unit, index)


@program(0x00426F90, 4)
def _c00426F90(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateLaserGreen`: sparks at the target, then a dotted beam.

    It **calls another creator** -- `0x0042A9D0` at the target -- before it
    places anything of its own, so its draw stream is that creator's for the
    first two hundred draws.  That alone defeats a per-record fit, and it is
    also why the capture's twelve records are all sparks: the beam is behind
    fifty of them in the pool.

    The beam's length is not drawn either.  It is
    `(max(|dx|, |dy|) - 0x0C80) / 0x0960` over the two symbol objects, and the
    dots sit `2400` apart along the direction service's answer.
    """
    inputs = pool.inputs
    source = (inputs.source[0], inputs.source[1],
              inputs.source[2] + inputs.source_height)
    tx, ty, tz = inputs.target
    z = inputs.target_height + tz
    PROGRAMS[0x0042A9D0][1](pool, draw, (tx, ty, z + 800, 0))
    d = eng3d.direction_vector(source, (tx, ty, z), 1)
    count = _beam_length(inputs)
    if count == 0:
        count = -1
    pitch, yaw = inputs.tables.orient(source, _step(source, d, 1, BEAM_STEP))
    for index in range(count + 1):
        at = _step(source, d, index, BEAM_STEP)
        pool.spawn("A_LASERG.3DI", 0, at[0], at[1], at[2], pitch, 0, yaw,
                   1, 4, 0, 0, 0, 0, 0)


@program(0x00427410, 4)
def _c00427410(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateBlueLaser`: the same beam, aimed at a scattered point.

    Three draws, then `0x0042A9D0` at the scattered aim, then a beam whose
    dots also carry a velocity -- the direction scaled by 80 -- where the
    green one's are still.
    """
    inputs = pool.inputs
    source = (inputs.source[0], inputs.source[1],
              inputs.source[2] + inputs.source_height)
    dx = draw(-600, 0x4B0)
    dy = draw(-600, 0x4B0)
    dz = draw(-600, 0x4B0)
    aim = (inputs.target[0] + dx, inputs.target[1] + dy,
           inputs.target_height + inputs.target[2] + dz)
    PROGRAMS[0x0042A9D0][1](pool, draw, (aim[0], aim[1], aim[2], 0))
    d = eng3d.direction_vector(source, aim, 1)
    count = _beam_length(inputs)
    pitch, yaw = inputs.tables.orient(source, _step(source, d, 1, BEAM_STEP))
    for index in range(1, count + 2):
        at = _step(source, d, index, BEAM_STEP)
        pool.spawn("A_BLASER.3DI", 0, at[0], at[1], at[2], pitch, 0, yaw,
                   0x26, 5, ftol(d[0] * DOT_SPEED), ftol(d[1] * DOT_SPEED),
                   ftol(d[2] * DOT_SPEED), 0, 0)


@program(0x00427810, 4)
def _c00427810(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreatePlasmaBeam`: three plasma heads, then a trail of pairs.

    Two loops with different laws is the whole reason this one had no recipe:
    the first three records all sit at one point and differ only in `delay`,
    the trail spaces itself by the loop counter, and every record's `rot_y` is
    a draw while `rot_x` and `rot_z` are the orientation's -- so the draw
    stream advances once per record in one loop and twice in the other.
    """
    inputs = pool.inputs
    source = (inputs.source[0], inputs.source[1],
              inputs.source[2] + inputs.source_height)
    aim = (inputs.target[0], inputs.target[1],
           inputs.target[2] + inputs.target_height)
    d = eng3d.direction_vector(source, aim, 1)
    span = max(abs(inputs.source[0] - inputs.target[0]),
               abs(inputs.source[1] - inputs.target[1]))
    count = (span - BEAM_UNIT) // BEAM_UNIT
    pitch, yaw = inputs.tables.orient(source, _step(source, d, 1, HEAD_STEP))
    head = _step(source, d, 1, BEAM_STEP)
    for index in range(3):
        rot_y = draw(0, 0x1000)
        pool.spawn("A_PLSMA1.3DI", 0, head[0], head[1], head[2],
                   pitch, rot_y, yaw, 1, (count & 0xFF) >> 1,
                   ftol(d[0] * HEAD_SPEED), ftol(d[1] * HEAD_SPEED),
                   ftol(d[2] * HEAD_SPEED), 0, index * 5)
    for index in range(1, count + 2):
        at = _step(source, d, index, BEAM_STEP)
        for name in ("A_BLIZ02.3DI", "A_BLIZ03.3DI"):
            rot_y = draw(0, 0x1000)
            pool.spawn(name, 0, at[0], at[1], at[2], pitch, rot_y, yaw,
                       0xC, 10, 0, 0, 0, 0, 0)


@program(0x00425810, 6)
def _c00425810(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateSmokeTrail`: rings of six along the line of fire.

    `docs/28` §7.6.1 already had this creator's **velocities** as a recipe --
    three draws of `(-320, 640)` per record -- and its positions as the
    residue.  They are not draws at all: each record sits at the ring's point
    on the line **plus its own velocity**, so the same three numbers appear
    twice, once as a displacement and once as a speed.  `delay` is the ring
    index over four.
    """
    inputs = pool.inputs
    source = (inputs.source[0], inputs.source[1],
              inputs.source[2] + inputs.source_height)
    aim = (inputs.target[0], inputs.target[1],
           inputs.target[2] + inputs.target_height)
    span = max(abs(inputs.source[0] - inputs.target[0]),
               abs(inputs.source[1] - inputs.target[1]))
    d = eng3d.direction_vector(source, aim, 1)
    count = (span - BEAM_BASE) // TRAIL_UNIT + 1
    for ring in range(count + 1):
        at = _step(source, d, ring, TRAIL_STEP)
        for _ in range(6):
            vx = draw(-0x140, 0x280)
            vy = draw(-0x140, 0x280)
            vz = draw(-0x140, 0x280)
            pool.spawn(SCRATCH, 2, at[0] + vx, at[1] + vy, at[2] + vz,
                       6, 0, 0, 0x2E, 8, vx, vy, vz, 5, ring >> 2)


@program(0x00424D20, 4)
def _c00424D20(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateMachineGun`: five bursts of tracer, casings and smoke.

    The hardest of the ten, and every one of its shapes is a different one:

    * the **delta** is a draw *minus* the direction service scaled by 2400, so
      each burst leaves along the line of fire with a small scatter -- two
      numbers per axis where a fit was looking for one;
    * the two tracers are placed **perpendicular** to that line, 400 apart:
      `x` takes the horizontal ratio scaled by 640 while `y` takes the other
      one, and the second record swaps the sign.  An axis-by-axis recipe
      cannot express a term that reads a *different* axis' ratio;
    * the two casings fly perpendicular too, at 80, and only their vertical is
      drawn -- `aRandom2(0, 0xA0) + 0x140`;
    * and each burst ends by calling **another creator**, `0x00423720`, whose
      `life` is the burst index.  Burst 0 therefore creates nothing: the
      constructor drops a record with no life, which is why the pool's
      first smoke puff belongs to burst 1.
    """
    inputs = pool.inputs
    x, y, z = inputs.source[0], inputs.source[1], \
        inputs.source[2] + inputs.source_height
    aim = (inputs.target[0], inputs.target[1],
           inputs.target[2] + inputs.target_height)
    d = eng3d.direction_vector((x, y, z), aim, 1)
    span = max(abs(inputs.source[0] - inputs.target[0]),
               abs(inputs.source[1] - inputs.target[1]))
    length = span // BEAM_UNIT
    if length < 1:
        length = 0
    for burst in range(5):
        dx = draw(-200, 400) - ftol(d[0] * BEAM_STEP)
        dy = draw(-200, 400) - ftol(d[1] * BEAM_STEP)
        dz = draw(-100, 200) - ftol(d[2] * BEAM_STEP)
        pitch, yaw = inputs.tables.orient(
            (x, y, z), (x + dx * 5, y + dy * 5, z + dz * 5))
        if length:
            # The pair is written out rather than looped with a sign: the
            # second record does not negate the first, it **exchanges** the
            # two terms, so `x` moves from "the scaled ratio minus the leaned
            # one" to "the leaned one minus the scaled".
            pool.spawn("A_LINE5.3DI", 0,
                       x + ftol(d[0] * TRACER_SPREAD)
                       - TRACER_LEAN * ftol(d[1]),
                       y + TRACER_LEAN * ftol(d[0])
                       - ftol(d[1] * -TRACER_SPREAD),
                       z, pitch, 0, yaw, 0xF, length, dx, dy, dz, 0, burst)
            pool.spawn("A_LINE5.3DI", 0,
                       x + TRACER_LEAN * ftol(d[1])
                       - ftol(d[0] * -TRACER_SPREAD),
                       y + ftol(d[1] * TRACER_SPREAD)
                       - TRACER_LEAN * ftol(d[0]),
                       z, pitch, 0, yaw, 0xF, length, dx, dy, dz, 0, burst)
        for sign in (1, -1):
            vz = draw(0, 0xA0) + 0x140
            pool.spawn("A_CASE.3DI", 0, x - trunc_div(dx, 3),
                       y - trunc_div(dy, 3), z - dz, pitch, 0, yaw,
                       0xB, 0x14,
                       ftol(d[1] * sign * CASING_SPEED),
                       ftol(d[0] * -sign * CASING_SPEED), vz, 0, burst)
        # `0x00423720`, whose whole body is one constructor call.
        pool.spawn(SCRATCH, 2, x + trunc_div(dx, 5), y + trunc_div(dy, 5),
                   z + trunc_div(dz, 5), 0, 0, 0, 0x32, burst,
                   0, 0, 0, 10, 0)
