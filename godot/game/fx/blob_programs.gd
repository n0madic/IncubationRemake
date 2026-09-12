class_name BlobPrograms
extends RefCounted

## The death and damage creators of docs/42 section 4.8.1, as programs.
##
## `tools/inclib/blob_creators.py` reads each creator out of its own
## instructions -- what it draws, in what order, and the record it hands the
## constructor -- and `tools/presentation_gold.py` calls the same creator
## inside a running `Incubation.exe` with controlled tiles and a written seed,
## then reads the pool back: every record agrees field for field, and the draw
## count agrees with the seed the call left (`docs/42` section 4.8.1). This
## file is that Python's twin, and `tests/test_presentation_native.gd` replays
## the **engine's** records against it -- so what a death looks like here is
## measured, not the remake's invention.
##
## The programs draw from their own [IncRandom], the twin of `0x004638E0`
## (`aRandom2`, the uncounted second generator of docs/22 section 3.2), and
## never from [member World.rng]: an effect must not move the simulation's
## seed.
##
## A record is a dictionary of the constructor's fifteen fields, in the order
## `blob_tables.BLOB_CTOR_STORES` reads them, plus `model_name` for the live
## pool to resolve; the suite compares the fifteen.

## The constructor's argument order.
const FIELDS: Array[String] = ["model", "class_id", "x", "y", "z", "rot_x",
	"rot_y", "rot_z", "kind", "life", "vx", "vy", "vz", "aux", "delay"]
## `0x004FA524` -- the name buffer classes 2 and 3 pass and the constructor
## ignores.
const SCRATCH: String = "<scratch>"
## docs/20 section 8 -- the gore levels of `Game.opt`'s dword 10.
const GORE_NONE: int = 1
const GORE_COMPUTER_ONLY: int = 2
const GORE_FULL: int = 3
## `0x00461E80` -- the output-system mode in which the debris loop is long.
const DEBRIS_FULL_MODE: int = 3
## docs/22 section 9.2 -- the computer's player byte.
const PLAYER_COMPUTER: int = 0xFF
## The doubles the blood sprays read (`blob_tables.CREATOR_CONSTANT_SITES`).
const BLOOD_VELOCITY: float = 16.0
const BLOOD_VELOCITY_LARGE: float = 48.0
const BLOOD_LIFT: float = 160.0
const BLOOD_STEP: float = -1280.0
## `0x004B1268` -- the species death's coin: `aRandom2(0, 10) <= 6.0`.
const SPECIES_COIN: float = 6.0
## The types with their own death models; type 57's arm is unreachable.
const SPECIES_MODELS: Dictionary = {
	50: ["A_50A.3DI", "A_50B.3DI", "A_50C.3DI"],
	51: ["A_51A.3DI", "A_51B.3DI", "A_51C.3DI"],
	56: ["A_56A.3DI", "A_56B.3DI", "A_56C.3DI"],
}
const SPLATS: Array[String] = ["A_SPLAT1.3DI", "A_SPLAT2.3DI", "A_SPLAT3.3DI",
	"A_SPLAT4.3DI", "A_SPLAT5.3DI"]
## The four blood pieces that trail a splat or a species piece, in order.
const BLOOD_TRAIL: Array[String] = ["A_BLUT1.3DI", "A_BLUT1.3DI", "A_BLUT2.3DI",
	"A_BLUT3.3DI"]
## The creators, by the address the death switch calls (docs/42 section 4.8).
const PUFF: String = "0x004297F0"
const BLOOD_BURST: String = "0x00420B80"
const BARREL_BURST: String = "0x004298D0"
const BLOOD_FLOOD: String = "0x00420D80"
const BLOOD_SPRAY_LARGE: String = "0x00421360"
const FLYING_DEBRIS: String = "0x004216D0"
const SPECIES_BURST: String = "0x00421C50"
const KILL_FIRE: String = "0x00423AD0"
const FIRE_DEATH: String = "0x0042B1D0"
const FLYING_UNIT: String = "0x00429700"
const FIRE_EXPLOSION: String = "0x00429A80"
## docs/42 section 7 -- the unit animations' creators (docs/97 section 31).
const SHOCK_WAVE: String = "0x00422B80"
const ARROWS: String = "0x00422D40"
const LANDING_DUST: String = "0x004227C0"
const HEAL_FLASH: String = "0x00423030"
const POISON_FLASH: String = "0x004232E0"
const ZOOMBOB: String = "0x00423720"
const TRAIL: String = "0x00423670"
const PUSH_DUST: String = "0x0042A6E0"
## `0x0042A660` -- `aBlob_CreateMainMapFire`, the one creator a **script**
## reaches: `CreateBGB` type 7 calls it once a tick (docs/28 section 8.2), and
## the campaign maps' own `InitMap` is where the shipped data uses it.
const MAIN_MAP_FIRE: String = "0x0042A660"
## The five one-shot creators `CreateBGB` runs **at registration**, and the
## smoke emitter its tick runs beside the fire.
##
## `aEnterBGBCreator`'s own jump table (`0x0041E120`, indexed by `type`) and
## the sweep's (`0x0041E300`, indexed by `type - 1`) are two different tables,
## and no type is in both: types 2..6 make their object once and are never
## touched again, types 1 and 7 make one per tick and nothing at registration.
## `blob_tables.py` pins both tables entry for entry.
##
## Types 4 and 6 push the name *"aBlob_CreateCreateFire"* on their failure
## path -- the same string type 4 pushes, and neither is a fire. A programmer
## pasted their neighbour's `CHECK` line, so these two are named by their
## model rather than by the image's own word for them.
const BGB_WARNING_LIGHT: String = "0x0042A4C0"
const BGB_FIRE3: String = "0x0042A520"
const BGB_LAMP: String = "0x0042A560"
const BGB_SPOT: String = "0x0042A5A0"
const BGB_SMOKE: String = "0x0042A5E0"
const BGB_COMPUTER_LIGHT: String = "0x0042A760"
## The five models those creators name, and the `A_PANEL.3DI` the flicker
## rides on. `L049EE00.3DI` is a world-set object name rather than an `A_`
## effect model, which is why type 6 is *the lamp* here and not a fire.
const BGB_WARNING_MODEL: String = "A_FLIGHT.3DI"
const BGB_FIRE3_MODEL: String = "A_FIRE3.3DI"
const BGB_LAMP_MODEL: String = "L049EE00.3DI"
const BGB_SPOT_MODEL: String = "A_SPOTL.3DI"
const BGB_PANEL_MODEL: String = "A_PANEL.3DI"
## `0x0042A4C0`'s coin: `aRandom2(0, 100) >= 50` picks the sign of the spin
## kind 41 divides `0x200` by, so the light turns one way or the other.
const BGB_WARNING_COIN: int = 50
const BGB_WARNING_SPIN: int = 5
## `0x0042A760` shifts the script's `gamma` left by ten before it becomes the
## panel's `rot_z` -- one unit of `gamma` is a quarter turn of Eng3d's 4096.
const BGB_GAMMA_SHIFT: int = 10
## The marker's and the poison flash's radius (`push 0x12C0`), doubled for
## a large type (`push 0x2580`); the heal flash's (`0x640` / `0x1900`); the
## landing dust's (`0xC80`) and the 204-unit turn between its puffs.
const RING_RADIUS: int = 0x12C0
const RING_RADIUS_LARGE: int = 0x2580
const FLASH_RADIUS: int = 0x640
const FLASH_RADIUS_LARGE: int = 0x1900
const DUST_RADIUS: int = 0xC80
const DUST_TURN: int = 0xCC
## The quarter turn between arrows and skulls, the twelfth between crosses.
## `0x00422B80`'s three arms, keyed by the low byte of its third argument:
## `[records, life, speed]`. A value outside the three makes nothing at all --
## `ecx` stays zero through the cascade at `0x00422BF4` and the `jle` at
## `0x00422C55` skips the loop entire. Both shipped call sites push **2**
## (`blob_tables.SHOCKWAVE_TYPE_SITES`), so what the game ever makes is the
## last row.
const SHOCKWAVE_ARMS: Dictionary[int, Array] = {
	0: [30, 5, 10], 1: [50, 60, 10], 2: [60, 20, 6],
}
## `mov edi, 0xA0` at `0x00422C50`, and `mov eax, 0x1000 / cdq / idiv ecx` at
## `0x00422C5B`: the ring's radius and a full turn divided by the record
## count, both taken once before the loop.
const SHOCKWAVE_RADIUS: int = 0xA0
const SHOCKWAVE_TURN: int = 0x1000
const SHOCKWAVE_MODEL: String = "A_EXPL05.3DI"
const SHOCKWAVE_KIND: int = 0x0D

const QUARTER_TURN: int = 0x400
const CROSS_TURN: int = 0x155
const ARROW_MODEL: String = "A_ARROW.3DI"
const SKULL_MODEL: String = "A_SKULL.3DI"
const CROSS_MODELS: Array[String] = ["A_CROSS3.3DI", "A_CROSS2.3DI",
	"A_CROSS1.3DI", "A_CROSS.3DI"]
## docs/42 section 8 -- the set pieces' creators (docs/97 section 32).
const TUBE_PUFFS: String = "0x00423770"
## `aBlob_CreateTubeSmoke`, the one thing an ignited ground fire makes on a
## cell with nobody on it (docs/42 section 9.1).
const TUBE_SMOKE: String = "0x00423C20"
const PLATFORM_DUST: String = "0x004234C0"
const GROUND_DEBRIS: String = "0x00422610"
const ROOF_DEBRIS: String = "0x00422460"
const WALL_DEBRIS: String = "0x004238C0"
const FIRE_CIRCLE: String = "0x00422F00"
const LASER_BARRIER: String = "0x00428990"
const STATUE_BEAM: String = "0x00428BF0"
const TELEPORT_STREAM: String = "0x0042A120"
const BOMBER: String = "0x0042A8E0"
const PARA_BOMB: String = "0x0042B070"
## The twelve an update **arm** calls (docs/97 section 49). They reach this
## file from a third place: not a weapon switch (docs/28 section 8.1) and not
## a set piece (docs/42), but [method BlobKinds._spawn], which [GameBlobHooks]
## runs. All twelve are stepped in a live `Incubation.exe`.
## The **weapon switches'** own creators, transcribed out of their own
## instructions and line-diffable against `tools/inclib/blob_creators.py`.
## `BlobTriggers` runs them where it used to build one record per constructor
## call site (docs/97 section 14.5); each is checked against
## `blob_gold.py`'s capture by `test_blob_native.gd`.
const SMOKE_TRAIL: String = "0x00425810"
const MACHINE_GUN: String = "0x00424D20"
const BLIZZARD_SHOT: String = "0x004264A0"
const LASER_GREEN: String = "0x00426F90"
const BLUE_LASER: String = "0x00427410"
const PLASMA_BEAM: String = "0x00427810"
const LINE_FIRE: String = "0x00429180"
const BLIZZARD_HIT: String = "0x0042AF10"
const SPORE_EXPLOSION: String = "0x00429F40"
const STINGER_RING: String = "0x00420A50"
const SPARKING_PLUG: String = "0x0042ACF0"
const PLASMA_BALL_IMPACT: String = "0x004294E0"
const EXPLOSION2: String = "0x004295D0"
const SPIDY_MINES: String = "0x00426B70"
const FIRE_WHEEL: String = "0x004228F0"
const MINE_PLUME: String = "0x00429C30"
const SPRAY: String = "0x00425400"
const GRENADE_ROUND: String = "0x00425CA0"
const GRENADE_ARC: String = "0x00426070"
const BEAM_DOTS: String = "0x00428200"
const LASER_DOTS: String = "0x00428570"
const FLAME_STREAM: String = "0x00427C80"

## `0x004B1278` / `0x004B12C0` / `0x004B1280` and the two the compiler left as
## reciprocal multiplies -- `blob_creators.py` carries the same numbers with
## the sites that hold them. Every one of them is negative and **subtracted**,
## which is the family's one shared idiom.
const BEAM_STEP: float = -2400.0
const BEAM_UNIT: int = 0x960
const BEAM_BASE: int = 0xC80
const HEAD_STEP: float = -3200.0
const HEAD_SPEED: float = 4800.0
const DOT_SPEED: float = 80.0
const SHARD_SPEED: float = 1920.0
const TRAIL_STEP: float = -960.0
const TRAIL_UNIT: int = 0x3C0
const TRACER_SPREAD: float = 640.0
const TRACER_LEAN: int = 200
const MACHINE_GUN_CASING_SPEED: float = 80.0
## `0x00420AE2`'s `mov edi, 0xA0` and `mov word [esp+0x24], 0x199`, and the
## `add eax, 0xC80` / `lea [ebx*4]` beside them: the stinger ring's radius,
## its accumulating turn, the map field it stands above the object and the
## four its offset is multiplied by to become a velocity.
const STINGER_RADIUS: int = 0xA0
const STINGER_TURN: int = 0x199
const STINGER_COUNT: int = 30
const STINGER_LIFT: int = 0xC80
const STINGER_SPEED: int = 4
## `aBlob_SparkingPlug` `0x0042ACF0`, all four off its own loop: `mov edi,
## 0x1E` at `0x0042AD53`, `shl eax, 5` at `0x0042AD6D`, `shl eax, 4` at
## `0x0042AD82`/`0x0042AD9D`, and `add eax, 0x960` at `0x0042ADAC`.
const SPARKING_PLUG_COUNT: int = 30
const SPARKING_PLUG_RISE: int = 32
const SPARKING_PLUG_DRIFT: int = 16
const SPARKING_PLUG_LIFT: int = 0x960
## `aBlob_CreatePlasmaBallImpact` `0x004294E0`: `mov ebp, 0x28` at
## `0x00429549` and the two draw ranges its loop pushes.
const PLASMA_IMPACT_COUNT: int = 40
const PLASMA_IMPACT_RISE_BASE: int = 200
const PLASMA_IMPACT_RISE_SPAN: int = 300
const PLASMA_IMPACT_DRIFT_BASE: int = -300
const PLASMA_IMPACT_DRIFT_SPAN: int = 600
## `aBlob_CreateExplosion2` `0x004295D0`: `mov ebp, 0xF` at `0x00429639` and
## its own rise range; the drift is the pair above, shared.
const EXPLOSION2_COUNT: int = 15
const EXPLOSION2_RISE_BASE: int = 600
const EXPLOSION2_RISE_SPAN: int = 700
## `aBlob_CreateSpidyMines` `0x00426B70` and `aBlob_CreateGrenade`
## `0x00425CA0`, which are one body with two models: the flight speed
## `0x004B12C8` holds as a double, the `sar edx, 8` after `imul 0x51EB851F`
## that divides the span by 800, the `lea esi, [edx+eax-2]` the life ends on,
## and the `shl 2` / `shl 3` the lob is written as.
const PROJECTILE_SPEED: float = 800.0
const PROJECTILE_UNIT: int = 800
const PROJECTILE_LIFE_BIAS: int = 2
## `aBlob_CreateFireWheel` `0x004228F0` -- weapon 44's muzzle and impact:
## thirty sprite puffs off the object, then thirty explosion models thrown
## outwards along a spoke the creator turns one step at a time.
const FIRE_WHEEL_COUNT: int = 0x1E
const FIRE_WHEEL_RISE_BASE: int = 0x190
const FIRE_WHEEL_RISE_SPAN: int = 0x320
const FIRE_WHEEL_DRIFT_BASE: int = -0x64
const FIRE_WHEEL_DRIFT_SPAN: int = 0xC8
## Thirty steps of 136 is 4080 of the circle's 4096, so the wheel closes.
const FIRE_WHEEL_RADIUS: int = 0xA0
const FIRE_WHEEL_TURN: int = 0x88
const FIRE_WHEEL_SPEED: int = 4
const FIRE_WHEEL_LIFT: int = 0xC80
## Every fourth explosion is `A_EXPL04.3DI` and the rest `A_EXPL03.3DI`.
const FIRE_WHEEL_EXPL04_EVERY: int = 3

## `0x00429C30` -- weapon 13's impact plume, three sprite puffs and no draw.
const MINE_PLUME_LIFT: int = 0x640

## `aBlob_CreateFlameStream` `0x00427C80` -- weapons 7 and 40's muzzle, and the
## one creator of the thirty whose first pass reads **uninitialised stack**.
## See [constant FLAME_RING0_DIVERGENCE].
##
## Its fifth argument is the ring count *and* the switch between two shapes:
## weapon 7's arm pushes four and weapon 40's ten, so twenty records against
## fifty and only the second sweeps.
const FLAME_RING_OFFSET: float = -960.0
const FLAME_STEP: float = 266.66666666666663
const FLAME_PER_RING: int = 5
## Half a map field, where both lasers count in whole ones.
const FLAME_UNIT: int = 1600
const FLAME_LIFT: int = 0x320
## The sprite's half-size is a draw **biased** by a third of a counter of its
## own, added on the FPU before the truncation. Its column is a second draw.
##
## **The counter is neither the ring nor the record index.** It is a byte at
## `[esp+0x30]`, set to two by a literal at `0x00427F25` ahead of both loops
## and incremented once per record at `0x00428181`, so the bias is
## `(2 + n) / 3` over the whole call and steps inside a ring as much as between
## rings. Read as `ring / 3` it was right for the call's first record and one
## or more short for every other -- eleven of the engine's twelve records
## disagreed, all of them on `aux` (docs/97 section 14.5.2).
const FLAME_SIZE_SPAN: int = 5
const FLAME_SIZE_BASE: int = 2
const FLAME_SIZE_DIVISOR: int = 3
const FLAME_COLUMN_SPAN: int = 3
## Above this type the stream sweeps: the aim is turned about the shooter by an
## angle that walks and reverses at the limit. The three angles it turns by are
## `(dz, dz, sweep)` -- the vertical delta twice, which reads as a slip for
## `(0, 0, sweep)` and is transcribed as it ships.
const FLAME_SWEEP_TYPE: int = 5
const FLAME_SWEEP_STEP: int = 0xA
const FLAME_SWEEP_LIMIT: int = 0x1E
## **What is still read rather than measured, now that the rest is measured.**
##
## `0x00427C80` opens each ring by reading the three doubles its inner loop
## wrote last (`0x00427F4F` onwards) and scaling them by
## [constant FLAME_RING_OFFSET]. On the **first** ring the inner loop has not
## run and those slots are the frame's own uninitialised locals, so the value
## is the caller's residue and not anything in the routine.
##
## Zero stands in for them, and on 2026-09-12 the engine agreed: the creator
## was called inside the live process and all twelve records it makes came
## back matching this program field for field, ring 0's five included, so the
## slots held zero in that frame. Two readings support it -- the point-blank
## arm at `0x00428093` zeroes exactly those three doubles, so zero is a value
## the routine itself writes there; and the residue at that depth is small
## integers and pointers reinterpreted as doubles, which are tiny and truncate
## to zero. (Not NaN: `_ftol` answers `0x80000000` for a NaN, so the NaN half
## of the old argument here was wrong.)
##
## **What that does not settle** is the frame. A plan calls the creator from
## `dbgcall`'s anchor, and a shot calls it from `aPlayFightAnimation`; the
## slots are whatever each caller left. Measuring the shipped path needs a
## break at `0x0040D014` or `0x0040D047` during a real shot, which no harness
## here does. `blob_creators.FLAME_RING0_DIVERGENCE` is the same note.
const FLAME_RING0_DIVERGENCE: String = FLAME_STREAM

