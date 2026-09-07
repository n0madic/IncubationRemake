class_name SaveCodec
extends RefCounted

## The remake's save format -- its own, and never a superset of the original's.
##
## docs/92 section 7.3 decides this: writing `.sav` would be a compatibility
## promise that permanently pins the state model to another game's, with a fixed
## slot 32, no field for the camera and a whole `.lev` embedded in every file.
## Reading original saves is a one-way import that constrains nothing and is
## deferred, not rejected.
##
## The container is a small binary header followed by the mutable map state and
## the unit records, with a SHA-256 of everything after the digest field.  It is
## deliberately not a Godot `Resource`: `.res` couples the on-disk contract to
## Godot's serialisation, script paths and class layout.
##
## Layout:
## [codeblock]
##   0   4   magic "INCS"
##   4   4   schema version
##   8  32   sha256 of everything from byte 44 on
##  40   4   payload length
##  44  32   the authored map's hash
##  76   ..  the JSON header (width, height, mission, rng, camera, scenery, flags)
##      ..   the MapState bytes
##      ..   the unit records
## [/codeblock]

const MAGIC: String = "INCS"
## Raised to 4 by the second slice (the header carries the [TurnState] and the
## canonical hash covers it), and to 5 when [UnitState] gained the columns
## combat reads -- armour, the absorber charges, both orders, the AI group and
## the six skills; and to 6 when the mission script arrived -- the C runtime's
## generator, which `InsertUnit` draws from, and the three unit columns a script
## writes; and to 7 when the kill award arrived -- the kill counter `+0x53`
## joined the record; and to **8** when the cell placers of docs/42 section 9.1
## went in -- [MapState] gained the glow's `+0x12` and `+0x13`, which makes the
## serialised block two columns longer, and an authored mine now detonates
## under a walker, which changes what a resumed game does; and to **9** with
## the campaign slice, when [TurnState] gained the three per-mission counters
## the scoreboard reads -- `mission_kills`, `mission_lost` and
## `mission_lost_to_enemy` -- so the debriefing stops summing survivors, a sum
## that lost every kill made by a unit which later died. Those three are in
## the save and **out** of the canonical hash, so D7 holds; and to **10** when
## the full derived-stat recompute `0x004759E0` went in -- [CampaignState]
## gained `recruit_ammo`, and a squad deployed by an older build reached the
## map with an empty magazine, so a save from one is not a state this build
## can resume into a playable mission; and to **11** when the scenery's
## poses joined the header (2026-09-06, docs/42 section 8.3) -- the joint
## words the door's family writes and the cells whose objects a crush wall
## or a footbridge freed, which the original keeps by embedding the
## special-object records in its `.sav` and which a save without them showed
## authored again on a load. Presentation, beside the camera and outside the
## canonical hash like it. An older save is
## refused **by name** rather than misread, which is the whole point of the
## field.
const SCHEMA_VERSION: int = 11
const HEADER_SIZE: int = 76
const DIGEST_SIZE: int = 32

enum Result {
	OK,
	TRUNCATED,
	BAD_SCHEMA,
	MAP_MISMATCH,
	BAD_DIGEST,
}


static func result_name(code: int) -> String:
	match code:
		Result.OK: return "OK"
		Result.TRUNCATED: return "TRUNCATED"
		Result.BAD_SCHEMA: return "BAD_SCHEMA"
		Result.MAP_MISMATCH: return "MAP_MISMATCH"
		Result.BAD_DIGEST: return "BAD_DIGEST"
	return "UNKNOWN"


static func encode(res: MapResource, state: MapState, units: Dictionary,
		turn: TurnState, control: GameControl, rng: IncRandom,
		crand: CRandom, compat_flags: PackedStringArray,
		camera: Dictionary, scenery: Dictionary = {}) -> PackedByteArray:
	var slots: Array[int] = []
	for slot: Variant in units:
		slots.append(DictRead.as_int(slot))
	slots.sort()
	var unit_records: Array = []
	for slot: int in slots:
		var unit: UnitState = units[slot]
		unit_records.append(unit.view())

	var header: Dictionary = {
		"schema": SCHEMA_VERSION,
		"mission": res.mission,
		"width": state.width,
		"height": state.height,
		"rng": rng.state(),
		# The second generator, stored beside the first. docs/20 section 7.4:
		# `InsertUnit` draws from the C runtime's, and a save that dropped it
		# would come back a different mission the next time one fires.
		"crand": crand.state(),
		"turn": turn.view(),
		"game_control": Array(control.values()),
		"compat_flags": _sorted_strings(compat_flags),
		# Presentation, stored beside the simulation and excluded from its hash:
		# where the player was looking, and what the scenery's objects were
		# turned to ([method Scenery.pose_record]).
		"camera": camera,
		"scenery": scenery,
		"units": unit_records,
	}
	var header_bytes: PackedByteArray = JSON.stringify(header).to_utf8_buffer()
	var body: PackedByteArray = PackedByteArray()
	body.append_array(res.authored_hash())
	body.append_array(PackedInt32Array([header_bytes.size()]).to_byte_array())
	body.append_array(header_bytes)
	body.append_array(state.to_bytes())

	var out: PackedByteArray = PackedByteArray()
	out.append_array(MAGIC.to_ascii_buffer())
	out.append_array(PackedInt32Array([SCHEMA_VERSION]).to_byte_array())
	out.append_array(_digest(body))
	out.append_array(PackedInt32Array([body.size()]).to_byte_array())
	out.append_array(body)
	return out


