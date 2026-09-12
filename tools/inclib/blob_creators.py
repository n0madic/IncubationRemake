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

Four more have joined the ten since: the three burst creators of ``docs/28``
§8.1.1 and ``aBlob_CreateShockWave`` ``0x00422B80``.  All four were missing for
the same reason and it was never the fitter -- the capture called them with
**arguments no caller would pass**, a round count of zero for the three and a
tile coordinate where the shock wave wants a type, so the engine ran a loop
zero times or took a fall-through arm and left nothing to fit.
``blob_gold.BURST_ARGS`` and ``blob_gold.SWITCH_ARGS`` are the corrections, and
``blob_gold.BURST_UNCAPTURED`` / ``PROGRAM_ARGS_STALE`` name the ones a capture
has yet to reach.

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
#: The same address as a **number**, which is what an arm that calls the
#: constructor itself passes for the model name (`docs/97` §49).
NAME_SCRATCH = 0x004FA524
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

#: `aBlob_CreateTracerBullet`'s own step, `0x004B1280`, and the spacing its
#: beam length is counted in.  The two are the **same number**: the tracer
#: leaves along the line of fire by 2240 a frame and lives one frame per 2240
#: units of the wider of the two horizontal spans.  The divisor is not an
#: immediate -- `mov eax, 0xEA0EA0EB / imul ecx / add edx, ecx / sar edx, 11`
#: -- and is recovered by replaying the multiply, like `BEAM_UNIT`'s.
TRACER_STEP = -2240.0
TRACER_UNIT = 2240
#: `0x004B1288` and `0x004B1290`: the ejected casing leaves sideways at 128,
#: which is **not** the machine gun's 80.  Its rise, `0x140 + aRandom2(0,
#: 0xA0)`, is two immediates and stays written out at its own draw.
TRACER_CASING_SPEED = 128.0
#: The other two burst creators' pair of the same shape, each with its own
#: spacing: `aBlob_CreateFlash` `0x00423D80` reads `0x004B1270` and divides by
#: the multiply at `0x00424058`, `aBlob_CreateNeedles` `0x00424250` reads
#: `0x004B1278` -- the cell `BEAM_STEP` names -- and divides at `0x00424540`.
#: Step and spacing are one number in all three, as they are for the tracer.
FLASH_STEP = -1600.0
FLASH_UNIT = 1600
NEEDLE_STEP = -2400.0
NEEDLE_UNIT = 2400


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
    #: Where the shooter's muzzle actually is: the world position of the part
    #: named by the creator's own argument, which `0x0042C660` writes over the
    #: three source coordinates when the shooter is animating.  `None` where
    #: nobody measured it, which is the body-axis fallback the engine takes
    #: for a unit whose `+0x56` is clear.
    source_joint: Optional[Tuple[int, int, int]] = None

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

    @property
    def seed(self) -> float:
        """Where the generator stands.

        A creator an update **arm** calls draws from the same stream the arm
        did and leaves it where the arms after it in the sweep continue from
        (`docs/97` §49), so a caller has to be able to read it back.
        """
        return self._rng.seed


class Pool:
    """The records a creator leaves, in the order `0x00420950` fills them."""

    def __init__(self, inputs: Inputs) -> None:
        self.inputs = inputs
        self.records: List[Dict[str, int]] = []
        #: How many records the constructor refused for a zero `life`.
        self.refused = 0
        #: Whether the creator wrote **0** over the *arrived* flag of
        #: `docs/42` §4.6 -- "there is something in flight to wait for".
        #:
        #: Exactly six sites in `.text` write a zero to ``0x004FE63C``, and
        #: five are inside a creator: ``aBlob_CreateGrenade`` ``0x00426070``,
        #: ``aBlob_EnergyCannon`` ``0x004264A0`` and ``aBlob_CreateLaser``
        #: ``0x00428570`` -- the three weapon projectiles -- and the bomber
        #: ``0x0042A8E0`` and the para bomb ``0x0042B070``, the two a set
        #: piece runs.  The sixth is ``0x0042B490``, the helper a sequence
        #: calls to acknowledge a landing.  ``presentation_tables.py`` pins
        #: all six; the two set-piece ones are modelled here, because they
        #: are the two the remake's own driver waits on.
        self.clears_arrived = False

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


#: **What is still read rather than measured in this module, now that the rest
#: of this creator is measured.**
#:
#: `aBlob_CreateFlameStream` `0x00427C80` opens each ring by reading the three
#: doubles its inner loop wrote last, at `[esp+0x4C]`, `[esp+0x54]` and
#: `[esp+0x5C]` (`0x00427F4F` onwards), and multiplying them by
#: :data:`FLAME_RING_OFFSET`.  On the **first** ring the inner loop has not run
#: and those three slots are the frame's own uninitialised locals, so the ring
#: begins at an offset nothing in the creator determines.
#:
#: **2026-09-12: the engine agreed.**  The creator was called inside the live
#: process with weapon 7's own ring count and all twelve records it makes came
#: back matching this program field for field -- ring 0's five included -- so
#: the three slots held zero in that frame.  Two readings say why:
#:
#: * the point-blank arm at `0x00428093` zeroes exactly those three doubles and
#:   puts the point back on the source, so zero is a value the *routine* writes
#:   there rather than one chosen for it.  Its guard is the flight length,
#:   `cmp ecx, 1` at `0x0042808B`, which is why a shot with ground to cross
#:   does not take that arm;
#: * the residue at that depth is small integers and pointers reinterpreted as
#:   doubles, which are tiny and truncate to zero.  *Not* NaN: `_ftol` answers
#:   `0x80000000` for a NaN on this binary, so the "denormal or NaN, both give
#:   0" half of the earlier argument here was simply wrong and is withdrawn.
#:
#: **2026-09-12, later the same day: the frame was settled too.**  The
#: agreement above is a measurement of `dbgcall`'s anchor stack, because a
#: plan calls the creator itself; a shot calls it from `aPlayFightAnimation`,
#: whose own earlier calls -- the sound-buffer chain under `0x00436B60`,
#: entered through `0x004176C0` at `0x0040CC15` -- write at exactly the depth
#: those three doubles occupy.  `blob_gold`'s `fight_` phase closes that gap:
#: it fires a real shot through `aAttackUnit`, which builds the target
#: pattern, resolves it and calls `aPlayFightAnimation` at `0x0046C186`, so
#: the creator runs from `0x0040D014` with the animation's frame underneath.
#: All twelve records the read window covers -- ring 0's five included --
#: reproduce this program field for field.  The three slots hold zero on the
#: shipped path.
#:
#: Two pokes make that run readable and neither is in the creator's way: the
#: muzzle switch's own weapon read at `0x0040CC38` is rewritten to `push
#: imm8 / pop eax / nop`, four bytes for four, so the switch dispatches the
#: weapon the phase names; and `aBlobsTick` `0x0041E3D0` is stubbed to `ret`,
#: because the animation pumps frames and a flame record lives two ticks --
#: without the stub the pool is empty when `aAttackUnit` returns, which was
#: measured -- with `aRandom2` advanced by 160 draws, far more than the
#: creator's forty, so the empty pool was a sweep and not a refusal.  (That
#: number counts nothing in particular: the stubbed run drew 177, and the
#: impact arms draw too.  The records are what prove the creator ran.)
#:
#: **Both branches of the sound code give zero.**  `0x0040CBE2` decides
#: whether `aAnimationCreateSoundBuffer` runs, and it is that call's subtree
#: under `0x00436B60` that last writes at this depth on the path the target's
#: unit type takes here.  Forcing `je 0x0040CC38` to `jmp` -- one byte, and it
#: changes neither the unit nor the weapon -- takes the other branch, and the
#: `shot_07_nosound` phase reproduces all twenty records as well.
#:
#: What stays open is narrower than it was, and is written down here rather
#: than buried.  The value is measured; its **provenance** is not.  Two
#: readings fit equally: two routines that both leave zeros at that depth, or
#: a depth neither of them reaches, in which case what is read is older still
#: -- `aAttackUnit`'s own frame, which is the same on both branches.  Nothing
#: here distinguishes them, and the zero is in any case this attacker's, this
#: weapon's and this save's answer rather than a constant of the routine.
FLAME_RING0_DIVERGENCE = "0x00427C80"

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


#: `aBlob_SparkingPlug` `0x0042ACF0`, all four read off its own loop:
#: `mov edi, 0x1E` at `0x0042AD53` is the round count, `shl eax, 5` at
#: `0x0042AD6D` and `shl eax, 4` at `0x0042AD82`/`0x0042AD9D` are the two
#: velocity scales, and `add eax, 0x960` at `0x0042ADAC` is the lift.
SPARKING_PLUG_COUNT = 30
SPARKING_PLUG_RISE = 32
SPARKING_PLUG_DRIFT = 16
SPARKING_PLUG_LIFT = 0x960


#: `aBlob_CreatePlasmaBallImpact` `0x004294E0`: `mov ebp, 0x28` at
#: `0x00429549` is the round count, and the three draw ranges are the
#: immediates its loop pushes -- `(200, 300)` for the rise at `0x0042954E`
#: and `(-300, 600)` twice for the drift.
PLASMA_IMPACT_COUNT = 40
PLASMA_IMPACT_RISE_BASE = 200
PLASMA_IMPACT_RISE_SPAN = 300
PLASMA_IMPACT_DRIFT_BASE = -300
PLASMA_IMPACT_DRIFT_SPAN = 600


