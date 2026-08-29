class_name World
extends RefCounted

## The only simulation object `game` holds.
##
## `core` has no scene tree, no rendering, no audio, no filesystem and no engine
## singleton (docs/92 section 10.4).  It also never hands out a live reference:
## every view is a freshly built `Dictionary` of scalars, and every packed array
## that leaves is a `duplicate()`.  `godot/tests/test_isolation.gd` enforces
## both -- the first by mutating a snapshot and re-hashing, the second by
## reading every file under `core/` as text and failing on a forbidden symbol.

var resource: MapResource = null
var state: MapState = null
var rng: IncRandom = null
var compat_flags: PackedStringArray = PackedStringArray()

var _units: Dictionary = {}
var _ctrlmap: CtrlMapTable = null
## Camera state carried by the last loaded save.  Deliberately outside the
## canonical hash -- where the player was looking is not simulation state.
var _camera: Dictionary = {}
var _unit_types: UnitTypeTable = null
var _weapons: WeaponTable = null
## docs/25 section 3 -- whose turn it is, and the counter. Outside [MapState]
## because it is not cell state; inside the canonical hash because it is
## simulation state, which docs/92 section 7.3 foresaw when it recorded that
## "campaign and turn phase have no representation yet".
var turn: TurnState = null


static func create(map_document: Dictionary, balance: Dictionary,
		rng_seed: float = 0.0) -> World:
	var world: World = World.new()
	world.resource = MapResource.from_document(map_document)
	world.state = MapState.from_resource(world.resource)
	world._ctrlmap = CtrlMapTable.from_rows(DictRead.as_array(balance["ctrlmap"]))
	world._unit_types = UnitTypeTable.from_rows(DictRead.as_array(balance["units"]))
	# Required, not optional: an empty weapon table would silently disable the
	# refresh's cooling and its weapon-mode revert, which is the "a fallback
	# where an error belongs" shape this project keeps finding.
	world._weapons = WeaponTable.from_rows(DictRead.as_array(balance["weapons"]))
	world.turn = TurnState.create()
	world.rng = IncRandom.new()
	# docs/92 section 10.3 item 2: seed explicitly even though the slice
	# consumes no draws, so the state shape later traces compare is established.
	world.rng.randomize_seed(rng_seed)

	var records: Array = DictRead.as_array(map_document["units"])
	for record: Variant in records:
		var view: Dictionary = record
		var unit: UnitState = UnitState.from_document(view)
		if not unit.is_placed():
			continue
		world._units[unit.slot] = unit
	return world


func ctrlmap() -> CtrlMapTable:
	return _ctrlmap


func unit_types() -> UnitTypeTable:
	return _unit_types


func weapons() -> WeaponTable:
	return _weapons


func unit_slots() -> PackedInt32Array:
	var slots: Array[int] = []
	for slot: Variant in _units:
		slots.append(DictRead.as_int(slot))
	slots.sort()
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(slots.size())
	for i: int in range(slots.size()):
		out[i] = slots[i]
	return out


func has_unit(slot: int) -> bool:
	return _units.has(slot)


## A fresh dictionary of scalars, never the [UnitState] itself.
func unit_view(slot: int) -> Dictionary:
	if not _units.has(slot):
		return {}
	var unit: UnitState = _units[slot]
	return unit.view()


func cell_view(x: int, y: int) -> Dictionary:
	if not state.in_bounds(x, y):
		return {}
	var index: int = state.index_of(x, y)
	return {
		"index": index,
		"x": x,
		"y": y,
		"height": state.height_at(index),
		"field_type": state.field_type_at(index),
		"field_type_name": _ctrlmap.type_name(state.field_type_at(index)),
		"action_point": state.action_point_at(index),
		"unit": state.unit_at(index),
		"obstacle": state.obstacle_at(index),
		"delay": _ctrlmap.delay(state.field_type_at(index)),
		"enterable": _ctrlmap.is_enterable(state.field_type_at(index)),
	}


## Copies of every mutable array, for rendering.  Mutating what comes back
## cannot reach the simulation.
func terrain_snapshot() -> Dictionary:
	return state.snapshot()


func submit_move_query(command: MoveQueryCommand) -> MoveMapResult:
	if not _units.has(command.unit_slot):
		# Sized, not empty: the result declares the map's dimensions, and a
		# caller that trusts them -- `game/highlight.gd` walks width x height --
		# would index past the end of a zero-length array for every cell.
		var overlay: PackedByteArray = PackedByteArray()
		overlay.resize(state.cell_count())
		var mp_left: PackedInt32Array = PackedInt32Array()
		mp_left.resize(state.cell_count())
		return MoveMapResult.create(state.width, state.height, 0,
			overlay, mp_left, false, 0)
	var unit: UnitState = _units[command.unit_slot]
	# docs/23:652 -- the fill spends the unit's current `+0x15`, and asks
	# `0x00475160` for the allowance the ladder step charges.  That allowance is
	# **computed** here rather than approximated by `mp_max`: the formula is in
	# [Allowance] and is pinned by 37 native calls into the live engine.
	return MoveMap.build(state, _units, _unit_types, _ctrlmap,
		command.unit_slot, command.pass_friendlies, unit.mp,
		movement_allowance(command.unit_slot))


## `aGetMovePoints` (`0x00475160`) for one slot -- docs/10 section 5.5.
func movement_allowance(slot: int,
		ai_level: int = Allowance.DEFAULT_AI_LEVEL) -> int:
	if not _units.has(slot):
		return 0
	var unit: UnitState = _units[slot]
	return Allowance.for_unit(unit, _unit_types, _units, ai_level)


## `aWalkMoveMap` (`0x004305E0`) over a move map this world produced.
##
## The result is a value, not a change: `core` owns no overlay, and the
## engine's own path marks live in the cells it sweeps afterwards.
func walk_path(result: MoveMapResult, slot: int, tx: int,
		ty: int) -> Dictionary:
	if not _units.has(slot):
		return {"ok": false, "steps": 0, "blocked": 0,
			"path": PackedInt32Array(), "state": PackedByteArray(),
			"reason": "no such unit"}
	var unit: UnitState = _units[slot]
	return WalkMap.path(state, _units, _ctrlmap, result, unit.x, unit.y,
		tx, ty)


func canonical_hash() -> PackedByteArray:
	return CanonicalHash.compute(state, _units, turn, rng, compat_flags)


func canonical_hash_hex() -> String:
	return CanonicalHash.to_hex(canonical_hash())


func save(camera: Dictionary) -> PackedByteArray:
	return SaveCodec.encode(resource, state, _units, turn, rng, compat_flags,
		camera)


## Returns the [enum SaveCodec.Result] code; the world is only changed on `OK`.
##
## The camera is stored beside the simulation and **excluded** from the
## canonical hash, so it comes back through [method restored_camera] rather
## than being applied here: `core` owns no camera, and `game` is what puts it
## back.  Discarding it entirely, which this used to do, made the field a
## write-only decoration.
func load_save(data: PackedByteArray) -> int:
	var decoded: Dictionary = SaveCodec.decode(data, resource)
	var code: int = DictRead.as_int(decoded["result"])
	if code != SaveCodec.Result.OK:
		return code
	state = decoded["state"]
	_units = decoded["units"]
	turn = decoded["turn"]
	rng = decoded["rng"]
	compat_flags = decoded["compat_flags"]
	_camera = DictRead.as_dict(decoded["camera"])
	return code


## The camera state the last successful [method load_save] read, or an empty
## dictionary when nothing has been loaded.
func restored_camera() -> Dictionary:
	return _camera.duplicate(true)
