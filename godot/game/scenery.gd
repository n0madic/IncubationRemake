class_name Scenery
extends Node3D

## The mission's placed geometry: the scene's `.3DW` clones, the special
## objects, and the ground lattice.
##
## One [MeshInstance3D] per object, sharing one [ArrayMesh] per prototype.  For
## the slice's lead mission that is 53 prototypes and about 84 instances, so a
## [MultiMeshInstance3D] would buy nothing.
##
## The lattice is instanced too, and deliberately -- but **hidden by default**.
## `S003_00X.3DI` is an octagon 320 world units across: an editor marker for the
## cell centre, not a terrain tile, and the original never draws it.  Building
## it is how "the rendered scenery agrees with the inspection tools" is
## checkable; *showing* it is not fidelity, it is a grid of white dots on every
## surface.  It lives under its own child node so that `G` can turn it on.
##
## `CLS.3DI` is parked at z = -1600000 by the `.lev` and is simply not built.

## docs/10 -- where the marker prototype is parked.
const MARKER_PARK_Z: int = -1600000

var _meshes: Dictionary = {}
var _built: int = 0
var _missing: PackedStringArray = PackedStringArray()
var _lattice: Node3D = null
## Map cell index -> the instances standing on it, and each instance's
## **authored** transform. A door does not get a new mesh when it opens; the
## panel it already is moves, and it moves by the difference between the live
## cell height and the one the `.lev` recorded.
var _by_cell: Dictionary[int, Array] = {}
var _authored: Dictionary[Node3D, Transform3D] = {}
## Authored cell height, from the `.lev`'s own lattice records. **Not** the
## height the world happens to have at build time: a save loaded with a door
## already open has to place that panel where the open door is, and comparing
## the live state against itself would place it where the closed one was.
var _authored_height: Dictionary[int, int] = {}
var _width: int = 0
var _moved: int = 0


func build(map_document: Dictionary, geometry: Dictionary,
		textures: Dictionary) -> void:
	_width = DictRead.as_int(map_document["width"])
	# Freed synchronously, not queued: a rebuild has to leave the node list in
	# its final state before anything reads it back, and `queue_free` defers to
	# the end of the frame.
	for child: Node in get_children():
		remove_child(child)
		child.free()
	_meshes.clear()
	_built = 0
	_moved = 0
	_missing = PackedStringArray()
	_by_cell.clear()
	_authored.clear()
	_authored_height.clear()
	_lattice = Node3D.new()
	_lattice.name = "Lattice"
	# The editor's cell markers are an inspection aid, not scenery: off until
	# asked for.
	_lattice.visible = false
	add_child(_lattice)
	var prototypes: Dictionary = DictRead.as_dict(geometry["prototypes"])

	var clones: Array = DictRead.as_array(map_document["scene_clones"])
	for entry: Variant in clones:
		var clone: Dictionary = DictRead.as_dict(entry)
		_place(prototypes, textures, DictRead.as_string(clone["prototype"]),
			DictRead.as_int(clone["x"]), DictRead.as_int(clone["y"]),
			DictRead.as_int(clone["z"]), DictRead.as_int(clone["yaw"]))

	var specials: Array = DictRead.as_array(map_document["special_objects"])
	for entry: Variant in specials:
		var obj: Dictionary = DictRead.as_dict(entry)
		_place(prototypes, textures, DictRead.as_string(obj["prototype"]),
			DictRead.as_int(obj["x"]), DictRead.as_int(obj["y"]),
			DictRead.as_int(obj["z"]), DictRead.as_int(obj["yaw"]))

	var land: Dictionary = DictRead.as_dict(map_document["land"])
	var name: String = DictRead.as_string(land["prototype"])
	var xs: Array = DictRead.as_array(land["x"])
	var ys: Array = DictRead.as_array(land["y"])
	var zs: Array = DictRead.as_array(land["z"])
	var yaws: Array = DictRead.as_array(land["yaw"])
	# The lattice records carry the authored cell **index** as well as the world
	# position, so the baseline height is read rather than divided back out.
	var grid_x: Array = DictRead.as_array(land["grid_x"])
	var grid_y: Array = DictRead.as_array(land["grid_y"])
	for i: int in range(xs.size()):
		_authored_height[DictRead.as_int(grid_y[i]) * _width
			+ DictRead.as_int(grid_x[i])] = DictRead.as_int(zs[i])
	for i: int in range(xs.size()):
		_place(prototypes, textures, name, DictRead.as_int(xs[i]),
			DictRead.as_int(ys[i]), DictRead.as_int(zs[i]),
			DictRead.as_int(yaws[i]), _lattice)


