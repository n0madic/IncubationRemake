class_name BlobTriggers
extends RefCounted

## What a shot looks like: the three switches of docs/28 section 8.1.
##
## `aPlayFightAnimation` contains three switches on the attacker's weapon id --
## the muzzle blob (ids 2..47), the impact blob (7..46) and the impact sound
## (0..44) -- and **nothing else decides what a shot looks like**. All three
## were read out of the compiler's own index and jump tables by
## `tools/blob_tables.py` and copied into `tables/blobs.json`, so this class
## looks the answer up rather than inventing one.
##
## **What is transcribed here, what is measured, and what is still ours.** The
## tables give, for every constructor call the arms reach: its class, its update
## kind, its literal lifetime, its model and -- for a sprite -- its atlas row,
## column and size. Those are verified-static, pinned by 116 checks.
##
## The creators' own argument arithmetic is transcribed nowhere, and used to be
## invented here outright. It is now **measured**: `tools/blob_gold.py` calls
## each creator inside a running `Incubation.exe` and reads the pool back, and
## `tests/test_blob_native.gd` replays that. Three things it settles:
##
## * the origin is the shooter's tile in world units, which is exactly what
##   [method muzzle_point] answers -- an assumption before, a measurement now;
## * every blob a creator makes lies **on the line from the shooter's tile to
##   the target's**, at the tile itself or a fraction of the way along it. One
##   creator lays eight of them evenly down that line, which is a tracer;
## * the elevation is a constant the creator carries, not the ground: over
##   tiles at height zero the captured `z` runs 0 to 3 679, and
##   [constant MUZZLE_HEIGHT] sits inside that.
##
## What is **still ours** is the per-blob speed: the velocities are drawn from
## `aRandom` inside the creator, so replaying one exactly would need the
## engine's generator state at the moment of the shot. [method _velocity] paces
## a blob by its own recorded lifetime instead, which is extracted data rather
## than a chosen constant, and that is said where it is done.
##
## Twenty-five of the 116 calls compute their lifetime and eighteen compute a
## sprite parameter; a `null` in the document is honoured as "the arm supplies
## it" and given the fallback below rather than being read as zero -- a zero
## lifetime aborts the constructor, so misreading it would silently drop the
## effect.

## Where a computed lifetime lands when the creator would have supplied it.
## Chosen inside the shipped literal range (4 to 255) and near its middle.
const DEFAULT_LIFE: int = 16
## The same, for a computed sprite half-size; the ten shipped values are 3..40.
const DEFAULT_SIZE: int = 10
const DEFAULT_ROW: int = 0
const DEFAULT_COLUMN: int = 0
## World units a muzzle effect travels per tick, for the blobs that have no
## lifetime to pace them. One map field is 3200 units and a tracer should cross
## a field in about four ticks.
const MUZZLE_SPEED: int = 800
## docs/28 section 7.2's kind 11 -- the ejected cartridge case. It is the one
## blob in a muzzle call that does **not** fly at what was shot at, and
## [method _casing_velocity] is why it has an arm of its own here.
const CASING_KIND: int = 11
## `0x004B1288` and `0x004B1290`, the two doubles `aBlob_CreateTracerBullet`
## `0x004247C0` multiplies the direction service's answer by: the case leaves
## **perpendicular** to the line of fire at 128 units a tick, `x` taking the
## line's `y` ratio and `y` its negated `x`.
const CASING_SPEED: int = 128
## `push 0xA0 / push 0` then `add eax, 0x140` at `0x00424BDD`: the case's rise
## is `aRandom2(0, 160) + 320` and is the only drawn component it has.
const CASING_RISE_SPAN: int = 0xA0
const CASING_RISE_BASE: int = 0x140
## `aBlob_CreateTracerBullet` `0x004247C0`, the default muzzle creator and the
## one fourteen weapons select. Its own arithmetic is transcribed --
## `inclib/blob_creators.py` `_c004247C0` -- and the two shapes the table
## alone cannot carry are the burst delta and where the casing is thrown from.
const TRACER_CREATOR: String = "0x004247C0"
## `0x004B1280`: the delta is a draw **minus** the direction scaled by this,
## so a round leaves along the line of fire with a little scatter. The draws
## are `aRandom2(-160, 320)` on the ground plane and `aRandom2(-80, 160)`
## vertically.
const TRACER_STEP: int = -2240
## The same 2240 again, as the spacing the tracer's life is counted in:
## `max(|dx|, |dy|) / 2240 - 1`, recovered from the reciprocal multiply at
## `0x00424A9A`. A shot inside one spacing gets a life of zero, and the
## constructor drops a record with no life -- so a point-blank shot makes no
## streak at all, which is the original's own answer.
const TRACER_UNIT: int = 2240
const TRACER_SCATTER_BASE: int = -160
const TRACER_SCATTER_SPAN: int = 320
const TRACER_RISE_BASE: int = -80
const TRACER_RISE_SPAN: int = 160
## `aBlob_CreateNeedles` `0x00424250` and `aBlob_CreateFlash` `0x00423D80`,
## the other two seven-argument creators (docs/28 section 8.1.1). Both are
## transcribed -- `inclib/blob_creators.py` -- and both have the tracer's
## shape with their own numbers: the step their delta leans by is the same
## number as the spacing their length is counted in (2400 at `0x004B1278` and
## the divide at `0x00424540`; 1600 at `0x004B1270` and `0x00424058`), and
## their scatter is half the tracer's.
const NEEDLE_CREATOR: String = "0x00424250"
const FLASH_CREATOR: String = "0x00423D80"
const NEEDLE_STEP: int = -2400
const NEEDLE_UNIT: int = 2400
const FLASH_STEP: int = -1600
const FLASH_UNIT: int = 1600
## Both draw half the tracer's spread: `aRandom2(-80, 160)` on the ground
## plane and `aRandom2(-40, 80)` vertically, against the tracer's own
## `-160/320` and `-80/160`.
const BURST_SCATTER_BASE: int = -80
const BURST_SCATTER_SPAN: int = 160
const BURST_RISE_BASE: int = -40
const BURST_RISE_SPAN: int = 80
## `[step, unit, scatter base, scatter span, rise base, rise span]` per burst
## creator. A creator not named here is not a burst creator and makes its
## records once, where the table puts them.
const SHAPE_STEP: int = 0
const SHAPE_UNIT: int = 1
const SHAPE_SCATTER_BASE: int = 2
const SHAPE_SCATTER_SPAN: int = 3
const SHAPE_RISE_BASE: int = 4
const SHAPE_RISE_SPAN: int = 5
const BURST_SHAPES: Dictionary[String, Array] = {
	TRACER_CREATOR: [TRACER_STEP, TRACER_UNIT,
		TRACER_SCATTER_BASE, TRACER_SCATTER_SPAN,
		TRACER_RISE_BASE, TRACER_RISE_SPAN],
	NEEDLE_CREATOR: [NEEDLE_STEP, NEEDLE_UNIT,
		BURST_SCATTER_BASE, BURST_SCATTER_SPAN,
		BURST_RISE_BASE, BURST_RISE_SPAN],
	FLASH_CREATOR: [FLASH_STEP, FLASH_UNIT,
		BURST_SCATTER_BASE, BURST_SCATTER_SPAN,
		BURST_RISE_BASE, BURST_RISE_SPAN],
}
## The needles: one round is nine sprites laid down eighths of its delta, the
## **last** of them kind 73 where the other eight are 74, and their size runs
## `NEEDLE_AUX_BASE - k` for `k` counting 8 down to 0.
const NEEDLE_SPLIT: int = 8
const NEEDLE_KIND: int = 0x4A
const NEEDLE_KIND_LAST: int = 0x49
const NEEDLE_AUX_BASE: int = 10
## `push 7 / push 0` at `0x0042411D`: the flash's atlas column is the one
## drawn sprite parameter among the three, and the only null column a burst
## creator's call carries.
const FLASH_COLUMN_SPAN: int = 7
## `aBlob_CreateSporeCannon` `0x004268B0` -- the Cy'Coo's spore round, and the
## one muzzle creator that is neither a burst nor a record the constructor
## table can place on its own.
##
## It is transcribed here because **every number in its record is computed**
## and the document carries none of them -- the call at `0x00426B52` is the
## only one in the image whose `life` is `null` outside a burst creator:
##
## * `life = max(|dx|, |dy|) / 800 - 2`. The divisor is not in the bytes: the
##   compiler left the reciprocal multiply `0x51EB851F` with `sar edx, 8` at
##   `0x00426A73`, which is a divide by 800, and the `lea ebp, [edx + eax - 2]`
##   at `0x00426A8E` takes the two off. The two ends are the source and target
##   **objects'** positions, so the span is measured in world units.
## * `v = ftol(direction * 800.0)` per axis, the double at `0x004B12C8`. The
##   direction service divides by `max(|dx|, |dy|)` (docs/28 section 7.4), so
##   the wide axis moves a whole step a tick and the round arrives as its life
##   runs out. The record itself sits at the source **plus one step**.
## * `vz` carries a launch loft of `0x50 * (life / 2)` on top --
##   `0x00426B0C`..`0x00426B29`, written as a negated `5 * (life/2) << 4` whose
##   sign is then thrown away. Kind 22's arm takes `0x50` off `vz` every tick
##   (`blob_kinds.gd`), so the boost is exactly half the fall and the round
##   follows an arc that comes back down on the target. Without it the round
##   flew a flat line that sagged, which is what the original visibly does not
##   do.
## * `[0x004FE63C] = (life <= 0) ? 1 : 0` at `0x00426A97`, the same write the
##   three burst creators make and the reason a point-blank spore shot waits
##   for nothing.
##
## What it does **not** do is use `0x00403AA0`: the orientation call at
## `0x00426AF9` fills two locals nothing afterwards reads, so its answer is
## dead and the record's rotation is the sprite table's row and column. It
## draws from no generator either, so a spore shot leaves `aRandom2`'s seed
## where it found it.
## **The one weapon creator this class does not build from the constructor
## table.** `aBlob_CreateShockWave` `0x00422B80` places sixty records in a
## ring where its single pinned constructor call describes one, so a shot
## from weapon 17 and a hit from weapon 36 showed one static blob where the
## original throws an explosion outward (docs/28 section 7.2). It is a
## transcribed creator instead -- [method BlobPrograms.shock_wave], the twin
## of `inclib/blob_creators.py` -- and it is asked for by tile, because the
## engine reads the tile's **placed object** rather than the muzzle point.
##
## Neither weapon waits on the flight ([constant
## ShotSequence.WAIT_SKIPPED_WEAPONS] holds 0x11 and 0x24), so the records
## going into the pool through [BlobPrograms] rather than through
## [method _place] costs [method in_flight] nothing.
const SHOCK_WAVE_CREATOR: String = "0x00422B80"
## The type both call sites push (`0x0040CD3C` and `0x0040D7AC`,
## `blob_tables.SHOCKWAVE_TYPE_SITES`): of the creator's three arms only this
## one is ever taken.
const SHOCK_WAVE_TYPE: int = 2
## A [method muzzle] or [method impact] whose caller has no tile to give.
const NO_TILE: Vector2i = Vector2i(-1, -1)
## A caller that does not separate the **placed object's** own position from
## the standing unit's height. The two are one argument for every creator
## built off the constructor table and two for a transcribed one, which reads
## them differently (docs/97 section 14.5), so a caller that has only the sum
## passes this and the sum stands in for both.
const NO_POINT: Vector3i = Vector3i(-0x40000000, -0x40000000, -0x40000000)

