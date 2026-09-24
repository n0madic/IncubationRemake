class_name MapState
extends RefCounted

## The mutable half of the grid (docs/92 section 7.2), struct of arrays.
##
## One `Packed*Array` per documented byte offset, each `width * height` long:
## height `+0x01`, field type `+0x0D`, the action point `+0x0B`, the unit link
## `+0x07` and the **six** effect bytes `+0x0E`..`+0x13`.
##
## It was four (`+0x0E`..`+0x11`) until 2026-09-03 (docs/97 section 37): the
## glow `SetGroundFire` lays lives in `+0x11`, `+0x12` and `+0x13`, so a model
## that stopped at `+0x11` could carry its slot index and neither its phase nor
## the state byte that says it is there at all.
##
## **The transient obstacle is `+0x10`, which is effect slot 2 -- one byte, not
## two.**  It used to be modelled twice: a synthesised `_obstacle` array filled
## with 255 *and* `_effect[2]`, which the converter fills from the same offset.
## The two then drifted, because `set_obstacle` wrote only one of them: a cell
## could report a mine and a 255 for one documented field, and the canonical
## hash committed both. `obstacle_at` and `set_obstacle` are now named views on
## effect slot 2.
##
## Its three branches -- fire, mine and shield -- have zero corpus coverage:
## `cell[+0x10]` is 255 in all 184162 shipped cells because it is created during
## play.  The native capture reaches them by writing the byte in the live
## process (`tests/fixtures/movemap/README.md`).
##
## docs/23 section 7.1 amendment to docs/92 section 7.2: `+0x0F` and `+0x11` are
## **slot indices** into the runtime object array while `+0x0E` and `+0x10` are
## values.  All four are carried through and none of them is interpreted here.

const OBSTACLE_NONE: int = 255
const OBSTACLE_FIRE: int = 1
const OBSTACLE_MINE: int = 2
const OBSTACLE_SHIELD: int = 3
## `cell[+0x13]` while a `SetGroundFire` glow stands on the cell.
const DECAL_GLOW: int = 4
const DECAL_NONE: int = 255
## `aCreateSpecialObject` `0x004069C0` scans ids 0..79 for a free slot.
const SPECIAL_OBJECT_SLOTS: int = 80
const NO_OBJECT: int = 255
## The object state byte `+0x40` of a **static** object -- drawn, never
## animated (docs/42 section 9.1): what the victory-point marker placer
## `0x00431E30` pushes (`push 5` at `0x00431F45`).
const OBJECT_STATIC: int = 5
## The VictoryPoints band of the action point, `cmp al, 0x50` / `cmp al, 0x59`
## at `0x00431E59` / `0x00431E61` (docs/10 section 4.6, docs/26 section 6.1).
const VICTORY_POINT_FIRST: int = 0x50
const VICTORY_POINT_LAST: int = 0x59
## The marker the placer stands on a victory-point cell, by `action point -
## 0x50` through the jump table at `0x00432000`: `A_MK_0A`..`A_MK_4A` for
## 80..84 and `A_MK_0B`..`A_MK_4B` for 85..89 -- the letter is the band and
## the digit the claiming player, 0 for nobody (docs/42 section 9.3).
const VICTORY_MARKER_MODELS: Array[String] = ["A_MK_0A.3DI", "A_MK_1A.3DI",
	"A_MK_2A.3DI", "A_MK_3A.3DI", "A_MK_4A.3DI", "A_MK_0B.3DI", "A_MK_1B.3DI",
	"A_MK_2B.3DI", "A_MK_3B.3DI", "A_MK_4B.3DI"]
const NO_UNIT: int = -1
## `cmp eax, 0x8C` / `jg` after `0x00407410` at the top of `GrowingLand`
## `0x0046FF20` and `FallingSpores`' drop `0x00414550`: neither inserts once
## the special-object table holds **more** than this many records.
const LAND_OBJECTS_GROWTH_MAX: int = 140
## No record in [method find_land_object]'s answer.
const NO_LAND_OBJECT: int = -1
const EFFECT_SLOTS: int = 6
## Which effect slot is which byte.  `+0x0E` is a countdown, `+0x0F` and
## `+0x11` are slot indices into the 80-entry special-object array, `+0x10` is
## the transient obstacle the rules read, and `+0x12`/`+0x13` are the glow's
## phase and state (docs/42 section 9.1).
const TIMER_SLOT: int = 0
const OBJECT_SLOT: int = 1
const OBSTACLE_SLOT: int = 2
const DECAL_OBJECT_SLOT: int = 3
const DECAL_PHASE_SLOT: int = 4
const DECAL_STATE_SLOT: int = 5