func built_count() -> int:
	return _built


## Whether the editor's cell markers are shown.  They are built either way, so
## `built_count()` counts them and the inspection-tool comparison still holds.
func lattice_visible() -> bool:
	return _lattice != null and _lattice.visible


func toggle_lattice() -> void:
	if _lattice != null:
		_lattice.visible = not _lattice.visible


func missing_prototypes() -> PackedStringArray:
	return _missing.duplicate()


func _place(prototypes: Dictionary, textures: Dictionary, name: String,
		x: int, y: int, z: int, yaw: int, parent: Node3D = null) -> void:
	if z <= MARKER_PARK_Z:
		return
	if not prototypes.has(name):
		if not _missing.has(name):
			_missing.append(name)
		return
	var mesh: ArrayMesh = _mesh_for(prototypes, textures, name)
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.mesh = mesh
	instance.name = "%s@%d_%d" % [name.get_basename(), x, y]
	instance.transform = Transform3D(WorldSpace.yaw_basis(yaw),
		WorldSpace.to_godot(x, y, z))
	if parent == null:
		add_child(instance)
	else:
		parent.add_child(instance)
	var cell: int = _cell_of(x, y)
	if not _by_cell.has(cell):
		_by_cell[cell] = []
	_by_cell[cell].append(instance)
	_authored[instance] = instance.transform
	_built += 1


func _mesh_for(prototypes: Dictionary, textures: Dictionary,
		name: String) -> ArrayMesh:
	if _meshes.has(name):
		return _meshes[name]
	var mesh: ArrayMesh = MeshBuilder.build(
		DictRead.as_dict(prototypes[name]), textures)
	_meshes[name] = mesh
	return mesh



## The map cell an object standing at engine `(x, y)` belongs to.
##
## Integer division of the world coordinate by the field size, which is where
## the `.lev` put it: an object is authored at its cell's own origin, and the
## few that sit off-centre still round into the cell they decorate.
func _cell_of(x: int, y: int) -> int:
	var cx: int = x / WorldSpace.WORLD_UNITS_PER_FIELD
	var cy: int = y / WorldSpace.WORLD_UNITS_PER_FIELD
	return cy * _width + cx


## Move the objects on `cells` to where the live state says their cell is.
##
## This is the second half of "the picture is a function of the state": the
## first half is that the offset is computed from the **authored** transform
## every time, never accumulated, so applying it twice is the same as applying
## it once and a reload lands in the same place as a live change.
##
## docs/26 section 3.4 -- *a door is a wall panel that rises out of the floor*
## -- and the corpus agrees: `_C_140`'s two closed doors carry the special
## object `L100EX00.3DI`, a full-tile-wide panel spanning z 36..3673, on a cell
## of field type 2 at height 3200. Toggling writes a height change of
## [constant Interact.DOOR_HEIGHT_STEP], so the panel is what moves, and it
## moves because it is an object standing on that cell. No special case.
func apply_state(snapshot: Dictionary, cells: PackedInt32Array) -> int:
	if snapshot.is_empty():
		return 0
	var heights: PackedInt32Array = snapshot["height_map"]
	_moved = 0
	for cell: int in cells:
		if cell < 0 or cell >= heights.size() or not _by_cell.has(cell):
			continue
		var delta: int = heights[cell] - _authored_height.get(cell, heights[cell])
		var offset: Vector3 = WorldSpace.to_godot(0, 0, delta)
		for node: Variant in _by_cell[cell]:
			var instance: Node3D = node
			if not is_instance_valid(instance):
				continue
			var authored: Transform3D = _authored[instance]
			instance.transform = Transform3D(authored.basis,
				authored.origin + offset)
			_moved += 1
	return _moved


## The same, for every cell -- what a fresh build or a loaded save needs.
func apply_all(snapshot: Dictionary) -> int:
	var every: PackedInt32Array = PackedInt32Array()
	for cell: int in _by_cell:
		every.append(cell)
	return apply_state(snapshot, every)


func moved_count() -> int:
	return _moved


## The instances standing on a cell, for the suite and for the set-piece
## driver. A copy: the array this returns must not be a handle into the index.
func instances_on(cell: int) -> Array:
	return (_by_cell[cell] as Array).duplicate() if _by_cell.has(cell) else []


func authored_height(cell: int) -> int:
	return _authored_height.get(cell, 0)