## **The part a creator resolves for itself**, where the switch's own call
## site pushes none.
##
## `0x0042C660` writes the world position of a named part of the shooter's
## Charisma model over the three source coordinates when the shooter's
## `+0x56` is set (docs/42 section 6's "already animating" byte). The three
## seven-argument burst creators take that name as an **argument**, which is
## what `weapon_muzzle_joint` carries; the other ten push it themselves, so
## the document is empty for them and the effect used to leave the body axis
## instead of the barrel. Every one of the ten pushes `"M"` (`0x004C10D8`) --
## read out of the shipped executable by `blob_tables.creator_joints`, which
## finds all thirteen `call 0x0042C660` sites and the string each one built
## in front of it.
const CREATOR_JOINT_M: String = "M"
const CREATOR_JOINTS: Dictionary[String, String] = {
	"0x00424D20": CREATOR_JOINT_M, "0x00425400": CREATOR_JOINT_M,
	"0x00425810": CREATOR_JOINT_M, "0x00425CA0": CREATOR_JOINT_M,
	"0x004264A0": CREATOR_JOINT_M, "0x00426B70": CREATOR_JOINT_M,
	"0x00426F90": CREATOR_JOINT_M, "0x00427C80": CREATOR_JOINT_M,
	"0x00428200": CREATOR_JOINT_M, "0x00428570": CREATOR_JOINT_M,
}

## **The weapon switches' creators that are transcribed**, and how this class
## builds each one's argument vector (docs/97 section 14.5).
##
## Everything not named here still goes down the constructor-table arm below
## -- one record per `call`, with a trajectory of the remake's own -- which is
## what the whole of this switch used to do. An entry is added only once its
## program is checked against `blob_gold.py`'s capture by
## `test_blob_native.gd`, so the table is also the list of what is measured.
##
## `[shape, arrived, tail...]`: *shape* says where the argument tiles come
## from, *arrived* is what the creator writes over `0x004FE63C` (or
## [constant ARRIVED_UNWRITTEN] for the ones that leave it alone), and the
## tail is the literals the switch's own arm pushes after them.
## **A tail entry the multi-target walk fills in**, rather than a literal the
## arm pushes: [constant MULTI_TAIL_INDEX] is the running count of cells the
## walk has matched so far and [constant MULTI_TAIL_INDEX_THIRD] that count
## over three, which is what weapon 9's `imul 0x55555556` at `0x0040CF98`
## computes. Both are zero on a shot with no cell list, which is the single
## call this class used to make.
const MULTI_TAIL_INDEX: int = -101
const MULTI_TAIL_INDEX_THIRD: int = -102
## **The five arms that call their creator more than once.** `blob_tables`'
## `MULTI_TARGET_ARMS` decodes them out of the shipped executable and the
## cache carries the result as `weapon_multi_target`; this is the reader.
##
## Four of the five walk the whole control map and fire once per cell whose
## state byte is in the arm's band -- the band `aBuildTargetPattern` marks and
## the resolver rewrites, `0x5A` miss, `0x5B` resolved, `0x5C` hit, `0x5D`
## killed (docs/22 sections 7.2 and 7.3) -- so the *Multi-target Destroyer*
## really does throw one grenade per target it caught, on a different arc
## each. The fifth, weapon 44, loops a literal five times at the one aim
## point.
##
## `[low, high, unit test, repeats]`; `repeats` is
## [constant MULTI_PER_CELL] for a walk.
const MULTI_PER_CELL: int = -1
const MULTI_LOW: int = 0
const MULTI_HIGH: int = 1
const MULTI_UNIT: int = 2
const MULTI_REPEATS: int = 3
## A cell of [method muzzle]'s `pattern`: where it is, what it resolved to and
## whether a unit is still standing on it. The caller builds these because it
## is the only side that can turn a tile into a point.
const PATTERN_TILE: String = "tile"
const PATTERN_POINT: String = "point"
const PATTERN_OBJECT: String = "object"
const PATTERN_UNIT: String = "unit"
const PATTERN_MARKER: String = "marker"
## What [constant PATTERN_UNIT] holds for a cell nobody is standing on -- the
## engine's own `0xFFFF`, which is what `aWriteUnitIdInfoCtrlMap` writes back
## over every cell a killed unit occupied, before the animation runs.
const PATTERN_NO_UNIT: int = 0xFFFF
## The two switch names [method _fire] is called with, so the impact end can
## move its **own** cell as well as its target cell -- its arms run on the one
## tile and push it twice.
const MUZZLE_SWITCH: String = "weapon_muzzle"
const IMPACT_SWITCH: String = "weapon_impact"