@program(0x004294E0, 2)
def _c004294E0(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreatePlasmaBallImpact`: forty sparks at the placed object.

    Weapon 43's impact `0x0040D60E`, and nothing else.  It stands on the
    object's own z with **no lift and no unit height** -- `0x004295B1`
    pushes `[esi+0x18]` untouched, where its neighbour `aBlob_SparkingPlug`
    adds `0x960` -- and the `aux` and `delay` zeros are the pair pushed at
    the top of the loop, the same shape `_c0042ACF0` documents.

    The three draws reach the constructor **out of order**: the rise is
    taken first and lands in `vz`, and the two drifts land in `vx` and `vy`
    in the reverse of the order they were drawn, MSVC evaluating arguments
    right to left.
    """
    x, y, z = pool.inputs.source
    for _ in range(PLASMA_IMPACT_COUNT):
        vz = draw(PLASMA_IMPACT_RISE_BASE, PLASMA_IMPACT_RISE_SPAN)
        vx = draw(PLASMA_IMPACT_DRIFT_BASE, PLASMA_IMPACT_DRIFT_SPAN)
        vy = draw(PLASMA_IMPACT_DRIFT_BASE, PLASMA_IMPACT_DRIFT_SPAN)
        pool.spawn("A_FUNKE.3DI", 0, x, y, z, 0, 0, 0, 0x18, 0x3C,
                   vx, vy, vz, 0, 0)


#: `aBlob_CreateExplosion2` `0x004295D0`: `mov ebp, 0xF` at `0x00429639`
#: and the loop's own immediates -- `(600, 700)` for the rise, `(-300, 600)`
#: twice for the drift, and three whole turns of `(0, 0x1000)`.
EXPLOSION2_COUNT = 15
EXPLOSION2_RISE_BASE = 600
EXPLOSION2_RISE_SPAN = 700


@program(0x004295D0, 2)
def _c004295D0(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateExplosion2`: fifteen tumbling pieces of debris.

    Weapon 17's muzzle and weapons 8 and 37's impact, each straight after
    `aBlob_SparkingPlug` on the same two arguments.  Six draws a round in
    three ranges, and the order they are **taken** is not the order they
    arrive: the rise is first and becomes `vz`, the two drifts fill `vx`
    and `vy` reversed, and the three whole-turn draws fill `rot_z`, `rot_y`
    and `rot_x` -- reversed again, the shape `_c0042AF10` names.
    """
    x, y, z = pool.inputs.source
    for _ in range(EXPLOSION2_COUNT):
        vz = draw(EXPLOSION2_RISE_BASE, EXPLOSION2_RISE_SPAN)
        vx = draw(PLASMA_IMPACT_DRIFT_BASE, PLASMA_IMPACT_DRIFT_SPAN)
        vy = draw(PLASMA_IMPACT_DRIFT_BASE, PLASMA_IMPACT_DRIFT_SPAN)
        rot_z = draw(0, 0x1000)
        rot_y = draw(0, 0x1000)
        rot_x = draw(0, 0x1000)
        pool.spawn("A_DEBRIS.3DI", 0, x, y, z, rot_x, rot_y, rot_z,
                   5, 0x64, vx, vy, vz, 0, 0)


#: `aBlob_CreateFlameStream` `0x00427C80` -- weapons 7 and 40's muzzle, and
#: the one creator of the thirty whose first pass reads **uninitialised
#: stack**.  See :data:`FLAME_RING0_DIVERGENCE`.
#:
#: `args[4]` rings of five records each, so weapon 7 lays twenty and weapon 40
#: fifty.  `0x004B12C0` is what the ring's own starting offset is scaled by --
#: negative, and *subtracted*, so the ring begins ahead of the shooter.
FLAME_RING_OFFSET = -960.0
#: `0x004B12B8` again (`SPARK_SPEED`'s cell) for the record's velocity, and
#: `0x004B12F0` for the step between the five records of one ring.
FLAME_STEP = 266.66666666666663
#: Five records a ring, and the length divisor they share -- half a map field,
#: where both lasers count in whole ones.
FLAME_PER_RING = 5
FLAME_UNIT = 1600
#: The aim is taken a quarter-cell above the target object, as both lasers do.
FLAME_LIFT = 0x320
#: The sprite's half-size is a draw **biased** by a third of a counter of its
#: own -- `fild` of `counter / 3` added on the FPU before `_ftol`, which is not
#: the same as adding it after.  Its column is a second draw.
#:
#: **The counter is neither the ring nor the record index.**  It is a *byte* at
#: `[esp+0x30]`, set to two by a literal at `0x00427F25` before either loop
#: opens and incremented once per record at `0x00428181`, so the bias is
#: `(2 + n) / 3` over the whole call and steps at the second, fifth, eighth
#: record and so on -- inside a ring as much as between rings.  Read as
#: `ring / 3` instead it was right for the first record of the call and one
#: short or more for every other, which is what the engine's twelve records
#: said on 2026-09-12: eleven disagreements, all of them `aux`, all of them
#: exactly `ceil(n / 3)` low.
FLAME_SIZE_SPAN = 5
FLAME_SIZE_BASE = 2
FLAME_SIZE_DIVISOR = 3
FLAME_COLUMN_SPAN = 3
#: Above this type the stream **sweeps**: the aim is turned about the shooter
#: by an angle that walks by `FLAME_SWEEP_STEP` and reverses at
#: `FLAME_SWEEP_LIMIT`, so weapon 40's fifty records fan out where weapon 7's
#: twenty go straight.  The three angles it turns by are
#: `(dz, dz, sweep)` -- the vertical delta twice, which reads as a slip for
#: `(0, 0, sweep)` and is transcribed as it ships.
FLAME_SWEEP_TYPE = 5
FLAME_SWEEP_STEP = 0xA
FLAME_SWEEP_LIMIT = 0x1E

#: `aBlob_CreateTracerBullet` `0x00425400` -- weapon 23's muzzle, and the
#: spore cannon's spray rather than a tracer despite the name it shares with
#: `0x004247C0`.  Its speed is `SPARK_SPEED`'s own cell, `0x004B12B8`, read
#: three times; the divisor below is the same 1600 recovered from the
#: reciprocal multiply the compiler left instead of a division.
SPRAY_UNIT = 1600
#: Two records a round, identical but for one frame of delay.
SPRAY_PAIR = 2

#: `aBlob_CreateGrenade` `0x00426070` -- weapon 11's muzzle, one shot per
#: enemy in range with the **target's index** as its sixth argument, and
#: weapon 44's, which pushes 0xFF instead.
#:
#: Six records a shot, all at the same point and differing only in `delay`.
GRENADE_COUNT = 6
#: `0x004B12D0` and `0x004B12D8` -- the direction times a field and a half
#: forwards, and the same magnitude negated for the offset the record's
#: position is *subtracted* by, which is the same step written twice.
GRENADE_SPEED = 1920.0
GRENADE_BACK = -1920.0
#: `add ecx, 0x1A` -- the kind, with one added when the type is 0xFF, which is
#: the pair `blobs.json`'s `computed_kinds` carries as `[26, 27]`.
GRENADE_KIND = 0x1A
#: Under this many tiles of separation a shot that is not the 0xFF type is
#: aimed at the target with **no** offset at all: `0x0044AE10`'s answer is
#: compared against it and the three offsets zeroed below it.
GRENADE_RANGE = 6
#: The scatter the fall-through type draws, `(base, span)` for x and y and a
#: rise with no base.  Types 0 to 5 take a fixed offset instead -- see
#: :data:`GRENADE_AIM`.
GRENADE_SCATTER_BASE = -0x1F40
GRENADE_SCATTER_SPAN = 0x3E80
GRENADE_SCATTER_RISE = 0x3200
#: The same for type 0xFF, weapon 44's: a tighter spread thrown higher.
GRENADE_PROXIMITY_BASE = -0x12C0
GRENADE_PROXIMITY_SPAN = 0x2580
GRENADE_PROXIMITY_RISE = 0x3E80
#: Where each of the first six shots is aimed, as an offset from the target
#: object -- `(dx, dy, dz)` per type, out of the six arms of the jump table at
#: `0x00426484`.  Six arcs, so six simultaneous shots do not overlap; a
#: seventh and beyond fall through to the scatter above.
#:
#: The eighteen numbers are read back out of the arms themselves by
#: `blob_tables`' `creators.grenade_aim_arms`, which decodes the jump table
#: from its bytes rather than trusting a disassembler's arm labels.
GRENADE_AIM = (
    (-0x3200, -0x2580, 0x1900),
    (0x1900, 0xC80, 0x3200),
    (-0x1F40, -0x2BC0, 0x12C0),
    (0x1900, 0x12C0, 0x1F40),
    (0xC80, 0xC80, 0x2580),
    (-0x3200, -0x2BC0, 0x3200),
)

#: `aBlob_CreateLaser` `0x00428200` -- weapon 47's muzzle.  A chain of dots
#: 320 apart along the line, one per frame of the flight, and a terminal dot
#: of its own kind.
BEAM_DOT_SPEED = 320.0
BEAM_DOT_UNIT = 320
#: Five dots leave per frame of delay -- `imul 0x66666667 / sar edx, 1` over
#: the dot's index, which is a division by five and not by ten.
BEAM_DOT_STAGGER = 5
#: The direction is taken to the target object **one quarter-cell up**.
BEAM_DOT_LIFT = 0x320

#: `aBlob_CreateLaser` `0x00428570` -- weapon 14's muzzle, and a different
#: routine of the same name: six dots stepped 480 along the line plus a
#: seventh of its own kind, all carrying the flight's whole length as their
#: lifetime.
LASER_DOT_COUNT = 6
LASER_DOT_SPEED = 3200.0
LASER_DOT_STEP = 480.0
LASER_DOT_UNIT = 3200
#: The same quarter-cell lift on the aim as `BEAM_DOT_LIFT`, in the other
#: routine's own instruction.
LASER_DOT_LIFT = 0x320

#: `aBlob_CreateFireWheel` `0x004228F0` -- weapon 44's muzzle and impact.
#: Thirty sprite puffs off the object, then thirty explosion models thrown
#: outwards along a spoke the creator turns one step at a time.
FIRE_WHEEL_COUNT = 0x1E
#: The puffs' rise, `push 0x190 / push 0x320` at `0x004229E5`.
FIRE_WHEEL_RISE_BASE = 0x190
FIRE_WHEEL_RISE_SPAN = 0x320
#: Their sideways scatter, the same draw twice.
FIRE_WHEEL_DRIFT_BASE = -0x64
FIRE_WHEEL_DRIFT_SPAN = 0xC8
#: The spoke: a vector this long, turned this far per record.  Thirty steps of
#: 136 is 4080 of the circle's 4096, so the wheel closes and does not overlap.
FIRE_WHEEL_RADIUS = 0xA0
FIRE_WHEEL_TURN = 0x88
#: What the turned spoke is multiplied by to become the record's velocity --
#: `lea eax, [ecx*4]`, the SIB's scale and no instruction of its own.
FIRE_WHEEL_SPEED = 4
#: One cell up, where the explosions stand: `add edx, 0xC80`.
FIRE_WHEEL_LIFT = 0xC80
#: Every fourth explosion is `A_EXPL04.3DI` and the rest `A_EXPL03.3DI`, off a
#: counter the `cmp` at `0x00422AB1` tests against this and then resets.
FIRE_WHEEL_EXPL04_EVERY = 3

#: `0x00429C30` -- weapon 13's impact, beside `0x00429180`'s sparks.  Three
#: sprite puffs rising off the object at one and a half cells, and the only
#: number it does not carry at its own three call sites.
MINE_PLUME_LIFT = 0x640

#: `aBlob_CreateSpidyMines` `0x00426B70` and `aBlob_CreateGrenade`
#: `0x00425CA0`, which are the same body with a different model: the flight
#: speed `0x004B12C8` holds as a double (800.0), the `sar edx, 8` after
#: `imul 0x51EB851F` that divides the span by 800, the `sub eax, 2` the life
#: ends on, and the `-5 << 3` the lob adds per half-life.
PROJECTILE_SPEED = 800.0
PROJECTILE_UNIT = 800
PROJECTILE_LIFE_BIAS = 2
#: The lob is written as `neg / shl 2 / sub / shl 3` -- five half-lives, then
#: eight -- rather than as one multiply, so it is pinned as the two shifts
#: the compiler actually emitted.
PROJECTILE_LOB_SPREAD = 4
PROJECTILE_LOB_SCALE = 8
#: `0x00425D9A` and `0x00426C6A` -- the `add eax, 0xA0` each of the two puts
#: between the unit's height and the object's `z`.  Exactly two sites in the
#: whole of `.text` add this to `0x0047AD30`'s answer, and they are these two,
#: so the lift is the creators' own and not a property of any object table.
PROJECTILE_LIFT = 0xA0
#: `0x00426F2C`: the puff the mine leaves behind, `(row, aux, life)`.
SPIDY_BOB_ROW = 4
SPIDY_BOB_AUX = 0x14
SPIDY_BOB_LIFE = 8


def _projectile(pool: Pool, args: Sequence[int], name: str, kind: int
                ) -> Tuple[int, int, int]:
    """The shared body of `0x00425CA0` and `0x00426B70`.

    **The shooter is lifted by a literal 160**, which is `PROJECTILE_LIFT`:
    both bodies do `call 0x0047AD30 / add eax, 0xA0 / add ecx, eax` over the
    symbol object's own `z`.  Both ends are the *symbol* object
    (`aGetSymbolObjectPtr` `0x00404C40`) -- the standard object each reads at
    `0x00404BD0` is only for the joint's part list at `+0x45` -- and the
    capture cannot tell the two readings apart, 0 + 160 being 160 either way.
    The bytes can, and `blob_tables.CREATOR_CONSTANT_SITES` reads both back.

    The round leaves at `direction * 800` and lives
    `max(|dx|, |dy|) / 800 - 2` frames, with `0x004FE63C` written **0** while
    that is positive -- the shot stage's "something is in flight".  Its `vz`
    carries a lob of forty per half-life on top of the direction's own, and
    its rotation is the engine's own `0x00403AA0` over the source and the
    source **plus the direction**, not plus the lob.

    Answers where the round started, for the caller's own second record.
    """
    inputs = pool.inputs
    source = (inputs.source[0], inputs.source[1],
              inputs.source[2] + inputs.source_height + PROJECTILE_LIFT)
    if inputs.source_joint is not None:
        source = inputs.source_joint
    aim = (inputs.target[0], inputs.target[1],
           inputs.target[2] + inputs.target_height)
    d = eng3d.direction_vector(source, aim, 1)
    span = max(abs(source[0] - aim[0]), abs(source[1] - aim[1]))
    life = span // PROJECTILE_UNIT - PROJECTILE_LIFE_BIAS
    pool.clears_arrived = life > 0
    vx = ftol(d[0] * PROJECTILE_SPEED)
    vy = ftol(d[1] * PROJECTILE_SPEED)
    vz = ftol(d[2] * PROJECTILE_SPEED)
    at = (source[0] + vx, source[1] + vy, source[2] + vz)
    turn = inputs.tables.orient(source, at)
    half = abs(life) >> 1
    lob = abs(-(half * PROJECTILE_LOB_SPREAD) - half) * PROJECTILE_LOB_SCALE + vz
    pool.spawn(name, 0, at[0], at[1], at[2], turn[0], 0, turn[1],
               kind, life, vx, vy, lob, 0, 0)
    return source


@program(0x00426B70, 4)
def _c00426B70(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateSpidyMines`: one thrown mine and the puff it leaves.

    Weapons 13 and 46's muzzle `0x0040D1BF`, four arguments and no tail.  The
    round is `_projectile`'s; the puff is `aBlob_CreateZoomBob` `0x00423720`
    at the shooter's own point, `0x00426F2C` pushing `(4, 0x14, 8)`.

    It is one of the ten creators that push `"M"` **inside their own body**
    (`0x00426CC8`), so a shooter that is animating throws from the barrel --
    which no capture exercises, nothing here animating.
    """
    source = _projectile(pool, args, "A_MINE2.3DI", 77)
    _c00423720(pool, draw, (source[0], source[1], source[2],
                            SPIDY_BOB_ROW, SPIDY_BOB_AUX, SPIDY_BOB_LIFE),
               None)



@program(0x004228F0, 3)
def _c004228F0(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateFireWheel`: thirty puffs, then a closing wheel of fire.

    Weapon 44's muzzle **and** its impact (`0x0040CC98`, `0x0040D8F9`), two
    tile coordinates and a third argument the body never reads -- the frame
    loads `[esp+4]` and `[esp+8]` and nothing else, which is why the phase in
    hand is an oracle whatever the stored tail says.

    Two loops of thirty, and only the first draws.  The puffs are class-2
    sprites at the object's own `z`, rising 400 to 1200 and scattered a
    hundred either way, staggered by **half** the loop index -- `cdq / sub /
    sar 1`, so two leave together.

    The wheel is the interesting half: a spoke of 160 is turned through
    Eng3d's own `0x004039A0` by 136 of 4096 per record, and each record is
    made from the **previous** answer with its `z` forced back to zero, so the
    turn accumulates and the wheel stays flat.  The velocity is that spoke
    times four.  Loop one copies a model name it cannot use -- its record is
    class 2 -- and that dead copy is the reason the two loops look alike.
    """
    x, y, z = pool.inputs.source
    for index in range(FIRE_WHEEL_COUNT):
        vz = draw(FIRE_WHEEL_RISE_BASE, FIRE_WHEEL_RISE_SPAN)
        vy = draw(FIRE_WHEEL_DRIFT_BASE, FIRE_WHEEL_DRIFT_SPAN)
        vx = draw(FIRE_WHEEL_DRIFT_BASE, FIRE_WHEEL_DRIFT_SPAN)
        pool.spawn(SCRATCH, 2, x, y, z, 0, 0, 0, 0x2C, 0x10,
                   vx, vy, vz, 0xA, index >> 1)
    spoke = (FIRE_WHEEL_RADIUS, 0, 0)
    for index in range(FIRE_WHEEL_COUNT):
        spoke = tuple(pool.inputs.tables.rotate(
            (spoke[0], spoke[1], 0), (0, 0, FIRE_WHEEL_TURN)))
        fourth = index % (FIRE_WHEEL_EXPL04_EVERY + 1) \
            == FIRE_WHEEL_EXPL04_EVERY
        pool.spawn("A_EXPL04.3DI" if fourth else "A_EXPL03.3DI", 0,
                   x, y, z + FIRE_WHEEL_LIFT, 0, 0, 0, 0x24, 0xF,
                   spoke[0] * FIRE_WHEEL_SPEED,
                   spoke[1] * FIRE_WHEEL_SPEED, 0, 0, 0xA)


@program(0x00429C30, 3)
def _c00429C30(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """Weapon 13's impact plume: three sprite puffs and no draw at all.

    `0x0040D6F5` is its only caller and it has no trace string of its own, so
    it is named by what it does.  Three class-2 records of kind 75 stand at
    the object plus `MINE_PLUME_LIFT`, each shorter-lived, slower and smaller
    than the last -- life 10/6/5, `vz` 640/480/320, half-size 30/25/20 -- and
    every one of those nine numbers is an immediate at its own call site,
    which is why none of them is a constant here.

    Its third argument is dead, the same as `0x004228F0`'s.
    """
    x, y, z = pool.inputs.source
    at = z + MINE_PLUME_LIFT
    pool.spawn(SCRATCH, 2, x, y, at, 0, 0, 0, 0x4B, 0xA, 0, 0, 0x280, 0x1E, 0)
    pool.spawn(SCRATCH, 2, x, y, at, 0, 0, 0, 0x4B, 0x6, 0, 0, 0x1E0, 0x19, 0)
    pool.spawn(SCRATCH, 2, x, y, at, 0, 0, 0, 0x4B, 0x5, 0, 0, 0x140, 0x14, 0)

@program(0x00427C80, 5)
def _c00427C80(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateFlameStream`: rings of five, and a sweep above type 5.

    Weapons 7 and 40's muzzle, and their arms push **different** literals --
    `push 4` at `0x0040D00E` and `push 0xA` at `0x0040D041` -- so the fifth
    argument is the ring count *and* the switch between two shapes.  Twenty
    records for the flame thrower, fifty for the enhanced one, and only the
    second sweeps.

    A ring begins at the source plus `FLAME_RING_OFFSET` along the **last**
    direction the inner loop took, and lays five records stepping `FLAME_STEP`
    along a direction it takes again at every one of them.  Each record's
    lifetime is the whole flight's, its velocity the direction times 1600, its
    sprite column a draw and its half-size a draw biased by the ring index over
    three -- added on the FPU **before** the truncation, which is
    `Draws.biased`.

    **The first ring is the one divergence in this module.**  See
    :data:`FLAME_RING0_DIVERGENCE`.
    """
    inputs = pool.inputs
    source = (inputs.source[0], inputs.source[1],
              inputs.source[2] + inputs.source_height)
    if inputs.source_joint is not None:
        source = inputs.source_joint
    span = max(abs(source[0] - inputs.target[0]),
               abs(source[1] - inputs.target[1]))
    life = span // FLAME_UNIT
    if life <= 0:
        life = 1
    # Unconditional, and a literal: `mov [0x4FE63C], ebx` with `ebx` zeroed at
    # `0x00427E32`, ahead of every branch.
    pool.clears_arrived = True
    aim = [inputs.target[0], inputs.target[1],
           inputs.target[2] + FLAME_LIFT]
    rings = args[4] & 0xFF
    sweeps = (args[4] & 0xFF) > FLAME_SWEEP_TYPE
    sweep, forward = -FLAME_SWEEP_LIMIT, 1
    # The three slots the ring's offset is read out of.  Zero on the first
    # pass: see `FLAME_RING0_DIVERGENCE`.
    d: Sequence[float] = (0.0, 0.0, 0.0)
    # `mov byte [esp+0x30], 2` at `0x00427F25`, ahead of both loops.
    counter = FLAME_SIZE_BASE
    for ring in range(rings):
        at = [source[0] - ftol(d[0] * FLAME_RING_OFFSET),
              source[1] - ftol(d[1] * FLAME_RING_OFFSET),
              source[2] - ftol(d[2] * FLAME_RING_OFFSET)]
        if sweeps:
            delta = (aim[0] - source[0], aim[1] - source[1],
                     aim[2] - source[2])
            # The walk happens **before** the turn and is what the turn reads:
            # `0x00427FD6` loads the angle, steps it, stores it back and only
            # then hands the structure over.
            angles = (delta[2] & 0xFFFF, delta[2] & 0xFFFF, sweep & 0xFFFF)
            sweep += FLAME_SWEEP_STEP if forward == 1 else -FLAME_SWEEP_STEP
            if sweep > FLAME_SWEEP_LIMIT:
                forward = 2
            if sweep < -FLAME_SWEEP_LIMIT:
                forward = 1
            turned = inputs.tables.rotate(delta, angles)
            aim = [source[0] + turned[0], source[1] + turned[1],
                   source[2] + turned[2]]
        for _step in range(FLAME_PER_RING):
            d = eng3d.direction_vector(tuple(at), tuple(aim), 1)
            size = draw.biased(0, FLAME_SIZE_SPAN,
                               (counter & 0xFF) // FLAME_SIZE_DIVISOR)
            counter += 1
            column = draw(0, FLAME_COLUMN_SPAN) & 0xFF
            pool.spawn(SCRATCH, 2, at[0], at[1], at[2], 0, column, 0,
                       0x31, life,
                       ftol(d[0] * SPARK_SPEED), ftol(d[1] * SPARK_SPEED),
                       ftol(d[2] * SPARK_SPEED), size, ring)
            at[0] += ftol(d[0] * FLAME_STEP)
            at[1] += ftol(d[1] * FLAME_STEP)
            at[2] += ftol(d[2] * FLAME_STEP)

@program(0x00425400, 6)
def _c00425400(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateTracerBullet` at `0x00425400`: the spore cannon's spray.

    Weapon 23's muzzle `0x0040CDEE`, and a **burst** creator like the three of
    `docs/28` §8.1.1 -- `args[4]` rounds staggered by `args[5]` -- but not one
    of them, and it does not share their prologue.  Two things are its own.

    The joint replaces the source for the record's **position** and not for
    the direction: `0x0042C660` writes over the three stack slots at
    `0x00425588`, and the direction call at `0x004256A5` then reads
    `[esi+0x10/0x14/0x18]` off the object itself.  So a spray from an
    animating shooter leaves the barrel travelling the way the body faces.

    The span it measures is the *arrived* one -- source **plus the velocity**
    against the target, at `0x004256DE` -- so a round already moving is one
    step nearer than the tile is, and a shot inside one spacing writes the
    flag and places nothing at all: the `jle` at `0x00425745` skips the loop.

    It calls `0x00403AA0` once a round and **throws the answer away**; its
    records are sprites, whose rotation slots carry an atlas row and column.
    """
    inputs = pool.inputs
    source = (inputs.source[0], inputs.source[1],
              inputs.source[2] + inputs.source_height)
    aim = (inputs.target[0], inputs.target[1],
           inputs.target[2] + inputs.target_height)
    d = eng3d.direction_vector(source, aim, 1)
    vx = ftol(d[0] * SPARK_SPEED)
    vy = ftol(d[1] * SPARK_SPEED)
    vz = ftol(d[2] * SPARK_SPEED)
    span = max(abs(source[0] + vx - inputs.target[0]),
               abs(source[1] + vy - inputs.target[1]))
    life = span // SPRAY_UNIT
    pool.clears_arrived = life > 0
    # **The point-blank arm places nothing**, which no check here exercises:
    # `blob_tables`' shape run uses a span wide enough that the loop always
    # runs, and the capture holds no records for this creator at all
    # (`PROGRAM_ARGS_STALE`).  Read, not measured.
    if life <= 0:
        return
    # The joint's own three slots, which are the record's origin.
    at = inputs.source_joint if inputs.source_joint is not None else source
    for index in range(args[4] & 0xFF):
        for pair in range(SPRAY_PAIR):
            pool.spawn(SCRATCH, 2, at[0] + vx, at[1] + vy, at[2] + vz,
                       3, 0, 0, 0x20, life, vx, vy, vz, 0x28,
                       (pair + index * args[5]) & 0xFF)


@program(0x00425CA0, 5)
def _c00425CA0(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateGrenade`: the mine thrower's round and nothing else.

    Weapons 8 and 42's muzzle `0x0040D160`, whose fifth argument the body
    never reads.  `_projectile`'s whole shape with `A_MINE1.3DI` where
    `0x00426B70` puts `A_MINE2.3DI`, and without the puff that one leaves.
    """
    _projectile(pool, args, "A_MINE1.3DI", 6)


@program(0x00426070, 6)
def _c00426070(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateGrenade` at `0x00426070`: six dots on one of seven arcs.

    Weapon 11's muzzle `0x0040D077` calls it **once per cell of its own target
    pattern that still holds a unit**, and `args[5]` is the running count of
    the cells matched so far -- in control-map order, `y * width + x` -- not
    the target's index in any list.  Weapon 44's `0x0040D0FD` pushes 0xFF
    instead and loops five times at the one aim point.

    That count is what picks the arc, out of `GRENADE_AIM`'s six, so the
    multi-target destroyer's simultaneous shots do not fly the same line; a
    seventh target and the 0xFF type both fall through to a drawn scatter.
    A cell the resolver marked **killed is among them**, which is the
    opposite of what this note used to say.  `aAttackUnit` never calls
    `aKillUnit` at all, and its only `aRemoveUnitElement` call is at
    `0x0046C1F9` -- *after* `aPlayFightAnimation` at `0x0046C186` -- so the
    cell still carries its occupant when the walk tests `cmp word [edi+7],
    0xFFFF`.  Measured, not only read: `blob_gold`'s `shot_09` phase fires
    weapon 9 at two cells the resolver marked `0x5D`, and its arm makes four
    records, which is two calls (`blob_tables.MULTI_TARGET_ARMS`,
    `docs/28` §8.1.3).

    What the type reaches, in order: the offset added to the target object
    before the direction is taken, whether three draws happen at all, and the
    record's kind -- `0x1A` and one more for 0xFF, which is
    `computed_kinds`' `[26, 27]`.

    Two gates sit in front of it.  `0x0044AE10` measures the two tiles in
    **bytes** and a separation under `GRENADE_RANGE` zeroes the whole offset
    for every type but 0xFF, so a point-blank shot flies straight.  And the
    record's position is the source *minus* the direction times
    `GRENADE_BACK` -- the same magnitude the velocity is built from, negated
    at the constant rather than at the instruction.

    Its `aux` is the **target cell's unit id**, which is what a seeking arm
    reads back as a unit-map slot (`docs/28` §7.7.1); the fourth argument's
    height is fetched at `0x0042619F` and discarded.
    """
    inputs = pool.inputs
    kind = args[5] & 0xFF
    if kind < len(GRENADE_AIM):
        offset = GRENADE_AIM[kind]
    elif kind == 0xFF:
        offset = (draw(GRENADE_PROXIMITY_BASE, GRENADE_PROXIMITY_SPAN),
                  draw(GRENADE_PROXIMITY_BASE, GRENADE_PROXIMITY_SPAN),
                  draw(0, GRENADE_PROXIMITY_RISE))
    else:
        offset = (draw(GRENADE_SCATTER_BASE, GRENADE_SCATTER_SPAN),
                  draw(GRENADE_SCATTER_BASE, GRENADE_SCATTER_SPAN),
                  draw(0, GRENADE_SCATTER_RISE))
    # `0x0044AE10` over the four tile coordinates **byte-masked**, which is
    # the engine's own four-argument form of `eng3d.distance_2d`.
    near = eng3d.distance_2d((args[0] & 0xFF) - (args[2] & 0xFF),
                             (args[1] & 0xFF) - (args[3] & 0xFF))
    if near < GRENADE_RANGE and kind != 0xFF:
        offset = (0, 0, 0)
    source = (inputs.source[0], inputs.source[1],
              inputs.source[2] + inputs.source_height)
    aim = (inputs.target[0] + offset[0], inputs.target[1] + offset[1],
           inputs.target[2] + offset[2])
    d = eng3d.direction_vector(source, aim, 1)
    at = (source[0] - ftol(d[0] * GRENADE_BACK),
          source[1] - ftol(d[1] * GRENADE_BACK),
          source[2] - ftol(d[2] * GRENADE_BACK))
    for index in range(GRENADE_COUNT):
        pool.spawn("A_LASER.3DI", 0, at[0], at[1], at[2], 0, 0, 0,
                   GRENADE_KIND + (1 if kind == 0xFF else 0), 0x64,
                   ftol(d[0] * GRENADE_SPEED), ftol(d[1] * GRENADE_SPEED),
                   ftol(d[2] * GRENADE_SPEED), inputs.target_unit, index)


@program(0x00428200, 5)
def _c00428200(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateLaser` at `0x00428200`: weapon 47's chain of dots.

    Its fifth argument is dead, and the slot that held its **fourth** is
    reused for the flight's length once the tile has been read out of it
    (`0x0042846B`) -- the same trick `0x004247C0` plays.

    One dot per frame of the flight, stepped `BEAM_DOT_SPEED` along the line
    to the target object a quarter-cell up, with a delay that advances once
    every `BEAM_DOT_STAGGER` dots, then a terminal dot of kind 71 where the
    chain ended.  The dots carry no velocity of their own: they are a drawn
    line and not a flight, and the kind-71 tail is the one that spawns
    `aBlob_CreateLaserHit2` from its update arm (`docs/97` §19.2).
    """
    inputs = pool.inputs
    at = [inputs.source[0], inputs.source[1],
          inputs.source[2] + inputs.source_height]
    if inputs.source_joint is not None:
        at = list(inputs.source_joint)
    aim = (inputs.target[0], inputs.target[1],
           inputs.target[2] + BEAM_DOT_LIFT)
    span = max(abs(at[0] - inputs.target[0]), abs(at[1] - inputs.target[1]))
    life = span // BEAM_DOT_UNIT - 1
    pool.clears_arrived = life > 0
    d = eng3d.direction_vector(tuple(at), aim, 1)
    index = 0
    while index < life:
        pool.spawn(SCRATCH, 2, at[0], at[1], at[2], 5, 0, 0, 0x46, 0x14,
                   0, 0, 0, 8, index // BEAM_DOT_STAGGER)
        at[0] += ftol(d[0] * BEAM_DOT_SPEED)
        at[1] += ftol(d[1] * BEAM_DOT_SPEED)
        at[2] += ftol(d[2] * BEAM_DOT_SPEED)
        index += 1
    pool.spawn(SCRATCH, 2, at[0], at[1], at[2], 5, 0, 0, 0x47, 0x14,
               0, 0, 0, 8, index // BEAM_DOT_STAGGER)


@program(0x00428570, 5)
def _c00428570(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateLaser` at `0x00428570`: weapon 14's seven dots.

    A different routine of the same name, and a different shape: **always**
    seven records, six of kind 63 stepped `LASER_DOT_STEP` apart and a seventh
    of kind 64 where they end, each carrying the flight's whole length as its
    lifetime and the direction times a whole map field as its velocity.  Its
    fifth argument is dead.

    A length of zero is written back as **one** at `0x004287DF` -- with the
    flag set, so the shot stage still knows there is nothing to wait for --
    which is why the loop is not a length the way `0x00428200`'s is, and why
    the direction slots the final record reads are never uninitialised.

    It opens with `aBlob_CreateZoomBob` at the shooter's own point, which is
    the puff at the muzzle, and takes its aim a quarter-cell above the target
    object.
    """
    inputs = pool.inputs
    at = [inputs.source[0], inputs.source[1],
          inputs.source[2] + inputs.source_height]
    if inputs.source_joint is not None:
        at = list(inputs.source_joint)
    _c00423720(pool, draw, (at[0], at[1], at[2], 5, 0xA, 8), None)
    span = max(abs(at[0] - inputs.target[0]), abs(at[1] - inputs.target[1]))
    life = span // LASER_DOT_UNIT - 1
    pool.clears_arrived = life > 0
    if life <= 0:
        life = 1
    aim = (inputs.target[0], inputs.target[1],
           inputs.target[2] + LASER_DOT_LIFT)
    # **The direction is taken again at every dot**, from wherever the last
    # step left the point -- `0x0046D400` sits *inside* the loop at
    # `0x00428883`, where `0x00428200`'s single call sits in front of its own.
    # So the dots do not share one velocity, and the further along the chain
    # one is the more the rounding of its own step shows in it.
    d: Sequence[float] = (0.0, 0.0, 0.0)
    for _index in range(LASER_DOT_COUNT):
        d = eng3d.direction_vector(tuple(at), aim, 1)
        pool.spawn(SCRATCH, 2, at[0], at[1], at[2], 5, 0, 0, 0x3F, life,
                   ftol(d[0] * LASER_DOT_SPEED),
                   ftol(d[1] * LASER_DOT_SPEED),
                   ftol(d[2] * LASER_DOT_SPEED), 8, 0)
        at[0] += ftol(d[0] * LASER_DOT_STEP)
        at[1] += ftol(d[1] * LASER_DOT_STEP)
        at[2] += ftol(d[2] * LASER_DOT_STEP)
    # The seventh carries the **last** direction, not one of its own.
    pool.spawn(SCRATCH, 2, at[0], at[1], at[2], 5, 0, 0, 0x40, life,
               ftol(d[0] * LASER_DOT_SPEED), ftol(d[1] * LASER_DOT_SPEED),
               ftol(d[2] * LASER_DOT_SPEED), 8, 0)

@program(0x0042ACF0, 2)
def _c0042ACF0(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_SparkingPlug`: thirty sparks off the placed object, one cell up.

    Weapon 17's muzzle and weapons 8 and 37's impact all reach it, each with
    the same two arguments and nothing else (`0x0040CCF4`, `0x0040D82C`,
    `0x0040D8D6`).

    Three things about it are worth naming.  The two zeros the loop opens
    with -- `push 0 / push 0` at `0x0042AD58` -- are pushed **before** the
    first draw and survive every `add esp, 8` in between, so they are the
    constructor's last two arguments, `aux` and `delay`, and not scratch.
    The velocities are draws **shifted**: `shl eax, 5` on the first and
    `shl eax, 4` on the other two, so the vertical one steps 32 and the two
    horizontal ones 16.  And the record stands at the object's own z plus
    `0x960` with no unit height in it at all, which `0x0042ADAC`'s
    `add eax, 0x960` is the whole of.
    """
    x, y, z = pool.inputs.source
    for _ in range(SPARKING_PLUG_COUNT):
        vz = draw(5, 0xA) * SPARKING_PLUG_RISE
        vy = draw(-0xA, 0x14) * SPARKING_PLUG_DRIFT
        vx = draw(-0xA, 0x14) * SPARKING_PLUG_DRIFT
        pool.spawn("A_FUNKE.3DI", 0, x, y, z + SPARKING_PLUG_LIFT,
                   0, 0, 0, 0x14, 0x1E, vx, vy, vz, 0, 0)


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


@program(0x00429F40, 4)
def _c00429F40(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateSporeExplosion`: rings of three, climbing `0x3C0` a ring.

    **Read from the listing, not measured** -- the class `_casing_velocity`
    is in, and the only creator in this module that no capture judges.  The
    capture in hand called it through `argument_vector`, which filled the tail
    past the two tile words with a coordinate; its fourth argument is a
    *type*, 18 is neither of the two the cascade at `0x00429FD2` names, and a
    creator that takes the cascade's fall-through makes nothing at all.  So
    the phase is a faithful zero that verifies nothing, which is exactly the
    shape `PROGRAM_ARGS_STALE` exists to name.  `blob_gold.SWITCH_ARGS` now
    carries the literal the shipped arms push, so a re-taken capture judges
    it.

    The type is the **fourth** argument and not the third: the prologue's
    `sub esp, 0x18` plus four pushes puts the return address at `[esp+0x28]`,
    and the read is at `[esp+0x38]`.  Weapon 26's arm (`0x0040D55E`) pushes
    **0** -- nine rings -- and weapons 23 and 25 (`0x0040D52C`, `0x0040D4FA`)
    push 1, which is three.  Anything else is the fall-through.

    Three things about one ring.  `rot_y` is a **flag**, 0 below the fifth
    ring and 4 from it up -- the inner loop's own `cmp esi, 3` can never
    fail, so the second arm of that cascade is unreachable and only the ring
    counter decides.  `aux` is a draw with twice the ring index added
    **inside** the conversion, the shape `0x00429A80` uses one address along.
    And `delay` is the ring index itself, so the rings go out one frame at a
    time.
    """
    x, y, z = pool.inputs.source
    kind = args[3] & 0xFF
    rings = 9 if kind == 0 else 3 if kind == 1 else 0
    for ring in range(rings):
        counter = 2 * ring
        for _ in range(3):
            dx = draw(-0x640, 0xC80)
            dy = draw(-0x640, 0xC80)
            dz = draw(0, 0x640)
            aux = draw.biased(5, 0xF, counter)
            pool.spawn(SCRATCH, 2, x + dx, y + dy,
                       z + 0x3C0 * ring + dz,
                       3, 0 if counter < 10 else 4, 0,
                       0x32, 8, 0, 0, 0, aux, ring)


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


@program(0x004247C0, 7)
def _c004247C0(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateTracerBullet`: `args[4]` rounds of tracer, casing and bob.

    The default muzzle creator -- `MUZZLE_DEFAULT` -- and the one fourteen of
    the shipped weapons select, so this is what an ordinary shot looks like.
    Its call sites all pass the same seventh argument, the one-character
    string ``"M"``, and that is the part of the shooter's Charisma model the
    round leaves from: `0x004249AF` tests the shooter's `+0x56` (docs/42 §6's
    "already animating" byte, which a fight animation sets), and when it is
    set `0x0042C660` writes the world position of the named part -- the
    part's own translation plus the object's, times the 16 of docs/40 §5.3 --
    **over the three source coordinates**.  So the axis at eye height is the
    *fallback*, for a body that is not animating; the shot itself comes out of
    the muzzle.  `Inputs.source_joint` is that position where a caller has it.

    Each round is three records and one nested creator:

    * the tracer, `A_LINE5.3DI`, at the source plus a delta that is a draw
      *minus* the direction scaled by `TRACER_STEP` -- the machine gun's shape
      with its own constant -- and living `max(|dx|, |dy|) / 2240 - 1` frames;
    * the casing, `A_CASE.3DI`, a **third of the delta behind** the source and
      at the source's own height (the machine gun drops its own by `dz`; this
      one does not), thrown sideways at 128 and up by `0x140 + draw(0, 0xA0)`;
    * `0x00423720`, the zoom bob, a fifth of the delta along.

    The last constructor field is a **stagger**: `(index * args[5]) & 0xFF`,
    read at `0x00424B8C` off the loop counter -- the slot that held argument 4
    before the prologue reused it -- times argument 6.  So the rounds leave
    one after another rather than together.
    """
    inputs = pool.inputs
    # The prologue all three seven-argument creators share, spacing apart.
    (x, y, z), _aim, d, length = _burst_prologue(pool, TRACER_UNIT)
    for index in range(args[4] & 0xFF):
        dx = draw(-160, 320) - ftol(d[0] * TRACER_STEP)
        dy = draw(-160, 320) - ftol(d[1] * TRACER_STEP)
        dz = draw(-80, 160) - ftol(d[2] * TRACER_STEP)
        pitch, yaw = inputs.tables.orient((x, y, z),
                                          (x + dx, y + dy, z + dz))
        stagger = (index * args[5]) & 0xFF
        pool.spawn("A_LINE5.3DI", 0, x + dx, y + dy, z + dz, pitch, 0, yaw,
                   0xF, length, dx, dy, dz, 0, stagger)
        vz = draw(0, 0xA0) + 0x140
        pool.spawn("A_CASE.3DI", 0, x - trunc_div(dx, 3), y - trunc_div(dy, 3),
                   z, pitch, 0, yaw, 0xB, 0x14,
                   ftol(d[1] * TRACER_CASING_SPEED),
                   ftol(d[0] * -TRACER_CASING_SPEED), vz, 0, stagger)
        # `0x00423720`, the zoom bob, with its life as a constant here where
        # the machine gun passes the burst index.
        pool.spawn(SCRATCH, 2, x + trunc_div(dx, 5), y + trunc_div(dy, 5),
                   z + trunc_div(dz, 5), 0, 0, 0, 0x32, 8, 0, 0, 0, 10, 0)


def _burst_prologue(pool: "Pool", unit: int
                    ) -> Tuple[Tuple[int, int, int], Tuple[int, int, int],
                               Sequence[float], int]:
    """The opening all three seven-argument creators share.

    `aBlob_CreateTracerBullet` `0x004247C0`, `aBlob_CreateNeedles`
    `0x00424250` and `aBlob_CreateFlash` `0x00423D80` open with the same
    instructions: the two symbol objects, the two unit heights, the joint
    override of `docs/97` §14.5, `0x0046D400`'s direction and a length that
    is the wider horizontal span over the creator's own spacing, **minus
    one** (`lea edx, [edx + eax - 1]`).  Only the spacing differs, so it is
    the argument.

    Answers `(source, aim, direction, length)`.  A length of zero is the
    point-blank answer, and each creator does something different with it.
    """
    inputs = pool.inputs
    source = (inputs.source[0], inputs.source[1],
              inputs.source[2] + inputs.source_height)
    if inputs.source_joint is not None:
        source = inputs.source_joint
    aim = (inputs.target[0], inputs.target[1],
           inputs.target[2] + inputs.target_height)
    d = eng3d.direction_vector(source, aim, 1)
    # **The span is measured from the source the joint may have replaced.**
    # `0x00424A73` reads the same stack slots `0x0042C660` wrote over, so a
    # shot from the barrel is measured from the barrel.
    span = max(abs(source[0] - inputs.target[0]),
               abs(source[1] - inputs.target[1]))
    length = trunc_div(span, unit) - 1
    if length > 0:
        pool.clears_arrived = True
    else:
        length = 0
    return source, aim, d, length


@program(0x00423D80, 7)
def _c00423D80(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateFlash`: `args[4]` muzzle flashes down the line of fire.

    Weapon 29's creator, and the second of the three burst creators
    (`docs/28` §8.1.1).  One class-2 record a round -- no casing, no model --
    at the source plus a delta that is a draw *minus* the direction scaled by
    `FLASH_STEP`, living the shared length and carrying that delta as its
    velocity.  The scatter is **half the tracer's**: `aRandom2(-80, 160)` on
    the ground plane and `aRandom2(-40, 80)` vertically.  The sprite's row is
    the literal 6 and its column is drawn, `aRandom2(0, 7)`, which is the one
    draw in this creator that is not a coordinate.

    Point-blank -- a span inside one spacing -- takes a **different branch**,
    which is what separates it from the tracer: `0x0042417B` runs `args[4]`
    zoom bobs around the *target* instead, each jittered `aRandom2(-1600,
    3200)` on all three axes, and then falls into the round loop with the
    length written back to zero, so every sprite the loop builds is dropped
    by the constructor while its four draws still happen.
    """
    source, aim, d, length = _burst_prologue(pool, FLASH_UNIT)
    rounds = args[4] & 0xFF
    if length == 0:
        for _ in range(rounds):
            aux = draw(5, 0xF)
            bob_z = draw(-1600, 3200)
            bob_y = draw(-1600, 3200)
            bob_x = draw(-1600, 3200)
            _c00423720(pool, draw, (aim[0] + bob_x, aim[1] + bob_y,
                                    aim[2] + bob_z, 6, aux, 8), None)
    for index in range(rounds):
        dx = draw(-80, 160) - ftol(d[0] * FLASH_STEP)
        dy = draw(-80, 160) - ftol(d[1] * FLASH_STEP)
        dz = draw(-40, 80) - ftol(d[2] * FLASH_STEP)
        stagger = (index * args[5]) & 0xFF
        column = draw(0, 7)
        pool.spawn(SCRATCH, 2, source[0] + dx, source[1] + dy, source[2] + dz,
                   6, column, 0, 0x45, length, dx, dy, dz, 5, stagger)


@program(0x00424250, 7)
def _c00424250(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateNeedles`: `args[4]` bursts of **nine** sprites each.

    Weapon 16's creator, the third burst creator and the one whose round is
    not a single record: the round's delta is divided by eight and laid down
    as an accumulator, so the nine records of one round sit at one eighth,
    two eighths … nine eighths of it -- a needle *streak* rather than a
    bullet.  They grow as they go: `aux` is `10 - k` for `k` counting 8 down
    to 0, and the **last** one is kind 73 where the other eight are 74
    (`xor eax, eax / test ebx, ebx / setne al / add eax, 0x49`).  All nine
    carry the round's whole delta as their velocity and the round's own
    stagger as their delay.

    Its point-blank branch is one shot rather than a loop, and it is at the
    *target*: a zoom bob at row 1 and then `0x00428F70`'s twenty plasma
    sparks.  As in `aBlob_CreateFlash` the round loop still runs and still
    draws; with the length at zero the constructor drops all nine records of
    every round.
    """
    source, aim, d, length = _burst_prologue(pool, NEEDLE_UNIT)
    for index in range(args[4] & 0xFF):
        dx = draw(-80, 160) - ftol(d[0] * NEEDLE_STEP)
        dy = draw(-80, 160) - ftol(d[1] * NEEDLE_STEP)
        dz = draw(-40, 80) - ftol(d[2] * NEEDLE_STEP)
        # `0x00403AA0` runs here in the original too and its answer is
        # thrown away: the records are class 2, whose three rotation fields
        # are the sprite's row, column and nothing.  It draws nothing, so
        # leaving it out changes no record and no seed.
        step = (trunc_div(dx, 8), trunc_div(dy, 8), trunc_div(dz, 8))
        stagger = (index * args[5]) & 0xFF
        at = list(source)
        for k in range(8, -1, -1):
            at = [at[0] + step[0], at[1] + step[1], at[2] + step[2]]
            pool.spawn(SCRATCH, 2, at[0], at[1], at[2], 1, 0, 0,
                       0x49 if k == 0 else 0x4A, length,
                       dx, dy, dz, 10 - k, stagger)
    if length == 0:
        aux = draw(5, 0xF)
        _c00423720(pool, draw, (aim[0], aim[1], aim[2], 1, aux, 8), None)
        _c00428F70(pool, draw, (aim[0], aim[1], aim[2], 0x14, 0x1E),
                   pool.inputs)


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


#: `0x00422B80` -- the shock wave's three arms, keyed by the low byte of its
#: third argument: `(records, life, speed)`.  A value outside the three makes
#: **nothing at all** -- `ecx` stays zero through the cascade at `0x00422BF4`
#: and the `jle` at `0x00422C55` skips the loop entire -- which is a real
#: answer and not a refusal, and is what the capture in hand recorded.
#: Both shipped call sites push **2** (`0x0040CD3C` and `0x0040D7AC`).
SHOCKWAVE_ARMS = {0: (30, 5, 10), 1: (50, 60, 10), 2: (60, 20, 6)}
#: `mov edi, 0xA0` at `0x00422C50` -- the ring's radius, set once before the
#: loop and then carried by the rotation itself.
SHOCKWAVE_RADIUS = 0xA0
#: `mov eax, 0x1000 / cdq / idiv ecx` at `0x00422C5B` -- a full turn divided
#: by the record count, taken **once** before the loop and kept as a word.
SHOCKWAVE_TURN = 0x1000


#: `mov edi, 0xA0` at `0x00420AE2` and `mov word [esp+0x24], 0x199` -- the
#: shock ring's radius and the turn it accumulates through `0x004039A0`.  The
#: turn is an immediate here rather than `0x1000` divided by the count, which
#: is what `aBlob_CreateShockWave` does one address along, so thirty records
#: walk the circle three times.
STINGER_RADIUS = 0xA0
STINGER_TURN = 0x199
STINGER_COUNT = 30
#: `add eax, 0xC80` -- the ring stands one map field above the placed object.
STINGER_LIFT = 0xC80
#: `lea eax, [ebx*4]` / `lea ecx, [edi*4]` -- the offset **is** the velocity,
#: four times over.
STINGER_SPEED = 4


@program(0x00420A50, 2)
def _c00420A50(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`0x00420A50`: thirty kind-47 sprites thrown off a rising ring
    (weapon 22's muzzle).

    Every record sits at the **same** point -- the placed object, one map
    field up -- and the ring goes into the *velocity*, exactly as
    `aBlob_CreateShockWave` and the selection marker do.  `delay` is the loop
    counter, so they leave one frame at a time, and nothing is drawn: the
    whole effect is the engine's own table arithmetic.
    """
    # No draw: `draw` is the signature every program shares.
    _draw = draw
    inputs = pool.inputs
    x, y, z = inputs.source
    for index, (dx, dy, _dz) in enumerate(
            _ring(inputs, STINGER_RADIUS, STINGER_TURN, STINGER_COUNT)):
        pool.spawn(SCRATCH, 2, x, y, z + STINGER_LIFT, 3, 0, 0,
                   0x2F, 0x10, dx * STINGER_SPEED, dy * STINGER_SPEED, 0,
                   10, index)


@program(0x00422B80, 3)
def _c00422B80(pool: Pool, draw: Draws, args: Sequence[int]) -> None:
    """`aBlob_CreateShockWave` (`0x0040CD56`): a ring of `A_EXPL05.3DI` model
    blobs thrown outward from the tile's placed object.

    Weapon 17's muzzle and weapon 36's impact are its two callers and both
    push type 2, so what the game ever makes is **sixty** records of kind 13
    with a life of 20.  Every one sits at the object's own position -- the
    ring goes into the *velocity*, not the placement -- oriented along the
    line from the object to its own point on the circle, exactly as the
    selection marker `0x00422D40` is.  No draw: the whole effect is table
    arithmetic, which is why `CREATOR_DRAWS` has it at zero.

    The turn accumulates through `0x004039A0` rather than being recomputed
    per record, so this is [`_ring`] and not a clean division of the circle.
    """
    inputs = pool.inputs
    arm = SHOCKWAVE_ARMS.get(args[2] & 0xFF)
    if arm is None:
        return
    count, life, speed = arm
    x, y, z = inputs.source
    turn = trunc_div(SHOCKWAVE_TURN, count) & 0xFFFF
    for dx, dy, _dz in _ring(inputs, SHOCKWAVE_RADIUS, turn, count):
        pitch, yaw = inputs.tables.orient((x, y, z), (x + dx, y + dy, z))
        pool.spawn("A_EXPL05.3DI", 0, x, y, z, pitch, 0, yaw,
                   0x0D, life, dx * speed, dy * speed, 0, 0, 0)


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


def _ring(inputs: Any, radius: int, turn: int, count: int
          ) -> List[Tuple[int, int, int]]:
    """`count` offsets, each the previous one turned by `turn` through
    `0x004039A0` -- the rotation accumulates, so the ring is the engine's
    table arithmetic and not a clean division of the circle -- paired with
    the orientation `0x00403AA0` gives the line from the object to that
    point.

    `inputs` is whichever of :class:`Inputs` and :class:`DeathInputs` the
    caller carries: the helper reads `tables` and nothing else, and the ring
    creators live in both registries.
    """
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
    # `0x0042A938` -- the fly-past is something to wait for.
    pool.clears_arrived = True
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
    # `0x0042B0E3` -- and so is each bomb, until it lands.
    pool.clears_arrived = True
    ox, oy, oz = inputs.object(x, y)
    life = abs(trunc_div(BOMB_CEILING - oz, BOMB_FALL))
    rz = draw(0, 0x1000)
    pool.spawn("A_PARAB1.3DI", 0, ox, oy, BOMB_DROP, 0, 0x40, rz, 0x19, life, 0, 0,
               -BOMB_FALL, 0, delay)


# --------------------------------------------------------------------------
# The twelve an update **arm** calls -- `docs/97` §49
# --------------------------------------------------------------------------
#
# `docs/28` §8.1's weapon switches name thirty creators and `docs/42` §§7-9
# another twenty-nine; these are the rest, and they are reached from a third
# place entirely -- an update arm's own `aBlob_Create*` call, `docs/28` §7.1.
# The remake recorded such a request and never ran it until `game_blob_hooks`
# did, which is why nothing here needed a program before and why every one of
# them needed one at once.
#
# All twelve are stepped in a live `Incubation.exe`: `blob_gold.py`'s
# `zoom_bob_*` and `spawn_*` families poke a donor record to the kind whose
# arm calls each, write the second generator's seed, step one `aBlob_Update`
# and read the pool **wide enough to hold the child** -- which the poked
# family's twelve-record window never did.


def _sparking_rain(pool: Pool, draw: Draws, x: int, y: int, z: int,
                   count: int, speed: int) -> None:
    """`aBlob_SparkingRain` `0x0042ADD0(x, y, z, count, speed)`.

    Not a program of its own: nothing but `0x0042A410` calls it.  ``speed``
    is a **two-value enumeration** and the third value is a `CHECK` --
    `0x0042ADF2` pushes `"unknown speed"` and the routine returns without
    making anything, which is the one arm of it a capture cannot reach
    because no caller passes a third value.  0 is the slow rain (a life of
    30 and the sideways draws as they come), 1 the fast one (a life of 5 and
    both doubled).
    """
    if speed == 0:
        multiplier, life = 1, 30
    elif speed == 1:
        multiplier, life = 2, 5
    else:
        return
    for _ in range(count & 0xFF):
        vz = draw(5, 10) << 5
        vy = (draw(-10, 20) * multiplier) << 4
        vx = (draw(-10, 20) * multiplier) << 4
        pool.spawn("A_FUNKE.3DI", 0, x, y, z, 0, 0, 0, 0x14, life,
                   vx, vy, vz, 0, 0)


@death_program(0x00420950, 15)
def _c00420950(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """The **constructor itself**, which two arms call directly.

    `0x00420950` is not a creator and has no arithmetic of its own -- it is
    the record writer every creator here ends in -- so the program is
    :meth:`Pool.spawn` and nothing else.  The name argument is a pointer, and
    the only one an arm passes is `0x004FA524`, the scratch buffer
    `blob_tables.BLOB_NAME_SCRATCH` pins: a class-2 record ignores it.
    """
    (name, class_id, x, y, z, rot_x, rot_y, rot_z, kind, life,
     vx, vy, vz, aux, delay) = args
    pool.spawn(SCRATCH if name == NAME_SCRATCH else str(name), class_id,
               x, y, z, rot_x, rot_y, rot_z, kind, life, vx, vy, vz,
               aux, delay)


@death_program(0x00428E30, 5)
def _c00428E30(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x00428E30(x, y, z, count, life)` -- the spore sparks: ``count``
    class-2 records of kind 23 at one point, row 6, aux 3, delayed one frame
    past the next, rising 100..400 and drifting +-100.  Three draws each, and
    the **middle one is the sideways x** rather than the y: the compiler
    evaluated the two `aRandom2(-100, 200)` calls in source order and pushed
    them in reverse, so the second draw is the tenth argument."""
    x, y, z, count, life = args
    for _ in range(count & 0xFF):
        vz = draw(100, 300)
        vx = draw(-100, 200)
        vy = draw(-100, 200)
        pool.spawn(SCRATCH, 2, x, y, z, 6, 0, 0, 0x17, life,
                   vx, vy, vz, 3, 2)


@death_program(0x00428ED0, 5)
def _c00428ED0(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x00428ED0(x, y, z, count, life)` -- the plasma sparks: the spore
    sparks' body with a **model** rather than a sprite (`A_FUNKE.3DI`, class
    0), no row and no aux."""
    x, y, z, count, life = args
    for _ in range(count & 0xFF):
        vz = draw(100, 300)
        vx = draw(-100, 200)
        vy = draw(-100, 200)
        pool.spawn("A_FUNKE.3DI", 0, x, y, z, 0, 0, 0, 0x17, life,
                   vx, vy, vz, 0, 2)


@death_program(0x00428F70, 5)
def _c00428F70(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x00428F70(x, y, z, count, _)` -- the big plasma burst, and the one
    creator here whose **speed is drawn per component**.

    It is called with **five** dwords and reads four.  The fifth is the
    sibling sparks' `life` and this one draws its own instead; the slot is
    never read, and the compiler uses the *fourth* argument's slot as the
    scratch its three `fild`s load from, which is what makes the omission
    easy to misread as a use.

    Three draws before the loop pick one scattered point (+-12800 sideways,
    12800..25600 up) and every spark then aims within +-160 of *that*, so the
    burst is a cone rather than a sphere.  Each spark's velocity is
    `0x0046D400`'s direction times a speed of its own -- `aRandom2(160, 160)`
    upward and `aRandom2(480, 320)` sideways, each truncated **before** the
    multiply (`fild` of the stored integer) and again after it.  Eight draws
    a spark, in the order x, y, z, delay, then the three speeds z, y, x, then
    the life.
    """
    x, y, z, count = args[:4]
    ax = x + draw(-0x3200, 0x6400)
    ay = y + draw(-0x3200, 0x6400)
    az = z + draw(0x3200, 0x3200)
    for _ in range(count & 0xFF):
        aim = (ax + draw(-0xA0, 0x140), ay + draw(-0xA0, 0x140),
               az + draw(-0xA0, 0x1E0))
        d = inputs.tables.direction((x, y, z), aim, 1)
        pitch, yaw = inputs.tables.orient((x, y, z), aim)
        delay = draw(0, 4)
        vz = ftol(draw(0xA0, 0xA0) * d[2])
        vy = ftol(draw(0x1E0, 0x140) * d[1])
        vx = ftol(draw(0x1E0, 0x140) * d[0])
        life = draw(0xA, 0xF)
        pool.spawn("A_SPARK.3DI", 0, x, y, z, pitch, 0, yaw, 0x48, life,
                   vx, vy, vz, 0, delay)


@death_program(0x00429390, 4)
def _c00429390(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x00429390(x, y, z, count)` -- the spores: the same three draws
    again, into kind 40 at row 3 with a fixed life of 8."""
    x, y, z, count = args
    for _ in range(count & 0xFF):
        vz = draw(100, 300)
        vx = draw(-100, 200)
        vy = draw(-100, 200)
        pool.spawn(SCRATCH, 2, x, y, z, 3, 0, 0, 0x28, 8, vx, vy, vz, 3, 2)


@death_program(0x00429430, 5)
def _c00429430(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x00429430(x, y, z, vx, vy)` -- the sting sparks, and the one creator
    here that **draws nothing**.

    Two class-2 records of kind 33, row 3, life 8, whose velocities are the
    caller's own turned a quarter turn either way and cut to a fifth:
    `(-vy/5, vx/5)` and `(vy/5, -vx/5)`.  The divide is the compiler's
    reciprocal multiply (`0x66666667` and `0x99999999` with `sar edx, 1`),
    which is a C divide and truncates toward zero -- Python's `//` does not.
    """
    x, y, z, vx, vy = args
    fifth_x = trunc_div(vx, 5)
    fifth_y = trunc_div(vy, 5)
    pool.spawn(SCRATCH, 2, x, y, z, 3, 0, 0, 0x21, 8,
               -fifth_y, fifth_x, 0, 5, 1)
    pool.spawn(SCRATCH, 2, x, y, z, 3, 0, 0, 0x21, 8,
               fifth_y, -fifth_x, 0, 5, 1)


@death_program(0x0042A410, 4)
def _c0042A410(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x0042A410(x, y, z, delay)` -- one hit flash over a fast sparking
    rain.  The rain is `0x0042ADD0` with a count of 1 and a speed of 1, both
    literals, and the flash is an `A_HIT1.3DI` of kind 16 and life 4 that
    carries the caller's delay."""
    x, y, z, delay = args
    _sparking_rain(pool, draw, x, y, z, 1, 1)
    pool.spawn("A_HIT1.3DI", 0, x, y, z, 0, 0, 0, 0x10, 4, 0, 0, 0, 0, delay)


@death_program(0x0042A480, 4)
def _c0042A480(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x0042A480(x, y, z, delay)` -- the same flash with `A_EXPL04.3DI` and
    without the rain.  No draw."""
    x, y, z, delay = args
    pool.spawn("A_EXPL04.3DI", 0, x, y, z, 0, 0, 0, 0x10, 4, 0, 0, 0, 0, delay)


@death_program(0x0042A7A0, 4)
def _c0042A7A0(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x0042A7A0(x, y, z, delay)` -- **a hundred** `A_LINE2.3DI` streaks.

    The body is `0x00429180`'s (`docs/97` §22) at a different scale: each
    streak aims at a point scattered around the origin, takes its rotation
    from `0x00403AA0` and its velocity from `0x0046D400` scaled by the same
    flat 1600, and lives `aRandom2(4, 15)` ticks.  The scatter is the wide
    one -- +-12800 sideways and -3200..22400 up -- and the aim is built by
    truncating each draw and **then** adding the coordinate, which is the
    plain `add` at `0x0042A7DA` and not kind 56's `fiadd`.
    """
    x, y, z, delay = args
    for _ in range(0x64):
        sx = x + draw(-0x3200, 0x6400)
        sy = y + draw(-0x3200, 0x6400)
        sz = z + draw(-0xC80, 0x6400)
        aim = (sx, sy, sz)
        d = inputs.tables.direction((x, y, z), aim, 1)
        pitch, yaw = inputs.tables.orient((x, y, z), aim)
        life = draw(4, 0xF)
        pool.spawn("A_LINE2.3DI", 0, x, y, z, pitch, 0, yaw, 0x13, life,
                   ftol(d[0] * SPARK_SPEED), ftol(d[1] * SPARK_SPEED),
                   ftol(d[2] * SPARK_SPEED), 0, delay)


@death_program(0x0042A9D0, 4)
def _c0042A9D0_arm(pool: Pool, draw: Draws, args: Sequence[int],
                   inputs: DeathInputs) -> None:
    """`0x0042A9D0` again -- the laser hit, which is both a weapon creator
    and an arm's.

    The program is `PROGRAMS`' (`docs/97` §22, measured against the engine's
    own pool through a weapon switch); this entry only makes it reachable
    from the registry the arms go through, so the two cannot drift apart.
    """
    PROGRAMS[0x0042A9D0][1](pool, draw, args)


@death_program(0x0042B150, 3)
def _c0042B150(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x0042B150(x, y, z)` -- **the arm's** para bomb, and not
    `0x0042B070`'s: no object lookup, no ceiling, no *arrived* flag.  One
    `A_PARAB1.3DI` of kind 25 and life 200 at the point given, falling 800 a
    tick with +-500 of sideways drift and a rotation drawn 0..4095.  Three
    draws, in the order y, x, spin."""
    x, y, z = args
    vy = draw(-500, 1000)
    vx = draw(-500, 1000)
    spin = draw(0, 0x1000)
    pool.spawn("A_PARAB1.3DI", 0, x, y, z, 0x100, 0, spin, 0x19, 0xC8,
               vx, vy, -800, 0, 0)


@death_program(0x0042B300, 3)
def _c0042B300(pool: Pool, draw: Draws, args: Sequence[int],
               inputs: DeathInputs) -> None:
    """`0x0042B300(x, y, z)` -- twenty tumbling `A_DEBRIS.3DI` of kind 39 and
    life 50.  Each takes four draws: two sideways at +-600, one upward
    40..1440 and one delay 0..5 -- and its **rotation is its velocity**, the
    same three registers pushed twice."""
    x, y, z = args
    for _ in range(0x14):
        vx = draw(-600, 1200)
        vy = draw(-600, 1200)
        vz = draw(40, 1400)
        delay = draw(0, 6)
        pool.spawn("A_DEBRIS.3DI", 0, x, y, z, vx, vy, vz, 0x27, 0x32,
                   vx, vy, vz, 0, delay)