## `aBlob_CreateTracerBullet` at `0x00425400` -- the spore cannon's spray.
## Its speed is [constant SPARK_SPEED]'s own cell.
const SPRAY_UNIT: int = 1600
const SPRAY_PAIR: int = 2

## `aBlob_CreateGrenade` at `0x00426070` -- weapon 11's arcs and weapon 44's
## proximity round.
const GRENADE_COUNT: int = 6
const GRENADE_SPEED: float = 1920.0
const GRENADE_BACK: float = -1920.0
const GRENADE_KIND: int = 0x1A
const GRENADE_RANGE: int = 6
const GRENADE_SCATTER_BASE: int = -0x1F40
const GRENADE_SCATTER_SPAN: int = 0x3E80
const GRENADE_SCATTER_RISE: int = 0x3200
const GRENADE_PROXIMITY_BASE: int = -0x12C0
const GRENADE_PROXIMITY_SPAN: int = 0x2580
const GRENADE_PROXIMITY_RISE: int = 0x3E80
## The type that draws instead of taking an arc, and the one that adds one to
## the kind: weapon 44's arm pushes it where weapon 11's pushes a target index.
const GRENADE_PROXIMITY: int = 0xFF
## Where each of the first six shots is aimed, as an offset from the target
## object -- one arc per type, out of the six arms of the jump table at
## `0x00426484`, so six simultaneous shots do not fly the same line.
const GRENADE_AIM: Array[Vector3i] = [
	Vector3i(-0x3200, -0x2580, 0x1900),
	Vector3i(0x1900, 0xC80, 0x3200),
	Vector3i(-0x1F40, -0x2BC0, 0x12C0),
	Vector3i(0x1900, 0x12C0, 0x1F40),
	Vector3i(0xC80, 0xC80, 0x2580),
	Vector3i(-0x3200, -0x2BC0, 0x3200),
]

## `aBlob_CreateLaser` at `0x00428200` -- weapon 47's chain of dots.
const BEAM_DOT_SPEED: float = 320.0
const BEAM_DOT_UNIT: int = 320
const BEAM_DOT_STAGGER: int = 5
const BEAM_DOT_LIFT: int = 0x320

## `aBlob_CreateLaser` at `0x00428570` -- weapon 14's seven dots.
const LASER_DOT_COUNT: int = 6
const LASER_DOT_SPEED: float = 3200.0
const LASER_DOT_STEP: float = 480.0
const LASER_DOT_UNIT: int = 3200
const LASER_DOT_LIFT: int = 0x320

const PROJECTILE_LOB_SPREAD: int = 4
const PROJECTILE_LOB_SCALE: int = 8
## `0x00425D9A` and `0x00426C6A` -- the `add eax, 0xA0` each of the two
## projectile creators puts between the unit's height and the object's `z`.
## Exactly two sites in the whole of `.text` add this to `0x0047AD30`'s
## answer, and they are these two, so the lift belongs to the creators and not
## to any object table.
const PROJECTILE_LIFT: int = 0xA0
## What [method _projectile] answers where there is no geometry to ask, which
## is the one case it places nothing.
const NO_THROW: Vector3i = Vector3i(-0x40000000, -0x40000000, -0x40000000)
## `0x00426F2C` -- the puff the mine leaves behind, `(row, aux, life)`.
const SPIDY_BOB_ROW: int = 4
const SPIDY_BOB_AUX: int = 0x14
const SPIDY_BOB_LIFE: int = 8

const EMITTER: String = "0x00420950"
const SPORE_SPARKS: String = "0x00428E30"
const PLASMA_SPARKS: String = "0x00428ED0"
const PLASMA_SPARKS_BURST: String = "0x00428F70"
const SPORES: String = "0x00429390"
const STING_SPARKS: String = "0x00429430"
const HITTING_BLOBS: String = "0x0042A410"
const HITTING_BLOBS_2: String = "0x0042A480"
const HITTING_BLOBS_3: String = "0x0042A7A0"
const SPARKS: String = "0x0042A9D0"
const ARM_PARA_BOMB: String = "0x0042B150"
const BARREL_DEBRIS: String = "0x0042B300"
## `0x004FA524` -- the name buffer classes 2 and 3 pass and the constructor
## ignores. An arm that calls the constructor itself passes it as a number.
const NAME_SCRATCH: int = 0x004FA524
## `0x004B1270` / `0x004B12E0` / `0x004B1300` -- the laser's offset and
## step, and the bomber's speed, as doubles the creators multiply the
## direction by. `0x004B12B8` is the statue beam's 1600 (`SPARK_SPEED`).
const LASER_OFFSET: float = -1600.0
const LASER_STEP: float = -3200.0
const BOMBER_SPEED: float = 3200.0
const SPARK_SPEED: float = 1600.0
const TUBE_PAIRS: int = 15
## `cmp ebx, 0x32` -- `aBlob_CreateTubeSmoke`'s own count, and the divisor its
## `delay` comes out of (`imul 0x2AAAAAAB` with no shift is a signed divide by
## six, so the fifty records go out in nine waves).
const TUBE_SMOKE_COUNT: int = 50
const TUBE_SMOKE_DELAY_DIVISOR: int = 6
## The two sprites it alternates on the low bit of the index.
const TUBE_SMOKE_MODELS: Array[String] = ["A_EXPL03.3DI", "A_EXPL04.3DI"]
const PLATFORM_DUST_SPREAD: int = 0x12C0
const PLATFORM_DUST_UP: int = 0x640
const FIRE_CIRCLE_FLAMES: int = 150
const FIRE_CIRCLE_TURN: int = 0x3C
const FIRE_CIRCLE_RADIUS: int = 0xC80
const STREAM_RECORDS: int = 200
const STREAM_STEP: int = 16
const BOMB_CEILING: int = 0x8980
const BOMB_DROP: int = 0xBB80
const BOMB_FALL: int = 800
## `0x00428990`'s direction switch: 0 +y, 1 -x, 2 -y, 3 +x.
const LASER_DIRECTIONS: Array[Vector2i] = [Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(0, -1), Vector2i(1, 0)]


## `0x004638E0` -- the uncounted twin of `aRandom`, with its own draw count.
class Draws extends RefCounted:
	var rng: IncRandom = IncRandom.new()
	var count: int = 0

	static func create(seed_value: float) -> Draws:
		var draws: Draws = Draws.new()
		draws.rng.randomize_seed(seed_value)
		return draws

	## `ftol(base + span * u)`.
	func draw(base: int, span: int) -> int:
		count += 1
		return rng.draw(base, span)

	## The x87 value before `_ftol`, for the one compare made as a double.
	func raw() -> float:
		count += 1
		var _drawn: int = rng.draw(0, 1)
		return rng.seed / IncRandom.MODULUS

	## A draw with a term added **before** the truncation: `0x00429A80`'s
	## `call aRandom2 / fadd [esp+0x2C] / _ftol`. Adding it after would
	## differ whenever the fraction and the addend cross an integer.
	func draw_biased(base: int, span: int, addend: int) -> int:
		count += 1
		var _drawn: int = rng.draw(0, 1)
		return int(float(base) + float(span) * (rng.seed / IncRandom.MODULUS)
			+ float(addend))


## What a death creator reads before it draws (`blob_creators.DeathInputs`).
class Inputs extends RefCounted:
	## Tile -> `{"object": Vector3i, "unit": {type, player, height} or {}}`:
	## the **placed object's** own position and the unit standing there.
	var tiles: Dictionary[Vector2i, Dictionary] = {}
	var gore: int = GORE_COMPUTER_ONLY
	var display_mode: int = 0
	## Model name -> the handle the constructor stores, or absent.
	var models: Dictionary[String, int] = {}
	## Unit type -> its own `.3DI` name (`unitInfo + 0x6C`).
	var type_models: Dictionary[int, String] = {}
	## Unit type -> `unitInfo + 0x7B`, the large flag the rings read.
	var sizes: Dictionary[int, int] = {}
	## The engine's table arithmetic, for the rings and the arrows' aim.
	var geometry: Eng3dGeometry = null
	## **What a weapon's creator reads instead of a tile** -- the two symbol
	## objects and the two unit heights of `blob_creators.Inputs`. The thirty
	## a weapon switch names open on the source and target cells rather than
	## on one, and they read the two **apart**: some from `object + height`
	## (see [method source_point]), some from the object alone, and the span a
	## beam is counted in is over the two objects. A caller that cannot tell
	## them apart leaves the heights at zero, which keeps the sum right and
	## the span wrong.
	var source: Vector3i = Vector3i.ZERO
	var source_height: int = 0
	var target: Vector3i = Vector3i.ZERO
	var target_height: int = 0
	## The low byte of the target cell's unit id, which `0x004264A0` stores as
	## its record's `aux` for a seeking arm to read back (docs/28 section
	## 7.7.1).
	var target_unit: int = 0
	## **The barrel**, where the caller knows it. A creator whose call site --
	## or whose own body, for the ten of `BlobTriggers.CREATOR_JOINTS` --
	## names a Charisma part calls `0x0042C660`, which writes that part's world
	## position over the **three source stack slots** the object and the height
	## were just loaded into (`0x00425810` loads them at `0x00425996` and hands
	## their addresses over at `0x00425A2E`). Everything the creator reads as
	## its source after that is the part.
	##
	## It is left unset where nothing is animating, which is the engine's own
	## fallback and is the case every capture was taken in -- so this is
	## asserted by `test_effects.gd` and confirmed in play, and diffed against
	## the engine by nothing.
	var source_joint: Vector3i = Vector3i.ZERO
	var has_source_joint: bool = false
	## Where a weapon creator's effect leaves from: the placed object's
	## position plus the unit's own height, or the barrel that replaced both.
	func source_point() -> Vector3i:
		if has_source_joint:
			return source_joint
		return Vector3i(source.x, source.y, source.z + source_height)

	## Where a **projectile** creator's round leaves from: the placed object
	## plus the unit's height plus [constant PROJECTILE_LIFT], or the barrel
	## that replaced all three.
	##
	## Separate from [method source_point] because only `0x00425CA0` and
	## `0x00426B70` carry that extra lift, in their own instructions.
	func throw_point() -> Vector3i:
		if has_source_joint:
			return source_joint
		return Vector3i(source.x, source.y,
			source.z + source_height + PROJECTILE_LIFT)

	## Where it is aimed.
	func target_point() -> Vector3i:
		return Vector3i(target.x, target.y, target.z + target_height)

	func large(unit: Dictionary) -> bool:
		return sizes.get(DictRead.as_int(unit.get("type", -1)), 0) == 1

	func object(x: int, y: int) -> Vector3i:
		var tile: Dictionary = tiles.get(Vector2i(x, y), {})
		if not tile.has("object"):
			return Vector3i.ZERO
		var at: Vector3i = tile["object"]
		return at

	## The unit on the tile, or an empty dictionary.
	func unit(x: int, y: int) -> Dictionary:
		var tile: Dictionary = tiles.get(Vector2i(x, y), {})
		return DictRead.as_dict(tile.get("unit", {}))

	func handle(name: String, class_id: int) -> int:
		if class_id >= 2:
			return -1
		return models.get(name, -1)


## The records a creator leaves, in the order `0x00420950` fills them.
class Pool extends RefCounted:
	var inputs: Inputs = null
	var records: Array[Dictionary] = []
	## How many the constructor refused -- a zero `life`, or a class-0/1
	## model the set does not carry (docs/28 section 7.5).
	var refused: int = 0
	## Whether the creator wrote **0** over the *arrived* flag of docs/42
	## section 4.6 -- "there is something in flight to wait for".
	##
	## Exactly six sites in `.text` write a zero to `0x004FE63C`, and five of
	## them are inside a creator: `aBlob_CreateGrenade` `0x00426070`,
	## `aBlob_EnergyCannon` `0x004264A0` and `aBlob_CreateLaser` `0x00428570`
	## -- the three weapon projectiles, which the shot path models at the
	## muzzle instead ([method ShotSequence.waits_for_projectile]) -- and the
	## bomber `0x0042A8E0` and the para bomb `0x0042B070`, the two a set piece
	## runs. The sixth is `0x0042B490`, the helper a sequence calls to
	## acknowledge a landing. `presentation_tables.py` pins all six.
	var clears_arrived: bool = false

	static func create(with: Inputs) -> Pool:
		var pool: Pool = Pool.new()
		pool.inputs = with
		return pool

	func spawn(name: String, class_id: int, x: int, y: int, z: int,
			rot_x: int, rot_y: int, rot_z: int, kind: int, life: int,
			vx: int, vy: int, vz: int, aux: int, delay: int) -> void:
		if life & 0xFF == 0:
			refused += 1
			return
		var model: int = inputs.handle(name, class_id)
		if class_id < 2 and model < 0:
			refused += 1
			return
		records.append({
			"model": model, "model_name": name,
			"class_id": class_id, "x": x, "y": y, "z": z,
			"rot_x": rot_x & 0xFFFF, "rot_y": rot_y & 0xFFFF,
			"rot_z": rot_z & 0xFFFF,
			"kind": kind & 0xFF, "life": life & 0xFF,
			"vx": vx, "vy": vy, "vz": vz,
			"aux": aux & 0xFF, "delay": delay & 0xFF,
		})


## The **arity of the creator** each program transcribes -- which is what a
## caller has to supply, and not always what the program reads: `0x00428F70`
## below is handed five values and uses four.
##
## The engine's creators are `__cdecl`, so the count lives at the **call
## site**, in its own `add esp, K`; `blob_tables.py`'s `arm_spawn.args_needed`
## reads it there for every site of every creator an arm can call and compares
## it with this table, so a program written against a signature the binary
## does not have is a failing check rather than a wrong effect. An entry
## raised above the real arity would be worse than a wrong effect and quieter:
## every request for that creator would come back as one of
## [member GameBlobHooks.short_call] and nothing would be made at all.
##
## It is also a guard. A caller with fewer values than the program reads would
## index past the end of its array -- a runtime error and a lost effect -- and
## for one day five of the seven `0x00423720` requests in [BlobKinds] did
## exactly that. They are fixed and measured now (`blob_kinds.gd`'s own note),
## so nothing trips this today; it stays because refusing is what the original
## does for an effect it cannot make (docs/28 section 7.1) and indexing past
## the end is not.
const ARGS_NEEDED: Dictionary[String, int] = {
	BLOOD_BURST: 2, BLOOD_FLOOD: 5, BLOOD_SPRAY_LARGE: 5, FLYING_DEBRIS: 2,
	SPECIES_BURST: 2, ROOF_DEBRIS: 3, GROUND_DEBRIS: 3, LANDING_DUST: 2,
	ARROWS: 2, FIRE_CIRCLE: 2, HEAL_FLASH: 2, POISON_FLASH: 2,
	SHOCK_WAVE: 3,
	PLATFORM_DUST: 3, TRAIL: 3, ZOOMBOB: 6, TUBE_PUFFS: 2, TUBE_SMOKE: 2,
	WALL_DEBRIS: 2,
	KILL_FIRE: 3, LASER_BARRIER: 4, STATUE_BEAM: 5, FLYING_UNIT: 3, PUFF: 2,
	BARREL_BURST: 2, FIRE_EXPLOSION: 2, TELEPORT_STREAM: 4, PUSH_DUST: 3,
	MAIN_MAP_FIRE: 3, BGB_WARNING_LIGHT: 3, BGB_FIRE3: 3, BGB_LAMP: 3,
	BGB_SPOT: 3, BGB_SMOKE: 3, BGB_COMPUTER_LIGHT: 4,
	BOMBER: 6, PARA_BOMB: 3, FIRE_DEATH: 2,
	EMITTER: 15, SPORE_SPARKS: 5, PLASMA_SPARKS: 5,
	# `0x00428F70` is called with five dwords and reads four: the fifth is
	# the sibling sparks' `life` and this one draws its own.
	PLASMA_SPARKS_BURST: 5,
	SPORES: 4, STING_SPARKS: 5, HITTING_BLOBS: 4, HITTING_BLOBS_2: 4,
	HITTING_BLOBS_3: 4, SPARKS: 4, ARM_PARA_BOMB: 3, BARREL_DEBRIS: 3,
	# The weapon switches' own, each arity its call sites' `add esp, K`.
	SMOKE_TRAIL: 6, MACHINE_GUN: 4, BLIZZARD_SHOT: 5, LASER_GREEN: 4,
	BLUE_LASER: 4, PLASMA_BEAM: 4, LINE_FIRE: 4, BLIZZARD_HIT: 2,
	SPORE_EXPLOSION: 4, STINGER_RING: 2,
	SPARKING_PLUG: 2, PLASMA_BALL_IMPACT: 2, EXPLOSION2: 2, SPIDY_MINES: 4,
	# Seven more on 2026-09-12. Three read a tail their arm pushes -- the
	# spray's round count and stagger, the grenade's type -- and four read
	# only the tiles, the rest of their arity being dead slots the frame
	# leaves as it found them.
	FIRE_WHEEL: 3, MINE_PLUME: 3, SPRAY: 6, GRENADE_ROUND: 5, GRENADE_ARC: 6,
	BEAM_DOTS: 5, LASER_DOTS: 5, FLAME_STREAM: 5,
}