const ARG_LINE: int = 0
## The switch's own cell -- the **source** for a muzzle and the **target**
## for an impact, which is what each arm pushes.
const ARG_TILE: int = 1
## The point the switch aimed at, for the one creator that takes a position.
const ARG_POINT: int = 2
const WEAPON_PROGRAMS: Dictionary[String, Array] = {
	BlobPrograms.SMOKE_TRAIL: [ARG_LINE, 1, 0, 0],
	BlobPrograms.MACHINE_GUN: [ARG_LINE, ARRIVED_UNWRITTEN],
	# `0x004264A0` is one of the three weapon projectiles that clear the flag.
	BlobPrograms.BLIZZARD_SHOT: [ARG_LINE, 0, MULTI_TAIL_INDEX_THIRD],
	BlobPrograms.LASER_GREEN: [ARG_LINE, ARRIVED_UNWRITTEN],
	BlobPrograms.BLUE_LASER: [ARG_LINE, ARRIVED_UNWRITTEN],
	BlobPrograms.PLASMA_BEAM: [ARG_LINE, ARRIVED_UNWRITTEN],
	# The impact arms. `0x0040D643` pushes 150 streaks for weapon 13 and
	# `0x0040D736` a zero delay for the sparks -- read back out of the
	# shipped executable by `blob_tables.weapon_call_args`.
	BlobPrograms.LINE_FIRE: [ARG_TILE, ARRIVED_UNWRITTEN, 150, 0],
	BlobPrograms.BLIZZARD_HIT: [ARG_TILE, ARRIVED_UNWRITTEN],
	BlobPrograms.LANDING_DUST: [ARG_TILE, ARRIVED_UNWRITTEN],
	BlobPrograms.FIRE_EXPLOSION: [ARG_TILE, ARRIVED_UNWRITTEN, 0],
	BlobPrograms.SPARKS: [ARG_POINT, ARRIVED_UNWRITTEN, 0],
	BlobPrograms.STINGER_RING: [ARG_TILE, ARRIVED_UNWRITTEN],
	BlobPrograms.SPARKING_PLUG: [ARG_TILE, ARRIVED_UNWRITTEN],
	BlobPrograms.PLASMA_BALL_IMPACT: [ARG_TILE, ARRIVED_UNWRITTEN],
	BlobPrograms.EXPLOSION2: [ARG_TILE, ARRIVED_UNWRITTEN],
	BlobPrograms.SPIDY_MINES: [ARG_LINE, ARRIVED_UNWRITTEN],
	# -- 2026-09-12, read out of the instructions rather than replayed ------
	#
	# Seven more, and the tails are the arms' own -- see
	# `blob_gold.SWITCH_ARGS`. Two registers the muzzle dispatcher sets carry
	# into every arm (`0x0040CC3C` is `xor edi, edi` and `0x0040CC41`
	# `mov ebx, 1`), so an arm pushing a bare `ebx` pushes **1** and one
	# pushing `edi` pushes 0; neither was ever a tile number.
	#
	# Five of the seven are **measured by nothing**: their phase in the
	# capture is a fall-through arm's and Wine has not landed the re-take, so
	# what stands behind them is the shape check in `blob_tables.py`, which
	# reads each record's class, kind, lifetime, model and sprite parameters
	# back off the creator's own constructor call sites. The fire wheel and
	# the mine plume are the two exceptions and are diffed against the engine.
	BlobPrograms.FIRE_WHEEL: [ARG_TILE, ARRIVED_UNWRITTEN, 0],
	BlobPrograms.MINE_PLUME: [ARG_TILE, ARRIVED_UNWRITTEN, 0],
	BlobPrograms.SPRAY: [ARG_LINE, ARRIVED_FROM_FLIGHT, 1, 0],
	BlobPrograms.GRENADE_ROUND: [ARG_LINE, ARRIVED_FROM_FLIGHT, 1],
	BlobPrograms.BEAM_DOTS: [ARG_LINE, ARRIVED_FROM_FLIGHT, 1],
	BlobPrograms.LASER_DOTS: [ARG_LINE, ARRIVED_FROM_FLIGHT, 1],
}
## The second entry whose tail **differs per weapon**, and the more consequential
## of the two: `0x00426070`'s sixth argument picks the arc.
##
## Weapon 44's arm `0x0040D0FD` pushes the literal 0xFF -- the proximity round,
## which draws its own scatter and wears kind 27 -- and loops five times at the
## one aim point. Weapon 11's `0x0040D077` pushes the **running count of cells
## its walk has matched**, which the creator reads as the arc, so the
## *Multi-target Destroyer*'s simultaneous grenades fly different lines. Both
## shapes go through [method multi_target]; the tail entry that carries the
## count is [constant MULTI_TAIL_INDEX].
## The third entry whose tail differs per weapon: `0x00427C80`'s fifth argument
## is its ring count *and* the switch between a straight stream and a sweeping
## one. Weapon 7's arm `0x0040D00E` pushes four, weapon 40's `0x0040D041` ten.
const FLAME_STREAM_TYPED: String = BlobPrograms.FLAME_STREAM
const FLAME_STREAM_TYPES: Dictionary[int, int] = {7: 4, 40: 0xA}
const GRENADE_ARC_TYPED: String = BlobPrograms.GRENADE_ARC
const GRENADE_ARC_TYPES: Dictionary[int, int] = {11: MULTI_TAIL_INDEX,
	44: 0xFF}
## The one entry whose **type argument differs per weapon**, which is why it
## is not a row in the table above.
##
## It was also the one nothing measured, until `blob_gold.SWITCH_ARGS` was
## given the literal its arms push and the phase re-taken: the capture had
## handed the creator a tile coordinate where the switch pushes a type, so
## the engine took the cascade's fall-through and left nothing. With the
## argument corrected it lays **twenty-seven** records where the constructor
## arm here used to make one, and all twenty-seven agree field for field
## (`test_blob_native.WEAPON_PROGRAMS`).
const SPORE_EXPLOSION_TYPED: String = BlobPrograms.SPORE_EXPLOSION
const SPORE_EXPLOSION_TYPES: Dictionary[int, int] = {23: 1, 25: 1, 26: 0}
## Where `[shape, arrived]` sit in one of those rows.
const PROGRAM_SHAPE: int = 0
const PROGRAM_ARRIVED: int = 1
const PROGRAM_TAIL: int = 2

const SPORE_CREATOR: String = "0x004268B0"
## The spore step in world units -- a quarter of a map field -- as the
## **divisor** the round's life is counted in.
const SPORE_UNIT: int = 800
## The same 800 again as the **speed**, and from a different place: the double
## at `0x004B12C8` the three direction ratios are multiplied by.
const SPORE_SPEED: int = 800
## `lea ebp, [edx + eax - 2]` -- the round is two steps shorter than the span.
const SPORE_LIFE_BIAS: int = 2
## `0x50` a tick up at launch against kind 22's `0x50` a tick down in flight.
const SPORE_LOFT: int = 0x50
## **Point-blank is a different branch, not an empty one.** A span inside one
## spacing writes the length back to zero -- so every record the round loop
## builds is dropped by the constructor for a zero life, which is the
## original -- and the two creators below then make something else *at the
## target* instead: `0x0042418B` runs one zoom bob per round for the flash,
## jittered on all three axes, and `0x00424739` runs one bob plus
## `0x00428F70`'s twenty plasma sparks for the needles. The tracer has no such
## branch: its casing carries a literal life and appears anyway.
##
## Both are nested creators the pool cannot build from the constructor table,
## so they are handed back as requests -- see [method take_programs].
const POINT_BLANK_BOB_LIFE: int = 8
const POINT_BLANK_AUX_BASE: int = 5
const POINT_BLANK_AUX_SPAN: int = 0xF
const FLASH_BOB_ROW: int = 6
const FLASH_BOB_JITTER_BASE: int = -1600
const FLASH_BOB_JITTER_SPAN: int = 3200
const NEEDLE_BOB_ROW: int = 1
const NEEDLE_SPARKS: int = 0x14
## `0x00428F70`'s fifth argument, which it is handed and does not read.
const NEEDLE_SPARKS_UNREAD: int = 0x1E
## The tracer's own nested creator, and the one it makes on **every** round
## rather than only point-blank: `0x00424CB0` calls `0x00423720` a fifth of
## the round's delta along, row 0, size 10, life 8. Its constructor call
## belongs to the zoom bob's own address, so the muzzle table cannot carry it
## and it is asked for the same way the point-blank branches are.
const TRACER_BOB_SPLIT: int = 5
const TRACER_BOB_ROW: int = 0
const TRACER_BOB_AUX: int = 10
const TRACER_BOB_LIFE: int = 8
## `life = 0xFF` never expires (docs/28 section 7.2).
const IMMORTAL_LIFE: int = 0xFF
## How far above the cell floor an effect starts where **nothing is standing
## there** -- an impact on bare ground. Where a unit is, its own type height
## is used instead, which is what every creator reads (see
## [method SliceMain._muzzle_of]).
const MUZZLE_HEIGHT: int = 1000

## No burst creator ran, so nothing wrote the flag.
const ARRIVED_UNWRITTEN: int = -1
## The row value for a creator that writes the flag from **its own flight
## length** rather than as a literal: `setle` over the length it just
## computed, so 0 while there is a round to wait for and 1 at point-blank
## range. Four of the seven creators added on 2026-09-12 do that
## (`0x00425400`, `0x00425CA0`, `0x00428200` and, over two branches,
## `0x00428570`); `0x00426070` writes a literal zero instead.
##
## It is the program that knows, so this is filled in **after** the program
## runs, out of [member BlobPrograms.Pool.clears_arrived].
const ARRIVED_FROM_FLIGHT: int = -2

var _pool: BlobPool = null
var _document: Dictionary = {}
## Nested creators a point-blank burst asked for, in the order it asked.
var _programs: Array[Dictionary] = []
## What the last burst creator wrote over the *arrived* flag, or
## [constant ARRIVED_UNWRITTEN] when none ran -- see [method arrived_write].
var _arrived_write: int = ARRIVED_UNWRITTEN
## `creator address -> the constructor calls inside it`, built once.
var _by_creator: Dictionary[String, Array] = {}
## The records the last [method muzzle] put in the pool -- see
## [method in_flight]. Held by **reference** and not by slot, because a slot
## falls free the moment its record dies and the next spawn takes it.
var _made: Array[Blob] = []
## Whether [method _place] is filling [member _made]. Only a muzzle does; an
## impact is not a thing anybody waits for.
var _recording: bool = false


