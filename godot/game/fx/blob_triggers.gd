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

var _pool: BlobPool = null
var _document: Dictionary = {}
## Nested creators a point-blank burst asked for, in the order it asked.
var _programs: Array[Dictionary] = []
## What the last burst creator wrote over the *arrived* flag, or
## [constant ARRIVED_UNWRITTEN] when none ran -- see [method arrived_write].
var _arrived_write: int = ARRIVED_UNWRITTEN
## `creator address -> the constructor calls inside it`, built once.
var _by_creator: Dictionary[String, Array] = {}


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
		joints: Dictionary[String, Vector3i] = {}) -> int:
	_programs.clear()
	_arrived_write = ARRIVED_UNWRITTEN
	return _fire("weapon_muzzle", weapon_id, from, to, joints)


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
## `{creator, at, extra}` per request, ready for [BlobPrograms]. Only a
## point-blank burst makes any; see [constant POINT_BLANK_BOB_LIFE].
func take_programs() -> Array[Dictionary]:
	var out: Array[Dictionary] = _programs
	_programs = []
	return out


## The impact effects, at the target and going nowhere.
func impact(weapon_id: int, at: Vector3i) -> int:
	return _fire("weapon_impact", weapon_id, at, at)


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


func _fire(switch_name: String, weapon_id: int, at: Vector3i,
		towards: Vector3i,
		joint_points: Dictionary[String, Vector3i] = {}) -> int:
	if _pool == null:
		return 0
	var made: int = 0
	var list: Array = creators(switch_name, weapon_id)
	var burst_list: Array = bursts(switch_name, weapon_id)
	var joint_list: Array = joints(switch_name, weapon_id)
	for index: int in range(list.size()):
		var key: String = DictRead.as_string(list[index])
		var shape: Array = DictRead.as_array(BURST_SHAPES.get(key, []))
		var burst_creator: bool = not shape.is_empty()
		# **The creator's own source, joint and all.** Everything downstream
		# reads it -- the direction, the span the streak's life is counted
		# in, the casing's origin -- because `0x0042C660` writes over the
		# three stack slots the rest of the creator goes on to read.
		var from: Vector3i = at
		var joint: String = joint_at(joint_list, index)
		if not joint.is_empty() and joint_points.has(joint):
			from = joint_points[joint]
		# **The creator's own round loop** -- see [method bursts]. Every record
		# a pass makes carries that pass's delay, so the burst leaves one round
		# at a time.
		var burst: Vector2i = burst_at(burst_list, index)
		var life: int = -1
		if burst_creator:
			life = maxi(_burst_life(from, towards,
				DictRead.as_int(shape[SHAPE_UNIT])), 0)
		# The creator's own write over `0x004FE63C`, ahead of everything it
		# makes: a flight begins at 0, and a span inside one spacing -- the
		# point-blank branch -- says there is nothing to wait for.
		if burst_creator:
			_arrived_write = 1 if life <= 0 else 0
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
	var sprite: Dictionary = DictRead.as_dict(
		DictRead.as_dict(_document.get("sprites", {}))
			.get(DictRead.as_string(call["site"]), {}))
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
		if _pool.create_blob(fields) >= 0:
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
		var sprite: Dictionary = DictRead.as_dict(
			DictRead.as_dict(_document.get("sprites", {}))
				.get(DictRead.as_string(call["site"]), {}))
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
	return _pool.create_blob(fields)


## Which way a **model** blob points when it is made, as the engine's own
## orientation service answers it.
##
## The class comment's caveat applies here and is the reason this exists: the
## thirty creators a weapon selects are *not* transcribed (docs/97 section 14.5),
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