# -- the weapon switches' own creators (docs/97 section 14.5) ---------------
#
# One block, because they share a prologue: the two symbol objects and the two
# unit heights, `source_point()` and `target_point()` above. `BlobTriggers`
# fills those from the shot's two ends with the joint already applied, which
# is `0x0042C660` writing the shooter's muzzle part over the three source
# coordinates.


## `source - ftol(index * d * scale)` per axis -- the family's one way of
## walking along the line of fire. Left to right, as the x87 does it.
static func _step(from: Vector3i, d: PackedFloat64Array, index: int,
		scale: float) -> Vector3i:
	return Vector3i(
		from.x - Eng3dGeometry.ftol(d[0] * float(index) * scale),
		from.y - Eng3dGeometry.ftol(d[1] * float(index) * scale),
		from.z - Eng3dGeometry.ftol(d[2] * float(index) * scale))


## The wider of the two horizontal spans, over the **symbol objects** rather
## than over the points the heights moved.
static func _span(inputs: Inputs) -> int:
	return maxi(absi(inputs.source.x - inputs.target.x),
		absi(inputs.source.y - inputs.target.y))


## `(max(|dx|, |dy|) - 0xC80) / 0x960`, a signed C divide -- the beam length
## the two lasers and the plasma beam count their dots in.
static func _beam_length(inputs: Inputs) -> int:
	return IncInt.div_trunc(_span(inputs) - BEAM_BASE, BEAM_UNIT)