var width: int = 0
var height: int = 0

var _height: PackedInt32Array = PackedInt32Array()
var _field_type: PackedByteArray = PackedByteArray()
var _action_point: PackedByteArray = PackedByteArray()
var _unit: PackedInt32Array = PackedInt32Array()
var _effect: Array[PackedByteArray] = []
var _objects: PackedByteArray = PackedByteArray()
## `cell[+0x14]`: the slot of the victory-point marker standing on the cell,
## `0xFF` on every other cell.  **Derived**, like [member _objects]: the placer
## `0x00431E30` rewrites it on every load and after every capture, so the
## shipped byte (docs/10 section 4.2) is the editor's own run of the same
## routine and is neither read, hashed nor saved.
var _marker_slot: PackedByteArray = PackedByteArray()
var _special_models: PackedStringArray = PackedStringArray()
## The special-object table `[0x004FA80C]`, counted by `[0x004FA7B4]` --
## docs/42 section 8.2. `aLoadFile` reads the `.lev`'s records and their count
## straight into it (`0x00407C94`); `aInsertLandObject` `0x00404E30` appends
## and `aDeleteLand` `0x00406C30` removes. Rules read it -- the search
## `0x00406F20` and the growth cap -- so unlike [member _objects] it is state:
## hashed, saved and carried by the journal.
##
## One record per object, in table order: `{"id", "model", "x", "y", "z"}`.
## `id` is the remake's own, a serial the picture keys its node by; the table
## itself carries no identity beyond the position.
var _land_objects: Array[Dictionary] = []
var _next_land_id: int = 0

## Write tracking for `EventJournal`, off by default.
##
## The picture's mirror is advanced by deltas, and a delta's cell half is
## whichever cells a command wrote.  Every write goes through a setter here --
## there is no path into the arrays from outside this file -- so the set is
## exact rather than a diff of the whole map.
var _tracking: bool = false
var _dirty: Dictionary[int, bool] = {}
## A whole-map write ([method load_bytes]); cheaper to flag than to enumerate.
var _dirty_all: bool = false
var _objects_dirty: bool = false
var _land_dirty: bool = false


static func from_resource(res: MapResource) -> MapState:
	var state: MapState = MapState.new()
	state.width = res.width
	state.height = res.height
	state._height = res.heights()
	state._field_type = res.field_types()
	state._action_point = res.action_points()
	state._unit = res.units()
	state._effect = []
	for slot: int in range(EFFECT_SLOTS):
		state._effect.append(res.effects(slot))
	state.rebuild_objects()
	for record: Dictionary in res.special_objects():
		var _id: int = state.insert_land_object(
			DictRead.as_string(record["model"]), DictRead.as_int(record["x"]),
			DictRead.as_int(record["y"]), DictRead.as_int(record["z"]))
	state._land_dirty = false
	return state


func cell_count() -> int:
	return width * height


func index_of(x: int, y: int) -> int:
	return y * width + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func height_at(index: int) -> int:
	return _height[index]


func set_height(index: int, value: int) -> void:
	_height[index] = value
	if _tracking:
		_dirty[index] = true


func field_type_at(index: int) -> int:
	return _field_type[index]


func set_field_type(index: int, value: int) -> void:
	_field_type[index] = value & 0xFF
	if _tracking:
		_dirty[index] = true


func action_point_at(index: int) -> int:
	return _action_point[index]


func set_action_point(index: int, value: int) -> void:
	_action_point[index] = value & 0xFF
	if _tracking:
		_dirty[index] = true


func unit_at(index: int) -> int:
	return _unit[index]


func set_unit(index: int, slot: int) -> void:
	_unit[index] = slot
	if _tracking:
		_dirty[index] = true


func effect_at(slot: int, index: int) -> int:
	return _effect[slot][index]


func set_effect(slot: int, index: int, value: int) -> void:
	_effect[slot][index] = value & 0xFF
	if _tracking:
		_dirty[index] = true


## `cell[+0x10]` under its own name.  The same storage as effect slot 2.
func obstacle_at(index: int) -> int:
	return _effect[OBSTACLE_SLOT][index]


func set_obstacle(index: int, value: int) -> void:
	set_effect(OBSTACLE_SLOT, index, value)