static func open(pool: BlobPool, document: Dictionary) -> BlobTriggers:
	var triggers: BlobTriggers = BlobTriggers.new()
	triggers._pool = pool
	triggers._document = document
	var calls: Dictionary = DictRead.as_dict(document.get("calls", {}))
	for site: Variant in calls:
		var call: Dictionary = DictRead.as_dict(calls[site])
		var creator: Variant = call.get("creator")
		if creator == null:
			continue
		var key: String = DictRead.as_string(creator)
		if not triggers._by_creator.has(key):
			triggers._by_creator[key] = []
		var record: Dictionary = call.duplicate()
		record["site"] = DictRead.as_string(site)
		triggers._by_creator[key].append(record)
	# Sorted by site so a creator's calls are made in the order the original
	# makes them, which is the order they draw in.
	for key: String in _keys_of(triggers._by_creator):
		var list: Array = triggers._by_creator[key]
		list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return DictRead.as_string(a["site"]) < DictRead.as_string(b["site"]))
	return triggers


static func _keys_of(from: Dictionary[String, Array]) -> Array[String]:
	var out: Array[String] = []
	for key: String in from:
		out.append(key)
	return out


## The muzzle effects weapon `weapon_id` makes, at `from`, aimed at `to`.
## Answers how many blobs the pool accepted.
##
## `joints` maps a Charisma part name to where that part is now. A creator
## whose call site names a part it holds leaves from **there** instead of
## from `from`, which is `0x0042C660` writing the part's world position over
## the three source coordinates (docs/28 section 8.1.1). An empty map is the
## body-axis fallback the engine takes for a shooter that is not animating.
func muzzle(weapon_id: int, from: Vector3i, to: Vector3i,
		joints: Dictionary[String, Vector3i] = {},
		tile: Vector2i = NO_TILE, target_tile: Vector2i = NO_TILE,
		from_object: Vector3i = NO_POINT,
		to_object: Vector3i = NO_POINT, target_unit: int = 0,
		pattern: Array[Dictionary] = []) -> int:
	_programs.clear()
	_arrived_write = ARRIVED_UNWRITTEN
	_made.clear()
	_recording = true
	var made: int = _fire(MUZZLE_SWITCH, weapon_id, from, to, joints, tile,
		target_tile, from_object, to_object, target_unit, pattern)
	_recording = false
	return made


## What the last [method muzzle] wrote over the *arrived* flag `0x004FE63C`.
##
## 1 when nothing is in flight and 0 when a round has just left, or
## [constant ARRIVED_UNWRITTEN] when no creator wrote it at all. **A burst
## creator writes it whether or not it then makes anything**: the three of
## them open with `cmp steps, 0 / jle`, and the point-blank arm writes the
## **1** before it runs the branch that lays its zoom bobs
## (`0x0042420D` for the flash, `0x0042456A` for the needles, `0x00424AC3`
## for the tracer, against the flight's zero at `0x0042407B`, `0x0042455E`
## and `0x00424AB9`). Twelve creators carry that shape (docs/42 section 4.6,
## `presentation_tables.py`'s `arrived.creator_writes` counts them), which is
## what makes an adjacent target arrive at once even though the burst still
## fills the pool.
func arrived_write() -> int:
	return _arrived_write


## The nested creators the last [method muzzle] asked for, and clears them.
##
## `{creator, at, extra}` per request, ready for [BlobPrograms] -- or
## `{creator, tile, extra}` where the creator reads a cell rather than a
## point ([constant SHOCK_WAVE_CREATOR]). A point-blank burst makes the
## first kind (see [constant POINT_BLANK_BOB_LIFE]); [method impact] can make
## the second.
func take_programs() -> Array[Dictionary]:
	var out: Array[Dictionary] = _programs
	_programs = []
	return out


## The impact effects, at the target and going nowhere.
##
## `tile` is the target's, for [constant SHOCK_WAVE_CREATOR] -- the impact
## switch's arms run on the target cell (`0x0040D7AC` pushes the same pair
## `aGetCtrlMapElementPtr` was given). It clears the request list for the
## same reason [method muzzle] does: whatever it asks for is its own.
func impact(weapon_id: int, at: Vector3i, tile: Vector2i = NO_TILE,
		at_object: Vector3i = NO_POINT, target_unit: int = 0,
		pattern: Array[Dictionary] = []) -> int:
	_recording = false
	_programs.clear()
	return _fire(IMPACT_SWITCH, weapon_id, at, at, {}, tile, tile,
		at_object, at_object, target_unit, pattern)


## Whether any record the last [method muzzle] made is still in the pool.
##
## **The other half of what ends the shot's flight stage**, beside the
## *arrived* flag -- the whole reasoning is at
## [constant ShotSequence.WAIT_FRAMES]. Fourteen update arms raise the flag
## and the spore cannon's kind 22 is not one of them, so a weapon whose round
## never signals would otherwise spend the bound in full.
func in_flight() -> bool:
	for blob: Blob in _made:
		if blob != null and blob.alive:
			return true
	return false


## Which of the three impact waves this weapon selects, or `""` for the
## twenty-eight ids that make no sound at all -- which is a real answer.
func impact_wave(weapon_id: int) -> String:
	var switch: Dictionary = DictRead.as_dict(
		_document.get("weapon_impact_sound", {}))
	var entry: Variant = switch.get(str(weapon_id))
	return "" if entry == null else DictRead.as_string(entry)


## The creators a switch names for this weapon, by address.
##
## **A weapon the jump table does not cover is not a weapon with no effect.**
## The muzzle switch's table starts at id 2 (`add eax, -2 / cmp eax, 0x2D /
## ja`), so weapons 0 and 1 -- the Light and Advanced Combat Guns the campaign
## starts with -- fall to its default arm, and that arm calls
## `aBlob_CreateTracerBullet` just as weapon 2's does. Reading only the table
## left both starting guns firing invisibly.
func creators(switch_name: String, weapon_id: int) -> Array:
	var switch: Dictionary = DictRead.as_dict(_document.get(switch_name, {}))
	if switch.has(str(weapon_id)):
		return DictRead.as_array(switch[str(weapon_id)])
	return DictRead.as_array(_document.get(switch_name + "_default", []))


## `[rounds, stagger]` per creator above, in the same order.
##
## **A shot is a burst.** Three of the muzzle creators take seven arguments,
## and the fifth and sixth are a round count and the frames between one round
## and the next: each loops the count and stamps `(index * step) & 0xFF` into
## the record's `delay`, so the original's ordinary rifle shot is ten rounds
## leaving one frame apart rather than the single tracer this class used to
## make. Neither the jump table nor the constructor table carries it -- it is
## pushed at the **call site** -- so `tools/blob_tables.py` pins it per site
## (`MUZZLE_BURSTS`) and the document carries it beside the creator list.
##
## A creator of any other arity, and the whole impact end, answers `[1, 0]`:
## one pass, no delay, which is what those make.
func bursts(switch_name: String, weapon_id: int) -> Array:
	var switch: Dictionary = DictRead.as_dict(
		_document.get(switch_name + "_burst", {}))
	if switch.has(str(weapon_id)):
		return DictRead.as_array(switch[str(weapon_id)])
	return DictRead.as_array(_document.get(switch_name + "_default_burst", []))


## One cell of a shot's pattern as `aPlayFightAnimation` sees it.
##
## `unit_byte` is the cell's occupant in the pre-removal CtrlMap. A `0x5D`
## marker does not clear it yet: both attack resolvers call the fight animation
## first and only then sweep killed cells through `aRemoveUnitElement`. The
## lagging picture therefore carries exactly the occupant these arms read.
static func pattern_cell(tile: Vector2i, point: Vector3i, object: Vector3i,
		marker: int, unit_byte: int) -> Dictionary:
	return {
		PATTERN_TILE: tile,
		PATTERN_POINT: point,
		PATTERN_OBJECT: object,
		PATTERN_UNIT: unit_byte & 0xFF,
		PATTERN_MARKER: marker,
	}


## The repeat shape of one weapon's arm, or `[]` for the forty-three that
## call their creator once -- see [constant MULTI_PER_CELL].
func multi_target(switch_name: String, weapon_id: int) -> Array:
	var all: Dictionary = DictRead.as_dict(
		_document.get("weapon_multi_target", {}))
	var switch: Dictionary = DictRead.as_dict(all.get(switch_name, {}))
	var raw: Array = DictRead.as_array(switch.get(str(weapon_id), []))
	if raw.size() < 4:
		return []
	# **The cache is JSON and holds no integer**, so the narrowing happens
	# here, once, at the loading boundary -- the rule the typed arrays in
	# `core` follow for the same reason.
	return [DictRead.as_int(raw[MULTI_LOW]), DictRead.as_int(raw[MULTI_HIGH]),
		DictRead.as_bool(raw[MULTI_UNIT]),
		DictRead.as_int(raw[MULTI_REPEATS])]


## The Charisma part each creator above fires from, in the same order.
## `""` is a creator that names none and leaves from the body's axis.
func joints(switch_name: String, weapon_id: int) -> Array:
	var switch: Dictionary = DictRead.as_dict(
		_document.get(switch_name + "_joint", {}))
	if switch.has(str(weapon_id)):
		return DictRead.as_array(switch[str(weapon_id)])
	return DictRead.as_array(_document.get(switch_name + "_default_joint", []))


## One entry of [method joints], or `""` past the end of an older document.
static func joint_at(list: Array, index: int) -> String:
	if index < 0 or index >= list.size():
		return ""
	return DictRead.as_string(list[index])


