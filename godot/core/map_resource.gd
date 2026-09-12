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
## `0x0042F410`'s sweep, run by the converter: cell -> every cell of the
## placed object standing on it (docs/42 section 8.2). Authored geometry, so it
## lives here and not in [MapState]; **outside** [method authored_hash], which
## digests the grid the save has to agree with and not what stands on it.
var _object_cells: Dictionary[int, PackedInt32Array] = {}


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
	res._read_object_cells(document)
	return res


## The footprint index, from the converter's `cells` on each special object.
##
## `CrushWall` names one cell and the engine's `0x00406F20` finds the object
## standing near it, so every cell of a run points at the whole run. Where two
## objects cover one cell the **first** placed wins -- this index's own
## tie-break, not the engine's box search, and the two are shown equal only on
## the nine shipped calls; no cell any `CrushWall` names is under two objects
## (`inclib.footprint`, `corpus.crush_wall_cells_carry_one_object`).
##
## A document with no `special_objects` -- the hand-built ones the suites pass
## -- leaves the index empty, and every reader falls back to the cell it was
## given.
func _read_object_cells(document: Dictionary) -> void:
	if document.has("special_objects"):
		for entry: Variant in DictRead.as_array(document["special_objects"]):
			var record: Dictionary = DictRead.as_dict(entry)
			if not record.has("cells"):
				continue
			var run: PackedInt32Array = _ints(record["cells"])
			for cell: int in run:
				if not _object_cells.has(cell):
					_object_cells[cell] = run
	# [method object_cells] shares this dictionary rather than copying it, and
	# this is what makes "never written" a property rather than a promise --
	# on an empty index as much as on a filled one.
	_object_cells.make_read_only()


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


## Every cell of the placed object standing on `index`, or just `index` itself
## where nothing stands there.
##
## The fallback is what the remake did everywhere before the footprints were
## emitted (docs/97 section 41.7): the command's own cell, which is always part
## of the run when there is one.
func object_cells_at(index: int) -> PackedInt32Array:
	if _object_cells.has(index):
		return _object_cells[index].duplicate()
	return PackedInt32Array([index])


## Whether anything stands on `index` at all.
func has_object_cells(index: int) -> bool:
	return _object_cells.has(index)


## The whole index, for a reader that keeps it for the life of a mission.
##
## The runs inside it are never written -- [method object_cells_at] hands out a
## `duplicate()` -- and the dictionary itself is rebuilt per mission, so this
## one is shared rather than copied.
func object_cells() -> Dictionary[int, PackedInt32Array]:
	return _object_cells


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