## The 80 special-object slots, `0xFF` where one is free.  **Derived**: the
## engine's `aBuild3DSpecialObjects` rebuilds it from the same cell bytes after
## every load, so it is neither hashed nor saved -- [method rebuild_objects] is
## what a loader calls instead.
func objects() -> PackedByteArray:
	return _objects.duplicate()


func object_state(object_id: int) -> int:
	return _objects[object_id]


func set_object_state(object_id: int, value: int) -> void:
	_objects[object_id] = value & 0xFF
	if _tracking:
		_objects_dirty = true


## The placer model names the mission's world set carries.  Empty means "no
## world set behind this map", which skips the gate; a real map must set it, or
## a `SetGroundFire` outside `World_D00` will appear to work (docs/97 §37).
func special_models() -> PackedStringArray:
	return _special_models.duplicate()


func set_special_models(names: PackedStringArray) -> void:
	_special_models = names.duplicate()


## The special-object table, in table order, as independent copies.
func land_objects() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for record: Dictionary in _land_objects:
		out.append(record.duplicate())
	return out


## `[0x004FA7B4]`, the count `0x00407410` answers.
func land_object_count() -> int:
	return _land_objects.size()


## The record with this id, a copy, or `{}`.
func land_object(id: int) -> Dictionary:
	for record: Dictionary in _land_objects:
		if DictRead.as_int(record["id"]) == id:
			return record.duplicate()
	return {}


## `aInsertLandObject` `0x00404E30`: append one record. Answers its id.
func insert_land_object(model: String, x: int, y: int, z: int) -> int:
	var id: int = _next_land_id
	_next_land_id += 1
	_land_objects.append({"id": id, "model": model, "x": x, "y": y, "z": z})
	_land_dirty = true
	return id


## `aDeleteLand` `0x00406C30`: take one record out, keeping the others' order.
func delete_land_object(id: int) -> bool:
	for i: int in range(_land_objects.size()):
		if DictRead.as_int(_land_objects[i]["id"]) == id:
			_land_objects.remove_at(i)
			_land_dirty = true
			return true
	return false


## `0x00406F20`: the record inside the box `half` around `at` -- strictly,
## `|d| < half` on each axis -- with the smallest `|dx| + |dy| + |dz|`, the
## first in table order on a tie. Answers its id or [constant NO_LAND_OBJECT].
func find_land_object(at: Vector3i, half: Vector3i) -> int:
	var best: int = NO_LAND_OBJECT
	var best_sum: int = 0
	for record: Dictionary in _land_objects:
		var dx: int = absi(DictRead.as_int(record["x"]) - at.x)
		var dy: int = absi(DictRead.as_int(record["y"]) - at.y)
		var dz: int = absi(DictRead.as_int(record["z"]) - at.z)
		if dx >= half.x or dy >= half.y or dz >= half.z:
			continue
		var sum: int = dx + dy + dz
		if best == NO_LAND_OBJECT or sum < best_sum:
			best = DictRead.as_int(record["id"])
			best_sum = sum
	return best


## Replace the table wholesale -- a load, a delta, a migrated save.
func set_land_objects(records: Array, next_id: int) -> void:
	_land_objects = []
	for entry: Variant in records:
		var record: Dictionary = DictRead.as_dict(entry)
		_land_objects.append({"id": DictRead.as_int(record["id"]),
			"model": DictRead.as_string(record["model"]),
			"x": DictRead.as_int(record["x"]), "y": DictRead.as_int(record["y"]),
			"z": DictRead.as_int(record["z"])})
	_next_land_id = next_id
	_land_dirty = true


func next_land_id() -> int:
	return _next_land_id


## Start or stop recording which cells are written.  `EventJournal` owns this;
## a world with no journal pays one boolean test per setter.
func track_writes(on: bool) -> void:
	_tracking = on
	_dirty.clear()
	_dirty_all = false
	_objects_dirty = false
	_land_dirty = false


## The cells written since the last call, and whether the object array moved.
## Clears the record.  The indices are sorted so a delta is comparable.
func take_dirty() -> Dictionary:
	var cells: PackedInt32Array = PackedInt32Array()
	if _dirty_all:
		cells.resize(cell_count())
		for i: int in range(cell_count()):
			cells[i] = i
	else:
		for index: int in _dirty:
			cells.append(index)
		cells.sort()
	var moved: bool = _objects_dirty
	var land: bool = _land_dirty
	_dirty.clear()
	_dirty_all = false
	_objects_dirty = false
	_land_dirty = false
	return {"cells": cells, "objects": moved, "land": land}