## One entry of [method bursts], as `(rounds, stagger)`.
static func burst_at(list: Array, index: int) -> Vector2i:
	if index < 0 or index >= list.size():
		return Vector2i(1, 0)
	var pair: Array = DictRead.as_array(list[index])
	if pair.size() < 2:
		return Vector2i(1, 0)
	return Vector2i(maxi(DictRead.as_int(pair[0]), 1),
		DictRead.as_int(pair[1]))


## The arm, run as many times as the arm runs it.
##
## Forty-three of the forty-eight weapons reach their creator once and this is
## one pass. The other five are [method multi_target]'s, and the *cells* they
## aim at come from the caller: `pattern` is the shot's own outcome per cell
## and this filters it by the arm's own band and unit test, in control-map
## order, because that order is what picks weapon 11's arc.
##
## An empty `pattern` makes nothing, and that is a faithful limit rather than
## a fallback. The engine has no caller that animates a shot it has not
## resolved: `aPlayFightAnimation` is called from exactly two sites
## (`0x0046C186` and `0x004705F5`) and both sit in a routine that has already
## called `aBuildTargetPattern`, whose own first instruction clears the
## `0x50`-`0x5E` band (`0x00431070`, its only caller). So the markers are
## wiped at the start of the next build and never after an animation -- a
## walking arm is never dispatched over an empty band, and never over a stale
## one either. `blob_tables`' `weapon.pattern_precedes_every_animation` pins
## it. Firing once at the aim point instead would be the remake inventing a
## round the engine has no arm for.
func _fire(switch_name: String, weapon_id: int, at: Vector3i,
		towards: Vector3i,
		joint_points: Dictionary[String, Vector3i] = {},
		tile: Vector2i = NO_TILE, target_tile: Vector2i = NO_TILE,
		at_object: Vector3i = NO_POINT,
		towards_object: Vector3i = NO_POINT, target_unit: int = 0,
		pattern: Array[Dictionary] = []) -> int:
	var arm: Array = multi_target(switch_name, weapon_id)
	if arm.is_empty():
		return _fire_once(switch_name, weapon_id, at, towards, joint_points,
			tile, target_tile, at_object, towards_object, target_unit)
	var repeats: int = DictRead.as_int(arm[MULTI_REPEATS])
	if repeats != MULTI_PER_CELL:
		# Weapon 44: the same aim point, `repeats` times over. Each pass draws
		# its own scatter, which is why five grenades do not fly as one.
		var made: int = 0
		for _round: int in range(repeats):
			made += _fire_once(switch_name, weapon_id, at, towards,
				joint_points, tile, target_tile, at_object, towards_object,
				target_unit)
		return made
	var cells: Array[Dictionary] = _multi_cells(arm, pattern)
	if cells.is_empty():
		# **Not a skip**, and not a fallback either: see this method's own
		# note. The engine's walk over a band with no cell in it makes
		# nothing, and no engine caller reaches the walk without having built
		# the band first.
		return 0
	var total: int = 0
	for index: int in range(cells.size()):
		var cell: Dictionary = cells[index]
		var point: Vector3i = DictRead.as_vector3i(cell[PATTERN_POINT])
		var object: Vector3i = DictRead.as_vector3i(cell[PATTERN_OBJECT])
		var here: Vector2i = DictRead.as_vector2i(cell[PATTERN_TILE])
		# **The impact end moves both of its ends.** Its arms run *on* the
		# cell -- `impact()` hands the same point and the same tile twice --
		# and the creators there place from `Inputs.source_point()`, so
		# leaving the source at the aim cell would pile every walked cell's
		# effect on the first one.
		var impacts: bool = switch_name == IMPACT_SWITCH
		total += _fire_once(switch_name, weapon_id,
			point if impacts else at, point, joint_points,
			here if impacts else tile, here,
			object if impacts else at_object, object,
			DictRead.as_int(cell[PATTERN_UNIT]) & 0xFF, index)
	return total


## Which cells of the shot's pattern one walking arm acts on, in the order it
## walks them -- ascending `y * width + x`, which is `0x0042F730`'s index and
## the remake's [method MapState.index_of] alike.
func _multi_cells(arm: Array, pattern: Array[Dictionary]) -> Array[Dictionary]:
	var low: int = DictRead.as_int(arm[MULTI_LOW])
	var high: int = DictRead.as_int(arm[MULTI_HIGH])
	var wants_unit: bool = DictRead.as_bool(arm[MULTI_UNIT])
	var out: Array[Dictionary] = []
	for cell: Dictionary in pattern:
		var marker: int = DictRead.as_int(cell.get(PATTERN_MARKER, 0))
		if marker < low or marker > high:
			continue
		if wants_unit and DictRead.as_int(
				cell.get(PATTERN_UNIT, PATTERN_NO_UNIT)) == PATTERN_NO_UNIT:
			continue
		out.append(cell)
	return out


func _fire_once(switch_name: String, weapon_id: int, at: Vector3i,
		towards: Vector3i,
		joint_points: Dictionary[String, Vector3i] = {},
		tile: Vector2i = NO_TILE, target_tile: Vector2i = NO_TILE,
		at_object: Vector3i = NO_POINT,
		towards_object: Vector3i = NO_POINT, target_unit: int = 0,
		arc: int = 0) -> int:
	if _pool == null:
		return 0
	var source_object: Vector3i = at if at_object == NO_POINT else at_object
	var target_object: Vector3i = towards if towards_object == NO_POINT \
		else towards_object
	var made: int = 0
	var list: Array = creators(switch_name, weapon_id)
	var burst_list: Array = bursts(switch_name, weapon_id)
	var joint_list: Array = joints(switch_name, weapon_id)
	for index: int in range(list.size()):
		var key: String = DictRead.as_string(list[index])
		var shape: Array = DictRead.as_array(BURST_SHAPES.get(key, []))
		var burst_creator: bool = not shape.is_empty()
		var spore: bool = key == SPORE_CREATOR
		# **The creator's own source, joint and all.** Everything downstream
		# reads it -- the direction, the span the streak's life is counted
		# in, the casing's origin -- because `0x0042C660` writes over the
		# three stack slots the rest of the creator goes on to read.
		var from: Vector3i = at
		var jointed: bool = false
		var joint: String = joint_at(joint_list, index)
		if joint.is_empty():
			joint = DictRead.as_string(CREATOR_JOINTS.get(key, ""))
		if not joint.is_empty() and joint_points.has(joint):
			from = joint_points[joint]
			jointed = true
		# **The creator's own round loop** -- see [method bursts]. Every record
		# a pass makes carries that pass's delay, so the burst leaves one round
		# at a time.
		var burst: Vector2i = burst_at(burst_list, index)
		var life: int = -1
		if burst_creator:
			life = maxi(_burst_life(from, towards,
				DictRead.as_int(shape[SHAPE_UNIT])), 0)
		elif spore:
			# **Not clamped**, unlike the burst's: the spore cannon's own
			# `test ebp, ebp / setle` reads the raw difference and the
			# constructor is handed it whole (`0x00426A92`).
			life = _spore_life(from, towards)
		# The creator's own write over `0x004FE63C`, ahead of everything it
		# makes: a flight begins at 0, and a span inside one spacing -- the
		# point-blank branch -- says there is nothing to wait for.
		if burst_creator or spore:
			_arrived_write = 1 if life <= 0 else 0
		elif WEAPON_PROGRAMS.has(key) or key == GRENADE_ARC_TYPED \
				or key == FLAME_STREAM_TYPED:
			# The transcribed creator's own store, ahead of everything it
			# makes and behind no branch -- so a creator that then lays
			# nothing still says what it said.
			var written: int = DictRead.as_int(
				_program_row(key, weapon_id, arc)[PROGRAM_ARRIVED])
			if written != ARRIVED_UNWRITTEN \
					and written != ARRIVED_FROM_FLIGHT:
				_arrived_write = written
		if burst_creator and life <= 0 and key == FLASH_CREATOR:
			_point_blank_flash(towards, burst.x)
		for round_index: int in range(burst.x):
			# **One delta per round, shared by the round's records.** The
			# transcribed creator draws it once and then places its records at
			# the source *plus* it -- and the tracer's casing a third of it
			# *behind*, so the case flies backwards out of the breech while
			# the round goes forward.
			var delta: Vector3i = _burst_delta(from, towards, shape) \
				if burst_creator else Vector3i.ZERO
			var delay: int = (round_index * burst.y) & 0xFF
			if key == NEEDLE_CREATOR:
				made += _needles(from, delta, life, delay)
				continue
			if spore:
				made += _spore_cannon(from, towards, life, delay)
				continue
			# **The transcribed creator, run whole.** Its records go through
			# [method _place] like everything else here, so [method in_flight]
			# still answers for them -- which is why this is not the
			# [method _ask_tile] seam a nested creator uses.
			if WEAPON_PROGRAMS.has(key) \
					or key == SPORE_EXPLOSION_TYPED \
					or key == GRENADE_ARC_TYPED \
					or key == FLAME_STREAM_TYPED:
				made += _run_weapon_program(key, weapon_id, source_object,
					target_object, at, towards, from if jointed else NO_POINT,
					tile, target_tile, target_unit, arc)
				continue
			# **The transcribed creator, by tile.** Counted by the caller
			# that runs it, as the point-blank requests are: what goes into
			# the pool is sixty records and not the one this loop would make.
			# With no tile the effect is skipped rather than approximated --
			# a wrong ring at a guessed cell is worse than none.
			if key == SHOCK_WAVE_CREATOR:
				if tile != NO_TILE:
					_ask_tile(key, tile,
						PackedInt32Array([SHOCK_WAVE_TYPE]))
				continue
			for call: Variant in _by_creator.get(key, []):
				if _create(DictRead.as_dict(call), from, towards, delta,
						burst_creator, delay, life) >= 0:
					made += 1
			if key == TRACER_CREATOR:
				_ask(BlobPrograms.ZOOMBOB, from + Vector3i(
						IncInt.div_trunc(delta.x, TRACER_BOB_SPLIT),
						IncInt.div_trunc(delta.y, TRACER_BOB_SPLIT),
						IncInt.div_trunc(delta.z, TRACER_BOB_SPLIT)),
					PackedInt32Array([TRACER_BOB_ROW, TRACER_BOB_AUX,
						TRACER_BOB_LIFE]))
		if burst_creator and life <= 0 and key == NEEDLE_CREATOR:
			_point_blank_needles(towards)
	return made


