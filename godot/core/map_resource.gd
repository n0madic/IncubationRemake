class_name MapResource
extends RefCounted

## The immutable authored grid (docs/92 section 7.2).
##
## The cut between this and [MapState] is by **lifetime, not by container**:
## everything interaction writes lives in [MapState] and everything else lives
## here.  Authored input therefore cannot be mutated by accident, and a fidelity
## diff runs array against array with each one mapping onto a documented byte
## offset.
##
## Every accessor that returns a packed array returns a `duplicate()`.  That is
## not belt and braces: `Packed*Array` returned from a function **aliases** the
## original in Godot 4.7 -- writing through the returned handle writes through
## to the source -- which was established by running it, not assumed.

## docs/10 section 7 -- one map field, and the metre.
const WORLD_UNITS_PER_FIELD: int = 3200
const WORLD_UNITS_PER_METRE: int = 1600

var width: int = 0
var height: int = 0
var mission: String = ""
var next_map: String = ""
var world_set: String = ""
var world_scene: String = ""
var camera_height: int = 0

var _height: PackedInt32Array = PackedInt32Array()
var _field_type: PackedByteArray = PackedByteArray()
var _action_point: PackedByteArray = PackedByteArray()
var _unit: PackedInt32Array = PackedInt32Array()
var _land: PackedInt32Array = PackedInt32Array()
var _start_index: PackedInt32Array = PackedInt32Array()
var _effect: Array[PackedByteArray] = []


static func from_document(document: Dictionary) -> MapResource:
	var res: MapResource = MapResource.new()
	res.width = DictRead.as_int(document["width"])
	res.height = DictRead.as_int(document["height"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	res.mission = DictRead.as_string(header["name"])
	res.next_map = DictRead.as_string(header["next_map"])
	res.world_set = DictRead.as_string(header["world_set"])
	res.world_scene = DictRead.as_string(header["world_scene"])
	res.camera_height = DictRead.as_int(header["camera_height"])

	var cells: Dictionary = DictRead.as_dict(document["cells"])
	res._height = _ints(cells["height"])
	res._field_type = _bytes(cells["field_type"])
	res._action_point = _bytes(cells["action_point"])
	res._unit = _ints(cells["unit"])
	res._land = _ints(cells["land"])
	res._start_index = _ints(cells["start_index"])
	res._effect = []
	for slot: int in range(MapState.EFFECT_SLOTS):
		res._effect.append(_bytes(cells["effect%d" % slot]))
	return res


## Every number `JSON.parse_string` produces is a `float`.  All of them are far
## below 2^53 so nothing is lost, but the conversion happens **here, once**, at
## the boundary -- the canonical hash must never see the parsed form.
static func _ints(values: Variant) -> PackedInt32Array:
	return DictRead.to_int32(values)


static func _bytes(values: Variant) -> PackedByteArray:
	return DictRead.to_bytes(values)


func cell_count() -> int:
	return width * height


func index_of(x: int, y: int) -> int:
	return y * width + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func height_at(index: int) -> int:
	return _height[index]


func field_type_at(index: int) -> int:
	return _field_type[index]


func action_point_at(index: int) -> int:
	return _action_point[index]


func unit_at(index: int) -> int:
	return _unit[index]


func land_at(index: int) -> int:
	return _land[index]


func start_index_at(index: int) -> int:
	return _start_index[index]


func effect_at(slot: int, index: int) -> int:
	return _effect[slot][index]


func heights() -> PackedInt32Array:
	return _height.duplicate()


func field_types() -> PackedByteArray:
	return _field_type.duplicate()


func action_points() -> PackedByteArray:
	return _action_point.duplicate()


func units() -> PackedInt32Array:
	return _unit.duplicate()


func effects(slot: int) -> PackedByteArray:
	return _effect[slot].duplicate()


## A digest of the authored grid alone, so a save can be refused when it is
## paired with a different converted map (docs/92 section 7.3).
func authored_hash() -> PackedByteArray:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	ctx.update(("%s|%s|%d|%d" % [mission, world_scene, width, height]).to_utf8_buffer())
	ctx.update(_height.to_byte_array())
	ctx.update(_field_type)
	ctx.update(_action_point)
	ctx.update(_unit.to_byte_array())
	ctx.update(_land.to_byte_array())
	ctx.update(_start_index.to_byte_array())
	for slot: PackedByteArray in _effect:
		ctx.update(slot)
	return ctx.finish()