## `aBlob_CreateSmokeTrail` `0x00425810` -- rings of six along the line of
## fire, the muzzle of weapon 26 (the Pyr'Coo's).
##
## Each record draws its three velocity components first and then sits at the
## ring's point **plus** them, so one set of numbers is both a displacement
## and a speed. `delay` is the ring index over four, and the creator writes
## **1** over the *arrived* flag at `0x00425AD6` -- ahead of the loop and
## behind no branch, so a trail is not something a shot waits on.
static func smoke_trail(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	var from: Vector3i = inputs.source_point()
	var d: PackedFloat64Array = Eng3dGeometry.direction(from,
		inputs.target_point(), 1)
	var count: int = IncInt.div_trunc(_span(inputs) - BEAM_BASE,
		TRAIL_UNIT) + 1
	for ring: int in range(count + 1):
		var at: Vector3i = _step(from, d, ring, TRAIL_STEP)
		for _index: int in range(6):
			var vx: int = draws.draw(-0x140, 0x280)
			var vy: int = draws.draw(-0x140, 0x280)
			var vz: int = draws.draw(-0x140, 0x280)
			pool.spawn(SCRATCH, 2, at.x + vx, at.y + vy, at.z + vz,
				6, 0, 0, 0x2E, 8, vx, vy, vz, 5,
				IncInt.div_trunc(ring, 4))


## `aBlob_CreateMachineGun` `0x00424D20` -- five bursts of tracer, casing and
## smoke (weapon 4).
##
## Three shapes in one creator. The **delta** is a draw minus the direction
## scaled by 2400, so each burst leaves along the line with a small scatter.
## The two tracers are placed **perpendicular** to that line: `x` takes the
## horizontal ratio scaled by 640 while `y` takes the *other* one, and the
## second record **exchanges** the two terms rather than negating them
## (`blob_tables.TRACER_AXIS_TERMS` pins all eight off the stack). The casings
## fly perpendicular at 80 with only their rise drawn, and each burst ends
## with `0x00423720`'s single record whose `life` is the burst index -- so
## burst 0 makes no puff at all, the constructor dropping a record with no
## life.
static func machine_gun(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	var from: Vector3i = inputs.source_point()
	var d: PackedFloat64Array = Eng3dGeometry.direction(from,
		inputs.target_point(), 1)
	var length: int = maxi(IncInt.div_trunc(_span(inputs), BEAM_UNIT), 0)
	for burst: int in range(5):
		var dx: int = draws.draw(-200, 400) - Eng3dGeometry.ftol(d[0] * BEAM_STEP)
		var dy: int = draws.draw(-200, 400) - Eng3dGeometry.ftol(d[1] * BEAM_STEP)
		var dz: int = draws.draw(-100, 200) - Eng3dGeometry.ftol(d[2] * BEAM_STEP)
		var turn: Vector2i = inputs.geometry.orient(from,
			Vector3i(from.x + dx * 5, from.y + dy * 5, from.z + dz * 5))
		if length != 0:
			pool.spawn("A_LINE5.3DI", 0,
				from.x + Eng3dGeometry.ftol(d[0] * TRACER_SPREAD)
					- TRACER_LEAN * Eng3dGeometry.ftol(d[1]),
				from.y + TRACER_LEAN * Eng3dGeometry.ftol(d[0])
					- Eng3dGeometry.ftol(d[1] * -TRACER_SPREAD),
				from.z, turn.x, 0, turn.y, 0xF, length, dx, dy, dz, 0, burst)
			pool.spawn("A_LINE5.3DI", 0,
				from.x + TRACER_LEAN * Eng3dGeometry.ftol(d[1])
					- Eng3dGeometry.ftol(d[0] * -TRACER_SPREAD),
				from.y + Eng3dGeometry.ftol(d[1] * TRACER_SPREAD)
					- TRACER_LEAN * Eng3dGeometry.ftol(d[0]),
				from.z, turn.x, 0, turn.y, 0xF, length, dx, dy, dz, 0, burst)
		for sign: int in [1, -1]:
			var vz: int = draws.draw(0, 0xA0) + 0x140
			pool.spawn("A_CASE.3DI", 0, from.x - IncInt.div_trunc(dx, 3),
				from.y - IncInt.div_trunc(dy, 3), from.z - dz,
				turn.x, 0, turn.y, 0xB, 0x14,
				Eng3dGeometry.ftol(d[1] * float(sign) * MACHINE_GUN_CASING_SPEED),
				Eng3dGeometry.ftol(d[0] * float(-sign) * MACHINE_GUN_CASING_SPEED),
				vz, 0, burst)
		pool.spawn(SCRATCH, 2, from.x + IncInt.div_trunc(dx, 5),
			from.y + IncInt.div_trunc(dy, 5),
			from.z + IncInt.div_trunc(dz, 5), 0, 0, 0, 0x32, burst,
			0, 0, 0, 10, 0)


## `aBlob_CreateBlizzardShot` `0x004264A0` -- two seeking shards, one behind
## the other (weapon 9).
##
## The **name** is chosen by a draw compared as a float *before* the
## truncation; the aim's scatter is thrown away when the two tiles are within
## six fields; the velocity is the direction scaled by 1920 and `delay` is the
## record index. The `aux` it stores is the target cell's unit id, which the
## seeking arm reads back as a unit-map slot.
static func blizzard_shot(pool: Pool, draws: Draws, inputs: Inputs,
		source_tile: Vector2i, target_tile: Vector2i) -> void:
	var from: Vector3i = inputs.source_point()
	var off_x: int = draws.draw(-0xC80, 0xC80)
	var off_y: int = draws.draw(-0x1F40, 0x1F40)
	if Eng3dGeometry.distance_2d(target_tile.x - source_tile.x,
			target_tile.y - source_tile.y) < 6:
		off_x = 0
		off_y = 0
	var aim: Vector3i = Vector3i(inputs.target.x + off_x,
		inputs.target.y + off_y, inputs.target.z)
	var d: PackedFloat64Array = Eng3dGeometry.direction(from, aim, 1)
	var name: String = "A_BLIZ03.3DI" if draws.raw() * 10.0 <= 5.0 \
		else "A_BLIZ02.3DI"
	for index: int in range(2):
		pool.spawn(name, 0, from.x, from.y, from.z, 0, 0, 0, 0x3D, 0x64,
			Eng3dGeometry.ftol(d[0] * SHARD_SPEED),
			Eng3dGeometry.ftol(d[1] * SHARD_SPEED),
			Eng3dGeometry.ftol(d[2] * SHARD_SPEED),
			inputs.target_unit, index)


## `aBlob_CreateLaserGreen` `0x00426F90` -- sparks at the target, then a
## dotted beam (weapon 10).
##
## It **calls another creator** before it places anything of its own, so its
## first two hundred draws are `0x0042A9D0`'s. A zero beam length is written
## back to -1, which makes the dot loop empty.
static func laser_green(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	var from: Vector3i = inputs.source_point()
	var aim: Vector3i = inputs.target_point()
	sparks(pool, draws, Vector3i(aim.x, aim.y, aim.z + 800), 0, inputs)
	var d: PackedFloat64Array = Eng3dGeometry.direction(from, aim, 1)
	var count: int = _beam_length(inputs)
	if count == 0:
		count = -1
	var turn: Vector2i = inputs.geometry.orient(from,
		_step(from, d, 1, BEAM_STEP))
	for index: int in range(count + 1):
		var at: Vector3i = _step(from, d, index, BEAM_STEP)
		pool.spawn("A_LASERG.3DI", 0, at.x, at.y, at.z, turn.x, 0, turn.y,
			1, 4, 0, 0, 0, 0, 0)


## `aBlob_CreateBlueLaser` `0x00427410` -- the same beam aimed at a scattered
## point, its dots carrying the direction scaled by 80 (weapon 45).
static func blue_laser(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	var from: Vector3i = inputs.source_point()
	var dx: int = draws.draw(-600, 0x4B0)
	var dy: int = draws.draw(-600, 0x4B0)
	var dz: int = draws.draw(-600, 0x4B0)
	var aim: Vector3i = inputs.target_point() + Vector3i(dx, dy, dz)
	sparks(pool, draws, aim, 0, inputs)
	var d: PackedFloat64Array = Eng3dGeometry.direction(from, aim, 1)
	var count: int = _beam_length(inputs)
	var turn: Vector2i = inputs.geometry.orient(from,
		_step(from, d, 1, BEAM_STEP))
	for index: int in range(1, count + 2):
		var at: Vector3i = _step(from, d, index, BEAM_STEP)
		pool.spawn("A_BLASER.3DI", 0, at.x, at.y, at.z, turn.x, 0, turn.y,
			0x26, 5, Eng3dGeometry.ftol(d[0] * DOT_SPEED),
			Eng3dGeometry.ftol(d[1] * DOT_SPEED),
			Eng3dGeometry.ftol(d[2] * DOT_SPEED), 0, 0)


## `aBlob_CreatePlasmaBeam` `0x00427810` -- three plasma heads at one point,
## then a trail of pairs (weapon 43).
##
## Two loops with different laws: the heads differ only in `delay`, the trail
## spaces itself by the loop counter, and every record's `rot_y` is a draw
## while the other two are the orientation's -- so the stream advances once
## per record in one loop and twice in the other.
static func plasma_beam(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	var from: Vector3i = inputs.source_point()
	var aim: Vector3i = inputs.target_point()
	var d: PackedFloat64Array = Eng3dGeometry.direction(from, aim, 1)
	var count: int = IncInt.div_trunc(_span(inputs) - BEAM_UNIT, BEAM_UNIT)
	var turn: Vector2i = inputs.geometry.orient(from,
		_step(from, d, 1, HEAD_STEP))
	var head: Vector3i = _step(from, d, 1, BEAM_STEP)
	for index: int in range(3):
		var rot_y: int = draws.draw(0, 0x1000)
		pool.spawn("A_PLSMA1.3DI", 0, head.x, head.y, head.z,
			turn.x, rot_y, turn.y, 1, (count & 0xFF) >> 1,
			Eng3dGeometry.ftol(d[0] * HEAD_SPEED),
			Eng3dGeometry.ftol(d[1] * HEAD_SPEED),
			Eng3dGeometry.ftol(d[2] * HEAD_SPEED), 0, index * 5)
	for index: int in range(1, count + 2):
		var at: Vector3i = _step(from, d, index, BEAM_STEP)
		for name: String in ["A_BLIZ02.3DI", "A_BLIZ03.3DI"]:
			var rot_y: int = draws.draw(0, 0x1000)
			pool.spawn(name, 0, at.x, at.y, at.z, turn.x, rot_y, turn.y,
				0xC, 10, 0, 0, 0, 0, 0)


## `aBlob_CreateLineFire` `0x00429180` -- `count` streaks, each with its own
## speed (weapon 13's impact, which pushes 150).
##
## Its velocity is neither a draw nor a fixed speed: a speed is drawn per axis
## and multiplied by the direction service's answer.
static func line_fire(pool: Pool, draws: Draws, inputs: Inputs,
		count: int) -> void:
	if inputs.geometry == null:
		return
	var at: Vector3i = inputs.source
	for _i: int in range(count & 0xFF):
		var aim: Vector3i = Vector3i(at.x + draws.draw(-0xA0, 0x140),
			at.y + draws.draw(-0xA0, 0x140), at.z + draws.draw(0x280, 0x280))
		var d: PackedFloat64Array = Eng3dGeometry.direction(at, aim, 1)
		var turn: Vector2i = inputs.geometry.orient(at, aim)
		var delay: int = draws.draw(0, 4)
		var vz: int = Eng3dGeometry.ftol(float(draws.draw(0xA0, 0xA0)) * d[2])
		var vy: int = Eng3dGeometry.ftol(float(draws.draw(0x1E0, 0x140)) * d[1])
		var vx: int = Eng3dGeometry.ftol(float(draws.draw(0x1E0, 0x140)) * d[0])
		pool.spawn("A_LINE6.3DI", 0, at.x, at.y, at.z, turn.x, 0, turn.y,
			0x48, draws.draw(0xA, 0xF), vx, vy, vz, 0, delay)


## `0x00420A50` -- thirty kind-47 sprites thrown off a rising ring
## (weapon 22's muzzle).
##
## Every record sits at the **same** point, the placed object one map field
## up, and the ring goes into the *velocity* -- the shape
## `aBlob_CreateShockWave` and the selection marker share. `delay` is the loop
## counter, so they leave one frame at a time, and nothing is drawn: the whole
## effect is the engine's own table arithmetic. The turn is an immediate
## rather than a full circle divided by the count, so thirty records walk the
## circle three times.
static func stinger_ring(pool: Pool, inputs: Inputs) -> void:
	var at: Vector3i = inputs.source
	var ring: Array[Vector3i] = _ring(inputs, STINGER_RADIUS, STINGER_TURN,
		STINGER_COUNT)
	for index: int in range(ring.size()):
		pool.spawn(SCRATCH, 2, at.x, at.y, at.z + STINGER_LIFT, 3, 0, 0,
			0x2F, 0x10, ring[index].x * STINGER_SPEED,
			ring[index].y * STINGER_SPEED, 0, 10, index)


## `aBlob_CreateSporeExplosion` `0x00429F40` -- rings of three climbing
## `0x3C0` a ring: the impact of weapons 23, 25 and **26**, the Pyr'Coo's.
##
## `kind` is the **fourth** argument: weapon 26's arm pushes 0, which is nine
## rings, and weapons 23 and 25 push 1, which is three; anything else takes
## the cascade's fall-through and makes nothing. `rot_y` is a flag rather
## than a draw, off below the fifth ring and 4 from it up; `aux` is a draw
## with twice the ring index added **inside** the conversion; `delay` is the
## ring index.
static func spore_explosion(pool: Pool, draws: Draws, inputs: Inputs,
		kind: int) -> void:
	var at: Vector3i = inputs.source
	var rings: int = 0
	match kind & 0xFF:
		0:
			rings = 9
		1:
			rings = 3
	for ring: int in range(rings):
		var counter: int = 2 * ring
		for _i: int in range(3):
			var dx: int = draws.draw(-0x640, 0xC80)
			var dy: int = draws.draw(-0x640, 0xC80)
			var dz: int = draws.draw(0, 0x640)
			var aux: int = draws.draw_biased(5, 0xF, counter)
			pool.spawn(SCRATCH, 2, at.x + dx, at.y + dy,
				at.z + 0x3C0 * ring + dz,
				3, 0 if counter < 10 else 4, 0,
				0x32, 8, 0, 0, 0, aux, ring)


## `aBlob_SparkingPlug` `0x0042ACF0` -- thirty sparks off the placed object,
## one map field up (weapon 17's muzzle, weapons 8 and 37's impact).
##
## The two zeros the loop opens with -- `push 0 / push 0` at `0x0042AD58` --
## are pushed **before** the first draw and survive every `add esp, 8` in
## between, so they are the constructor's `aux` and `delay` rather than
## scratch. The velocities are draws **shifted**: `shl eax, 5` on the rise
## and `shl eax, 4` on the two drifts. And the record stands at the object's
## own z plus `0x960` with no unit height in it, which `0x0042ADAC`'s
## `add eax, 0x960` is the whole of.
static func sparking_plug(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	var at: Vector3i = inputs.source
	for _index: int in range(SPARKING_PLUG_COUNT):
		var vz: int = draws.draw(5, 0xA) * SPARKING_PLUG_RISE
		var vy: int = draws.draw(-0xA, 0x14) * SPARKING_PLUG_DRIFT
		var vx: int = draws.draw(-0xA, 0x14) * SPARKING_PLUG_DRIFT
		pool.spawn("A_FUNKE.3DI", 0, at.x, at.y, at.z + SPARKING_PLUG_LIFT,
			0, 0, 0, 0x14, 0x1E, vx, vy, vz, 0, 0)


## `aBlob_CreatePlasmaBallImpact` `0x004294E0` -- forty sparks at the placed
## object (weapon 43's impact, and nothing else).
##
## It stands on the object's own z with **no lift and no unit height** --
## `0x004295B1` pushes `[esi+0x18]` untouched where its neighbour above adds
## `0x960`. The three draws reach the constructor out of order: the rise is
## taken first and lands in `vz`, and the two drifts land in `vx` and `vy`
## reversed, MSVC evaluating arguments right to left.
static func plasma_ball_impact(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	var at: Vector3i = inputs.source
	for _index: int in range(PLASMA_IMPACT_COUNT):
		var vz: int = draws.draw(PLASMA_IMPACT_RISE_BASE,
			PLASMA_IMPACT_RISE_SPAN)
		var vx: int = draws.draw(PLASMA_IMPACT_DRIFT_BASE,
			PLASMA_IMPACT_DRIFT_SPAN)
		var vy: int = draws.draw(PLASMA_IMPACT_DRIFT_BASE,
			PLASMA_IMPACT_DRIFT_SPAN)
		pool.spawn("A_FUNKE.3DI", 0, at.x, at.y, at.z, 0, 0, 0, 0x18, 0x3C,
			vx, vy, vz, 0, 0)


## `aBlob_CreateExplosion2` `0x004295D0` -- fifteen tumbling pieces of debris,
## straight after [method sparking_plug] on the same two arguments.
##
## Six draws a round in three ranges, and the order they are **taken** is not
## the order they arrive: the rise is first and becomes `vz`, the two drifts
## fill `vx` and `vy` reversed, and the three whole-turn draws fill `rot_z`,
## `rot_y` and `rot_x` -- reversed again, the shape [method blizzard_hit]
## names.
static func explosion2(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	var at: Vector3i = inputs.source
	for _index: int in range(EXPLOSION2_COUNT):
		var vz: int = draws.draw(EXPLOSION2_RISE_BASE, EXPLOSION2_RISE_SPAN)
		var vx: int = draws.draw(PLASMA_IMPACT_DRIFT_BASE,
			PLASMA_IMPACT_DRIFT_SPAN)
		var vy: int = draws.draw(PLASMA_IMPACT_DRIFT_BASE,
			PLASMA_IMPACT_DRIFT_SPAN)
		var rot_z: int = draws.draw(0, 0x1000)
		var rot_y: int = draws.draw(0, 0x1000)
		var rot_x: int = draws.draw(0, 0x1000)
		pool.spawn("A_DEBRIS.3DI", 0, at.x, at.y, at.z, rot_x, rot_y, rot_z,
			5, 0x64, vx, vy, vz, 0, 0)


## `aBlob_CreateSpidyMines` `0x00426B70` -- one thrown mine and the puff it
## leaves (weapons 13 and 46's muzzle, four arguments and no tail).
##
## **The shooter is lifted by a literal 160.** Both this and `0x00425CA0` do
## `call 0x0047AD30 / add eax, 0xA0 / add ecx, eax` over the symbol object's
## own `z`; both ends are the *symbol* object, and the standard object each
## reads is only for the joint's part list at `+0x45`. See
## [constant PROJECTILE_LIFT].
##
## The round leaves at `direction * 800` and lives `max(|dx|, |dy|) / 800 - 2`
## frames, with the *arrived* flag written **0** while that is positive. Its
## `vz` carries a lob of forty per half-life on top of the direction's own,
## and its rotation is `0x00403AA0` over the source and the source **plus the
## direction** -- not plus the lob. It is one of the ten creators that push
## `"M"` inside their own body (`0x00426CC8`), so an animating shooter throws
## from the barrel.
static func spidy_mines(pool: Pool, inputs: Inputs) -> void:
	var from: Vector3i = _projectile(pool, inputs, "A_MINE2.3DI", 77)
	if from == NO_THROW:
		return
	zoombob(pool, from, SPIDY_BOB_ROW, SPIDY_BOB_AUX, SPIDY_BOB_LIFE)


## The body `0x00425CA0` and `0x00426B70` share, answering where the round
## started so the caller can place its own second record -- or
## [constant NO_THROW] where there is no geometry to ask.
static func _projectile(pool: Pool, inputs: Inputs, name: String,
		kind: int) -> Vector3i:
	var from: Vector3i = inputs.throw_point()
	var aim: Vector3i = inputs.target_point()
	var span: int = maxi(absi(from.x - aim.x), absi(from.y - aim.y))
	var life: int = IncInt.div_trunc(span, PROJECTILE_UNIT) \
		- PROJECTILE_LIFE_BIAS
	# **Ahead of the geometry guard**, because the engine's own `setle` is over
	# the span alone: a caller with no orientation tables still has to be told
	# there is a round in flight.
	pool.clears_arrived = life > 0
	if inputs.geometry == null:
		return NO_THROW
	var d: PackedFloat64Array = Eng3dGeometry.direction(from, aim, 1)
	var v: Vector3i = Vector3i(
		Eng3dGeometry.ftol(d[0] * PROJECTILE_SPEED),
		Eng3dGeometry.ftol(d[1] * PROJECTILE_SPEED),
		Eng3dGeometry.ftol(d[2] * PROJECTILE_SPEED))
	var at: Vector3i = from + v
	var turn: Vector2i = inputs.geometry.orient(from, at)
	var half: int = absi(life) >> 1
	var lob: int = absi(-(half * PROJECTILE_LOB_SPREAD) - half) \
		* PROJECTILE_LOB_SCALE + v.z
	pool.spawn(name, 0, at.x, at.y, at.z, turn.x, 0, turn.y,
		kind, life, v.x, v.y, lob, 0, 0)
	return from


## `aBlob_CreateFlameStream` `0x00427C80` -- rings of five, and a sweep above
## type 5 (weapons 7 and 40's muzzle).
##
## A ring begins at the source plus [constant FLAME_RING_OFFSET] along the
## **last** direction the inner loop took, and lays five records stepping
## [constant FLAME_STEP] along a direction it takes again at every one of them.
## Each record's lifetime is the whole flight's, its velocity the direction
## times [constant SPARK_SPEED], its sprite column a draw and its half-size a
## draw biased by a per-record counter over three -- added before the
## truncation.
##
## **What the first ring reads is still the caller's stack.** See
## [constant FLAME_RING0_DIVERGENCE].
static func flame_stream(pool: Pool, draws: Draws, inputs: Inputs,
		rings: int) -> void:
	var source: Vector3i = inputs.source_point()
	var span: int = maxi(absi(source.x - inputs.target.x),
		absi(source.y - inputs.target.y))
	var life: int = IncInt.div_trunc(span, FLAME_UNIT)
	if life <= 0:
		life = 1
	# Unconditional and a literal: `mov [0x4FE63C], ebx` with `ebx` zeroed at
	# `0x00427E32`, ahead of every branch.
	pool.clears_arrived = true
	var aim: Vector3i = inputs.target + Vector3i(0, 0, FLAME_LIFT)
	var count: int = rings & 0xFF
	var sweeps: bool = count > FLAME_SWEEP_TYPE
	var sweep: int = -FLAME_SWEEP_LIMIT
	var forward: int = 1
	var d: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0])
	# `mov byte [esp+0x30], 2` at `0x00427F25`, ahead of both loops.
	var counter: int = FLAME_SIZE_BASE
	for ring: int in range(count):
		var at: Vector3i = Vector3i(
			source.x - Eng3dGeometry.ftol(d[0] * FLAME_RING_OFFSET),
			source.y - Eng3dGeometry.ftol(d[1] * FLAME_RING_OFFSET),
			source.z - Eng3dGeometry.ftol(d[2] * FLAME_RING_OFFSET))
		# **Only the sweep wants the tables**, so a caller without them still
		# gets the stream -- straight, which is what the guard costs and is
		# said here rather than hidden. Every shipped path has them: the cache
		# carries `TRIG.IMG` and `ATN.IMG`, and it is the fixture-less suites
		# that do not. The same contract [member BlobHooks.geometry] states
		# for [method BlobHooks.orient]'s substitute.
		if sweeps and inputs.geometry != null:
			var delta: Vector3i = aim - source
			# The walk happens **before** the turn and is what the turn reads:
			# `0x00427FD6` loads the angle, steps it, stores it back and only
			# then hands the structure over.
			var angles: Vector3i = Vector3i(delta.z & 0xFFFF,
				delta.z & 0xFFFF, sweep & 0xFFFF)
			sweep += FLAME_SWEEP_STEP if forward == 1 else -FLAME_SWEEP_STEP
			if sweep > FLAME_SWEEP_LIMIT:
				forward = 2
			if sweep < -FLAME_SWEEP_LIMIT:
				forward = 1
			aim = source + inputs.geometry.rotate(delta, angles)
		for _step: int in range(FLAME_PER_RING):
			d = Eng3dGeometry.direction(at, aim, 1)
			var size: int = draws.draw_biased(0, FLAME_SIZE_SPAN,
				IncInt.div_trunc(counter & 0xFF, FLAME_SIZE_DIVISOR))
			counter += 1
			var column: int = draws.draw(0, FLAME_COLUMN_SPAN) & 0xFF
			pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 0, column, 0, 0x31, life,
				Eng3dGeometry.ftol(d[0] * SPARK_SPEED),
				Eng3dGeometry.ftol(d[1] * SPARK_SPEED),
				Eng3dGeometry.ftol(d[2] * SPARK_SPEED), size, ring)
			at += Vector3i(Eng3dGeometry.ftol(d[0] * FLAME_STEP),
				Eng3dGeometry.ftol(d[1] * FLAME_STEP),
				Eng3dGeometry.ftol(d[2] * FLAME_STEP))


## `aBlob_CreateFireWheel` `0x004228F0` -- thirty puffs, then a closing wheel
## of fire (weapon 44's muzzle **and** its impact).
##
## Two tile coordinates and a third argument the body never reads -- the frame
## loads `[esp+4]` and `[esp+8]` and nothing else -- which is what makes the
## phase `blob_gold.py` already holds an oracle for it.
##
## Two loops of thirty, and only the first draws. The puffs are class-2
## sprites at the object's own `z`, staggered by **half** the loop index. The
## wheel is a spoke of 160 turned through Eng3d's own `0x004039A0` by 136 of
## 4096 per record, each record made from the **previous** answer with its `z`
## forced back to zero, so the turn accumulates and the wheel stays flat.
static func fire_wheel(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	var at: Vector3i = inputs.source
	for index: int in range(FIRE_WHEEL_COUNT):
		var vz: int = draws.draw(FIRE_WHEEL_RISE_BASE, FIRE_WHEEL_RISE_SPAN)
		var vy: int = draws.draw(FIRE_WHEEL_DRIFT_BASE, FIRE_WHEEL_DRIFT_SPAN)
		var vx: int = draws.draw(FIRE_WHEEL_DRIFT_BASE, FIRE_WHEEL_DRIFT_SPAN)
		pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 0, 0, 0, 0x2C, 0x10,
			vx, vy, vz, 0xA, index >> 1)
	var spoke: Vector3i = Vector3i(FIRE_WHEEL_RADIUS, 0, 0)
	for index: int in range(FIRE_WHEEL_COUNT):
		spoke = inputs.geometry.rotate(Vector3i(spoke.x, spoke.y, 0),
			Vector3i(0, 0, FIRE_WHEEL_TURN))
		var fourth: bool = index % (FIRE_WHEEL_EXPL04_EVERY + 1) \
			== FIRE_WHEEL_EXPL04_EVERY
		pool.spawn("A_EXPL04.3DI" if fourth else "A_EXPL03.3DI", 0,
			at.x, at.y, at.z + FIRE_WHEEL_LIFT, 0, 0, 0, 0x24, 0xF,
			spoke.x * FIRE_WHEEL_SPEED, spoke.y * FIRE_WHEEL_SPEED, 0, 0, 0xA)


## `0x00429C30` -- weapon 13's impact plume: three sprite puffs, no draw at
## all, and every one of its nine numbers an immediate at its own call site.
##
## Shorter-lived, slower and smaller with each record. Its third argument is
## dead, the same as [method fire_wheel]'s.
static func mine_plume(pool: Pool, inputs: Inputs) -> void:
	var at: Vector3i = inputs.source + Vector3i(0, 0, MINE_PLUME_LIFT)
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 0, 0, 0, 0x4B, 0xA,
		0, 0, 0x280, 0x1E, 0)
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 0, 0, 0, 0x4B, 0x6,
		0, 0, 0x1E0, 0x19, 0)
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 0, 0, 0, 0x4B, 0x5,
		0, 0, 0x140, 0x14, 0)


## `aBlob_CreateTracerBullet` at `0x00425400` -- the spore cannon's spray
## (weapon 23's muzzle), and a different routine from the tracer of the same
## name at `0x004247C0`.
##
## A burst -- `rounds` staggered by `stagger` -- but not one of the three of
## docs/28 section 8.1.1, and it does not share their prologue. Two things are
## its own. The joint replaces the source for the record's **position** and not
## for the direction, which reads the object itself at `0x004256A5`. And the
## span it measures is the *arrived* one -- source plus the velocity against
## the target -- so a shot inside one spacing writes the flag and places
## nothing: the `jle` at `0x00425745` skips the loop.
static func spray(pool: Pool, inputs: Inputs, rounds: int,
		stagger: int) -> void:
	var from: Vector3i = Vector3i(inputs.source.x, inputs.source.y,
		inputs.source.z + inputs.source_height)
	var d: PackedFloat64Array = Eng3dGeometry.direction(from,
		inputs.target_point(), 1)
	var v: Vector3i = Vector3i(
		Eng3dGeometry.ftol(d[0] * SPARK_SPEED),
		Eng3dGeometry.ftol(d[1] * SPARK_SPEED),
		Eng3dGeometry.ftol(d[2] * SPARK_SPEED))
	var span: int = maxi(absi(from.x + v.x - inputs.target.x),
		absi(from.y + v.y - inputs.target.y))
	var life: int = IncInt.div_trunc(span, SPRAY_UNIT)
	pool.clears_arrived = life > 0
	if life <= 0:
		return
	var at: Vector3i = inputs.source_joint if inputs.has_source_joint else from
	for index: int in range(rounds & 0xFF):
		for pair: int in range(SPRAY_PAIR):
			pool.spawn(SCRATCH, 2, at.x + v.x, at.y + v.y, at.z + v.z,
				3, 0, 0, 0x20, life, v.x, v.y, v.z, 0x28,
				(pair + index * stagger) & 0xFF)


## `aBlob_CreateGrenade` `0x00425CA0` -- the mine thrower's round and nothing
## else (weapons 8 and 42's muzzle, fifth argument dead).
##
## [method spidy_mines]' whole shape with `A_MINE1.3DI` in place of
## `A_MINE2.3DI`, and without the puff that one leaves.
static func grenade_round(pool: Pool, inputs: Inputs) -> void:
	var _from: Vector3i = _projectile(pool, inputs, "A_MINE1.3DI", 6)


## `aBlob_CreateGrenade` at `0x00426070` -- six dots on one of seven arcs.
##
## Weapon 11's muzzle calls it **once per cell of its own target pattern that
## still holds a unit**, and the type it pushes is the running count of the
## cells matched so far -- in control-map order -- which is the arc. Weapon
## 44's arm pushes [constant GRENADE_PROXIMITY] and loops five times at the one
## aim point instead. [method BlobTriggers.multi_target] is the walk; a cell
## the resolver marked killed is still among them because removal follows the
## animation. The type reaches three things: the offset
## added to the target object before the direction is taken, whether the three
## draws happen at all, and the record's kind -- [constant GRENADE_KIND] and
## one more for the proximity round, which is `computed_kinds`' `[26, 27]`.
##
## Two gates sit in front of it. `0x0044AE10` measures the two tiles in
## **bytes** and a separation under [constant GRENADE_RANGE] zeroes the whole
## offset for every type but the proximity one, so a point-blank shot flies
## straight. And the record's position is the source *minus* the direction
## times [constant GRENADE_BACK] -- the same magnitude the velocity is built
## from, negated at the constant rather than at the instruction.
static func grenade_arc(pool: Pool, draws: Draws, inputs: Inputs,
		tile: Vector2i, target_tile: Vector2i, type: int) -> void:
	var kind: int = type & 0xFF
	var offset: Vector3i = Vector3i.ZERO
	if kind < GRENADE_AIM.size():
		offset = GRENADE_AIM[kind]
	elif kind == GRENADE_PROXIMITY:
		offset = Vector3i(
			draws.draw(GRENADE_PROXIMITY_BASE, GRENADE_PROXIMITY_SPAN),
			draws.draw(GRENADE_PROXIMITY_BASE, GRENADE_PROXIMITY_SPAN),
			draws.draw(0, GRENADE_PROXIMITY_RISE))
	else:
		offset = Vector3i(
			draws.draw(GRENADE_SCATTER_BASE, GRENADE_SCATTER_SPAN),
			draws.draw(GRENADE_SCATTER_BASE, GRENADE_SCATTER_SPAN),
			draws.draw(0, GRENADE_SCATTER_RISE))
	var near: int = Eng3dGeometry.distance_2d(
		(tile.x & 0xFF) - (target_tile.x & 0xFF),
		(tile.y & 0xFF) - (target_tile.y & 0xFF))
	if near < GRENADE_RANGE and kind != GRENADE_PROXIMITY:
		offset = Vector3i.ZERO
	var from: Vector3i = Vector3i(inputs.source.x, inputs.source.y,
		inputs.source.z + inputs.source_height)
	var d: PackedFloat64Array = Eng3dGeometry.direction(from,
		inputs.target + offset, 1)
	var at: Vector3i = Vector3i(
		from.x - Eng3dGeometry.ftol(d[0] * GRENADE_BACK),
		from.y - Eng3dGeometry.ftol(d[1] * GRENADE_BACK),
		from.z - Eng3dGeometry.ftol(d[2] * GRENADE_BACK))
	for index: int in range(GRENADE_COUNT):
		pool.spawn("A_LASER.3DI", 0, at.x, at.y, at.z, 0, 0, 0,
			GRENADE_KIND + (1 if kind == GRENADE_PROXIMITY else 0), 0x64,
			Eng3dGeometry.ftol(d[0] * GRENADE_SPEED),
			Eng3dGeometry.ftol(d[1] * GRENADE_SPEED),
			Eng3dGeometry.ftol(d[2] * GRENADE_SPEED),
			inputs.target_unit, index)


## `aBlob_CreateLaser` at `0x00428200` -- weapon 47's chain of dots.
##
## One dot per frame of the flight, stepped [constant BEAM_DOT_SPEED] along the
## line to the target object a quarter-cell up, with a delay that advances once
## every [constant BEAM_DOT_STAGGER] dots, then a terminal dot of kind 71 where
## the chain ended. The dots carry no velocity of their own: they are a drawn
## line and not a flight, and the kind-71 tail is the one whose update arm
## spawns `aBlob_CreateLaserHit2` (docs/97 section 19.2).
##
## Its fifth argument is dead, and the slot that held its **fourth** is reused
## for the flight's length once the tile has been read out of it.
static func beam_dots(pool: Pool, inputs: Inputs) -> void:
	var at: Vector3i = inputs.source_point()
	var aim: Vector3i = inputs.target + Vector3i(0, 0, BEAM_DOT_LIFT)
	var span: int = maxi(absi(at.x - inputs.target.x),
		absi(at.y - inputs.target.y))
	var life: int = IncInt.div_trunc(span, BEAM_DOT_UNIT) - 1
	pool.clears_arrived = life > 0
	var d: PackedFloat64Array = Eng3dGeometry.direction(at, aim, 1)
	var index: int = 0
	while index < life:
		pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 5, 0, 0, 0x46, 0x14,
			0, 0, 0, 8, IncInt.div_trunc(index, BEAM_DOT_STAGGER))
		at += Vector3i(Eng3dGeometry.ftol(d[0] * BEAM_DOT_SPEED),
			Eng3dGeometry.ftol(d[1] * BEAM_DOT_SPEED),
			Eng3dGeometry.ftol(d[2] * BEAM_DOT_SPEED))
		index += 1
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 5, 0, 0, 0x47, 0x14,
		0, 0, 0, 8, IncInt.div_trunc(index, BEAM_DOT_STAGGER))