## `0x0042418B` -- the flash's point-blank branch: one zoom bob per round,
## jittered on all three axes, around the **target**. Its draws are the
## flash's own and are taken here so they land in the pool's one stream in
## the order the engine takes them: the size first, then z, y and x.
func _point_blank_flash(at: Vector3i, rounds: int) -> void:
	var hooks: BlobHooks = _pool.hooks() if _pool != null else null
	if hooks == null:
		return
	for _round: int in range(rounds):
		var aux: int = hooks.random(POINT_BLANK_AUX_BASE, POINT_BLANK_AUX_SPAN)
		var jz: int = hooks.random(FLASH_BOB_JITTER_BASE, FLASH_BOB_JITTER_SPAN)
		var jy: int = hooks.random(FLASH_BOB_JITTER_BASE, FLASH_BOB_JITTER_SPAN)
		var jx: int = hooks.random(FLASH_BOB_JITTER_BASE, FLASH_BOB_JITTER_SPAN)
		_ask(BlobPrograms.ZOOMBOB, at + Vector3i(jx, jy, jz),
			PackedInt32Array([FLASH_BOB_ROW, aux, POINT_BLANK_BOB_LIFE]))


## `0x00424739` -- the needles' point-blank branch: one zoom bob at the
## target and `0x00428F70`'s twenty plasma sparks there, once for the whole
## call rather than once per round.
func _point_blank_needles(at: Vector3i) -> void:
	var hooks: BlobHooks = _pool.hooks() if _pool != null else null
	if hooks == null:
		return
	var aux: int = hooks.random(POINT_BLANK_AUX_BASE, POINT_BLANK_AUX_SPAN)
	_ask(BlobPrograms.ZOOMBOB, at,
		PackedInt32Array([NEEDLE_BOB_ROW, aux, POINT_BLANK_BOB_LIFE]))
	_ask(BlobPrograms.PLASMA_SPARKS_BURST, at,
		PackedInt32Array([NEEDLE_SPARKS, NEEDLE_SPARKS_UNREAD]))


func _ask(creator: String, at: Vector3i, extra: PackedInt32Array) -> void:
	_programs.append({"creator": creator, "at": at, "extra": extra})


## A request a **tile** creator answers: `x, y` and the literals its call site
## pushes, which is what [method BlobPrograms.run] wants and what
## `SliceMain.spawn_program` builds its inputs from.
func _ask_tile(creator: String, tile: Vector2i,
		extra: PackedInt32Array) -> void:
	_programs.append({"creator": creator, "tile": tile, "extra": extra})


## `aBlob_CreateNeedles`' round: **nine** sprites down the round's own delta.
##
## The one burst creator whose round is not a single record, and the one whose
## record the constructor table cannot carry: its call at `0x004246F9`
## computes the kind (`xor eax, eax / test ebx, ebx / setne al / add eax,
## 0x49`), so the document holds `null` there and [method _create] refuses it
## -- which is why weapon 16 made no muzzle effect at all before this.
##
## The delta is divided by eight and accumulated, so the nine sit at one
## eighth, two eighths ... nine eighths of it and grow as they go
## ([constant NEEDLE_AUX_BASE] minus the counter). All nine carry the round's
## whole delta as their velocity and its stagger as their delay.
func _needles(from: Vector3i, delta: Vector3i, life: int, delay: int) -> int:
	var calls: Array = DictRead.as_array(_by_creator.get(NEEDLE_CREATOR, []))
	if calls.is_empty() or life <= 0:
		return 0
	var call: Dictionary = DictRead.as_dict(calls[0])
	var sprite: Dictionary = _sprite_of(call)
	var step: Vector3i = Vector3i(
		IncInt.div_trunc(delta.x, NEEDLE_SPLIT),
		IncInt.div_trunc(delta.y, NEEDLE_SPLIT),
		IncInt.div_trunc(delta.z, NEEDLE_SPLIT))
	var made: int = 0
	var walk: Vector3i = from
	for k: int in range(NEEDLE_SPLIT, -1, -1):
		walk += step
		var fields: Dictionary = {
			"kind": NEEDLE_KIND_LAST if k == 0 else NEEDLE_KIND,
			"class_id": DictRead.as_int(call["class"]),
			"life": life,
			"x": walk.x, "y": walk.y, "z": walk.z,
			"vx": delta.x, "vy": delta.y, "vz": delta.z,
			"rot_x": _sprite_field(sprite, "row", DEFAULT_ROW),
			"rot_y": _sprite_field(sprite, "col", DEFAULT_COLUMN),
			"aux": NEEDLE_AUX_BASE - k,
			"delay": delay,
		}
		if _place(fields) >= 0:
			made += 1
	return made


## `max(|dx|, |dy|) / unit - 1` over the two ends -- `0x00424A73`..
## `0x00424AB1` for the tracer, and the same three instructions with their own
## divisor in the other two. The span is measured from the **jointed** source:
## the divide reads the very stack slots `0x0042C660` wrote over.
func _burst_life(from: Vector3i, to: Vector3i, unit: int) -> int:
	var span: int = maxi(absi(from.x - to.x), absi(from.y - to.y))
	return IncInt.div_trunc(span, unit) - 1


## `0x00424AE4`..`0x00424B5D` -- the round's own offset from the muzzle.
##
## `aRandom2(-160, 320) - ftol(d * -2240)` per horizontal axis and
## `aRandom2(-80, 160)` vertically, over the direction service's answer. It is
## the tracer's velocity as well as its offset, which is why one number does
## both jobs here.
func _burst_delta(from: Vector3i, to: Vector3i, shape: Array) -> Vector3i:
	var hooks: BlobHooks = _pool.hooks() if _pool != null else null
	var ground_base: int = DictRead.as_int(shape[SHAPE_SCATTER_BASE])
	var ground_span: int = DictRead.as_int(shape[SHAPE_SCATTER_SPAN])
	var step: int = DictRead.as_int(shape[SHAPE_STEP])
	var scatter: Vector3i = Vector3i.ZERO
	if hooks != null:
		scatter = Vector3i(
			hooks.random(ground_base, ground_span),
			hooks.random(ground_base, ground_span),
			hooks.random(DictRead.as_int(shape[SHAPE_RISE_BASE]),
				DictRead.as_int(shape[SHAPE_RISE_SPAN])))
	if from == to:
		return scatter
	var d: PackedFloat64Array = Eng3dGeometry.direction(from, to, 1)
	if is_nan(d[0]) or is_nan(d[1]) or is_nan(d[2]):
		return scatter
	return Vector3i(
		scatter.x - Eng3dGeometry.ftol(d[0] * float(step)),
		scatter.y - Eng3dGeometry.ftol(d[1] * float(step)),
		scatter.z - Eng3dGeometry.ftol(d[2] * float(step)))


## `0x00426A4E`..`0x00426A8E` -- the spore round's life, in spore steps.
##
## Zero or less is the point-blank branch: the constructor drops a record with
## no life (`test al, al / je` at `0x00420957`, and `al` is the `life`
## argument), so a spore shot inside two steps makes nothing at all -- which
## is why the creator writes the *arrived* flag up rather than down.
func _spore_life(from: Vector3i, to: Vector3i) -> int:
	var span: int = maxi(absi(from.x - to.x), absi(from.y - to.y))
	return IncInt.div_trunc(span, SPORE_UNIT) - SPORE_LIFE_BIAS


