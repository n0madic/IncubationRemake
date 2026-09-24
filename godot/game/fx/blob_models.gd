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

## The joint-buffer offsets docs/28 section 7.8 found in the shipped data.
## Triple 0 is the object's own rotation; 6 and 12 are the two the arms write,
## and the two the special-object refresh writes (docs/42 section 9.1).
const TRIPLE_ROOT: int = 0
const TRIPLE_FIRST: int = 6
const TRIPLE_SECOND: int = 12

## These are flat particle cards, not solid scenery. Their shipped faces point
## along one fixed world axis, so a blood burst is entirely back-facing in two
## of the four camera quadrants and the casualty appears to simply vanish.
## The remake keeps Eng3d's one-sided rule for every ordinary model; only the
## blood cards are visible from both sides.
const BLOOD_PREFIX: String = "A_BLUT"

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
			and not blob.is_sprite() and blob.model >= 0 \
			and not unturned_seeker(blob)
		if not draws:
			if _nodes.has(slot):
				_nodes[slot].visible = false
			continue
		if _place(slot, blob):
			_drawn += 1
	return _drawn


## **A seeker is not drawn before its arm has turned it** -- the remake's own,
## and a deliberate divergence (docs/92 section 7.11).
##
## The creators of all three seeking kinds push a zero rotation, and the arm
## is what points the record along its path. The engine's sweep draws a record
## *before* it updates it (`0x0041E43D` ahead of `0x0041E44B`), so the first
## frame of every round -- and of each of weapon 11's five delayed ones, the
## frame its delay runs out -- shows the rod at the muzzle along engine +Y,
## whichever way the shot goes: across the line of fire for a target east or
## west, backwards for one south. At the original's frame rate that was one
## frame; at the remake's twenty ticks a second it is a twentieth of a second
## per round, six times an arc.
static func unturned_seeker(blob: Blob) -> bool:
	return not blob.dispatched and BlobPool.SEEKER_KINDS.has(blob.kind)


func _place(slot: int, blob: Blob) -> bool:
	var name: String = _names.get(blob.model, "")
	if name.is_empty():
		return false
	return place(slot, name, Vector3i(blob.x, blob.y, blob.z),
		[Vector3i(blob.rot_x, blob.rot_y, blob.rot_z),
		Vector3i(blob.angle0, blob.angle1, blob.angle2),
		Vector3i(blob.angle3, blob.angle4, blob.angle5)])


## Draw one model under `key`, at `position`, with its **three joint triples**.
##
## Triple 0 is the object's own rotation and 1 and 2 are the two the shipped
## data's `joint_place` offsets 6 and 12 name (docs/28 section 7.8). Public
## because the special objects of docs/42 section 9.1 are records of the same
## shape animated by the same three triples -- they are not blobs, but they are
## drawn and turned exactly like one, so they take a second instance of this
## node rather than a second copy of it.
func place(key: int, name: String, position: Vector3i,
		triples: Array[Vector3i]) -> bool:
	if name.is_empty() or not _prototypes.has(name):
		return false
	var node: Node3D = _node_for(key, name)
	if node == null:
		return false
	node.visible = true
	node.transform = Transform3D(
		WorldSpace.joint_basis(triples[0].x, triples[0].y, triples[0].z),
		WorldSpace.to_godot(position.x, position.y, position.z))
	# The parts, each under the triple its own `joint_place` names.
	var parts: Array = DictRead.as_array(
		DictRead.as_dict(_prototypes[name]).get("parts", []))
	for index: int in range(parts.size()):
		var part: Node3D = node.get_node_or_null(
			NodePath(MeshBuilder.PART_NODE % index)) as Node3D
		if part == null:
			continue
		var entry: Dictionary = DictRead.as_dict(parts[index])
		part.transform = Transform3D(
			_triple_basis(triples, entry.get("anim", null)),
			MeshBuilder.part_translation(entry))
	return true


## Hide every node whose key is not in `keep`, and answer how many are shown.
func keep_only(keep: Dictionary) -> int:
	var shown: int = 0
	for key: int in _nodes:
		if keep.has(key):
			shown += 1
		else:
			_nodes[key].visible = false
	return shown


## The triple a part's `anim` offset names, as a basis.
##
## An offset the shipped data does not use -- anything but 0, 6 or 12 -- leaves
## the part unrotated rather than reading whatever field happens to be nearby;
## docs/28 section 7.8 measured the three and only the three.
static func _triple_basis(triples: Array[Vector3i], anim: Variant) -> Basis:
	if anim == null:
		return Basis.IDENTITY
	var which: int = DictRead.as_int(anim)
	if which == 0:
		return WorldSpace.joint_basis(triples[0].x, triples[0].y, triples[0].z)
	if which == 6:
		return WorldSpace.joint_basis(triples[1].x, triples[1].y, triples[1].z)
	if which == 12:
		return WorldSpace.joint_basis(triples[2].x, triples[2].y, triples[2].z)
	return Basis.IDENTITY


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
	var node: Node3D = MeshBuilder.assemble(name,
		DictRead.as_dict(_prototypes[name]), _textures, _meshes)
	# All seven shipped A_BLUT models are one-face root meshes; there are no
	# articulated children to visit. The mesh cache belongs to this renderer,
	# so this cannot change the same prototype when scenery draws it.
	if node != null and name.begins_with(BLOOD_PREFIX):
		var body: MeshInstance3D = node.get_node_or_null(
			MeshBuilder.BODY_NODE) as MeshInstance3D
		if body != null and body.mesh != null:
			for surface: int in range(body.mesh.get_surface_count()):
				var material: StandardMaterial3D = \
					body.mesh.surface_get_material(surface) as StandardMaterial3D
				if material != null:
					material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return node