## `aBlob_CreateLaser` at `0x00428570` -- weapon 14's seven dots.
##
## A different routine of the same name and a different shape: **always** seven
## records, six of kind 63 stepped [constant LASER_DOT_STEP] apart and a
## seventh of kind 64 where they end, each carrying the flight's whole length
## as its lifetime and the direction times a whole map field as its velocity.
##
## A length of zero is written back as **one** at `0x004287DF` -- with the flag
## set, so the shot stage still knows there is nothing to wait for -- which is
## why the direction slots the final record reads are never uninitialised. It
## opens with the zoom bob at the shooter's own point, the puff at the muzzle.
static func laser_dots(pool: Pool, inputs: Inputs) -> void:
	var at: Vector3i = inputs.source_point()
	zoombob(pool, at, 5, 0xA, 8)
	var span: int = maxi(absi(at.x - inputs.target.x),
		absi(at.y - inputs.target.y))
	var life: int = IncInt.div_trunc(span, LASER_DOT_UNIT) - 1
	pool.clears_arrived = life > 0
	if life <= 0:
		life = 1
	var aim: Vector3i = inputs.target + Vector3i(0, 0, LASER_DOT_LIFT)
	# **The direction is taken again at every dot**, from wherever the last
	# step left the point -- `0x0046D400` sits *inside* the loop at
	# `0x00428883`, where [method beam_dots]' single call sits in front of its
	# own. So the dots do not share one velocity, and the further along the
	# chain a dot is the more the rounding of its own step shows in it. Reading
	# it as one velocity put the third dot's `vz` 4 units out and the fifth's
	# `z` 2, which is what the capture's diff caught.
	var d: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0])
	for _index: int in range(LASER_DOT_COUNT):
		d = Eng3dGeometry.direction(at, aim, 1)
		pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 5, 0, 0, 0x3F, life,
			Eng3dGeometry.ftol(d[0] * LASER_DOT_SPEED),
			Eng3dGeometry.ftol(d[1] * LASER_DOT_SPEED),
			Eng3dGeometry.ftol(d[2] * LASER_DOT_SPEED), 8, 0)
		at += Vector3i(Eng3dGeometry.ftol(d[0] * LASER_DOT_STEP),
			Eng3dGeometry.ftol(d[1] * LASER_DOT_STEP),
			Eng3dGeometry.ftol(d[2] * LASER_DOT_STEP))
	# The seventh carries the **last** direction, not one of its own.
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 5, 0, 0, 0x40, life,
		Eng3dGeometry.ftol(d[0] * LASER_DOT_SPEED),
		Eng3dGeometry.ftol(d[1] * LASER_DOT_SPEED),
		Eng3dGeometry.ftol(d[2] * LASER_DOT_SPEED), 8, 0)


## `aBlob_CreateBlizzardHit` `0x0042AF10` -- a flash and two tumbling shards
## (weapon 9's impact).
##
## The three rotation draws reach the constructor in the **reverse** of the
## order they were taken, MSVC evaluating arguments right to left.
static func blizzard_hit(pool: Pool, draws: Draws, inputs: Inputs) -> void:
	var at: Vector3i = inputs.source_point()
	pool.spawn("A_PLSMA1.3DI", 0, at.x, at.y, at.z, 0, 0, 0, 8, 0xA,
		0, 0, 0, 0, 0)
	for _i: int in range(2):
		var rot_z: int = draws.draw(0, 0xFFF)
		var rot_y: int = draws.draw(0, 0xFFF)
		var rot_x: int = draws.draw(0, 0xFFF)
		pool.spawn("A_BLIZ01.3DI", 0, at.x, at.y, at.z, rot_x, rot_y, rot_z,
			8, 0x14, 0, 0, 0, 0, 3)


## How many values a creator needs, or -1 for an address this file does not
## carry. The two answers are different and a caller that wants to say why it
## made nothing needs both.
static func args_needed(creator: String) -> int:
	return ARGS_NEEDED.get(creator, -1)


## Run the creator at `creator` with `args`. Answers false for an address
## this file does not carry, and for a call with too few values to run.
static func run(creator: String, pool: Pool, draws: Draws,
		args: PackedInt32Array, inputs: Inputs) -> bool:
	if args.size() < args_needed(creator):
		return false
	match creator:
		PUFF:
			puff(pool, draws, inputs.object(args[0], args[1]))
		BLOOD_BURST:
			blood_burst(pool, draws, args[0], args[1], inputs)
		BARREL_BURST:
			barrel_burst(pool, draws, args[0], args[1], inputs)
		BLOOD_FLOOD:
			blood_flood(pool, draws, args[0], args[1], args[2], args[3], args[4],
				inputs)
		BLOOD_SPRAY_LARGE:
			blood_spray_large(pool, draws, args[0], args[1], args[2], args[3],
				args[4], inputs)
		FLYING_DEBRIS:
			flying_debris(pool, draws, args[0], args[1], inputs)
		SPECIES_BURST:
			species_burst(pool, draws, args[0], args[1], inputs)
		KILL_FIRE:
			kill_fire(pool, draws, args[0], args[1], args[2], inputs)
		FIRE_DEATH:
			fire_death(pool, draws, args[0], args[1], inputs)
		FLYING_UNIT:
			flying_unit(pool, draws, args[0], args[1], args[2], inputs)
		FIRE_EXPLOSION:
			fire_explosion(pool, draws, args[0], args[1], inputs)
		ARROWS:
			arrows(pool, args[0], args[1], inputs)
		SHOCK_WAVE:
			shock_wave(pool, args[0], args[1], args[2], inputs)
		LANDING_DUST:
			landing_dust(pool, args[0], args[1], inputs)
		SMOKE_TRAIL:
			smoke_trail(pool, draws, inputs)
		MACHINE_GUN:
			machine_gun(pool, draws, inputs)
		BLIZZARD_SHOT:
			blizzard_shot(pool, draws, inputs, Vector2i(args[0], args[1]),
				Vector2i(args[2], args[3]))
		LASER_GREEN:
			laser_green(pool, draws, inputs)
		BLUE_LASER:
			blue_laser(pool, draws, inputs)
		PLASMA_BEAM:
			plasma_beam(pool, draws, inputs)
		LINE_FIRE:
			line_fire(pool, draws, inputs, args[2])
		BLIZZARD_HIT:
			blizzard_hit(pool, draws, inputs)
		SPORE_EXPLOSION:
			spore_explosion(pool, draws, inputs, args[3])
		STINGER_RING:
			stinger_ring(pool, inputs)
		SPARKING_PLUG:
			sparking_plug(pool, draws, inputs)
		PLASMA_BALL_IMPACT:
			plasma_ball_impact(pool, draws, inputs)
		EXPLOSION2:
			explosion2(pool, draws, inputs)
		SPIDY_MINES:
			spidy_mines(pool, inputs)
		FIRE_WHEEL:
			fire_wheel(pool, draws, inputs)
		MINE_PLUME:
			mine_plume(pool, inputs)
		SPRAY:
			spray(pool, inputs, args[4], args[5])
		GRENADE_ROUND:
			grenade_round(pool, inputs)
		GRENADE_ARC:
			grenade_arc(pool, draws, inputs, Vector2i(args[0], args[1]),
				Vector2i(args[2], args[3]), args[5])
		BEAM_DOTS:
			beam_dots(pool, inputs)
		LASER_DOTS:
			laser_dots(pool, inputs)
		FLAME_STREAM:
			flame_stream(pool, draws, inputs, args[4])
		HEAL_FLASH:
			heal_flash(pool, args[0], args[1], inputs)
		POISON_FLASH:
			poison_flash(pool, args[0], args[1], inputs)
		ZOOMBOB:
			zoombob(pool, Vector3i(args[0], args[1], args[2]), args[3], args[4],
				args[5])
		TRAIL:
			trail(pool, draws, Vector3i(args[0], args[1], args[2]))
		PUSH_DUST:
			push_dust(pool, draws, Vector3i(args[0], args[1], args[2]))
		MAIN_MAP_FIRE:
			main_map_fire(pool, draws, Vector3i(args[0], args[1], args[2]))
		BGB_WARNING_LIGHT:
			bgb_warning_light(pool, draws,
				Vector3i(args[0], args[1], args[2]))
		BGB_FIRE3:
			bgb_fire3(pool, Vector3i(args[0], args[1], args[2]))
		BGB_LAMP:
			bgb_lamp(pool, Vector3i(args[0], args[1], args[2]))
		BGB_SPOT:
			bgb_spot(pool, Vector3i(args[0], args[1], args[2]))
		BGB_SMOKE:
			bgb_smoke(pool, draws, Vector3i(args[0], args[1], args[2]))
		BGB_COMPUTER_LIGHT:
			bgb_computer_light(pool, Vector3i(args[0], args[1], args[2]),
				args[3])
		TUBE_PUFFS:
			tube_puffs(pool, draws, args[0], args[1], inputs)
		TUBE_SMOKE:
			tube_smoke(pool, draws, args[0], args[1], inputs)
		PLATFORM_DUST:
			platform_dust(pool, draws, Vector3i(args[0], args[1], args[2]))
		GROUND_DEBRIS:
			ground_debris(pool, draws, args[0], args[1], args[2], inputs)
		ROOF_DEBRIS:
			roof_debris(pool, draws, args[0], args[1], args[2], inputs)
		WALL_DEBRIS:
			wall_debris(pool, draws, args[0], args[1], inputs)
		FIRE_CIRCLE:
			fire_circle(pool, draws, args[0], args[1], inputs)
		LASER_BARRIER:
			laser_barrier(pool, args[0], args[1], args[2], args[3], inputs)
		STATUE_BEAM:
			statue_beam(pool, draws, args[0], args[1], args[2], args[3], args[4],
				inputs)
		TELEPORT_STREAM:
			teleport_stream(pool, draws, args[0], args[1], args[2], args[3], inputs)
		BOMBER:
			bomber(pool, Vector3i(args[0], args[1], args[2]),
				Vector3i(args[3], args[4], args[5]), inputs)
		PARA_BOMB:
			para_bomb(pool, draws, args[0], args[1], args[2], inputs)
		EMITTER:
			emitter(pool, args)
		SPORE_SPARKS:
			spore_sparks(pool, draws, Vector3i(args[0], args[1], args[2]),
				args[3], args[4])
		PLASMA_SPARKS:
			plasma_sparks(pool, draws, Vector3i(args[0], args[1], args[2]),
				args[3], args[4])
		PLASMA_SPARKS_BURST:
			plasma_sparks_burst(pool, draws,
				Vector3i(args[0], args[1], args[2]), args[3], inputs)
		SPORES:
			spores(pool, draws, Vector3i(args[0], args[1], args[2]), args[3])
		STING_SPARKS:
			sting_sparks(pool, Vector3i(args[0], args[1], args[2]), args[3],
				args[4])
		HITTING_BLOBS:
			hitting_blobs(pool, draws, Vector3i(args[0], args[1], args[2]),
				args[3])
		HITTING_BLOBS_2:
			hitting_blobs_2(pool, Vector3i(args[0], args[1], args[2]), args[3])
		HITTING_BLOBS_3:
			hitting_blobs_3(pool, draws, Vector3i(args[0], args[1], args[2]),
				args[3], inputs)
		SPARKS:
			sparks(pool, draws, Vector3i(args[0], args[1], args[2]), args[3],
				inputs)
		ARM_PARA_BOMB:
			arm_para_bomb(pool, draws, Vector3i(args[0], args[1], args[2]))
		BARREL_DEBRIS:
			barrel_debris(pool, draws, Vector3i(args[0], args[1], args[2]))
		_:
			return false
	return true


## Hand a program's records to the live pool, in order. The pool resolves
## each model name itself, so a name this world set does not carry is
## refused there the way the constructor refuses it (docs/28 section 7.5).
## Answers how many the pool accepted.
static func spawn_into(pool: BlobPool, records: Array[Dictionary]) -> int:
	var made: int = 0
	for record: Dictionary in records:
		var fields: Dictionary = record.duplicate()
		if pool.create_blob(fields) >= 0:
			made += 1
	return made


## `0x004297F0` -- the bloodless substitute: one class-2 record, kind 59,
## life 20, drifting sideways.
static func puff(pool: Pool, draws: Draws, at: Vector3i) -> void:
	var aux: int = draws.draw(5, 0x14)
	var vy: int = draws.draw(-1000, 2000)
	var vx: int = draws.draw(-1000, 2000)
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 1, 0, 0, 0x3B, 0x14, vx, vy, 0,
		aux, 0)


## Level 2 keeps the blood for the computer's units only.
static func _gore_substitutes(inputs: Inputs, unit: Dictionary) -> bool:
	return inputs.gore == GORE_COMPUTER_ONLY \
		and DictRead.as_int(unit["player"]) != PLAYER_COMPUTER


