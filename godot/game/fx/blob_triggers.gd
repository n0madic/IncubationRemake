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
## `life = 0xFF` never expires (docs/28 section 7.2).
const IMMORTAL_LIFE: int = 0xFF
## How far above the cell floor an effect starts, in world units -- roughly
## chest height on a human body.
const MUZZLE_HEIGHT: int = 1000

var _pool: BlobPool = null
var _document: Dictionary = {}
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
func muzzle(weapon_id: int, from: Vector3i, to: Vector3i) -> int:
	return _fire("weapon_muzzle", weapon_id, from, to)


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


func _fire(switch_name: String, weapon_id: int, at: Vector3i,
		towards: Vector3i) -> int:
	if _pool == null:
		return 0
	var made: int = 0
	for creator: Variant in creators(switch_name, weapon_id):
		var key: String = DictRead.as_string(creator)
		for call: Variant in _by_creator.get(key, []):
			if _create(DictRead.as_dict(call), at, towards) >= 0:
				made += 1
	return made


func _create(call: Dictionary, at: Vector3i, towards: Vector3i) -> int:
	var class_id: int = DictRead.as_int(call["class"])
	var life: int = DictRead.as_int(call["life"]) if call["life"] != null \
		else DEFAULT_LIFE
	var velocity: Vector3i = _velocity(at, towards, life)
	var fields: Dictionary = {
		"kind": DictRead.as_int(call["kind"]) if call["kind"] != null else 0,
		"class_id": class_id,
		"life": life,
		"x": at.x, "y": at.y, "z": at.z,
		"vx": velocity.x, "vy": velocity.y, "vz": velocity.z,
	}
	# A computed kind is the two-way choice of docs/28 section 7.7; without the
	# creator we cannot know which side it took, so the effect is not made at
	# all rather than made as kind 0.
	if call["kind"] == null:
		return -1
	if class_id >= 2:
		var sprite: Dictionary = DictRead.as_dict(
			DictRead.as_dict(_document.get("sprites", {}))
				.get(DictRead.as_string(call["site"]), {}))
		fields["rot_x"] = _sprite_field(sprite, "row", DEFAULT_ROW)
		fields["rot_y"] = _sprite_field(sprite, "col", DEFAULT_COLUMN)
		fields["aux"] = _sprite_field(sprite, "size", DEFAULT_SIZE)
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
static func muzzle_point(x: int, y: int, h: int) -> Vector3i:
	return Vector3i(x * WorldSpace.WORLD_UNITS_PER_FIELD,
		y * WorldSpace.WORLD_UNITS_PER_FIELD, h + MUZZLE_HEIGHT)