## Returns `{"result": Result, "state": MapState, "units": Dictionary,
## "turn": TurnState, "game_control": GameControl, "rng": IncRandom,
## "camera": Dictionary, "scenery": Dictionary,
## "compat_flags": PackedStringArray}`.
## Everything but `result` is absent unless the result is `OK`.
static func decode(data: PackedByteArray, res: MapResource) -> Dictionary:
	if data.size() < HEADER_SIZE - 32:
		return {"result": Result.TRUNCATED}
	if data.slice(0, 4).get_string_from_ascii() != MAGIC:
		return {"result": Result.BAD_SCHEMA}
	var version: int = data.slice(4, 8).to_int32_array()[0]
	if version != SCHEMA_VERSION:
		return {"result": Result.BAD_SCHEMA}
	var stored: PackedByteArray = data.slice(8, 8 + DIGEST_SIZE)
	var length: int = data.slice(40, 44).to_int32_array()[0]
	var body: PackedByteArray = data.slice(44)
	if body.size() != length:
		return {"result": Result.TRUNCATED}
	if _digest(body) != stored:
		return {"result": Result.BAD_DIGEST}
	if body.size() < DIGEST_SIZE + 4:
		return {"result": Result.TRUNCATED}
	if body.slice(0, DIGEST_SIZE) != res.authored_hash():
		return {"result": Result.MAP_MISMATCH}

	var header_size: int = body.slice(DIGEST_SIZE, DIGEST_SIZE + 4) \
		.to_int32_array()[0]
	var at: int = DIGEST_SIZE + 4
	if body.size() < at + header_size:
		return {"result": Result.TRUNCATED}
	var header_bytes: PackedByteArray = body.slice(at, at + header_size)
	at += header_size
	var parsed: Variant = JSON.parse_string(header_bytes.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"result": Result.BAD_SCHEMA}
	var header: Dictionary = parsed

	var state: MapState = MapState.from_resource(res)
	if not state.load_bytes(body.slice(at)):
		return {"result": Result.TRUNCATED}

	var units: Dictionary = {}
	var records: Array = DictRead.as_array(header["units"])
	for record: Variant in records:
		# One decode, not a second copy of [method UnitState.view]: the two are
		# a pair, and a field added to one without the other is a field a save
		# silently drops.
		var unit: UnitState = UnitState.from_view(DictRead.as_dict(record))
		units[unit.slot] = unit

	var flags: PackedStringArray = PackedStringArray()
	var stored_flags: Array = DictRead.as_array(header["compat_flags"])
	for flag: Variant in stored_flags:
		flags.append(DictRead.as_string(flag))

	return {
		"result": Result.OK,
		"state": state,
		"units": units,
		"rng": IncRandom.from_state(DictRead.as_dict(header["rng"])),
		"crand": CRandom.from_state(DictRead.as_dict(header["crand"])),
		"turn": _turn_from(DictRead.as_dict(header["turn"])),
		"game_control": GameControl.from_array(
			_int_array(DictRead.as_array(header["game_control"]))),
		"camera": DictRead.as_dict(header["camera"]),
		"scenery": DictRead.as_dict(header["scenery"]),
		"compat_flags": flags,
	}


## Every field of [TurnState] the header carries, narrowed at the boundary.
##
## `JSON.parse_string` gives a `float` for every number, so the typed arrays are
## rebuilt here rather than assigned -- the same rule the cache loader follows,
## and for the same reason: a hash over the parsed form would be stable and
## wrong.
static func _turn_from(view: Dictionary) -> TurnState:
	return TurnState.from_view(view)


static func _int_array(values: Array) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(values.size())
	for i: int in range(values.size()):
		out[i] = DictRead.as_int(values[i])
	return out


static func _digest(body: PackedByteArray) -> PackedByteArray:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	# `update()` rejects an empty array and prints an engine error.  A save
	# whose length field says zero is a truncated file, and refusing it is a
	# clean `BAD_DIGEST` -- it should not also spray the log on the way out.
	# `canonical_hash.gd` and `unit_state.gd` work around the same rule.
	if not body.is_empty():
		ctx.update(body)
	return ctx.finish()


static func _sorted_strings(values: PackedStringArray) -> Array:
	var copy: PackedStringArray = values.duplicate()
	copy.sort()
	var out: Array = []
	for value: String in copy:
		out.append(value)
	return out
