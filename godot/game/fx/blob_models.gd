class_name BlobModels
extends Node3D

## The other half of the effect system: the blobs that draw **geometry**.
##
## docs/28 section 7.5. Sixty-two of the 116 constructor calls make a class-0
## or class-1 blob, whose appearance is not an atlas tile but one of thirty
## `.3DI` prototypes -- an explosion hull, a flame, a warning light, a computer
## panel, a para bomb. They resolve through the same `prototyp.dir` chain as
## scenery, which is why the converter puts them in the world set's own
## geometry document and why a set that does not carry one **cancels** the
## effect rather than drawing a hole (section 7.5's four rare models).
##
## **Two of the arms animate joints, and that is the reason this class exists
## rather than a static mesh per blob.** docs/28 section 7.8: `+0x2A`…`+0x34`
## are the model's articulated sub-objects' rotations, written by kind 42
## (`A_PANEL.3DI`, the computer panel whose plate flips edge-on and face-on
## every tick) and kind 54 (`A_FIRE3.3DI`, whose two flame billboards take a
## fresh random heading every tick) and read by nothing in `Incubation.exe` --
## the reader is in `Eng3d.dll`. A single flattened mesh cannot show either, so
## a model blob is built as a **node per scope**: the root, plus one child per
## `part_push` the prototype carries, each placed at its `part_push`
## translation and rotated by the joint triple its `joint_place` names.
##
## **Meshes are cached and instances are pooled.** One `ArrayMesh` per
## (model, scope) for the mission, and one `MeshInstance3D` per pool slot,
## hidden rather than freed when its blob dies -- the same argument
## [BlobSprites] makes for its single [ImmediateMesh], applied to the half of
## the system that cannot be one mesh.

## The joint-buffer offsets docs/28 section 7.8 found in the shipped data, and
## the blob fields that hold each triple. Triple 0 is the object's own
## rotation, which is [member Blob.rot_x] and friends; 6 and 12 are the two
## the arms write.
const TRIPLE_FIELDS: Dictionary = {
	0: ["rot_x", "rot_y", "rot_z"],
	6: ["angle0", "angle1", "angle2"],
	12: ["angle3", "angle4", "angle5"],
}

var _prototypes: Dictionary = {}
var _textures: Dictionary = {}
## Model index -> its name, the reverse of [member BlobHooks.model_index].
var _names: Dictionary[int, String] = {}
## `"<name>/<scope>"` -> the mesh built for it, once per mission.
var _meshes: Dictionary[String, ArrayMesh] = {}
## Pool slot -> the root node standing in for it.
var _nodes: Dictionary[int, Node3D] = {}
var _drawn: int = 0


func setup(prototypes: Dictionary, textures: Dictionary,
		index: Dictionary[String, int]) -> void:
	_prototypes = prototypes
	_textures = textures
	_names.clear()
	for name: String in index:
		_names[index[name]] = name
	for child: Node in get_children():
		remove_child(child)
		child.free()
	_meshes.clear()
	_nodes.clear()
	_drawn = 0


func drawn() -> int:
	return _drawn


## The models this mission could build a mesh for, for a caller and a suite.
func cached() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for key: String in _meshes:
		out.append(key)
	out.sort()
	return out


## Show every live model blob where it is, and hide the slots that are not one.
##
## Answers how many were drawn, so "nothing was drawn" and "nothing was
## checked" are distinguishable -- the same reason [method BlobSprites.rebuild]
## answers a count.
## Takes the **pool**, not its live array: a node belongs to a pool slot, and
## [member Blob.slot_tag] is the original's low address byte truncated to eight
## bits, so it repeats every 256 slots and cannot key one.
func rebuild(pool: BlobPool) -> int:
	_drawn = 0
	for slot: int in range(pool.capacity()):
		var blob: Blob = pool.at(slot)
		var draws: bool = blob != null and blob.alive and blob.delay == 0 \
			and not blob.is_sprite() and blob.model >= 0
		if not draws:
			if _nodes.has(slot):
				_nodes[slot].visible = false
			continue
		if _place(slot, blob):
			_drawn += 1
	return _drawn