## `0x00426A7A`..`0x00426AC4` -- one spore step along the line of fire.
##
## `ftol` answers zero for the NaN and the infinities the direction service
## returns over a zero span, so the degenerate cases need no arm of their own.
func _spore_velocity(from: Vector3i, to: Vector3i) -> Vector3i:
	if from == to:
		return Vector3i.ZERO
	var d: PackedFloat64Array = Eng3dGeometry.direction(from, to, 1)
	return Vector3i(
		Eng3dGeometry.ftol(d[0] * float(SPORE_SPEED)),
		Eng3dGeometry.ftol(d[1] * float(SPORE_SPEED)),
		Eng3dGeometry.ftol(d[2] * float(SPORE_SPEED)))


## One spore round -- the creator's single constructor call at `0x00426B52`.
##
## The record's **position** carries the plain step (`0x00426ADB` adds the
## `vz` the stack slot kept) and its **velocity** the lofted one
## (`0x00426B29`), which is the whole of the arc. The engine's `abs` over the
## loft is a no-op for every life that reaches the constructor, so it is left
## out rather than written down as arithmetic nothing takes.
func _spore_cannon(from: Vector3i, to: Vector3i, life: int, delay: int) -> int:
	var calls: Array = DictRead.as_array(_by_creator.get(SPORE_CREATOR, []))
	if calls.is_empty() or life <= 0:
		return 0
	var call: Dictionary = DictRead.as_dict(calls[0])
	if call["kind"] == null:
		return 0
	var step: Vector3i = _spore_velocity(from, to)
	var sprite: Dictionary = _sprite_of(call)
	var fields: Dictionary = {
		"kind": DictRead.as_int(call["kind"]),
		"class_id": DictRead.as_int(call["class"]),
		"life": life,
		"x": from.x + step.x, "y": from.y + step.y, "z": from.z + step.z,
		"vx": step.x, "vy": step.y,
		"vz": step.z + SPORE_LOFT * IncInt.div_trunc(life, 2),
		"rot_x": _sprite_field(sprite, "row", DEFAULT_ROW),
		"rot_y": _sprite_field(sprite, "col", DEFAULT_COLUMN),
		"aux": _sprite_field(sprite, "size", DEFAULT_SIZE),
		"delay": delay,
	}
	return 1 if _place(fields) >= 0 else 0


## One transcribed weapon creator, run against the live pool.
##
## The seam is deliberately **not** [method _ask_tile]: a nested creator's
## records are the caller's business and go in through
## `SliceMain.spawn_program`, but a muzzle's are what [method in_flight] waits
## on, so they go through [method _place] like every other record this class
## makes.
##
## The generator is the pool's own -- `aRandom2`, the uncounted twin -- handed
## over and handed back, so a creator's draws land in the one stream the arms
## keep drawing from.
func _run_weapon_program(key: String, weapon_id: int, source_object: Vector3i,
		target_object: Vector3i, source_point: Vector3i,
		target_point: Vector3i, joint: Vector3i, tile: Vector2i,
		target_tile: Vector2i, target_unit: int = 0, arc: int = 0) -> int:
	var hooks: BlobHooks = _pool.hooks()
	if hooks == null:
		return 0
	var row: Array = _program_row(key, weapon_id, arc)
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.geometry = hooks.geometry
	for name: Variant in hooks.model_index:
		inputs.models[DictRead.as_string(name)] = DictRead.as_int(
			hooks.model_index[name])
	# **The object and the height stay apart**, because the programs read them
	# apart: the span a beam's length is counted in is over the two *objects*
	# (`0x00425A8A` reads `[edi+0x10]`/`[ecx+0x10]`), three of them open at
	# the object's own z with no height at all, and only the ones that go
	# through `source_point()` want the sum. A caller with no object of its
	# own passed [constant NO_POINT] and the sum stands in for both, which is
	# what [method _fire] has already resolved.
	inputs.source = source_object
	inputs.source_height = source_point.z - source_object.z
	inputs.target = target_object
	inputs.target_height = target_point.z - target_object.z
	# **The slot a seeking arm reads back.** Kind 26 -- arm 25, the seeker of
	# docs/28 section 7.7.1 -- takes the record's `aux` as a unit-map index, so
	# a creator that stores it and a caller that leaves it zero make every shot
	# home on slot 0.
	inputs.target_unit = target_unit & 0xFF
	if joint != NO_POINT:
		inputs.source_joint = joint
		inputs.has_source_joint = true
	# **The tiles the two ends stand on**, for a creator that reads a cell
	# rather than the arguments it was handed ([method BlobPrograms.Inputs.object]).
	if tile != NO_TILE:
		inputs.tiles[tile] = {"object": source_object}
	if target_tile != NO_TILE:
		inputs.tiles[target_tile] = {"object": target_object}
	# The point arm's own three coordinates are the creator's **source stack
	# slots**, which is the joint where one applied.
	var args: PackedInt32Array = _program_args(key, row,
		source_point if joint == NO_POINT else joint, tile, target_tile, arc)
	var pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(
		hooks.rng.seed if hooks.rng.seed != 0.0 else 1.0)
	if not BlobPrograms.run(key, pool, draws, args, inputs):
		return 0
	# **The flag the creator wrote out of its own flight length**, which only
	# the program knows -- see [constant ARRIVED_FROM_FLIGHT].
	if DictRead.as_int(row[PROGRAM_ARRIVED]) == ARRIVED_FROM_FLIGHT:
		_arrived_write = 0 if pool.clears_arrived else 1
	hooks.rng.randomize_seed(draws.rng.seed)
	var made: int = 0
	for record: Dictionary in pool.records:
		if _place(record) >= 0:
			made += 1
	return made


## One creator's row, with the spore explosion's per-weapon type filled in --
## the one literal in the table that is not the same at every call site.
func _program_row(key: String, weapon_id: int, arc: int = 0) -> Array:
	if key == SPORE_EXPLOSION_TYPED:
		return [ARG_TILE, ARRIVED_UNWRITTEN, 0,
			DictRead.as_int(SPORE_EXPLOSION_TYPES.get(weapon_id, 0))]
	if key == FLAME_STREAM_TYPED:
		return [ARG_LINE, 0,
			DictRead.as_int(FLAME_STREAM_TYPES.get(weapon_id, 4))]
	if key == GRENADE_ARC_TYPED:
		# The fifth argument is the one every arm pushes and the body never
		# reads; the sixth is the arc.
		return [ARG_LINE, 0, 0xA,
			DictRead.as_int(GRENADE_ARC_TYPES.get(weapon_id, 0))]
	return DictRead.as_array(WEAPON_PROGRAMS[key])


## The argument vector one creator's own call site pushes -- see
## [constant WEAPON_PROGRAMS].
func _program_args(key: String, row: Array, from: Vector3i, tile: Vector2i,
		target_tile: Vector2i, arc: int = 0) -> PackedInt32Array:
	var args: PackedInt32Array = PackedInt32Array()
	match DictRead.as_int(row[PROGRAM_SHAPE]):
		ARG_LINE:
			args.append_array(PackedInt32Array([tile.x, tile.y,
				target_tile.x, target_tile.y]))
		ARG_TILE:
			args.append_array(PackedInt32Array([tile.x, tile.y]))
		ARG_POINT:
			args.append_array(PackedInt32Array([from.x, from.y, from.z]))
	for index: int in range(PROGRAM_TAIL, row.size()):
		# **The two tail entries a walking arm computes** rather than pushes as
		# a literal: the running count of matched cells, and that count over
		# three (`MULTI_TAIL_INDEX`).
		var value: int = DictRead.as_int(row[index])
		if value == MULTI_TAIL_INDEX:
			value = arc
		elif value == MULTI_TAIL_INDEX_THIRD:
			value = IncInt.div_trunc(arc, 3)
		args.append(value)
	# A creator whose arity is wider than what its arm pushes reads the rest
	# as the frame left it; the programs here read none of it, so a zero is
	# the honest filler rather than an invention.
	while args.size() < BlobPrograms.args_needed(key):
		args.append(0)
	return args


## The sprite parameters the extractor recorded for one constructor call.
func _sprite_of(call: Dictionary) -> Dictionary:
	return DictRead.as_dict(DictRead.as_dict(_document.get("sprites", {}))
		.get(DictRead.as_string(call["site"]), {}))


## Put one record in the pool and, for a muzzle, remember it.
##
## Everything this class builds goes through here rather than through
## [method BlobPool.create_blob] directly, so [method in_flight] can answer
## for the whole of a shot's muzzle -- a burst's rounds, the needles' nine
## sprites, the casing and the spore round alike.
func _place(fields: Dictionary) -> int:
	var slot: int = _pool.create_blob(fields)
	if slot >= 0 and _recording:
		_made.append(_pool.at(slot))
	return slot


