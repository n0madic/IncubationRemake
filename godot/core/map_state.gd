class_name MapState
extends RefCounted

## The mutable half of the grid (docs/92 section 7.2), struct of arrays.
##
## One `Packed*Array` per documented byte offset, each `width * height` long:
## height `+0x01`, field type `+0x0D`, the action point `+0x0B`, the unit link
## `+0x07` and the four effect bytes `+0x0E`..`+0x11`.
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
const NO_UNIT: int = -1
const EFFECT_SLOTS: int = 4
## Which effect slot is `cell[+0x10]`, the transient obstacle.
const OBSTACLE_SLOT: int = 2

var width: int = 0
var height: int = 0

var _height: PackedInt32Array = PackedInt32Array()
var _field_type: PackedByteArray = PackedByteArray()
var _action_point: PackedByteArray = PackedByteArray()
var _unit: PackedInt32Array = PackedInt32Array()
var _effect: Array[PackedByteArray] = []


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


func field_type_at(index: int) -> int:
	return _field_type[index]


func set_field_type(index: int, value: int) -> void:
	_field_type[index] = value & 0xFF


func action_point_at(index: int) -> int:
	return _action_point[index]


func set_action_point(index: int, value: int) -> void:
	_action_point[index] = value & 0xFF


func unit_at(index: int) -> int:
	return _unit[index]


func set_unit(index: int, slot: int) -> void:
	_unit[index] = slot


func effect_at(slot: int, index: int) -> int:
	return _effect[slot][index]


func set_effect(slot: int, index: int, value: int) -> void:
	_effect[slot][index] = value & 0xFF


## `cell[+0x10]` under its own name.  The same storage as effect slot 2.
func obstacle_at(index: int) -> int:
	return _effect[OBSTACLE_SLOT][index]


func set_obstacle(index: int, value: int) -> void:
	set_effect(OBSTACLE_SLOT, index, value)


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
	return true
