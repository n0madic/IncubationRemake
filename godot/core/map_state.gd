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
const NO_UNIT: int = -1
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
var _special_models: PackedStringArray = PackedStringArray()

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


## Start or stop recording which cells are written.  `EventJournal` owns this;
## a world with no journal pays one boolean test per setter.
func track_writes(on: bool) -> void:
	_tracking = on
	_dirty.clear()
	_dirty_all = false
	_objects_dirty = false


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
	_dirty.clear()
	_dirty_all = false
	_objects_dirty = false
	return {"cells": cells, "objects": moved}


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
	out._special_models = _special_models.duplicate()
	return out


## `aBuild3DSpecialObjects` `0x004079D0`, as occupancy only: every cell whose
## `+0x10` is 1, 2 or 3 owns the slot at `+0x0F`, and every cell whose `+0x13`
## is 4 owns the one at `+0x11`.
func rebuild_objects() -> void:
	if _tracking:
		_objects_dirty = true
	_objects = PackedByteArray()
	_objects.resize(SPECIAL_OBJECT_SLOTS)
	_objects.fill(NO_OBJECT)
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