## `0x00420B80` -- fifteen pairs of `A_BLUT4` rising from the unit's tile,
## kinds 17 and 43, paired by the `delay` they share.
static func blood_burst(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	if inputs.gore == GORE_NONE:
		puff(pool, draws, inputs.object(x, y))
		return
	var unit: Dictionary = inputs.unit(x, y)
	if unit.is_empty():
		return
	if _gore_substitutes(inputs, unit):
		puff(pool, draws, inputs.object(x, y))
		return
	var at: Vector3i = inputs.object(x, y)
	for i: int in range(15):
		var vz: int = draws.draw(500, 500)
		var delay: int = (i >> 1) & 0x7F
		var vy: int = draws.draw(0, 100)
		var vx: int = draws.draw(0, 100)
		var dz: int = draws.draw(0, 0x960)
		pool.spawn("A_BLUT4.3DI", 0, at.x, at.y, at.z + dz, 0, 0, 0, 0x11, 0xF,
			vx, vy, vz, 0, delay)
		vz += 0x640
		vy = draws.draw(0, 100)
		vx = draws.draw(0, 100)
		dz = draws.draw(0, 0x960)
		pool.spawn("A_BLUT4.3DI", 0, at.x, at.y, at.z + dz, 0, 0, 0, 0x2B, 0xF,
			vx, vy, vz, 0, delay)


## `0x004298D0` -- ten tumbling `A_BDEBI1` / `A_BDEBI0` pieces, kind 5,
## life 100, from the object's own position: the class-0x0D death.
static func barrel_burst(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	for i: int in range(10):
		var vx: int = draws.draw(-500, 1000)
		var vy: int = draws.draw(-500, 1000)
		var vz: int = draws.draw(500, 500)
		var name: String = "A_BDEBI1.3DI" if i % 2 == 0 else "A_BDEBI0.3DI"
		var rot_z: int = draws.draw(0, 0x1000)
		var rot_y: int = draws.draw(0, 0x1000)
		var rot_x: int = draws.draw(0, 0x1000)
		pool.spawn(name, 0, at.x, at.y, at.z, rot_x, rot_y, rot_z, 5, 100,
			vx, vy, vz, 0, 0)


## The shared body of the two blood sprays (docs/42 section 4.8.1).
##
## Both take the **target's** object as the origin and, in mode 0, the
## direction from the target (raised by half its unit's height) to the source
## through `0x0046D400` with its shift flag; the horizontal terms are scaled by
## 16 or 48 and the vertical one by 160, and every record starts 1280 along
## that direction. Modes 1 and 2 leave the direction at zero.
static func _spray(pool: Pool, draws: Draws, inputs: Inputs, sx: int, sy: int,
		tx: int, ty: int, mode: int, large: bool) -> void:
	var at: Vector3i = inputs.object(tx, ty)
	var unit: Dictionary = inputs.unit(tx, ty)
	if unit.is_empty():
		return
	var half: int = DictRead.as_int(unit["height"]) / 2
	var dx: float = 0.0
	var dy: float = 0.0
	var d_x: int = 0
	var d_y: int = 0
	var d_z: int = 0
	var count: int = 0
	var speed: int = 0
	var zspan: int = 0
	var scatter: int = 0
	if mode == 0:
		var from: Vector3i = inputs.object(sx, sy)
		var d: PackedFloat64Array = Eng3dGeometry.direction(
			Vector3i(at.x, at.y, at.z + half),
			Vector3i(from.x, from.y, from.z + half), 1)
		dx = d[0]
		dy = d[1]
		var scale: float = BLOOD_VELOCITY_LARGE if large else BLOOD_VELOCITY
		d_x = Eng3dGeometry.ftol(dx * scale)
		d_y = Eng3dGeometry.ftol(dy * scale)
		d_z = Eng3dGeometry.ftol(d[2] * BLOOD_LIFT)
		if large:
			count = 4
			speed = 100
			zspan = 0xA0
			scatter = 0
		else:
			count = 12
			speed = 20
			zspan = 0xA0
			scatter = 800
	elif mode == 1:
		count = 15
		speed = 400
		zspan = 0x960
		scatter = 0
	elif mode == 2:
		count = 35
		speed = 400
		zspan = 0x1900
		scatter = 0x12C0
	else:
		return
	var px: int = at.x
	var py: int = at.y
	var player: int = DictRead.as_int(unit["player"])
	for i: int in range(count):
		if scatter != 0:
			px += draws.draw(-scatter, 2 * scatter)
			py += draws.draw(-scatter, 2 * scatter)
		var delay: int = 0
		var aux: int = 0
		var vx: int = 0
		var vy: int = 0
		var vz: int = 0
		var model: String = SCRATCH
		var class_id: int = 2
		var rot_x: int = 0
		var kind: int = 0
		var life: int = 8
		if large:
			delay = i / 2
			aux = 10
			vz = draws.draw(100, speed) + d_z
			vy = draws.draw(0, 100) + d_y
			vx = draws.draw(0, 100) + d_x
			rot_x = 1
			kind = 0x32
		elif inputs.gore == GORE_NONE or (inputs.gore == GORE_COMPUTER_ONLY
				and player != PLAYER_COMPUTER):
			aux = draws.draw(5, 10)
			vz = draws.draw(100, speed) + d_z
			vy = draws.draw(-200, 400) + d_y
			vx = draws.draw(-200, 400) + d_x
			rot_x = 5
			kind = 0x3C
		elif inputs.gore == GORE_COMPUTER_ONLY:
			delay = i >> 1
			vz = draws.draw(100, speed) + d_z
			vy = draws.draw(-200, 400) + d_y
			vx = draws.draw(-200, 400) + d_x
			model = "A_BLUT4.3DI"
			class_id = 0
			kind = 0x11
		elif inputs.gore == GORE_FULL:
			delay = i >> 1
			vz = draws.draw(100, speed) + d_z
			vy = draws.draw(0, 0x32) + d_y
			vx = draws.draw(0, 0x32) + d_x
			model = "A_BLUT4.3DI"
			class_id = 0
			kind = 0x11
		else:
			continue
		var z: int = draws.draw(0, zspan) + at.z + half
		var y: int = py - Eng3dGeometry.ftol(dy * BLOOD_STEP)
		var x: int = px - Eng3dGeometry.ftol(dx * BLOOD_STEP)
		pool.spawn(model, class_id, x, y, z, rot_x, 0, 0, kind, life, vx, vy,
			vz, aux, delay)


## `aBlob_CreateBloodFlood(sx, sy, tx, ty, mode)` -- the damage effect.
static func blood_flood(pool: Pool, draws: Draws, sx: int, sy: int, tx: int,
		ty: int, mode: int, inputs: Inputs) -> void:
	_spray(pool, draws, inputs, sx, sy, tx, ty, mode, false)


## `0x00421360` -- the same spray with kind 50, fewer records and three times
## the sideways velocity, for a large target.
static func blood_spray_large(pool: Pool, draws: Draws, sx: int, sy: int,
		tx: int, ty: int, mode: int, inputs: Inputs) -> void:
	_spray(pool, draws, inputs, sx, sy, tx, ty, mode, true)


## `aBlob_CreateFlyingDebris(x, y)` -- splats thrown from the unit's tile,
## each trailed by four blood pieces; twelve throws in output mode 3, five
## otherwise; then five lower splats with no trail.
static func flying_debris(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	var unit: Dictionary = inputs.unit(x, y)
	if unit.is_empty():
		return
	var half: int = DictRead.as_int(unit["height"]) / 2
	var count: int = 12 if inputs.display_mode == DEBRIS_FULL_MODE else 5
	for i: int in range(count):
		var name: String = SPLATS[i % SPLATS.size()]
		var vx: int = draws.draw(-1000, 2000)
		var vy: int = draws.draw(-1000, 2000)
		var vz: int = draws.draw(-1000, 2000)
		var dz: int = draws.draw(0, 0xC80) + half
		var delay: int = draws.draw(0, 3)
		pool.spawn(name, 0, at.x, at.y, at.z + dz, 0, 0, 0, 0x12, 0x32, vx, vy,
			vz + 500, 0, delay)
		for m: int in range(1, 5):
			pool.spawn(BLOOD_TRAIL[m - 1], 0, at.x, at.y, at.z + dz, 0, 0, 0,
				0x12, 0x1E, vx, vy, vz + 500, 0, m)
	for i: int in range(5):
		var name: String = SPLATS[i % SPLATS.size()]
		var vx: int = draws.draw(-0xFA, 500)
		var vy: int = draws.draw(-0xFA, 500)
		var vz: int = draws.draw(0, 500)
		var dz: int = draws.draw(0, 0xC80)
		var delay: int = draws.draw(0, 3)
		pool.spawn(name, 0, at.x, at.y, at.z + half + dz, 0, 0, 0, 0x12, 0x1E,
			vx, vy, vz + 500, 0, delay)


## `0x00421C50` -- the death of types 50, 51 and 56: seven times in ten two
## `A_SPLAT5`, two class-2 bursts and the type's own three pieces each trailed
## by four blood pieces; otherwise, and for every other type, a mode-1
## [method blood_flood] and [method flying_debris] on the tile.
static func species_burst(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	if inputs.gore == GORE_NONE:
		puff(pool, draws, inputs.object(x, y))
		return
	var unit: Dictionary = inputs.unit(x, y)
	if unit.is_empty():
		return
	if _gore_substitutes(inputs, unit):
		puff(pool, draws, inputs.object(x, y))
		return
	var type_id: int = DictRead.as_int(unit["type"])
	if not SPECIES_MODELS.has(type_id):
		blood_flood(pool, draws, x, y, x, y, 1, inputs)
		flying_debris(pool, draws, x, y, inputs)
		return
	var coin: float = 10.0 * draws.raw()
	if coin > SPECIES_COIN:
		blood_flood(pool, draws, x, y, x, y, 1, inputs)
		flying_debris(pool, draws, x, y, inputs)
		return
	var at: Vector3i = inputs.object(x, y)
	var half: int = DictRead.as_int(unit["height"]) / 2
	for _i: int in range(2):
		var delay: int = draws.draw(0, 3)
		var vz: int = draws.draw(500, 1000) + 500
		var vy: int = draws.draw(500, 1000)
		var vx: int = draws.draw(500, 1000)
		pool.spawn("A_SPLAT5.3DI", 0, at.x, at.y, at.z + half, 0, 0, 0, 0x12,
			0x1E, vx, vy, vz, 0, delay)
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z + half, 7, 0, 0, 0x33, 0x10, 0, 0,
		0, 0x19, 0)
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z + half + 500, 7, 0, 0, 0x33, 0x10,
		0, 0, 0, 0x1E, 2)
	var models: Array = DictRead.as_array(SPECIES_MODELS[type_id])
	for j: int in range(4):
		if j >= models.size():
			continue
		var name: String = DictRead.as_string(models[j])
		var vx2: int = draws.draw(-600, 0x4B0)
		var vy2: int = draws.draw(-600, 0x4B0)
		var vz: int = draws.draw(500, 700)
		var dz: int = draws.draw(0, 0x640)
		var vx: int = vx2 / 2
		var vy: int = vy2 / 2
		pool.spawn(name, 0, at.x, at.y, at.z + half + dz, 0, 0, 0, 0x12, 0x32,
			vx, vy, vz, 0, 0)
		for m: int in range(1, 5):
			pool.spawn(BLOOD_TRAIL[m - 1], 0, at.x, at.y, at.z + half + dz, 0, 0,
				0, 0x12, 0x1E, vx, vy, vz, 0, m)


## `aBlob_CreateFireExplosion(x, y, _)` -- nine rings of three class-2
## records rising 0x3C0 a ring, kind 50, life 8, the ring index as the delay
## and a rotation word that turns on at the fifth ring; `aux` draws with the
## ring's height counter added **inside** the conversion. The species-3 and
## barrel death, and three impact arms; the third argument is never read.
static func fire_explosion(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	var z: int = at.z
	var step: int = 0
	var ring: int = 0
	while step <= 0x11:
		for _i: int in range(3):
			var dx: int = draws.draw(-0x640, 0xC80)
			var dy: int = draws.draw(-0x640, 0xC80)
			var dz: int = draws.draw(0, 0x640)
			var aux: int = draws.draw_biased(5, 0xF, step)
			pool.spawn(SCRATCH, 2, at.x + dx, at.y + dy, z + dz,
				0 if step < 10 else 2, 0, 0, 0x32, 8, 0, 0, 0, aux, ring)
		step += 2
		ring += 1
		z += 0x3C0


## `aBlob_CreateKillFire(x, y, delay)` -- ten class-2 flames, kind 10, life
## 20, scattered ±800 around the placed object, each delayed `aRandom2(0, 3)`
## plus the argument: 0 from the fight's death switch, 20 from `FireCircle`.
static func kill_fire(pool: Pool, draws: Draws, x: int, y: int,
		delay_base: int, inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	for _i: int in range(10):
		var vx: int = draws.draw(-0x30, 0x60)
		var vy: int = draws.draw(-0x30, 0x60)
		var vz: int = draws.draw(0x140, 0xA0)
		var delay: int = draws.draw(0, 3) + delay_base
		var z: int = draws.draw(-0x320, 0x640) + at.z
		var py: int = draws.draw(-0x320, 0x640) + at.y
		var px: int = draws.draw(-0x320, 0x640) + at.x
		pool.spawn(SCRATCH, 2, px, py, z, 0, 0, 0, 0xA, 0x14, vx, vy, vz, 0x14,
			delay)


## `aBlob_CreateFireDeath(x, y)` -- a column of twenty class-2 records, kind
## 60, life 8, sprite row 4, stacked 20 units apart and delayed by index.
static func fire_death(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	for i: int in range(20):
		var vx: int = draws.draw(-0x1E0, 0x3C0)
		var vy: int = draws.draw(-0x1E0, 0x3C0)
		var vz: int = draws.draw(0xA0, 0x640)
		var aux: int = draws.draw(5, 0x14)
		pool.spawn(SCRATCH, 2, at.x, at.y, at.z + i * 20, 4, 0, 0, 0x3C, 8, vx,
			vy, vz, aux, i)


## `aBlob_CreateFlyingUnit(x, y, delay)` -- one class-0 record whose model is
## the unit type's own `.3DI`, kind 3, life 10, thrown straight up at 800: the
## barrel of class 0x0C leaves its cell.
static func flying_unit(pool: Pool, draws: Draws, x: int, y: int, delay: int,
		inputs: Inputs) -> void:
	var unit: Dictionary = inputs.unit(x, y)
	if unit.is_empty():
		return
	var at: Vector3i = inputs.object(x, y)
	var name: String = inputs.type_models.get(DictRead.as_int(unit["type"]), "")
	# No draw: `draws` is the signature every program shares.
	var _draws: Draws = draws
	pool.spawn(name, 0, at.x, at.y, at.z, 0, 0, 0, 3, 0xA, 0, 0, 0x320, 0, delay)


## `count` offsets, each the previous one turned by `turn` through
## `0x004039A0` -- the rotation accumulates, so a ring is the engine's table
## arithmetic and not a clean division of the circle.
static func _ring(inputs: Inputs, radius: int, turn: int, count: int
		) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if inputs.geometry == null:
		# No tables, no ring: the constructor would have nothing to place.
		return out
	var offset: Vector3i = Vector3i(radius, 0, 0)
	for _i: int in range(count):
		offset = inputs.geometry.rotate(offset, Vector3i(0, 0, turn))
		out.append(offset)
	return out


## `0x00422D40` -- the selection marker (docs/42 section 7.3): four
## `A_ARROW.3DI` model blobs, kind 14, life 15, a quarter turn apart at the
## ring's radius around the unit's object, each aimed along the line from
## the object to itself, the object's x and y in `vx`/`vy` for kind 14's arm.
## No draw.
static func arrows(pool: Pool, x: int, y: int, inputs: Inputs) -> void:
	var unit: Dictionary = inputs.unit(x, y)
	if unit.is_empty():
		return
	var at: Vector3i = inputs.object(x, y)
	var radius: int = RING_RADIUS_LARGE if inputs.large(unit) else RING_RADIUS
	for offset: Vector3i in _ring(inputs, radius, QUARTER_TURN, 4):
		var there: Vector3i = Vector3i(at.x + offset.x, at.y + offset.y, at.z)
		var aim: Vector2i = inputs.geometry.orient(at, there)
		pool.spawn(ARROW_MODEL, 0, there.x, there.y, at.z, aim.x, 0, aim.y,
			0xE, 0xF, at.x, at.y, 0, 0, 0)


## `0x00422B80` -- `aBlob_CreateShockWave` (`0x0040CD56`): a ring of
## `A_EXPL05.3DI` model blobs thrown outward from the tile's placed object.
##
## Weapon 17's muzzle and weapon 36's impact are its two callers and both push
## type 2, so what the game ever makes is **sixty** records of kind 13 with a
## life of 20. Every one sits at the object's own position -- the ring goes
## into the *velocity*, not the placement -- oriented along the line from the
## object to its own point on the circle, exactly as the selection marker
## `0x00422D40` is. No draw: the whole effect is table arithmetic.
static func shock_wave(pool: Pool, x: int, y: int, type_id: int,
		inputs: Inputs) -> void:
	var arm: Array = DictRead.as_array(SHOCKWAVE_ARMS.get(type_id & 0xFF, []))
	if arm.size() < 3:
		return
	var count: int = DictRead.as_int(arm[0])
	var life: int = DictRead.as_int(arm[1])
	var speed: int = DictRead.as_int(arm[2])
	var at: Vector3i = inputs.object(x, y)
	var turn: int = IncInt.div_trunc(SHOCKWAVE_TURN, count) & 0xFFFF
	for offset: Vector3i in _ring(inputs, SHOCKWAVE_RADIUS, turn, count):
		var there: Vector3i = Vector3i(at.x + offset.x, at.y + offset.y, at.z)
		var aim: Vector2i = inputs.geometry.orient(at, there)
		pool.spawn(SHOCKWAVE_MODEL, 0, at.x, at.y, at.z, aim.x, 0, aim.y,
			SHOCKWAVE_KIND, life, offset.x * speed, offset.y * speed, 0, 0, 0)


## `0x004227C0` -- the landing dust (docs/42 section 7.1): twenty class-2
## puffs from the object, kind 9, life 10, row 4, thrown at a third of an
## offset that turns 204 units a puff, rising at 800. No draw.
static func landing_dust(pool: Pool, x: int, y: int, inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	for offset: Vector3i in _ring(inputs, DUST_RADIUS, DUST_TURN, 20):
		pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 4, 0, 0, 9, 10,
			IncInt.div_trunc(offset.x, 3), IncInt.div_trunc(offset.y, 3),
			0x320, 10, 0)


## `0x00423030` -- the heal orbit's flash circle: four crosses a twelfth of
## a turn apart, each with its mirror image, kind 37, life 40, at half the
## unit's height. Eight records, no draw.
static func heal_flash(pool: Pool, x: int, y: int, inputs: Inputs) -> void:
	var unit: Dictionary = inputs.unit(x, y)
	if unit.is_empty():
		return
	var at: Vector3i = inputs.object(x, y)
	var half: int = IncInt.div_trunc(DictRead.as_int(unit["height"]), 2)
	var radius: int = FLASH_RADIUS_LARGE if inputs.large(unit) else FLASH_RADIUS
	var ring: Array[Vector3i] = _ring(inputs, radius, CROSS_TURN, 4)
	for index: int in range(ring.size()):
		var offset: Vector3i = ring[index]
		var aim: Vector2i = inputs.geometry.orient(at,
			Vector3i(at.x + offset.x, at.y + offset.y, at.z))
		var name: String = CROSS_MODELS[index]
		pool.spawn(name, 0, at.x + offset.x, at.y + offset.y, at.z + half,
			aim.x, 0, aim.y, 0x25, 0x28, at.x, at.y, 0, 0, 0)
		pool.spawn(name, 0, at.x - offset.x, at.y - offset.y, at.z + half,
			aim.x, 0, aim.y, 0x25, 0x28, at.x, at.y, 0, 0, 0)


## `0x004232E0` -- the poison orbit's flash circle: four `A_SKULL.3DI` a
## quarter turn apart at the **flash's** radius (the heal circle's, not the
## marker's -- the capture corrected that), kind 37, life 40, at half the
## unit's height. No draw.
static func poison_flash(pool: Pool, x: int, y: int, inputs: Inputs) -> void:
	var unit: Dictionary = inputs.unit(x, y)
	if unit.is_empty():
		return
	var at: Vector3i = inputs.object(x, y)
	var half: int = IncInt.div_trunc(DictRead.as_int(unit["height"]), 2)
	var radius: int = FLASH_RADIUS_LARGE if inputs.large(unit) else FLASH_RADIUS
	for offset: Vector3i in _ring(inputs, radius, QUARTER_TURN, 4):
		var aim: Vector2i = inputs.geometry.orient(at,
			Vector3i(at.x + offset.x, at.y + offset.y, at.z))
		pool.spawn(SKULL_MODEL, 0, at.x + offset.x, at.y + offset.y,
			at.z + half, aim.x, 0, aim.y, 0x25, 0x28, at.x, at.y, 0, 0, 0)


## `0x00423720` -- `aBlob_CreateZoomBob(x, y, z, row, aux, life)`: one
## class-2 record at a position, kind 50, no velocity, no draw.
static func zoombob(pool: Pool, at: Vector3i, row: int, aux: int, life: int
		) -> void:
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, row, 0, 0, 0x32, life, 0, 0, 0,
		aux, 0)


## `0x00423670` -- the jump's trail (docs/42 section 7.1): a zoom bob (row 4,
## aux 10, life 3) and four class-2 sprites of kind 10, life 11, row 4,
## drifting 48 either way and falling 640..592, each delayed by its index --
## three draws each, in the order z, y, x.
static func trail(pool: Pool, draws: Draws, at: Vector3i) -> void:
	zoombob(pool, at, 4, 10, 3)
	for index: int in range(4):
		var vz: int = draws.draw(0, 0x30) - 0x280
		var vy: int = draws.draw(-0x30, 0x60)
		var vx: int = draws.draw(-0x30, 0x60)
		pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 4, 0, 0, 0xA, 0xB, vx, vy, vz,
			0xB, index)


## `0x0042A6E0` -- the push's dust (docs/42 section 7.2): one class-2 sprite
## of row 4, kind 10, life 20, drifting 48 either way and rising 320..480 --
## three draws, in the order x, y, z.
static func push_dust(pool: Pool, draws: Draws, at: Vector3i) -> void:
	var vx: int = draws.draw(-0x30, 0x60)
	var vy: int = draws.draw(-0x30, 0x60)
	var vz: int = draws.draw(0x140, 0xA0)
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 4, 0, 0, 0xA, 0x14, vx, vy, vz,
		10, 0)


## `0x0042A660` -- one flame of a `CreateBGB` type-7 emitter.
##
## The same three draws as the push's dust -- 48 either way and 320..480 up --
## into a **class-3** record with no rotation, kind 58, life 12 and `aux` 5.
## Kind 58 walks it up, advances its atlas column and, in its last four ticks,
## writes the column down again, which is a flame guttering out.
##
## The whole of the creator is those three draws and one constructor call;
## `blob_tables.py`'s `bgb.fire_*` pins both halves against the executable.
static func main_map_fire(pool: Pool, draws: Draws, at: Vector3i) -> void:
	var vx: int = draws.draw(-0x30, 0x60)
	var vy: int = draws.draw(-0x30, 0x60)
	var vz: int = draws.draw(0x140, 0xA0)
	pool.spawn(SCRATCH, 3, at.x, at.y, at.z, 0, 0, 0, 0x3A, 0xC, vx, vy, vz,
		5, 0)


## `0x0042A5E0` -- one puff of a `CreateBGB` type-1 emitter.
##
## The same three draws and the same shape as [method main_map_fire] -- the
## two are the only creators the sweep reaches -- with kind 10 instead of 58,
## sprite row 4, and `aux` 10 instead of 5. Kind 10 walks the record up and
## reverses its atlas column over the last four ticks, so this is the flame's
## quieter sibling rather than a different mechanism.
##
## **Nothing in the shipped corpus reaches it.** All four `1_smoke` lines --
## two in `_C_XXX.lcl`, two in `_C_YYY.lcl` -- are commented out in their own
## scripts, so the type is registered by no mission and the program is checked
## against the executable's bytes (`blob_tables.py`'s `bgb.smoke_*`) rather
## than against a record anything makes.
static func bgb_smoke(pool: Pool, draws: Draws, at: Vector3i) -> void:
	var vx: int = draws.draw(-0x30, 0x60)
	var vy: int = draws.draw(-0x30, 0x60)
	var vz: int = draws.draw(0x140, 0xA0)
	pool.spawn(SCRATCH, 3, at.x, at.y, at.z, 4, 0, 0, 0xA, 0xC, vx, vy, vz,
		10, 0)


## `0x0042A4C0` -- `CreateBGB` type 2, made **once, at registration**.
##
## A class-1 `A_FLIGHT.3DI` model with `life` 255, which never expires
## (`blob.gd`, `+0x45`), so the light turns for the whole mission. Its one
## draw is a coin: `aRandom2(0, 100) >= 50` gives `vx` +5 and anything under
## it -5, and kind 41 turns the model by `0x200 / vx` a tick -- so the sign is
## which way it sweeps and the magnitude the rate. Kind 41 divides by `vx`
## with nothing in front of the divide, which is why the port guards a zero
## the original would fault on; +/-5 never reaches that guard.
##
## `_C_102.lcl` and `_S_005.lcl` light two each.
static func bgb_warning_light(pool: Pool, draws: Draws, at: Vector3i) -> void:
	var spin: int = BGB_WARNING_SPIN \
		if draws.draw(0, 100) >= BGB_WARNING_COIN else -BGB_WARNING_SPIN
	pool.spawn(BGB_WARNING_MODEL, 1, at.x, at.y, at.z, 0, 0, 0, 0x29, 0xFF,
		spin, 0, 0, 0, 0)


## `0x0042A760` -- `CreateBGB` type 3, made once at registration.
##
## The only one of the six that reads a fourth argument: the command shifts
## the script's `gamma` left by ten on its way in, and the creator hands that
## straight to the record's `rot_z`. Kind 42 copies `rot_x` and `rot_z` into
## the model's first and third angles and rolls the second between `0x400`
## and `0x1000` every tick, which is a panel flipping edge-on and face-on --
## the flicker of docs/28 section 7.8.
##
## The one shipped call, `_S_005.lcl`'s `3_computerlight ... 1_gamma`, is
## commented out; the gamma is transcribed because the shift is the command's
## and is read from its bytes.
static func bgb_computer_light(pool: Pool, at: Vector3i, gamma: int) -> void:
	pool.spawn(BGB_PANEL_MODEL, 1, at.x, at.y, at.z, 0, 0, gamma, 0x2A, 0xFF,
		0, 0, 0, 0, 0)


## `0x0042A520` -- `CreateBGB` type 4, `A_FIRE3.3DI`, kind 54.
##
## Three of the six share one body byte for byte and differ only in the model
## and the kind: no draw, no velocity, `life` 255, everything else zero. Kind
## 54 rolls two of the model's angles over the full 4096 each tick, which is a
## fire that never settles.
##
## **No shipped script asks for type 4, 5 or 6.** They are transcribed because
## registration dispatches on them, not because the corpus reaches them.
static func bgb_fire3(pool: Pool, at: Vector3i) -> void:
	_bgb_still(pool, BGB_FIRE3_MODEL, at, 0x36)


## `0x0042A5A0` -- `CreateBGB` type 5, `A_SPOTL.3DI`, kind 55: a spotlight
## turning `0x33` a tick, one twentieth of a turn a second at 20 fps.
static func bgb_spot(pool: Pool, at: Vector3i) -> void:
	_bgb_still(pool, BGB_SPOT_MODEL, at, 0x37)


## `0x0042A560` -- `CreateBGB` type 6, `L049EE00.3DI`, kind 57, which sets
## `rot_z` to a fresh full-circle draw every tick rather than advancing it.
static func bgb_lamp(pool: Pool, at: Vector3i) -> void:
	_bgb_still(pool, BGB_LAMP_MODEL, at, 0x39)


## The body types 4, 5 and 6 share: a class-1 model at the emitter's own
## place, `life` 255 and no motion of any sort. What moves is the arm.
static func _bgb_still(pool: Pool, model: String, at: Vector3i,
		kind: int) -> void:
	pool.spawn(model, 1, at.x, at.y, at.z, 0, 0, 0, kind, 0xFF,
		0, 0, 0, 0, 0)


# --- docs/42 section 8: the set pieces' creators ------------------------------

## `0x00423770` -- the tube's puffs (`OpenTube` at its tenth frame): fifteen
## pairs of class-2 sprites at the object, kind 10, life 20, row 4, aux 10,
## drifting 48 either way and rising 320..480, each pair delayed by its
## index -- three draws a record, in the order x, y, z.
static func tube_puffs(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	for index: int in range(TUBE_PAIRS):
		for _i: int in range(2):
			var vx: int = draws.draw(-0x30, 0x60)
			var vy: int = draws.draw(-0x30, 0x60)
			var vz: int = draws.draw(0x140, 0xA0)
			pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 4, 0, 0, 0xA, 0x14, vx, vy,
				vz, 10, index)


## `0x00423C20(x, y)` -- `aBlob_CreateTubeSmoke`: fifty class-0 explosion
## sprites at the cell's land marker, kind 31, life 5, drifting 48 either way
## and rising 320..1920, alternating `A_EXPL03` and `A_EXPL04` on the low bit
## of the index and delayed by the index over six -- three draws a record, in
## the order x, y, z.
##
## This is what `aPlayGroundFireAnimation` `0x004157B0` makes on the burning
## cell itself, **outside** its victim loop, so a glow that ignites with
## nobody standing on it still flashes (docs/42 section 9.1). It has no twin
## in `inclib`: docs/92 section 5.1 -- a new presentation subject goes
## straight into GDScript, and the existing Python models are frozen.
static func tube_smoke(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	for index: int in range(TUBE_SMOKE_COUNT):
		var vx: int = draws.draw(-0x30, 0x60)
		var vy: int = draws.draw(-0x30, 0x60)
		var vz: int = draws.draw(0x140, 0x640)
		pool.spawn(TUBE_SMOKE_MODELS[index & 1], 0, at.x, at.y, at.z,
			0, 0, 0, 0x1F, 5, vx, vy, vz, 0,
			index / TUBE_SMOKE_DELAY_DIVISOR)


## `0x004234C0(x, y, z)` -- the platform's dust, once a frame: four sprites
## at the block's corners, 4800 out and 1600 up, kind 10, life 12, row 4,
## aux 10, rising 320..368 and drifting 48 either way -- three draws a
## record, in the order z, y, x.
static func platform_dust(pool: Pool, draws: Draws, at: Vector3i) -> void:
	var up: int = at.z + PLATFORM_DUST_UP
	var s: int = PLATFORM_DUST_SPREAD
	var corners: Array[Vector2i] = [Vector2i(at.x - s, at.y - s),
		Vector2i(at.x - s, at.y + s), Vector2i(at.x + s, at.y + s),
		Vector2i(at.x + s, at.y - s)]
	for corner: Vector2i in corners:
		var vz: int = draws.draw(0, 0x30) + 0x140
		var vy: int = draws.draw(-0x30, 0x60)
		var vx: int = draws.draw(-0x30, 0x60)
		pool.spawn(SCRATCH, 2, corner.x, corner.y, up, 4, 0, 0, 0xA, 0xC, vx, vy,
			vz, 10, 0)


## Twenty `A_DEBRIS` and four `A_SPLAT1` from `(ox, oy, z)`: the shape the
## ground unit's and the roof unit's debris share. Each record draws its x
## and y velocity in -200..100 and a third value -- taken and discarded by
## the ground unit's, kept as the vertical by the roof's -- then a delay 0..3.
static func _debris_pair(pool: Pool, draws: Draws, ox: int, oy: int, z: int,
		kind: int, vz: int, third: Vector2i, splat_third: Vector2i,
		vz_drawn: bool) -> void:
	var shapes: Array = [["A_DEBRIS.3DI", 20, third], ["A_SPLAT1.3DI", 4, splat_third]]
	for shape: Array in shapes:
		var name: String = shape[0]
		var count: int = shape[1]
		var span: Vector2i = shape[2]
		for _i: int in range(count):
			var vx: int = draws.draw(-200, 300)
			var vy: int = draws.draw(-200, 300)
			var drawn: int = draws.draw(span.x, span.y)
			var delay: int = draws.draw(0, 4)
			pool.spawn(name, 0, ox, oy, z, 0, 0, 0, kind, 0x32, vx, vy,
				drawn if vz_drawn else vz, 0, delay)


## `0x00422610(x, y, z)` -- the ground unit's debris: kind 29, life 50,
## thrown 300 up, the third draw discarded.
static func ground_debris(pool: Pool, draws: Draws, x: int, y: int, z: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	_debris_pair(pool, draws, at.x, at.y, z, 0x1D, 0x12C, Vector2i(40, 140),
		Vector2i(40, 100), false)


## `0x00422460(x, y, z)` -- the roof unit's debris: kind 0, life 50, the
## third draw kept as the vertical, `aRandom2(40, -100)`, a span the wrong
## way round.
static func roof_debris(pool: Pool, draws: Draws, x: int, y: int, z: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	_debris_pair(pool, draws, at.x, at.y, z, 0, 0, Vector2i(40, -100),
		Vector2i(40, -100), true)


## `0x004238C0(x, y)` -- the crush wall's debris, once a cell: thirty
## sprites scattered 1600 either way around the object (kind 10, life 20,
## row 4, aux 30, delayed 0..2; seven draws in the order vx, vy, vz, delay,
## z, y, x), then five `A_DEBRIS` of kind 5, life 100, spun by three draws
## of 0..4095.
static func wall_debris(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	for _i: int in range(30):
		var vx: int = draws.draw(-0x30, 0x60)
		var vy: int = draws.draw(-0x30, 0x60)
		var vz: int = draws.draw(0x140, 0xA0)
		var delay: int = draws.draw(0, 3)
		var z: int = draws.draw(-0x640, 0xC80) + at.z
		var py: int = draws.draw(-0x640, 0xC80) + at.y
		var px: int = draws.draw(-0x640, 0xC80) + at.x
		pool.spawn(SCRATCH, 2, px, py, z, 4, 0, 0, 0xA, 0x14, vx, vy, vz, 0x1E,
			delay)
	for _j: int in range(5):
		var vz: int = draws.draw(100, 500)
		var vx: int = draws.draw(-300, 600)
		var vy: int = draws.draw(-300, 600)
		var rz: int = draws.draw(0, 0x1000)
		var ry: int = draws.draw(0, 0x1000)
		var rx: int = draws.draw(0, 0x1000)
		pool.spawn("A_DEBRIS.3DI", 0, at.x, at.y, at.z, rx, ry, rz, 5, 100, vx,
			vy, vz, 0, 0)


## `0x00422F00(x, y)` -- the fire circle's ring: 150 flames on a ring of a
## field's radius, each offset the previous turned by 60, a field below the
## object, kind 67, life 6, aux 20, delayed `i / 8`, the pitch drawn 0..2.
static func fire_circle(pool: Pool, draws: Draws, x: int, y: int,
		inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	var at: Vector3i = inputs.object(x, y)
	var offset: Vector3i = Vector3i(FIRE_CIRCLE_RADIUS, 0, 0)
	for index: int in range(FIRE_CIRCLE_FLAMES):
		offset = inputs.geometry.rotate(offset, Vector3i(0, 0, FIRE_CIRCLE_TURN))
		var pitch: int = draws.draw(0, 3)
		pool.spawn(SCRATCH, 2, at.x + offset.x, at.y + offset.y,
			at.z - FIRE_CIRCLE_RADIUS, pitch, 0, 0, 0x43, 6, 0, 0, 0, 0x14, index >> 3)


## `aBlob_CreateLaserBarrier(x, y, dir, count)` `0x00428990`: from the object
## 2400 down, aimed 100 units along `dir`, three class-2 dots one field back
## along the line (kind 51, life 16, aux 10, pitch 5) at z, z + 800, z +
## 1600; then `count` times the line moves a field on and three
## `A_LASERG.3DI` (kind 1, life 9) are laid at the same heights, aimed by
## `0x00403AA0`. No draw.
static func laser_barrier(pool: Pool, x: int, y: int, direction: int,
		count: int, inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	var at: Vector3i = inputs.object(x, y)
	var z0: int = at.z - 0x960
	var step: Vector2i = LASER_DIRECTIONS[direction & 3] \
		if (direction & 0xFF) <= 3 else Vector2i.ZERO
	var source: Vector3i = Vector3i(at.x, at.y, z0)
	var target: Vector3i = Vector3i(at.x + step.x * 100, at.y + step.y * 100, z0)
	var d: PackedFloat64Array = Eng3dGeometry.direction(source, target, 1)
	var aim: Vector2i = inputs.geometry.orient(source, target)
	for i: int in range(3):
		pool.spawn(SCRATCH, 2, at.x - Eng3dGeometry.ftol(d[0] * LASER_OFFSET),
			at.y - Eng3dGeometry.ftol(d[1] * LASER_OFFSET), z0 + i * 0x320,
			5, 0, 0, 0x33, 0x10, 0, 0, 0, 10, 0)
	var line: Vector3i = source
	for _c: int in range(count & 0xFF):
		line = Vector3i(line.x - Eng3dGeometry.ftol(d[0] * LASER_STEP),
			line.y - Eng3dGeometry.ftol(d[1] * LASER_STEP),
			line.z - Eng3dGeometry.ftol(_finite(d[2]) * LASER_STEP))
		for i: int in range(3):
			pool.spawn("A_LASERG.3DI", 0, line.x, line.y, line.z + i * 0x320,
				aim.x, 0, aim.y, 1, 9, 0, 0, 0, 0, 0)


static func _finite(value: float) -> float:
	return 0.0 if is_nan(value) or is_inf(value) else value


## The statue's beam `0x00428BF0(sx, sy, tx, ty, cells)`: from the source
## object, stepping `1600 * direction` a dot, `2 * cells - 1` dots at z 3200
## (kind 62, life 7, aux 25, rot_y 3, delayed by index), then six sparks from
## the last dot, kind 62, life 7, aux 30, rising 800 and thrown 3000 either
## way (vy then vx), rotations alternating `(0, 3)` and `(2, 0)`, delayed
## `j / 2` plus the dot count.
static func statue_beam(pool: Pool, draws: Draws, sx: int, sy: int, tx: int,
		ty: int, cells: int, inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(sx, sy)
	var aim: Vector3i = inputs.object(tx, ty)
	var d: PackedFloat64Array = Eng3dGeometry.direction(at,
		Vector3i(aim.x, aim.y, at.z), 1)
	var px: int = at.x + Eng3dGeometry.ftol(d[0] * SPARK_SPEED)
	var py: int = at.y + Eng3dGeometry.ftol(d[1] * SPARK_SPEED)
	var dots: int = 2 * cells - 1
	for index: int in range(dots):
		px += Eng3dGeometry.ftol(d[0] * SPARK_SPEED)
		py += Eng3dGeometry.ftol(d[1] * SPARK_SPEED)
		pool.spawn(SCRATCH, 2, px, py, 0xC80, 0, 3, 0, 0x3E, 7, 0, 0, 0, 0x19,
			index)
	for j: int in range(6):
		var rx: int = 2 if j & 1 else 0
		var ry: int = 0 if j & 1 else 3
		var vy: int = draws.draw(-3000, 6000)
		var vx: int = draws.draw(-3000, 6000)
		pool.spawn(SCRATCH, 2, px, py, 0xC80, rx, ry, 0, 0x3E, 7, vx, vy, 0x320,
			0x1E, (j / 2 + dots) & 0xFF)


## The teleporter's stream `0x0042A120(sx, sy, tx, ty)`: two hundred
## records, kind 65, life 70, aux 5, one every 16 units up from the source
## object's z, scattered 1600 either way around the source and given, in
## the velocity slots, a point around the target at its height plus 3200
## less the rise -- four draws each, converted with the addend inside, in
## the order vy, vx, y, x; delayed `i / 10`.
static func teleport_stream(pool: Pool, draws: Draws, sx: int, sy: int,
		tx: int, ty: int, inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(sx, sy)
	var aim: Vector3i = inputs.object(tx, ty)
	for index: int in range(STREAM_RECORDS):
		var rise: int = index * STREAM_STEP
		var vz: int = aim.z - rise + 0xC80
		var vy: int = draws.draw_biased(-0x640, 0xC80, aim.y)
		var vx: int = draws.draw_biased(-0x640, 0xC80, aim.x)
		var py: int = draws.draw_biased(-0x640, 0xC80, at.y)
		var px: int = draws.draw_biased(-0x640, 0xC80, at.x)
		pool.spawn(SCRATCH, 2, px, py, at.z + rise, 5, 0, 0, 0x41, 0x46, vx, vy,
			vz, 5, index / 10)


## The bomber `0x0042A8E0(x, y, z, tx, ty, tz)`: one `L069EE00.3DI` at the
## source, kind 52, life 150, flying a field a tick along the direction,
## aimed by `0x00403AA0`. No draw.
static func bomber(pool: Pool, from: Vector3i, to: Vector3i, inputs: Inputs
		) -> void:
	if inputs.geometry == null:
		return
	var d: PackedFloat64Array = Eng3dGeometry.direction(from, to, 1)
	var aim: Vector2i = inputs.geometry.orient(from, to)
	# `0x0042A938` -- the fly-past is something to wait for.
	pool.clears_arrived = true
	pool.spawn("L069EE00.3DI", 0, from.x, from.y, from.z, aim.x, 0, aim.y, 0x34,
		0x96, Eng3dGeometry.ftol(d[0] * BOMBER_SPEED),
		Eng3dGeometry.ftol(d[1] * BOMBER_SPEED),
		Eng3dGeometry.ftol(_finite(d[2]) * BOMBER_SPEED), 0, 0)


## One para bomb `0x0042B070(x, y, delay)`: an `A_PARAB1.3DI` dropped from
## 48000 over the object, kind 25, falling 800 a tick, its life the fall from
## 35200 to the object's height at that rate, rot_y 64 and rot_z drawn.
static func para_bomb(pool: Pool, draws: Draws, x: int, y: int, delay: int,
		inputs: Inputs) -> void:
	var at: Vector3i = inputs.object(x, y)
	var life: int = absi(IncInt.div_trunc(BOMB_CEILING - at.z, BOMB_FALL))
	var rz: int = draws.draw(0, 0x1000)
	# `0x0042B0E3` -- and so is each bomb, until it lands.
	pool.clears_arrived = true
	pool.spawn("A_PARAB1.3DI", 0, at.x, at.y, BOMB_DROP, 0, 0x40, rz, 0x19, life,
		0, 0, -BOMB_FALL, 0, delay)


# --- docs/97 section 49: the twelve an update arm calls ----------------------
#
# `docs/28` section 8.1's weapon switches name thirty creators and docs/42's
# set pieces and unit animations another twenty-nine; these are the rest, and
# an update arm is the only thing that calls them. The remake **recorded** such
# a request and never ran it until [GameBlobHooks] did, which is why none of
# them needed a program before and all twelve needed one at once.
#
# Every one is stepped inside a live `Incubation.exe`: `blob_gold.py`'s
# `zoom_bob_*` and `spawn_*` families poke a donor record to a kind whose arm
# calls it, write the second generator's seed, step one `aBlob_Update` and read
# the pool wide enough to hold the child.


## `0x0042ADD0` -- `aBlob_SparkingRain(x, y, z, count, speed)`, which only
## [method hitting_blobs] calls. `speed` is a two-value enumeration and the
## third value is a `CHECK`: `0x0042ADF2` pushes "unknown speed" and the
## routine makes nothing. 0 is the slow rain (life 30, the draws as they come)
## and 1 the fast one (life 5, both sideways draws doubled).
static func _sparking_rain(pool: Pool, draws: Draws, at: Vector3i, count: int,
		speed: int) -> void:
	var multiplier: int = 0
	var life: int = 0
	if speed == 0:
		multiplier = 1
		life = 30
	elif speed == 1:
		multiplier = 2
		life = 5
	else:
		return
	for _i: int in range(count & 0xFF):
		var vz: int = draws.draw(5, 10) << 5
		var vy: int = (draws.draw(-10, 20) * multiplier) << 4
		var vx: int = (draws.draw(-10, 20) * multiplier) << 4
		pool.spawn("A_FUNKE.3DI", 0, at.x, at.y, at.z, 0, 0, 0, 0x14, life,
			vx, vy, vz, 0, 0)


## `0x00420950` -- **the constructor itself**, which two arms call directly.
## It is not a creator and has no arithmetic of its own, so the program is
## [method Pool.spawn] and nothing else. The only name an arm passes is
## [constant NAME_SCRATCH], which a class-2 record ignores.
static func emitter(pool: Pool, args: PackedInt32Array) -> void:
	var name: String = SCRATCH if args[0] == NAME_SCRATCH else str(args[0])
	pool.spawn(name, args[1], args[2], args[3], args[4], args[5], args[6],
		args[7], args[8], args[9], args[10], args[11], args[12], args[13],
		args[14])


## `0x00428E30` -- the spore sparks: `count` class-2 records of kind 23 at one
## point, row 6, aux 3, one frame of delay, rising 100..400 and drifting 100
## either way. Three draws each, and the **middle one is the sideways x**
## rather than the y: the compiler evaluated the two `aRandom2(-100, 200)`
## calls in source order and pushed them in reverse.
static func spore_sparks(pool: Pool, draws: Draws, at: Vector3i, count: int,
		life: int) -> void:
	for _i: int in range(count & 0xFF):
		var vz: int = draws.draw(100, 300)
		var vx: int = draws.draw(-100, 200)
		var vy: int = draws.draw(-100, 200)
		pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 6, 0, 0, 0x17, life,
			vx, vy, vz, 3, 2)


## `0x00428ED0` -- the plasma sparks: [method spore_sparks]' body with a
## **model** rather than a sprite, no row and no aux.
static func plasma_sparks(pool: Pool, draws: Draws, at: Vector3i, count: int,
		life: int) -> void:
	for _i: int in range(count & 0xFF):
		var vz: int = draws.draw(100, 300)
		var vx: int = draws.draw(-100, 200)
		var vy: int = draws.draw(-100, 200)
		pool.spawn("A_FUNKE.3DI", 0, at.x, at.y, at.z, 0, 0, 0, 0x17, life,
			vx, vy, vz, 0, 2)


## `0x00428F70` -- the big plasma burst, and the one creator here whose
## **speed is drawn per component**. It is called with five dwords and reads
## four; the fifth is the sibling sparks' `life`, which this one draws. Three draws before the loop pick one
## scattered point (12800 either way, 12800..25600 up) and every spark then
## aims within 160 of *that*, so the burst is a cone rather than a sphere.
## Each velocity is `0x0046D400`'s direction times a speed of its own, the
## draw truncated **before** the multiply (`fild` of the stored integer) and
## again after it. Eight draws a spark: x, y, z, delay, the speeds z, y, x,
## and the life.
static func plasma_sparks_burst(pool: Pool, draws: Draws, at: Vector3i,
		count: int, inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	var base: Vector3i = Vector3i(at.x + draws.draw(-0x3200, 0x6400),
		at.y + draws.draw(-0x3200, 0x6400), at.z + draws.draw(0x3200, 0x3200))
	for _i: int in range(count & 0xFF):
		var aim: Vector3i = Vector3i(base.x + draws.draw(-0xA0, 0x140),
			base.y + draws.draw(-0xA0, 0x140),
			base.z + draws.draw(-0xA0, 0x1E0))
		var d: PackedFloat64Array = Eng3dGeometry.direction(at, aim, 1)
		var turn: Vector2i = inputs.geometry.orient(at, aim)
		var delay: int = draws.draw(0, 4)
		var vz: int = Eng3dGeometry.ftol(draws.draw(0xA0, 0xA0) * d[2])
		var vy: int = Eng3dGeometry.ftol(draws.draw(0x1E0, 0x140) * d[1])
		var vx: int = Eng3dGeometry.ftol(draws.draw(0x1E0, 0x140) * d[0])
		pool.spawn("A_SPARK.3DI", 0, at.x, at.y, at.z, turn.x, 0, turn.y,
			0x48, draws.draw(0xA, 0xF), vx, vy, vz, 0, delay)


## `0x00429390` -- the spores: the same three draws again, into kind 40 at
## row 3 with a fixed life of 8.
static func spores(pool: Pool, draws: Draws, at: Vector3i, count: int) -> void:
	for _i: int in range(count & 0xFF):
		var vz: int = draws.draw(100, 300)
		var vx: int = draws.draw(-100, 200)
		var vy: int = draws.draw(-100, 200)
		pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 3, 0, 0, 0x28, 8,
			vx, vy, vz, 3, 2)


## `0x00429430` -- the sting sparks, and the one creator here that **draws
## nothing**. Two class-2 records of kind 33, row 3, life 8, whose velocities
## are the caller's own turned a quarter turn either way and cut to a fifth.
## The divide is the compiler's reciprocal multiply, which truncates toward
## zero.
static func sting_sparks(pool: Pool, at: Vector3i, vx: int, vy: int) -> void:
	var fifth_x: int = IncInt.div_trunc(vx, 5)
	var fifth_y: int = IncInt.div_trunc(vy, 5)
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 3, 0, 0, 0x21, 8,
		-fifth_y, fifth_x, 0, 5, 1)
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 3, 0, 0, 0x21, 8,
		fifth_y, -fifth_x, 0, 5, 1)


## `0x0042A410` -- one hit flash over a fast sparking rain. The rain is
## [method _sparking_rain] with a count of 1 and a speed of 1, both literals;
## the flash is an `A_HIT1.3DI` of kind 16 and life 4 carrying the caller's
## delay.
static func hitting_blobs(pool: Pool, draws: Draws, at: Vector3i,
		delay: int) -> void:
	_sparking_rain(pool, draws, at, 1, 1)
	pool.spawn("A_HIT1.3DI", 0, at.x, at.y, at.z, 0, 0, 0, 0x10, 4,
		0, 0, 0, 0, delay)


## `0x0042A480` -- the same flash with `A_EXPL04.3DI` and without the rain.
## No draw.
static func hitting_blobs_2(pool: Pool, at: Vector3i, delay: int) -> void:
	pool.spawn("A_EXPL04.3DI", 0, at.x, at.y, at.z, 0, 0, 0, 0x10, 4,
		0, 0, 0, 0, delay)


## `0x0042A7A0` -- **a hundred** `A_LINE2.3DI` streaks. The body is
## [method sparks]' at a different scale: each streak aims at a point
## scattered around the origin, takes its rotation from `0x00403AA0` and its
## velocity from `0x0046D400` scaled by a flat 1600, and lives
## `aRandom2(4, 15)` ticks. The scatter is the wide one, and the aim
## truncates each draw and **then** adds the coordinate -- the plain `add` at
## `0x0042A7DA`, not kind 56's `fiadd`.
static func hitting_blobs_3(pool: Pool, draws: Draws, at: Vector3i, delay: int,
		inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	for _i: int in range(0x64):
		var aim: Vector3i = Vector3i(at.x + draws.draw(-0x3200, 0x6400),
			at.y + draws.draw(-0x3200, 0x6400),
			at.z + draws.draw(-0xC80, 0x6400))
		var d: PackedFloat64Array = Eng3dGeometry.direction(at, aim, 1)
		var turn: Vector2i = inputs.geometry.orient(at, aim)
		pool.spawn("A_LINE2.3DI", 0, at.x, at.y, at.z, turn.x, 0, turn.y,
			0x13, draws.draw(4, 0xF),
			Eng3dGeometry.ftol(d[0] * SPARK_SPEED),
			Eng3dGeometry.ftol(d[1] * SPARK_SPEED),
			Eng3dGeometry.ftol(d[2] * SPARK_SPEED), 0, delay)


## `0x0042A9D0` -- `aBlob_CreateSparks`: one emitter, then fifty sparks along
## a ray. It is both a weapon creator (docs/97 section 22, measured through a
## weapon switch) and an arm's, and it takes a **position** rather than a tile,
## so it reads nothing before it draws.
static func sparks(pool: Pool, draws: Draws, at: Vector3i, delay: int,
		inputs: Inputs) -> void:
	if inputs.geometry == null:
		return
	pool.spawn(SCRATCH, 2, at.x, at.y, at.z, 5, 0, 0, 0x33, 0x10, 0, 0, 0,
		0x28, delay)
	for _i: int in range(0x32):
		var aim: Vector3i = Vector3i(at.x + draws.draw(-0x3200, 0x6400),
			at.y + draws.draw(-0x3200, 0x6400),
			at.z + draws.draw(-0xC80, 0x2580))
		var d: PackedFloat64Array = Eng3dGeometry.direction(at, aim, 1)
		var turn: Vector2i = inputs.geometry.orient(at, aim)
		pool.spawn("A_SPARK.3DI", 0, at.x, at.y, at.z, turn.x, 0, turn.y,
			0x22, draws.draw(4, 0xF),
			Eng3dGeometry.ftol(d[0] * SPARK_SPEED),
			Eng3dGeometry.ftol(d[1] * SPARK_SPEED),
			Eng3dGeometry.ftol(d[2] * SPARK_SPEED), 0, delay)


## `0x0042B150` -- **the arm's** para bomb, and not [method para_bomb]'s: no
## object lookup, no ceiling and no *arrived* flag. One `A_PARAB1.3DI` of
## kind 25 and life 200 at the point given, falling 800 a tick with 500 of
## sideways drift and a rotation drawn 0..4095. Three draws: y, x, spin.
static func arm_para_bomb(pool: Pool, draws: Draws, at: Vector3i) -> void:
	var vy: int = draws.draw(-500, 1000)
	var vx: int = draws.draw(-500, 1000)
	var spin: int = draws.draw(0, 0x1000)
	pool.spawn("A_PARAB1.3DI", 0, at.x, at.y, at.z, 0x100, 0, spin, 0x19, 0xC8,
		vx, vy, -BOMB_FALL, 0, 0)


## `0x0042B300` -- twenty tumbling `A_DEBRIS.3DI` of kind 39 and life 50. Each
## takes four draws: two sideways at 600, one upward 40..1440 and one delay
## 0..5 -- and its **rotation is its velocity**, the same three registers
## pushed twice.
static func barrel_debris(pool: Pool, draws: Draws, at: Vector3i) -> void:
	for _i: int in range(0x14):
		var vx: int = draws.draw(-600, 1200)
		var vy: int = draws.draw(-600, 1200)
		var vz: int = draws.draw(40, 1400)
		var delay: int = draws.draw(0, 6)
		pool.spawn("A_DEBRIS.3DI", 0, at.x, at.y, at.z, vx, vy, vz, 0x27, 0x32,
			vx, vy, vz, 0, delay)