## Every documented byte of one cell, for a delta row.
func cell_record(index: int) -> Dictionary:
	var effects: PackedByteArray = PackedByteArray()
	effects.resize(EFFECT_SLOTS)
	for slot: int in range(EFFECT_SLOTS):
		effects[slot] = _effect[slot][index]
	return {
		"height": _height[index],
		"field_type": _field_type[index],
		"action_point": _action_point[index],
		"unit": _unit[index],
		"effect": effects,
	}


## Write one cell back from a [method cell_record] row.
func apply_cell_record(index: int, record: Dictionary) -> void:
	set_height(index, DictRead.as_int(record["height"]))
	set_field_type(index, DictRead.as_int(record["field_type"]))
	set_action_point(index, DictRead.as_int(record["action_point"]))
	set_unit(index, DictRead.as_int(record["unit"]))
	var effects: PackedByteArray = DictRead.to_bytes(record["effect"])
	for slot: int in range(EFFECT_SLOTS):
		set_effect(slot, index, effects[slot])


## Replace the derived object array wholesale, for a delta that carries it.
func set_objects(values: PackedByteArray) -> void:
	_objects = values.duplicate()
	if _tracking:
		_objects_dirty = true


## An independent copy: every array duplicated, tracking off.
##
## The mirror the picture reads is one of these, so an aliased array here
## would make the two worlds share storage and the lag disappear
## (`tests/test_isolation.gd` is the standing check for that class of bug).
func clone() -> MapState:
	var out: MapState = MapState.new()
	out.width = width
	out.height = height
	out._height = _height.duplicate()
	out._field_type = _field_type.duplicate()
	out._action_point = _action_point.duplicate()
	out._unit = _unit.duplicate()
	out._effect = []
	for slot: PackedByteArray in _effect:
		out._effect.append(slot.duplicate())
	out._objects = _objects.duplicate()
	out._marker_slot = _marker_slot.duplicate()
	out._special_models = _special_models.duplicate()
	for record: Dictionary in _land_objects:
		out._land_objects.append(record.duplicate())
	out._next_land_id = _next_land_id
	return out


## `aBuild3DSpecialObjects` `0x004079D0`, as occupancy only: every cell whose
## `+0x10` is 1, 2 or 3 owns the slot at `+0x0F`, and every cell whose `+0x13`
## is 4 owns the one at `+0x11`.  Then, as the routine does at `0x00407A86`
## once the cells are walked, the victory-point markers take the first free
## slots ([method rebuild_markers]).
func rebuild_objects() -> void:
	if _tracking:
		_objects_dirty = true
	_objects = PackedByteArray()
	_objects.resize(SPECIAL_OBJECT_SLOTS)
	_objects.fill(NO_OBJECT)
	_marker_slot = PackedByteArray()
	_marker_slot.resize(cell_count())
	_marker_slot.fill(NO_OBJECT)
	for i: int in range(cell_count()):
		var state: int = _effect[OBSTACLE_SLOT][i]
		var oid: int = _effect[OBJECT_SLOT][i]
		if (state == OBSTACLE_FIRE or state == OBSTACLE_MINE \
				or state == OBSTACLE_SHIELD) \
				and oid >= 0 and oid < SPECIAL_OBJECT_SLOTS:
			_objects[oid] = state
		if _effect[DECAL_STATE_SLOT][i] == DECAL_GLOW:
			oid = _effect[DECAL_OBJECT_SLOT][i]
			if oid >= 0 and oid < SPECIAL_OBJECT_SLOTS:
				_objects[oid] = DECAL_GLOW
	rebuild_markers()


