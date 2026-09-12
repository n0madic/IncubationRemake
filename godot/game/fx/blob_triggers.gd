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
## **What is transcribed here and what is measured.** The tables give, for
## every constructor call the arms reach: its class, its update kind, its
## literal lifetime, its model and -- for a sprite -- its atlas row, column
## and size. Those are verified-static, pinned by 116 checks. The creators'
## own arithmetic -- where each record sits, what it carries, what it draws
## -- is **not** built from that table any more: every one of the thirty
## creators the two switches reach is a program of [BlobPrograms],
## transcribed out of its own instructions, and this class only builds the
## argument vector the arm pushes and hands the pool's generator over.
## `tools/blob_gold.py` calls each creator inside a running `Incubation.exe`
## and reads the pool back, and `tests/test_blob_native.gd` replays every
## one of the thirty against that capture (docs/97 section 51). Until
## 2026-09-12 the three burst creators still went down a constructor-table
## arm here, one record per call with a trajectory of the remake's own, and
## the spore cannon was built by hand; those were the last of it.

## **The one weapon creator that does not run here.** `aBlob_CreateShockWave`
## `0x00422B80` reads the tile's **placed object** and nothing of the shot's
## two points (`aGetCtrlMapElementPtr` then `aGetSymbolObjectPtr`, and the
## ring goes into the velocity), so it is asked for by tile and
## `SliceMain.spawn_program` runs [method BlobPrograms.shock_wave] with the
## tile's own inputs -- a caller with only the summed point would otherwise
## lift the ring by the unit's height. It is replayed against the capture
## like the other twenty-nine (`test_blob_native.gd`).
##
## Neither weapon waits on the flight ([constant
## ShotSequence.WAIT_SKIPPED_WEAPONS] holds 0x11 and 0x24), so the records
## going into the pool through that seam rather than through
## [method _place] costs [method in_flight] nothing.
const SHOCK_WAVE_CREATOR: String = BlobPrograms.SHOCK_WAVE
## The type both call sites push (`0x0040CD3C` and `0x0040D7AC`,
## `blob_tables.SHOCKWAVE_TYPE_SITES`): of the creator's three arms only this
## one is ever taken.
const SHOCK_WAVE_TYPE: int = 2
## A [method muzzle] or [method impact] whose caller has no tile to give.
const NO_TILE: Vector2i = Vector2i(-1, -1)
## A caller that does not separate the **placed object's** own position from
## the standing unit's height. The programs read the two apart (docs/97
## section 14.5), so a caller that has only the sum passes this and the sum
## stands in for both.
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

## **The weapon switches' creators**, and how this class builds each one's
## argument vector (docs/97 section 14.5).
##
## Every creator either switch reaches is a row here, one of the typed seams
## below or [constant SHOCK_WAVE_CREATOR]; the table used to be shorter, with
## everything else going down a constructor-table arm that laid one record
## per `call` with a trajectory of the remake's own. An entry is added only
## once its program is checked against `blob_gold.py`'s capture by
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
	# -- 2026-09-12, the evening: the spore cannon, the Cy'Coo's round -----
	#
	# Four arguments, all tiles, and a `setle` over its own flight length
	# written to the flag at `0x00426A97` ahead of the one record it makes.
	# Replayed against the capture's single record (docs/97 section 51).
	BlobPrograms.SPORE_CANNON: [ARG_LINE, ARRIVED_FROM_FLIGHT],
}
## **The three burst creators**, whose tail differs per weapon the way the
## three typed seams' does: the fifth and sixth arguments are the round count
## and the stagger the muzzle switch's own arm pushes (`weapon_muzzle_burst`
## in the document, [method bursts]), and the seventh is the joint's name,
## resolved by the caller into [member BlobPrograms.Inputs.source_joint]
## before the call. All three write the *arrived* flag from their own flight
## length (`0x00424AB9`/`0x00424AC3` and the two pairs beside them), which is
## [constant ARRIVED_FROM_FLIGHT].
const BURST_TYPED: Array[String] = [BlobPrograms.TRACER_BULLET,
	BlobPrograms.FLASH, BlobPrograms.NEEDLES]
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

## The spore cannon's address, for callers that name the creator rather
## than the program.
const SPORE_CREATOR: String = BlobPrograms.SPORE_CANNON
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
	return triggers


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
## fills the pool. The program reports it as [member
## BlobPrograms.Pool.clears_arrived] and [method _run_weapon_program] turns
## that into the byte.
func arrived_write() -> int:
	return _arrived_write