func _create(call: Dictionary, at: Vector3i, towards: Vector3i,
		delta: Vector3i = Vector3i.ZERO, burst: bool = false,
		delay: int = 0, burst_life: int = -1) -> int:
	# A computed kind is the two-way choice of docs/28 section 7.7; without the
	# creator we cannot know which side it took, so the effect is not made at
	# all rather than made as kind 0.
	#
	# **First**, and not after the record is built: the column is nullable and
	# two of the shipped calls carry it as null, both under creators a weapon
	# reaches -- so narrowing it to an `int` before this test is a runtime
	# error on every shot from those weapons.
	if call["kind"] == null:
		return -1
	var kind: int = DictRead.as_int(call["kind"])
	var class_id: int = DictRead.as_int(call["class"])
	var life: int = DictRead.as_int(call["life"]) if call["life"] != null \
		else DEFAULT_LIFE
	var velocity: Vector3i = _casing_velocity(at, towards) \
		if kind == CASING_KIND else _velocity(at, towards, life)
	# The transcribed creator's own two numbers where they exist: the streak
	# lives one frame per [constant TRACER_UNIT] of the wider horizontal span
	# and travels the round's whole delta each of them, so it arrives instead
	# of being paced to arrive. Every other call keeps the lifetime its own
	# site passes and the speed that crosses in it.
	if burst and kind != CASING_KIND:
		# **The round's own life, and only where the site computes one.** The
		# tracer's casing carries the literal 0x14 at its call and keeps it,
		# so a point-blank shot ejects a case with no streak -- which is the
		# original's own answer.
		if call["life"] == null:
			life = burst_life
			if life <= 0:
				return -1
		velocity = delta
	# Where the round's own records sit relative to the muzzle, and both are
	# the transcribed creator's (`0x00424C2B` and `0x00424C45` for the third,
	# `0x00424B7B` for the tracer's whole delta). A creator with no delta --
	# every other one, and the impact end -- keeps the point it was given.
	var origin: Vector3i = at + delta
	if kind == CASING_KIND:
		origin = Vector3i(at.x - IncInt.div_trunc(delta.x, 3),
			at.y - IncInt.div_trunc(delta.y, 3), at.z)
	var fields: Dictionary = {
		"kind": kind,
		"class_id": class_id,
		"life": life,
		"x": origin.x, "y": origin.y, "z": origin.z,
		"vx": velocity.x, "vy": velocity.y, "vz": velocity.z,
		# The constructor's last field, and the burst's whole timing: a record
		# with a delay is not drawn and does not step until it has counted
		# down (`blob_kinds.gd`).
		"delay": delay,
	}
	if class_id >= 2:
		var sprite: Dictionary = _sprite_of(call)
		fields["rot_x"] = _sprite_field(sprite, "row", DEFAULT_ROW)
		fields["rot_y"] = _sprite_field(sprite, "col", DEFAULT_COLUMN)
		fields["aux"] = _sprite_field(sprite, "size", DEFAULT_SIZE)
		# The flash's column is the one sprite parameter a burst creator draws
		# rather than pushes (`0x0042411F`, after the round's three offsets).
		if burst and sprite.get("col") == null and _pool.hooks() != null:
			fields["rot_y"] = _pool.hooks().random(0, FLASH_COLUMN_SPAN)
	elif call["model"] != null:
		fields["model_name"] = DictRead.as_string(call["model"])
		var facing: Vector3i = _facing(at, towards)
		fields["rot_x"] = facing.x
		fields["rot_y"] = facing.y
		fields["rot_z"] = facing.z
	return _place(fields)


## Which way a **model** blob points when it is made, as the engine's own
## orientation service answers it.
##
## The class comment's caveat applies here and is the reason this exists: all
## but one of the thirty creators a weapon selects are *not* transcribed
## (docs/97 section 14.5; the exceptions are [constant WEAPON_PROGRAMS],
## which never reach here because they build their records themselves),
## so the record this class builds carries the call site's real kind, class,
## life and model and a trajectory of the remake's own. The rotation triple was
## left at **zero**, and for a class-0 blob that is not a neutral value: the
## tracer's `A_LINE5.3DI`, the laser's `A_LASERG.3DI` and the plasma bolt are
## *shaped* models, so a round crossing the map on any bearing but the one they
## are authored along flew visibly sideways (docs/97 section 46).
##
## The rule is **read out of the capture, not chosen**. `blob_gold.py`'s
## records for `0x00424D20` -- a burst of two tracers and two casings -- carry
## `(65528, 0, 2344)` on *every* record of the call, and 2344 is exactly what
## `0x00403AA0` answers for that burst's own direction: one triple per call,
## along the line, the middle word zero. The casings keep it although their own
## velocities point elsewhere, which is why this is stamped per call here
## rather than derived per blob.
##
## So the direction comes from [method BlobHooks.orient], `0x00403AA0`'s
## **measured** arithmetic -- a 4096-unit yaw in the third word, the pitch in
## the first. What stays the remake's is the small spread the creators put on
## that line before they orient (the capture's yaws are 2344 and 2379 against
## the line's own 2350, and their pitches differ with it); this uses the line
## itself. The creator's own arithmetic replaces it the day those thirty are
## transcribed.
func _facing(from: Vector3i, to: Vector3i) -> Vector3i:
	if _pool == null or from == to:
		return Vector3i.ZERO
	return _pool.hooks().orient(from, to)


func _sprite_field(sprite: Dictionary, name: String, fallback: int) -> int:
	if sprite.is_empty() or sprite.get(name) == null:
		return fallback
	return DictRead.as_int(sprite[name])


## The ejected case's velocity -- **not** a line to what was shot at.
##
## Read out of `aBlob_CreateTracerBullet` `0x004247C0`, the creator fourteen
## of the shipped weapons' muzzle switch selects (weapon 2, the Standard
## Assault Rifle, among them) and the default arm for the two ids the table
## does not reach. Its loop makes a tracer, a case and a zoom bob per round,
## and the case is the one record whose velocity has nothing to do with the
## aim: `x` takes `0x0046D400`'s `y` ratio times `0x004B1290` (+128), `y` its
## `x` ratio times `0x004B1288` (-128), and `z` is `aRandom2(0, 0xA0) +
## 0x140` -- so it leaves sideways and upwards and falls, which is what a
## cartridge case does and what the original visibly shows.
##
## **Read from the listing, not measured.** The rest of that creator -- its
## per-round scatter, the tracer's own placement, the zoom bob -- is still not
## transcribed (docs/97 section 14.5 stays open), so this is one record's
## arithmetic lifted out of a function nothing has run. The machine gun's
## `0x00424D20` is transcribed and captured (`tools/inclib/blob_creators.py`)
## and its casing arm is the same shape at a different speed, which is the
## corroboration there is for it.
func _casing_velocity(from: Vector3i, to: Vector3i) -> Vector3i:
	var rise: int = CASING_RISE_BASE
	if _pool != null and _pool.hooks() != null:
		rise += _pool.hooks().random(0, CASING_RISE_SPAN)
	if from == to:
		return Vector3i(0, 0, rise)
	var d: PackedFloat64Array = Eng3dGeometry.direction(from, to, 1)
	if is_nan(d[0]) or is_nan(d[1]):
		return Vector3i(0, 0, rise)
	return Vector3i(Eng3dGeometry.ftol(d[1] * float(CASING_SPEED)),
		Eng3dGeometry.ftol(d[0] * float(-CASING_SPEED)), rise)


## A straight line from `from` to `to`, crossed in the blob's **own lifetime**.
##
## The trajectory is still ours -- see the class comment -- but its timing is
## not invented any more: `life` is the literal the creator passes at that call
## site, extracted with the kind and the class, so a tracer with `life = 8`
## takes eight ticks to reach what was shot at and dies as it arrives. A fixed
## speed made short shots overshoot and long ones expire in mid-air.
##
## Two cases keep [constant MUZZLE_SPEED]: an immortal blob (`life = 0xFF`,
## which the original uses for effects nothing is meant to time) has no
## lifetime to divide by, and a call whose lifetime the arm computes falls back
## to [constant DEFAULT_LIFE] and so to the same reasoning. Integer throughout,
## because a blob's velocity words hold exactly what the arms will read.
static func _velocity(from: Vector3i, to: Vector3i, life: int) -> Vector3i:
	var dx: int = to.x - from.x
	var dy: int = to.y - from.y
	var dz: int = to.z - from.z
	if dx == 0 and dy == 0 and dz == 0:
		return Vector3i.ZERO
	if life > 0 and life < IMMORTAL_LIFE:
		return Vector3i(dx / life, dy / life, dz / life)
	var length: float = sqrt(float(dx * dx + dy * dy + dz * dz))
	if length < 1.0:
		return Vector3i.ZERO
	var scale: float = float(MUZZLE_SPEED) / length
	return Vector3i(int(float(dx) * scale), int(float(dy) * scale),
		int(float(dz) * scale))


## The world position an effect starts from, for a unit standing on `(x, y)`
## at engine height `h`.
## *lift* is how far above the cell floor the effect starts: the standing
## unit's own height where there is one ([method SliceMain._muzzle_of]), and
## [constant MUZZLE_HEIGHT] for bare ground.
static func muzzle_point(x: int, y: int, h: int,
		lift: int = MUZZLE_HEIGHT) -> Vector3i:
	return Vector3i(x * WorldSpace.WORLD_UNITS_PER_FIELD,
		y * WorldSpace.WORLD_UNITS_PER_FIELD, h + lift)
