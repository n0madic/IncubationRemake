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
# Every number below is at a named address in `Incubation.exe`, and
# `blob_tables.CREATOR_CONSTANT_SITES` reads each one back out of the shipped
# executable -- the doubles from the constant block, the subtracted
# immediates from their own instructions, the two divisors by replaying the
# reciprocal multiply the compiler left instead of them.  That check needs no
# capture, which matters: `blob_gold.native.creator_constants_discriminated`
# measures that the capture tells only seven of the thirteen apart from a
# neighbour, and a constant no captured record exercises would otherwise be
# checked by nothing at all.  The two claims are different and both are made.

#: `0x004B12B8` -- the flat speed three creators multiply the direction
#: service by.
SPARK_SPEED = 1600.0
#: `0x004B12D0` -- the blizzard shard's.
SHARD_SPEED = 1920.0
#: `0x004B12B0` -- the blue beam's dots carry this much velocity.  The **same
#: cell** as the positive half of `CASING_SPEED`: thirteen names here stand
#: over twelve distinct cells, and one cell is read by two creators.
DOT_SPEED = 80.0
#: `0x004B12E0` and `0x004B12E8` -- the plasma beam orients one step further
#: out than it places, and its heads carry a much larger velocity.  `HEAD_STEP`
#: reaches a *quantised* answer -- it only ever feeds the orientation service,
#: whose result is in 4096ths of a circle -- so no capture will ever tell it
#: from a neighbouring value; the address is the whole of the evidence.
HEAD_STEP = -3200.0
HEAD_SPEED = 4800.0
#: `0x004B1278` -- the spacing between the dots of a beam.  Negative, and the
#: creators **subtract**, which is the same double-negative the seeking arms
#: use (`docs/28` §7.7.1).
BEAM_STEP = -2400.0
#: The beam's own length: `(max(|dx|, |dy|) - 0x0C80) / 0x0960` over the two
#: symbol objects, truncated toward zero as a signed C divide.  Neither number
#: is an immediate everywhere: `0x004272A0`'s `lea ecx, [eax - 0xC80]` holds
#: the first, while the divide is `mov eax, 0x1B4E81B5 / imul / sar edx, 8`
#: -- there is no `0x960` in those bytes at all, and the check recovers it by
#: replaying the multiply rather than by recognising a magic.
BEAM_BASE = 0xC80
BEAM_UNIT = 0x960
#: The machine gun's tracers and casings, and the only place in these ten
#: where a coordinate is built from a **different axis'** ratio: the x term
#: reads the y ratio and the y term the x.  That mapping is *read*, not
#: matched -- `0x00424FC6` hands the direction service out-pointers at
#: `S+0x20`, `S+0x28` and `S+0x38` off one settled frame, and each term's
#: `fld qword [esp+disp]` minus the stack depth there names its component.
#: `blob_tables.TRACER_AXIS_TERMS` carries the eight terms with their sites,
#: and checks that the two records exchange their spread cells rather than
#: negating them.  `TRACER_SPREAD` is `0x004B1298`/`0x004B12A0`,
#: `CASING_SPEED` `0x004B12A8`/`0x004B12B0`, and `TRACER_LEAN` is not a cell
#: at all: it is `lea`/`lea`/`shl` over a `sar`, `5 * 5 * 32 >> 2`.
TRACER_SPREAD = 640.0
TRACER_LEAN = 200
CASING_SPEED = 80.0
#: The smoke trail's own spacing: `0x004B12C0`, and a ring every `0x3C0` --
#: the second again a reciprocal multiply (`0x88888889`, `sar edx, 9`) rather
#: than a literal.
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
    """`_ftol` `0x004AE7B6` -- :func:`inclib.eng3d.ftol`.

    Not `int(value)`: two creators can hand it a NaN or an infinity.
    `_c00428990` does when its direction falls through
    `LASER_DIRECTIONS`' `(0, 0)` default, which makes the target the source,
    and `_c0042A8E0` does when source and target share a column.  The engine
    answers **zero** there and `int()` raises.
    """
    return eng3d.ftol(value)


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
        # **And so is a class-0 or class-1 record whose model does not
        # resolve.**  `0x00420950` looks the name up through `0x004038F0`
        # and returns before a slot is found when the answer is negative
        # (`docs/28` §7.5) -- which is how `aBlob_CreateFlyingUnit` on a
        # unit whose type's `.3DI` the set does not carry spawns nothing.
        model = self.inputs.handle(name, class_id)
        if class_id not in MODELLESS and model < 0:
            self.refused += 1
            return
        self.records.append({
            "model": model,
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
    """`aBlob_CreateFireExplosion` (`blob_tables`' name table, `0x0040CCE5`):
    nine rings of three, rising 0x3C0 a ring.  The fight's death switch
    calls it on species 3 and on a class-0x0C barrel (`docs/42` §4.8), the
    impact switch on three weapons.  Its third argument is pushed by every
    caller and read by none -- the routine's own frame names two.

    The `delay` is the ring index, which is the stagger `docs/28` §7.6.1 names
    as "the loop counter" -- and the rotation word is a **flag** that turns on
    at the fifth ring, not a draw.  `aux` is a third shape again: a draw with
    the ring's own height counter **added inside the conversion**, which is
    why fitting it as a plain `aRandom2(base, span)` was hopeless from the
    fourth record on.
    """
    _fire_explosion_at(pool, draw, pool.inputs.source)


def _fire_explosion_at(pool: Pool, draw: Draws, at: Tuple[int, int, int]) -> None:
    """The ring loop of `aBlob_CreateFireExplosion`, from a position."""
    x, y, z = at
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
      one, and the second record *exchanges* the two cells.  An axis-by-axis
      recipe cannot express a term that reads a *different* axis' ratio.
      Which component each term reads is **read off the stack** and not
      inferred from the records it produced: the frame settles to one
      baseline after `0x004250E5`, the direction service's three out-slots
      sit at `+0x20`, `+0x28` and `+0x38` from it, and every term's
      `fld qword [esp+disp]` minus the depth at that instruction lands on one
      of them.  `blob_tables.TRACER_AXIS_TERMS` pins all eight;
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


# --------------------------------------------------------------------------
# The death and damage creators -- `docs/42` §4.8
# --------------------------------------------------------------------------
#
# A second registry, kept apart from `PROGRAMS` because these creators are
# not reached by the weapon switches `blob_gold` captures: they are what
# `aPlayFightAnimation` calls per floating-text entry when a unit is hurt or
# killed, and `tools/presentation_gold.py`'s `deaths` phases capture them
# with controlled tiles and a written seed.  Four of the seven carry no
# developer name anywhere in the binary (`blob_tables.BLOB_CREATOR_NAMES`
# lists them as `None`); the names used here are this project's, chosen
# from what the code does, and are marked as such in the docs.
#
# Every one of them reads the **gore level** first -- `0x004604A0` returns
# dword 10 of `Game.opt` (`0x00512A00`, `docs/20` §8, written by the LCL
# `?_` command) -- and at level 1, or at level 2 for a unit that is not the
# computer's (`+0x45 != 0xFF`), replaces its blood with one class-2 puff
# (`0x004297F0`).  That is what the option is; `docs/20` had it as a
# "unit-drawing path".

#: `0x004B1248`, `0x004B1250`, `0x004B1258`, `0x004B1260` -- the four doubles
#: the two blood sprays scale the direction service by: the horizontal
#: velocity term, the vertical one, the placement step back along the line
#: (negative, and subtracted, so the blood starts *toward* the source), and
#: the larger spray's horizontal term.
BLOOD_VELOCITY = 16.0
BLOOD_VELOCITY_LARGE = 48.0
BLOOD_LIFT = 160.0
BLOOD_STEP = -1280.0
#: `0x004B1268` -- the species death's coin: `aRandom2(0, 10) <= 6.0` takes
#: the species branch, compared as a double before any truncation.
SPECIES_COIN = 6.0


class Death:
    """The small integers the death creators branch on -- ids and levels,
    not measured magnitudes, so they are not module constants for
    `blob_tables.creators.constant_sites_cover_module` to inventory."""

    #: The gore levels, `docs/20` §8.
    GORE_NONE, GORE_COMPUTER_ONLY, GORE_FULL = 1, 2, 3
    #: `0x0047AD70` -- a unit's full height: the type's height byte times 160.
    HEIGHT_UNIT = 0xA0
    #: The output-system mode id the debris creator reads (`0x00461E80`,
    #: `docs/97` §23.3); only mode 3 gets the long debris loop.
    DEBRIS_FULL_MODE = 3


#: The types with their own death models (`A_50A/B/C`, `A_51A/B/C`,
#: `A_56A/B/C`); type 57's arm (`A_57A`, repeated four times) is in the
#: switch but not in this set, so it is dead code.
SPECIES_MODELS = {
    50: ("A_50A.3DI", "A_50B.3DI", "A_50C.3DI"),
    51: ("A_51A.3DI", "A_51B.3DI", "A_51C.3DI"),
    56: ("A_56A.3DI", "A_56B.3DI", "A_56C.3DI"),
}
SPECIES_TYPES = frozenset(SPECIES_MODELS)
SPLATS = ("A_SPLAT1.3DI", "A_SPLAT2.3DI", "A_SPLAT3.3DI", "A_SPLAT4.3DI", "A_SPLAT5.3DI")
#: The four blood pieces that trail a splat or a species piece, in order.
BLOOD_TRAIL = ("A_BLUT1.3DI", "A_BLUT1.3DI", "A_BLUT2.3DI", "A_BLUT3.3DI")


@dataclass
class DeathUnit:
    type_id: int
    player: int
    height: int


@dataclass
class DeathInputs:
    """What a death creator reads before it draws.

    `tiles` maps a tile to the **symbol** object's own `+0x10/+0x14/+0x18`
    (`docs/97` §22: `aGetSymbolObjectPtr`, not the standard object) and to
    the unit standing there, if any, with the height `0x0047AD70` answers
    for it.  `gore` is `0x00512A00`, `display_mode` is `0x00512A78`, and
    `models` is `0x004038F0`'s answer per model name -- all measured in the
    same process the creator ran in.
    """

    tiles: Dict[Tuple[int, int], Tuple[Tuple[int, int, int], Optional[DeathUnit]]]
    gore: int
    display_mode: int
    models: Dict[str, int]
    #: `unitInfo[type] + 0x6C` -- the type's own `.3DI` name (`docs/21` §2),
    #: which `aBlob_CreateFlyingUnit` hands the constructor as the model.
    type_models: Dict[int, str] = field(default_factory=dict)
    #: `0x004039A0` and `0x00403AA0`, for the ring creators of `docs/42` §7:
    #: an :class:`inclib.eng3d.Tables`, or `None` for a program that needs
    #: neither.
    tables: Any = None
    #: `unitInfo[type] + 0x7B` per type, for the radius the ring creators pick.
    sizes: Dict[int, int] = field(default_factory=dict)

    def large(self, unit: "DeathUnit") -> bool:
        return self.sizes.get(unit.type_id, 0) == 1

    def handle(self, name: str, class_id: int) -> int:
        if class_id in MODELLESS:
            return -1
        return self.models.get(name, -1)

    def object(self, x: int, y: int) -> Tuple[int, int, int]:
        return self.tiles[(x, y)][0]

    def unit(self, x: int, y: int) -> Optional[DeathUnit]:
        return self.tiles[(x, y)][1]


DEATH_PROGRAMS: Dict[int, Tuple[int, Callable[..., None]]] = {}


def death_program(address: int, arity: int
                  ) -> Callable[[Callable[..., None]], Callable[..., None]]:
    def register(fn: Callable[..., None]) -> Callable[..., None]:
        DEATH_PROGRAMS[address] = (arity, fn)
        return fn
    return register


def _puff(pool: Pool, draw: Draws, at: Tuple[int, int, int]) -> None:
    """`0x004297F0` -- the bloodless substitute: one class-2 record, kind
    59, life 20, drifting sideways.  Named `death_puff` by this project."""
    aux = draw(5, 0x14)
    vy = draw(-1000, 2000)
    vx = draw(-1000, 2000)
    pool.spawn(SCRATCH, 2, at[0], at[1], at[2], 1, 0, 0, 0x3B, 0x14, vx, vy, 0, aux, 0)


@death_program(0x004297F0, 2)
def _c004297F0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    x, y = args
    _puff(pool, draw, inputs.object(x, y))


def _gore_substitutes(inputs: DeathInputs, unit: DeathUnit) -> bool:
    """Level 2 keeps the blood for the computer's units only."""
    return inputs.gore == Death.GORE_COMPUTER_ONLY and unit.player != 0xFF


@death_program(0x00420B80, 2)
def _c00420B80(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`death_blood_burst` (no developer name): fifteen pairs of `A_BLUT4`
    rising from the unit's tile, kinds 17 and 43, paired by the `delay`
    they share -- the severity-3 death of a unit of species 1."""
    x, y = args
    if inputs.gore == Death.GORE_NONE:
        _puff(pool, draw, inputs.object(x, y))
        return
    unit = inputs.unit(x, y)
    if unit is None:
        return
    if _gore_substitutes(inputs, unit):
        _puff(pool, draw, inputs.object(x, y))
        return
    ox, oy, oz = inputs.object(x, y)
    for i in range(15):
        vz = draw(500, 500)
        delay = (i >> 1) & 0x7F
        vy = draw(0, 100)
        vx = draw(0, 100)
        dz = draw(0, 0x960)
        pool.spawn("A_BLUT4.3DI", 0, ox, oy, oz + dz, 0, 0, 0, 0x11, 0xF, vx, vy, vz, 0, delay)
        vz += 0x640
        vy = draw(0, 100)
        vx = draw(0, 100)
        dz = draw(0, 0x960)
        pool.spawn("A_BLUT4.3DI", 0, ox, oy, oz + dz, 0, 0, 0, 0x2B, 0xF, vx, vy, vz, 0, delay)


@death_program(0x004298D0, 2)
def _c004298D0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`death_barrel_burst` (no developer name): ten tumbling `A_BDEBI1` /
    `A_BDEBI0` pieces, kind 5, life 100, from the object's own position --
    the class-0x0D death that `aPlayFightAnimation` pairs with
    `aBlob_CreateFlyingUnit`'s class-0x0C one."""
    x, y = args
    ox, oy, oz = inputs.object(x, y)
    for i in range(10):
        vx = draw(-500, 1000)
        vy = draw(-500, 1000)
        vz = draw(500, 500)
        name = "A_BDEBI1.3DI" if i % 2 == 0 else "A_BDEBI0.3DI"
        rot_z = draw(0, 0x1000)
        rot_y = draw(0, 0x1000)
        rot_x = draw(0, 0x1000)
        pool.spawn(name, 0, ox, oy, oz, rot_x, rot_y, rot_z, 5, 100, vx, vy, vz, 0, 0)


def _spray(pool: Pool, draw: Draws, inputs: DeathInputs,
           source: Tuple[int, int], target: Tuple[int, int], mode: int,
           *, large: bool) -> None:
    """The shared body of the two blood sprays.

    Both take the **target's** object as the origin and, in mode 0, the
    direction from the target (raised by half its unit's height) to the
    source, through `0x0046D400` with its shift flag; the horizontal terms
    are scaled by 16 (`aBlob_CreateBloodFlood`) or 48 (the large one) and
    the vertical one by 160, and every record starts `1280` along that
    direction.  Modes 1 and 2 leave the direction at zero: a burst on the
    spot, the second one scattered.  The named creator alone reads the gore
    level, per record, and switches the model and the spread on it.
    """
    tx, ty = target
    ox, oy, oz = inputs.object(tx, ty)
    unit = inputs.unit(tx, ty)
    if unit is None:
        return
    half = trunc_div(unit.height, 2)
    dx = dy = dz = 0.0
    d_x = d_y = d_z = 0
    if mode == 0:
        sx, sy, sz = inputs.object(source[0], source[1])
        dx, dy, dz = eng3d.direction_vector((ox, oy, oz + half), (sx, sy, sz + half), 1)
        scale = BLOOD_VELOCITY_LARGE if large else BLOOD_VELOCITY
        d_x, d_y, d_z = ftol(dx * scale), ftol(dy * scale), ftol(dz * BLOOD_LIFT)
        count, speed, zspan, scatter = (4, 100, 0xA0, 0) if large else (12, 20, 0xA0, 800)
    elif mode == 1:
        count, speed, zspan, scatter = 15, 400, 0x960, 0
    elif mode == 2:
        count, speed, zspan, scatter = 35, 400, 0x1900, 0x12C0
    else:
        return
    px, py = ox, oy
    for i in range(count):
        if scatter:
            px += draw(-scatter, 2 * scatter)
            py += draw(-scatter, 2 * scatter)
        if large:
            delay, aux = i // 2, 10
            vz = draw(100, speed) + d_z
            vy = draw(0, 100) + d_y
            vx = draw(0, 100) + d_x
            model, class_id, rot_x, kind, life = SCRATCH, 2, 1, 0x32, 8
        elif inputs.gore == Death.GORE_NONE or (inputs.gore == Death.GORE_COMPUTER_ONLY
                                           and unit.player != 0xFF):
            delay, aux = 0, draw(5, 10)
            vz = draw(100, speed) + d_z
            vy = draw(-200, 400) + d_y
            vx = draw(-200, 400) + d_x
            model, class_id, rot_x, kind, life = SCRATCH, 2, 5, 0x3C, 8
        elif inputs.gore == Death.GORE_COMPUTER_ONLY:
            delay, aux = i >> 1, 0
            vz = draw(100, speed) + d_z
            vy = draw(-200, 400) + d_y
            vx = draw(-200, 400) + d_x
            model, class_id, rot_x, kind, life = "A_BLUT4.3DI", 0, 0, 0x11, 8
        elif inputs.gore == Death.GORE_FULL:
            delay, aux = i >> 1, 0
            vz = draw(100, speed) + d_z
            vy = draw(0, 0x32) + d_y
            vx = draw(0, 0x32) + d_x
            model, class_id, rot_x, kind, life = "A_BLUT4.3DI", 0, 0, 0x11, 8
        else:
            continue
        z = draw(0, zspan) + oz + half
        y = py - ftol(dy * BLOOD_STEP)
        x = px - ftol(dx * BLOOD_STEP)
        pool.spawn(model, class_id, x, y, z, rot_x, 0, 0, kind, life, vx, vy, vz, aux, delay)


@death_program(0x00420D80, 5)
def _c00420D80(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateBloodFlood(sx, sy, tx, ty, mode)` -- the damage effect."""
    sx, sy, tx, ty, mode = args
    _spray(pool, draw, inputs, (sx, sy), (tx, ty), mode, large=False)


@death_program(0x00421360, 5)
def _c00421360(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`death_blood_spray_large` (no developer name): the same spray with
    kind 50, life 8, fewer records and three times the sideways velocity,
    the one `aPlayFightAnimation` uses for units flagged at `+0x7B`."""
    sx, sy, tx, ty, mode = args
    _spray(pool, draw, inputs, (sx, sy), (tx, ty), mode, large=True)


@death_program(0x004216D0, 2)
def _c004216D0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateFlyingDebris` (`aBlob_CreateSplatter` at one call site):
    splats thrown from the unit's tile, each trailed by four blood pieces
    (`A_BLUT1`, `A_BLUT1`, `A_BLUT2`, `A_BLUT3`) -- twelve throws in output
    mode 3, five otherwise, the splat model cycling `A_SPLAT1..5` -- then
    five lower splats with no trail."""
    x, y = args
    ox, oy, oz = inputs.object(x, y)
    unit = inputs.unit(x, y)
    if unit is None:
        return
    half = trunc_div(unit.height, 2)
    count = 12 if inputs.display_mode == Death.DEBRIS_FULL_MODE else 5
    for i in range(count):
        name = SPLATS[i % len(SPLATS)]
        vx = draw(-1000, 2000)
        vy = draw(-1000, 2000)
        vz = draw(-1000, 2000)
        dz = draw(0, 0xC80) + half
        delay = draw(0, 3)
        pool.spawn(name, 0, ox, oy, oz + dz, 0, 0, 0, 0x12, 0x32, vx, vy, vz + 500, 0, delay)
        for m in range(1, 5):
            pool.spawn(BLOOD_TRAIL[m - 1], 0, ox, oy, oz + dz, 0, 0, 0, 0x12, 0x1E,
                       vx, vy, vz + 500, 0, m)
    for i in range(5):
        name = SPLATS[i % len(SPLATS)]
        vx = draw(-0xFA, 500)
        vy = draw(-0xFA, 500)
        vz = draw(0, 500)
        dz = draw(0, 0xC80)
        delay = draw(0, 3)
        pool.spawn(name, 0, ox, oy, oz + half + dz, 0, 0, 0, 0x12, 0x1E, vx, vy, vz + 500, 0, delay)


@death_program(0x00421C50, 2)
def _c00421C50(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`death_species_burst` (no developer name): the severity-3 death of
    types 50, 51 and 56 -- seven times in ten two `A_SPLAT5`, two class-2
    bursts and the type's own three `A_50A/B/C`-style pieces each trailed
    by four `A_BLUT1/2/3`; otherwise, and for every other type, a mode-1
    `aBlob_CreateBloodFlood` and `aBlob_CreateFlyingDebris` on the tile."""
    x, y = args
    if inputs.gore == Death.GORE_NONE:
        _puff(pool, draw, inputs.object(x, y))
        return
    unit = inputs.unit(x, y)
    if unit is None:
        return
    if _gore_substitutes(inputs, unit):
        _puff(pool, draw, inputs.object(x, y))
        return
    if unit.type_id not in SPECIES_TYPES:
        _c00420D80(pool, draw, (x, y, x, y, 1), inputs)
        _c004216D0(pool, draw, (x, y), inputs)
        return
    coin = 10.0 * draw.raw()
    if coin > SPECIES_COIN:
        _c00420D80(pool, draw, (x, y, x, y, 1), inputs)
        _c004216D0(pool, draw, (x, y), inputs)
        return
    ox, oy, oz = inputs.object(x, y)
    half = trunc_div(unit.height, 2)
    for _ in range(2):
        delay = draw(0, 3)
        vz = draw(500, 1000) + 500
        vy = draw(500, 1000)
        vx = draw(500, 1000)
        pool.spawn("A_SPLAT5.3DI", 0, ox, oy, oz + half, 0, 0, 0, 0x12, 0x1E, vx, vy, vz, 0, delay)
    pool.spawn(SCRATCH, 2, ox, oy, oz + half, 7, 0, 0, 0x33, 0x10, 0, 0, 0, 0x19, 0)
    pool.spawn(SCRATCH, 2, ox, oy, oz + half + 500, 7, 0, 0, 0x33, 0x10, 0, 0, 0, 0x1E, 2)
    models = SPECIES_MODELS[unit.type_id]
    for j in range(4):
        if j >= len(models):
            continue
        name = models[j]
        vx2 = draw(-600, 0x4B0)
        vy2 = draw(-600, 0x4B0)
        vz = draw(500, 700)
        dz = draw(0, 0x640)
        vx, vy = trunc_div(vx2, 2), trunc_div(vy2, 2)
        pool.spawn(name, 0, ox, oy, oz + half + dz, 0, 0, 0, 0x12, 0x32, vx, vy, vz, 0, 0)
        for m in range(1, 5):
            pool.spawn(BLOOD_TRAIL[m - 1], 0, ox, oy, oz + half + dz, 0, 0, 0, 0x12, 0x1E,
                       vx, vy, vz, 0, m)


@death_program(0x00423AD0, 3)
def _c00423AD0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateKillFire(x, y, delay)`: ten class-2 flames, kind 10,
    life 20, scattered ±800 around the placed object on every axis, drifting
    ±48 sideways and rising 320..480, each delayed `aRandom2(0, 3)` frames
    **plus the third argument** -- 0 from the fight's death switch
    (`0x0040DCE2`, the class-0x10 `Bea'Coo`), 20 from `FireCircle`
    (`0x0041332C`).  The add is a byte add (`add al, [arg]`), which the
    constructor's own `delay & 0xFF` already reproduces.  Seven draws a
    flame, in the order velocity x, y, z, the delay, then z, y, x of the
    position."""
    x, y, delay_base = args
    ox, oy, oz = inputs.object(x, y)
    for _ in range(10):
        vx = draw(-0x30, 0x60)
        vy = draw(-0x30, 0x60)
        vz = draw(0x140, 0xA0)
        delay = draw(0, 3) + delay_base
        z = draw(-0x320, 0x640) + oz
        py = draw(-0x320, 0x640) + oy
        px = draw(-0x320, 0x640) + ox
        pool.spawn(SCRATCH, 2, px, py, z, 0, 0, 0, 0xA, 0x14, vx, vy, vz, 0x14, delay)


@death_program(0x0042B1D0, 2)
def _c0042B1D0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateFireDeath(x, y)`: a column of twenty class-2 records,
    kind 60, life 8, sprite row 4, stacked 20 units apart from the object's
    own height, each delayed by its index -- so the column burns upward one
    record a frame.  Velocity ±480 sideways and 160..1760 up, `aux`
    `aRandom2(5, 20)`; four draws a record.  The fight reaches it through
    death style 2, which only weapon 40's muzzle arm selects (`docs/42`
    §4.8)."""
    x, y = args
    ox, oy, oz = inputs.object(x, y)
    for i in range(20):
        vx = draw(-0x1E0, 0x3C0)
        vy = draw(-0x1E0, 0x3C0)
        vz = draw(0xA0, 0x640)
        aux = draw(5, 0x14)
        pool.spawn(SCRATCH, 2, ox, oy, oz + i * 20, 4, 0, 0, 0x3C, 8, vx, vy, vz, aux, i)


@death_program(0x00429700, 3)
def _c00429700(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateFlyingUnit(x, y, delay)`: **one** class-0 record whose
    model is the unit type's own `.3DI` (`unitInfo + 0x6C`, `docs/21` §2),
    kind 3, life 10, thrown straight up at 800 with no rotation and no draw,
    delayed by the argument -- the fight passes twice the type's size byte
    (`0x0040DB68`).  The barrel death of class 0x0C: the object itself
    leaves the cell, and `aBlob_CreateFireExplosion` follows it.  A type
    whose model the set does not carry spawns nothing, by the constructor's
    own refusal."""
    x, y, delay = args
    unit = inputs.unit(x, y)
    if unit is None:
        return
    ox, oy, oz = inputs.object(x, y)
    name = inputs.type_models.get(unit.type_id, "")
    pool.spawn(name, 0, ox, oy, oz, 0, 0, 0, 3, 0xA, 0, 0, 0x320, 0, delay)


@death_program(0x00429A80, 3)
def _c00429A80_death(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateFireExplosion(x, y, _)` as the death switch calls it: the
    same nine rings, from the tile's placed object.  The third argument is
    pushed and never read (`docs/42` §4.8)."""
    x, y, _unused = args
    _fire_explosion_at(pool, draw, inputs.object(x, y))


# --------------------------------------------------------------------------
# The unit animations' creators -- docs/42 §7: the selection marker, the
# jump's trail and dust, the push's dust, the two flash circles
# --------------------------------------------------------------------------

#: `0x00422D40` / `0x004232E0` -- the ring radius: 4800, or 9600 for a large
#: type (`unitInfo + 0x7B`).
RING_RADIUS = 0x12C0
RING_RADIUS_LARGE = 0x2580
#: `0x00423030` -- the heal flash's radius: 1600, or 6400 for a large type.
FLASH_RADIUS = 0x640
FLASH_RADIUS_LARGE = 0x1900
#: `0x004227C0` -- the landing dust's twenty puffs, 3200 out and turned 204
#: angle units (18 degrees) a puff, thrown at a third of the offset.
DUST_RADIUS = 0xC80
DUST_TURN = 0xCC
#: The heal flash's four crosses, in the order the index selects them
#: (`0x004232D0`'s jump table: 0 -> A_CROSS3).
CROSS_MODELS = ("A_CROSS3.3DI", "A_CROSS2.3DI", "A_CROSS1.3DI", "A_CROSS.3DI")


def _ring(inputs: DeathInputs, radius: int, turn: int, count: int
          ) -> List[Tuple[Tuple[int, int, int], Tuple[int, int, int]]]:
    """`count` offsets, each the previous one turned by `turn` through
    `0x004039A0` -- the rotation accumulates, so the ring is the engine's
    table arithmetic and not a clean division of the circle -- paired with
    the orientation `0x00403AA0` gives the line from the object to that
    point."""
    tables = inputs.tables
    offset = (radius, 0, 0)
    out = []
    for _ in range(count):
        offset = tables.rotate(offset, (0, 0, turn))
        out.append(offset)
    return out


@death_program(0x00422D40, 2)
def _c00422D40(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateArrowMarker` (this project's name for `0x00422D40`,
    docs/42 §7.3): four `A_ARROW.3DI` model blobs, kind 14, life 15, ninety
    degrees apart at a radius of 4800 -- 9600 for a large type -- around the
    unit's object, each oriented along the line from the object to itself,
    with the object's own x and y in `vx`/`vy` for kind 14's arm to turn them
    around.  No draw."""
    x, y = args
    unit = inputs.unit(x, y)
    if unit is None:
        return
    ox, oy, oz = inputs.object(x, y)
    radius = RING_RADIUS_LARGE if inputs.large(unit) else RING_RADIUS
    for dx, dy, dz in _ring(inputs, radius, 0x400, 4):
        pitch, yaw = inputs.tables.orient((ox, oy, oz), (ox + dx, oy + dy, oz))
        pool.spawn("A_ARROW.3DI", 0, ox + dx, oy + dy, oz, pitch, 0, yaw,
                   0xE, 0xF, ox, oy, 0, 0, 0)


@death_program(0x004227C0, 2)
def _c004227C0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateLandingDust` (this project's name for `0x004227C0`,
    docs/42 §7.1): twenty class-2 puffs from the object, kind 9, life 10,
    row 4, thrown at a third of an offset that turns 204 units a puff from
    3200 out, rising at 800.  No draw."""
    x, y = args
    ox, oy, oz = inputs.object(x, y)
    for dx, dy, _dz in _ring(inputs, DUST_RADIUS, DUST_TURN, 20):
        pool.spawn(SCRATCH, 2, ox, oy, oz, 4, 0, 0, 9, 10,
                   trunc_div(dx, 3), trunc_div(dy, 3), 0x320, 10, 0)


@death_program(0x00423030, 2)
def _c00423030(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateFlashCircle` (`0x00423030`, the heal orbit's, docs/42
    §7.3): four crosses `A_CROSS3/2/1/A_CROSS` at 30-degree steps around
    the unit, each paired with its mirror image, kind 37, life 40, at half
    the unit's height, oriented along their own line, the object's x and y
    in `vx`/`vy`.  Eight records, no draw."""
    x, y = args
    unit = inputs.unit(x, y)
    if unit is None:
        return
    ox, oy, oz = inputs.object(x, y)
    half = trunc_div(unit.height, 2)
    radius = FLASH_RADIUS_LARGE if inputs.large(unit) else FLASH_RADIUS
    for index, (dx, dy, _dz) in enumerate(_ring(inputs, radius, 0x155, 4)):
        pitch, yaw = inputs.tables.orient((ox, oy, oz), (ox + dx, oy + dy, oz))
        name = CROSS_MODELS[index]
        pool.spawn(name, 0, ox + dx, oy + dy, oz + half, pitch, 0, yaw,
                   0x25, 0x28, ox, oy, 0, 0, 0)
        pool.spawn(name, 0, ox - dx, oy - dy, oz + half, pitch, 0, yaw,
                   0x25, 0x28, ox, oy, 0, 0, 0)


@death_program(0x004232E0, 2)
def _c004232E0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The poison orbit's flash circle (`0x004232E0`): four `A_SKULL.3DI`
    ninety degrees apart at the **flash's** radius (`mov edi, 0x640` /
    `0x1900` at `0x004233BF` / `0x004233B0` -- the heal circle's, not the
    marker's, which the capture corrected), kind 37, life 40, at half the
    unit's height.  No draw."""
    x, y = args
    unit = inputs.unit(x, y)
    if unit is None:
        return
    ox, oy, oz = inputs.object(x, y)
    half = trunc_div(unit.height, 2)
    radius = FLASH_RADIUS_LARGE if inputs.large(unit) else FLASH_RADIUS
    for dx, dy, _dz in _ring(inputs, radius, 0x400, 4):
        pitch, yaw = inputs.tables.orient((ox, oy, oz), (ox + dx, oy + dy, oz))
        pool.spawn("A_SKULL.3DI", 0, ox + dx, oy + dy, oz + half, pitch, 0, yaw,
                   0x25, 0x28, ox, oy, 0, 0, 0)


@death_program(0x00423720, 6)
def _c00423720(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateZoomBob(x, y, z, row, aux, life)`: one class-2 record at a
    position, kind 50, no velocity, no draw."""
    x, y, z, row, aux, life = args
    pool.spawn(SCRATCH, 2, x, y, z, row, 0, 0, 0x32, life, 0, 0, 0, aux, 0)


@death_program(0x00423670, 3)
def _c00423670(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The jump's trail (`0x00423670(x, y, z)`, docs/42 §7.1): a `ZoomBob`
    (row 4, aux 10, life 3) and four class-2 sprites of kind 10, life 11,
    row 4, drifting ±48 sideways and falling 640..592, each delayed by its
    index (`push esi`, the loop counter, is the constructor's last argument)
    -- three draws each, in the order z, y, x."""
    x, y, z = args
    _c00423720(pool, draw, (x, y, z, 4, 10, 3), inputs)
    for index in range(4):
        vz = draw(0, 0x30) - 0x280
        vy = draw(-0x30, 0x60)
        vx = draw(-0x30, 0x60)
        pool.spawn(SCRATCH, 2, x, y, z, 4, 0, 0, 0xA, 0xB, vx, vy, vz, 0xB, index)


@death_program(0x0042A6E0, 3)
def _c0042A6E0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The push's dust (`0x0042A6E0(x, y, z)`, docs/42 §7.2): one class-2
    sprite of row 4, kind 10, life 20, drifting ±48 and rising 320..480 --
    three draws, in the order x, y, z."""
    x, y, z = args
    vx = draw(-0x30, 0x60)
    vy = draw(-0x30, 0x60)
    vz = draw(0x140, 0xA0)
    pool.spawn(SCRATCH, 2, x, y, z, 4, 0, 0, 0xA, 0x14, vx, vy, vz, 10, 0)


# ---------------------------------------------------------------------------
# The set pieces' creators -- docs/42 §8, docs/97 §32
# ---------------------------------------------------------------------------

#: `0x004B1270` / `0x004B12E0` -- the laser barrier lays its three dots one
#: field along the line (`-1600.0`, subtracted) and steps its models one field
#: further per count (`-3200.0`, subtracted).
LASER_OFFSET = -1600.0
LASER_STEP = -3200.0
#: `0x004B1300` -- the bomber's velocity is the direction times a field.
BOMBER_SPEED = 3200.0
#: `0x00423770` -- the tube's puffs, fifteen pairs.
TUBE_PAIRS = 15
#: `0x004234C0` -- the platform's four corner puffs, 4800 out, 1600 up.
PLATFORM_DUST_SPREAD = 0x12C0
PLATFORM_DUST_UP = 0x640
#: `0x00422F00` -- the fire circle's 150 flames, 60 units of turn apart at a
#: field's radius, a field below the object.
FIRE_CIRCLE_FLAMES = 150
FIRE_CIRCLE_TURN = 0x3C
FIRE_CIRCLE_RADIUS = 0xC80
#: `0x0042A120` -- the teleporter's two hundred records, sixteen units apart.
STREAM_RECORDS = 200
STREAM_STEP = 16
#: `0x0042B070` -- the para bomb's life is its fall from 35200 at 800 a tick;
#: it is dropped from 48000.
BOMB_CEILING = 0x8980
BOMB_DROP = 0xBB80
BOMB_FALL = 800


@death_program(0x00423770, 2)
def _c00423770(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The tube's puffs (this project's name for `0x00423770`, docs/42 §8:
    `OpenTube` at its tenth frame): fifteen pairs of class-2 sprites at the
    object, kind 10, life 20, row 4, aux 10, drifting ±48 and rising
    320..480, each pair delayed by its index -- three draws a record, in the
    order x, y, z."""
    x, y = args
    ox, oy, oz = inputs.object(x, y)
    for index in range(TUBE_PAIRS):
        for _ in range(2):
            vx = draw(-0x30, 0x60)
            vy = draw(-0x30, 0x60)
            vz = draw(0x140, 0xA0)
            pool.spawn(SCRATCH, 2, ox, oy, oz, 4, 0, 0, 0xA, 0x14, vx, vy, vz, 10, index)


@death_program(0x004234C0, 3)
def _c004234C0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The platform's dust (`0x004234C0(x, y, z)`, docs/42 §8, once a frame):
    four class-2 sprites at the block's corners, 4800 out and 1600 up, kind
    10, life 12, row 4, aux 10, rising 320..368 and drifting ±48 -- three
    draws a record, in the order z, y, x."""
    x, y, z = args
    up = z + PLATFORM_DUST_UP
    s = PLATFORM_DUST_SPREAD
    for cx, cy in ((x - s, y - s), (x - s, y + s), (x + s, y + s), (x + s, y - s)):
        vz = draw(0, 0x30) + 0x140
        vy = draw(-0x30, 0x60)
        vx = draw(-0x30, 0x60)
        pool.spawn(SCRATCH, 2, cx, cy, up, 4, 0, 0, 0xA, 0xC, vx, vy, vz, 10, 0)


def _debris_pair(pool: Pool, draw: Draws, ox: int, oy: int, z: int, kind: int,
                 vz: int, third: Tuple[int, int], splat_third: Tuple[int, int],
                 vz_drawn: bool) -> None:
    """Twenty `A_DEBRIS` and four `A_SPLAT1` thrown from `(ox, oy, z)`: the
    shape `0x00422610` and `0x00422460` share.  Each record draws its x and
    y velocity in ±200..300 and a third value -- taken and **discarded** by
    the ground unit's (`fstp st(0)`), kept as the vertical by the roof's --
    then its delay in 0..3."""
    for name, count, span in (("A_DEBRIS.3DI", 20, third), ("A_SPLAT1.3DI", 4, splat_third)):
        for _ in range(count):
            vx = draw(-200, 300)
            vy = draw(-200, 300)
            drawn = draw(span[0], span[1])
            delay = draw(0, 4)
            pool.spawn(name, 0, ox, oy, z, 0, 0, 0, kind, 0x32, vx, vy,
                       drawn if vz_drawn else vz, 0, delay)


@death_program(0x00422610, 3)
def _c00422610(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The ground unit's debris (`0x00422610(x, y, z)`, docs/42 §8.1): twenty
    `A_DEBRIS` and four `A_SPLAT1` from the object's x, y at the given z,
    kind 29, life 50, thrown ±200..300 sideways and 300 up, delayed 0..3;
    the third draw (40..180 / 40..140) is taken and never converted."""
    x, y, z = args
    ox, oy, _oz = inputs.object(x, y)
    _debris_pair(pool, draw, ox, oy, z, 0x1D, 0x12C, (40, 140), (40, 100), False)


@death_program(0x00422460, 3)
def _c00422460(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The roof unit's debris (`0x00422460(x, y, z)`, docs/42 §8): the same
    twenty and four, kind **0**, life 50, with the third draw kept as the
    vertical velocity -- `aRandom2(40, -100)`, a span the wrong way round,
    so the pieces fall 40..-60."""
    x, y, z = args
    ox, oy, _oz = inputs.object(x, y)
    _debris_pair(pool, draw, ox, oy, z, 0, 0, (40, -100), (40, -100), True)


@death_program(0x004238C0, 2)
def _c004238C0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The crush wall's debris (`0x004238C0(x, y)`, docs/42 §8, once a cell):
    thirty class-2 sprites scattered ±1600 around the object -- kind 10,
    life 20, row 4, aux 30, drifting ±48, rising 320..480, delayed 0..2;
    seven draws in the order vx, vy, vz, delay, z, y, x -- then five
    `A_DEBRIS` of kind 5, life 100, thrown vz 100..600, vx and vy ±300..600,
    spun by three draws of 0..4095 (rot_z, rot_y, rot_x)."""
    x, y = args
    ox, oy, oz = inputs.object(x, y)
    for _ in range(30):
        vx = draw(-0x30, 0x60)
        vy = draw(-0x30, 0x60)
        vz = draw(0x140, 0xA0)
        delay = draw(0, 3)
        z = draw(-0x640, 0xC80) + oz
        py = draw(-0x640, 0xC80) + oy
        px = draw(-0x640, 0xC80) + ox
        pool.spawn(SCRATCH, 2, px, py, z, 4, 0, 0, 0xA, 0x14, vx, vy, vz, 0x1E, delay)
    for _ in range(5):
        vz = draw(100, 500)
        vx = draw(-300, 600)
        vy = draw(-300, 600)
        rz = draw(0, 0x1000)
        ry = draw(0, 0x1000)
        rx = draw(0, 0x1000)
        pool.spawn("A_DEBRIS.3DI", 0, ox, oy, oz, rx, ry, rz, 5, 100, vx, vy, vz, 0, 0)


@death_program(0x00422F00, 2)
def _c00422F00(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The fire circle's ring (`0x00422F00(x, y)`, docs/42 §8): 150 class-2
    flames on a ring of a field's radius, each offset the previous turned
    by 60 through `0x004039A0`, a field **below** the object, kind 67, life
    6, aux 20, delayed by `i / 8`, the pitch drawn 0..2 -- one draw each."""
    x, y = args
    ox, oy, oz = inputs.object(x, y)
    tables = inputs.tables
    offset = (FIRE_CIRCLE_RADIUS, 0, 0)
    for index in range(FIRE_CIRCLE_FLAMES):
        offset = tables.rotate(offset, (0, 0, FIRE_CIRCLE_TURN))
        pitch = draw(0, 3)
        pool.spawn(SCRATCH, 2, ox + offset[0], oy + offset[1], oz - FIRE_CIRCLE_RADIUS,
                   pitch, 0, 0, 0x43, 6, 0, 0, 0, 0x14, index >> 3)


#: `0x00428990`'s direction switch: 0 → +y, 1 → -x, 2 → -y, 3 → +x.
LASER_DIRECTIONS = {0: (0, 1), 1: (-1, 0), 2: (0, -1), 3: (1, 0)}


@death_program(0x00428990, 4)
def _c00428990(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """`aBlob_CreateLaserBarrier(x, y, dir, count)` (`0x00428990`, docs/42
    §8): from the object 2400 down, aimed 100 units along `dir`, three
    class-2 dots one field back along the line (kind 51, life 16, aux 10,
    pitch 5) at z, z + 800, z + 1600; then `count` times: the line moves a
    field along the direction and three `A_LASERG.3DI` models (kind 1, life
    9) are laid at the same three heights, aimed by `0x00403AA0`.  No draw."""
    x, y, direction, count = args
    ox, oy, oz = inputs.object(x, y)
    tables = inputs.tables
    z0 = oz - 0x960
    dx, dy = LASER_DIRECTIONS.get(direction & 0xFF, (0, 0))
    source = (ox, oy, z0)
    target = (ox + dx * 100, oy + dy * 100, z0)
    d = tables.direction(source, target, 1)
    pitch, yaw = tables.orient(source, target)
    sx, sy = ox, oy
    for step in range(3):
        pool.spawn(SCRATCH, 2, sx - ftol(d[0] * LASER_OFFSET), sy - ftol(d[1] * LASER_OFFSET),
                   z0 + step * 0x320, 5, 0, 0, 0x33, 0x10, 0, 0, 0, 10, 0)
    lx, ly, lz = ox, oy, z0
    for _ in range(count & 0xFF):
        lx -= ftol(d[0] * LASER_STEP)
        ly -= ftol(d[1] * LASER_STEP)
        lz -= ftol(d[2] * LASER_STEP)
        for step in range(3):
            pool.spawn("A_LASERG.3DI", 0, lx, ly, lz + step * 0x320, pitch, 0, yaw,
                       1, 9, 0, 0, 0, 0, 0)


@death_program(0x00428BF0, 5)
def _c00428BF0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The statue's beam (`0x00428BF0(sx, sy, tx, ty, cells)`, docs/42 §8.1):
    from the source object, stepping `1600 * direction` a dot, `2 * cells -
    1` class-2 dots at z 3200 (kind 62, life 7, aux 25, rot_y 3, delayed by
    index), then six sparks from the last dot, kind 62, life 7, aux 30,
    rising 800 and thrown ±3000..6000 (two draws, vy then vx), rotations
    alternating `(0, 3)` and `(2, 0)`, delayed `j / 2` plus the dot count."""
    sx, sy, tx, ty, cells = args
    ox, oy, oz = inputs.object(sx, sy)
    ax, ay, _az = inputs.object(tx, ty)
    d = inputs.tables.direction((ox, oy, oz), (ax, ay, oz), 1)
    px = ox + ftol(d[0] * SPARK_SPEED)
    py = oy + ftol(d[1] * SPARK_SPEED)
    dots = 2 * cells - 1
    for index in range(dots):
        px += ftol(d[0] * SPARK_SPEED)
        py += ftol(d[1] * SPARK_SPEED)
        pool.spawn(SCRATCH, 2, px, py, 0xC80, 0, 3, 0, 0x3E, 7, 0, 0, 0, 0x19, index)
    for j in range(6):
        rx, ry = (2, 0) if j & 1 else (0, 3)
        vy = draw(-3000, 6000)
        vx = draw(-3000, 6000)
        pool.spawn(SCRATCH, 2, px, py, 0xC80, rx, ry, 0, 0x3E, 7, vx, vy, 0x320, 0x1E,
                   (j // 2 + dots) & 0xFF)


@death_program(0x0042A120, 4)
def _c0042A120(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The teleporter's stream (`0x0042A120(sx, sy, tx, ty)`, docs/42 §8.1):
    two hundred class-2 records, kind 65, life 70, aux 5, one every 16 units
    up from the source object's z, scattered ±1600..3200 around the source
    in x and y and given, in the velocity slots, a point ±1600..3200 around
    the target at its height plus 3200 less the rise -- four draws each,
    every one converted with its addend inside (`fiadd` / `fadd`), in the
    order vy, vx, y, x; delayed `i / 10`."""
    sx, sy, tx, ty = args
    ox, oy, oz = inputs.object(sx, sy)
    ax, ay, az = inputs.object(tx, ty)
    for index in range(STREAM_RECORDS):
        rise = index * STREAM_STEP
        vz = az - rise + 0xC80
        vy = draw.biased(-0x640, 0xC80, ay)
        vx = draw.biased(-0x640, 0xC80, ax)
        py = draw.biased(-0x640, 0xC80, oy)
        px = draw.biased(-0x640, 0xC80, ox)
        pool.spawn(SCRATCH, 2, px, py, oz + rise, 5, 0, 0, 0x41, 0x46, vx, vy, vz, 5,
                   index // 10)


@death_program(0x0042A8E0, 6)
def _c0042A8E0(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """The bomber (`0x0042A8E0(x, y, z, tx, ty, tz)`, docs/42 §8): one
    `L069EE00.3DI` model at the source, kind 52, life 150, flying a field a
    tick along `0x0046D400`'s direction, aimed by `0x00403AA0`.  It clears
    the *arrived* flag and writes its start into `0x004FE3F8..`; no draw."""
    x, y, z, tx, ty, tz = args
    d = inputs.tables.direction((x, y, z), (tx, ty, tz), 1)
    pitch, yaw = inputs.tables.orient((x, y, z), (tx, ty, tz))
    pool.spawn("L069EE00.3DI", 0, x, y, z, pitch, 0, yaw, 0x34, 0x96,
               ftol(d[0] * BOMBER_SPEED), ftol(d[1] * BOMBER_SPEED),
               ftol(d[2] * BOMBER_SPEED), 0, 0)


@death_program(0x0042B070, 3)
def _c0042B070(pool: Pool, draw: Draws, args: Sequence[int], inputs: DeathInputs) -> None:
    """One para bomb (`0x0042B070(x, y, delay)`, docs/42 §8): an
    `A_PARAB1.3DI` dropped from 48000 over the object, kind 25, falling 800 a
    tick, its life the fall from 35200 to the object's height at that rate
    (a reciprocal multiply, then `abs`), rot_y 64 and rot_z drawn 0..4095;
    it clears the *arrived* flag.  One draw."""
    x, y, delay = args
    ox, oy, oz = inputs.object(x, y)
    life = abs(trunc_div(BOMB_CEILING - oz, BOMB_FALL))
    rz = draw(0, 0x1000)
    pool.spawn("A_PARAB1.3DI", 0, ox, oy, BOMB_DROP, 0, 0x40, rz, 0x19, life, 0, 0,
               -BOMB_FALL, 0, delay)