## The tile creators the last [method muzzle] or [method impact] asked for,
## and clears them: `{creator, tile, extra}` per request, ready for
## [BlobPrograms] with the tile's own inputs. Only [constant
## SHOCK_WAVE_CREATOR] is asked for this way; the nested creators a burst's
## point-blank branch runs are spawned by the program itself.
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
		# **The transcribed creator, by tile.** Counted by the caller that
		# runs it, as a request: what goes into the pool is sixty records
		# and not one. With no tile the effect is skipped rather than
		# approximated -- a wrong ring at a guessed cell is worse than none.
		if key == SHOCK_WAVE_CREATOR:
			if tile != NO_TILE:
				_ask_tile(key, tile, PackedInt32Array([SHOCK_WAVE_TYPE]))
			continue
		if not _is_program(key):
			# A creator neither switch reaches has no row; the tables pin
			# that every creator the two switches name is one of the thirty
			# (`blob_tables.creators.reachable`), so this is unreachable
			# rather than a fallback.
			continue
		# **The creator's own round loop** -- see [method bursts]: the three
		# burst creators take the pair as their fifth and sixth arguments
		# and loop it themselves; every other creator's pair is `[1, 0]`.
		var burst: Vector2i = burst_at(burst_list, index)
		var row: Array = _program_row(key, weapon_id, arc, burst)
		# The transcribed creator's own store over `0x004FE63C`, ahead of
		# everything it makes and behind no branch -- so a creator that then
		# lays nothing still says what it said. A creator that writes it
		# from its flight length says so after it runs.
		var written: int = DictRead.as_int(row[PROGRAM_ARRIVED])
		if written != ARRIVED_UNWRITTEN and written != ARRIVED_FROM_FLIGHT:
			_arrived_write = written
		# **The transcribed creator, run whole.** Its records go through
		# [method _place] like everything else here, so [method in_flight]
		# still answers for them.
		made += _run_weapon_program(key, row, source_object, target_object,
			at, towards, from if jointed else NO_POINT, tile, target_tile,
			target_unit, arc)
	return made


## Whether `key` is one of the thirty creators this class runs as a program:
## a row of [constant WEAPON_PROGRAMS], one of the typed seams or one of the
## three bursts.
static func _is_program(key: String) -> bool:
	return WEAPON_PROGRAMS.has(key) or key == SPORE_EXPLOSION_TYPED \
		or key == GRENADE_ARC_TYPED or key == FLAME_STREAM_TYPED \
		or BURST_TYPED.has(key)


## A request a **tile** creator answers: `x, y` and the literals its call site
## pushes, which is what [method BlobPrograms.run] wants and what
## `SliceMain.spawn_program` builds its inputs from.
func _ask_tile(creator: String, tile: Vector2i,
		extra: PackedInt32Array) -> void:
	_programs.append({"creator": creator, "tile": tile, "extra": extra})


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
func _run_weapon_program(key: String, row: Array, source_object: Vector3i,
		target_object: Vector3i, source_point: Vector3i,
		target_point: Vector3i, joint: Vector3i, tile: Vector2i,
		target_tile: Vector2i, target_unit: int = 0, arc: int = 0) -> int:
	var hooks: BlobHooks = _pool.hooks()
	if hooks == null:
		return 0
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


## One creator's row, with the per-weapon literals filled in: the spore
## explosion's type, the flame stream's ring count, the grenade's arc and the
## three bursts' round count and stagger -- the literals in the table that
## are not the same at every call site.
func _program_row(key: String, weapon_id: int, arc: int = 0,
		burst: Vector2i = Vector2i(1, 0)) -> Array:
	if BURST_TYPED.has(key):
		# Rounds, stagger, and the joint's name -- a pointer the program
		# never reads as a number.
		return [ARG_LINE, ARRIVED_FROM_FLIGHT, burst.x, burst.y, 0]
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


## The world position an effect starts from, for a unit standing on `(x, y)`
## at engine height `h`.
## *lift* is how far above the cell floor the effect starts: the standing
## unit's own height where there is one ([method SliceMain._muzzle_of]), and
## [constant MUZZLE_HEIGHT] for bare ground.
static func muzzle_point(x: int, y: int, h: int,
		lift: int = MUZZLE_HEIGHT) -> Vector3i:
	return Vector3i(x * WorldSpace.WORLD_UNITS_PER_FIELD,
		y * WorldSpace.WORLD_UNITS_PER_FIELD, h + lift)
