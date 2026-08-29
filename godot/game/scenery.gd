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


func build(map_document: Dictionary, geometry: Dictionary,
		textures: Dictionary) -> void:
	# Freed synchronously, not queued: a rebuild has to leave the node list in
	# its final state before anything reads it back, and `queue_free` defers to
	# the end of the frame.
	for child: Node in get_children():
		remove_child(child)
		child.free()
	_meshes.clear()
	_built = 0
	_missing = PackedStringArray()
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
	_built += 1


func _mesh_for(prototypes: Dictionary, textures: Dictionary,
		name: String) -> ArrayMesh:
	if _meshes.has(name):
		return _meshes[name]
	var mesh: ArrayMesh = MeshBuilder.build(
		DictRead.as_dict(prototypes[name]), textures)
	_meshes[name] = mesh
	return mesh