## The victory-point marker placer `0x00431E30` (`aCtrlMap.cpp`), called by
## `aBuild3DSpecialObjects` after the cells' own objects and by `aExecuteMove`
## `0x0046E9E7` after a walk that may have claimed one.
##
## Cell by cell, in map order: a cell whose action point is in 80..89 first
## frees the object its `+0x14` names (`aDeleteSpecialObject`, `0x00431E8D`)
## and then takes the **first free slot** for a static object of the model the
## action point selects, writing the slot back into `+0x14` (`0x00431F74`);
## every other cell gets `0xFF` there (`0x00431F79`).  Freeing before placing
## is what keeps a claimed marker in the slot it had, and what lets a capture
## change the letter's colour without moving anything else in the array.
##
## Where the object stands is not modelled here: `aGetSymbolObjectPtr` of the
## cell's land link, the same point every other placer positions around
## ([method CellObjects.object_position]'s origin).  The picture derives it
## from the action-point plane alone, which is why the mirror needs nothing
## of this.
func rebuild_markers() -> void:
	if _marker_slot.size() != cell_count():
		_marker_slot = PackedByteArray()
		_marker_slot.resize(cell_count())
		_marker_slot.fill(NO_OBJECT)
	for i: int in range(cell_count()):
		if not is_victory_point(_action_point[i]):
			_marker_slot[i] = NO_OBJECT
			continue
		var held: int = _marker_slot[i]
		if held != NO_OBJECT:
			_objects[held] = NO_OBJECT
		_marker_slot[i] = NO_OBJECT
		for slot: int in range(SPECIAL_OBJECT_SLOTS):
			if _objects[slot] == NO_OBJECT:
				_objects[slot] = OBJECT_STATIC
				_marker_slot[i] = slot
				break
	if _tracking:
		_objects_dirty = true


## `cmp al, 0x50` / `cmp al, 0x59` -- whether an action point is in the
## VictoryPoints band.
static func is_victory_point(action_point: int) -> bool:
	return action_point >= VICTORY_POINT_FIRST \
		and action_point <= VICTORY_POINT_LAST


## The marker model a victory-point cell carries, or `""` for any other cell.
static func victory_marker_model(action_point: int) -> String:
	if not is_victory_point(action_point):
		return ""
	return VICTORY_MARKER_MODELS[action_point - VICTORY_POINT_FIRST]


## `cell[+0x14]` after the placer: the marker's slot, or [constant NO_OBJECT].
func marker_slot_at(index: int) -> int:
	return _marker_slot[index]


## A copy of every array, for rendering.  `game` gets its own storage: a
## `Packed*Array` returned from a function aliases the original in Godot 4.7.
func snapshot() -> Dictionary:
	var effects: Array[PackedByteArray] = []
	for slot: PackedByteArray in _effect:
		effects.append(slot.duplicate())
	return {
		"width": width,
		"height": height,
		"height_map": _height.duplicate(),
		"field_type": _field_type.duplicate(),
		"action_point": _action_point.duplicate(),
		"unit": _unit.duplicate(),
		"effect": effects,
		# The same bytes as `effect[2]`, under the name the renderer uses.
		"obstacle": _effect[OBSTACLE_SLOT].duplicate(),
	}


func hash_into(ctx: HashingContext) -> void:
	ctx.update(_height.to_byte_array())
	ctx.update(_field_type)
	ctx.update(_action_point)
	ctx.update(_unit.to_byte_array())
	for slot: PackedByteArray in _effect:
		ctx.update(slot)
	var land: PackedInt32Array = PackedInt32Array([_next_land_id,
		_land_objects.size()])
	for record: Dictionary in _land_objects:
		land.append_array(PackedInt32Array([DictRead.as_int(record["id"]),
			DictRead.as_int(record["x"]), DictRead.as_int(record["y"]),
			DictRead.as_int(record["z"])]))
	ctx.update(land.to_byte_array())
	for record: Dictionary in _land_objects:
		ctx.update(DictRead.as_string(record["model"]).to_utf8_buffer())
		ctx.update(PackedByteArray([0]))


func to_bytes() -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	out.append_array(_height.to_byte_array())
	out.append_array(_field_type)
	out.append_array(_action_point)
	out.append_array(_unit.to_byte_array())
	for slot: PackedByteArray in _effect:
		out.append_array(slot)
	return out


func byte_size() -> int:
	var n: int = cell_count()
	return n * 4 + n + n + n * 4 + n * EFFECT_SLOTS


func load_bytes(data: PackedByteArray) -> bool:
	if data.size() != byte_size():
		return false
	var n: int = cell_count()
	var at: int = 0
	_height = data.slice(at, at + n * 4).to_int32_array()
	at += n * 4
	_field_type = data.slice(at, at + n)
	at += n
	_action_point = data.slice(at, at + n)
	at += n
	_unit = data.slice(at, at + n * 4).to_int32_array()
	at += n * 4
	_effect = []
	for _slot: int in range(EFFECT_SLOTS):
		_effect.append(data.slice(at, at + n))
		at += n
	if _tracking:
		_dirty_all = true
	rebuild_objects()
	return true