func _place(slot: int, blob: Blob) -> bool:
	var name: String = _names.get(blob.model, "")
	if name.is_empty() or not _prototypes.has(name):
		return false
	var node: Node3D = _node_for(slot, name)
	if node == null:
		return false
	node.visible = true
	node.transform = Transform3D(
		WorldSpace.joint_basis(blob.rot_x, blob.rot_y, blob.rot_z),
		WorldSpace.to_godot(blob.x, blob.y, blob.z))
	# The parts, each under the triple its own `joint_place` names.
	var parts: Array = DictRead.as_array(
		DictRead.as_dict(_prototypes[name]).get("parts", []))
	for index: int in range(parts.size()):
		var part: Node3D = node.get_node_or_null(
			NodePath("part_%d" % index)) as Node3D
		if part == null:
			continue
		var entry: Dictionary = DictRead.as_dict(parts[index])
		part.transform = Transform3D(_basis_of(blob, entry.get("anim", null)),
			_translation_of(entry))
	return true


## The triple a part's `anim` offset names, as a basis.
##
## An offset the shipped data does not use -- anything but 0, 6 or 12 -- leaves
## the part unrotated rather than reading whatever field happens to be nearby;
## docs/28 section 7.8 measured the three and only the three.
func _basis_of(blob: Blob, anim: Variant) -> Basis:
	if anim == null or not TRIPLE_FIELDS.has(DictRead.as_int(anim)):
		return Basis.IDENTITY
	var fields: Array = TRIPLE_FIELDS[DictRead.as_int(anim)]
	return WorldSpace.joint_basis(
		DictRead.as_int(blob.get(DictRead.as_string(fields[0]))),
		DictRead.as_int(blob.get(DictRead.as_string(fields[1]))),
		DictRead.as_int(blob.get(DictRead.as_string(fields[2]))))


static func _translation_of(part: Dictionary) -> Vector3:
	var t: Array = DictRead.as_array(part["translation"])
	if t.size() < 3:
		return Vector3.ZERO
	return WorldSpace.to_godot(DictRead.as_int(t[0]), DictRead.as_int(t[1]),
		DictRead.as_int(t[2]))


## The node for a pool slot, built on first use and rebuilt when the slot's
## model changes -- a slot is reused by whatever effect takes it next.
func _node_for(slot: int, name: String) -> Node3D:
	var node: Node3D = _nodes.get(slot, null)
	if node != null and node.name == StringName("blob_%d_%s" % [slot, name]):
		return node
	if node != null:
		remove_child(node)
		node.free()
		_nodes.erase(slot)
	node = _build(name)
	if node == null:
		return null
	node.name = "blob_%d_%s" % [slot, name]
	add_child(node)
	_nodes[slot] = node
	return node


func _build(name: String) -> Node3D:
	var prototype: Dictionary = DictRead.as_dict(_prototypes[name])
	var root: Node3D = Node3D.new()
	var body: ArrayMesh = _mesh_for(name, MeshBuilder.ROOT_SCOPE, prototype)
	if body != null and body.get_surface_count() > 0:
		var instance: MeshInstance3D = MeshInstance3D.new()
		instance.name = "body"
		instance.mesh = body
		root.add_child(instance)
	var parts: Array = DictRead.as_array(prototype.get("parts", []))
	for index: int in range(parts.size()):
		var pivot: Node3D = Node3D.new()
		pivot.name = "part_%d" % index
		var mesh: ArrayMesh = _mesh_for(name, index, prototype)
		if mesh != null and mesh.get_surface_count() > 0:
			var child: MeshInstance3D = MeshInstance3D.new()
			child.name = "mesh"
			child.mesh = mesh
			pivot.add_child(child)
		root.add_child(pivot)
	if root.get_child_count() == 0:
		root.free()
		return null
	return root


func _mesh_for(name: String, scope: int, prototype: Dictionary) -> ArrayMesh:
	var key: String = "%s/%d" % [name, scope]
	if _meshes.has(key):
		return _meshes[key]
	var mesh: ArrayMesh = MeshBuilder.build_scope(prototype, _textures, scope)
	_meshes[key] = mesh
	return mesh
