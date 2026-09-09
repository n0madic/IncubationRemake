class_name CharismaModel
extends RefCounted

## One `.cho` out of the cache: the parts, the bind pose, and the clips it can
## be posed by.
##
## A `.cho` holds **no geometry** (docs/40 section 8). A part names a mesh, and
## that name resolves in `geometry/units.json` -- which the converter emits
## once for every world set, because a body is the same mesh everywhere even
## though a texture *id* is not.
##
## Parts and bones are kept in **file order**. That is the order the engine
## builds them in, and it is what makes a parent name resolvable in one pass:
## docs/40 section 3.2 records that a node's parent always precedes it.

## A part: an instance name, and the mesh it draws (empty for a pure bone).
var part_meshes: Dictionary[String, String] = {}
## Bone names, in file order.
var bones: PackedStringArray = PackedStringArray()
## Bone name -> its parent's name. The one bone whose parent is not itself a
## bone here is the model's top-level bone (docs/40 section 6.2).
var parent_of: Dictionary[String, String] = {}
## Bone name -> its 16-element, row-major, **parent-relative** bind matrix,
## widened from the file's `f32` to double for the same reason
## [CharismaTrack] widens its keys.
var bind_of: Dictionary[String, PackedFloat64Array] = {}
var name: String = ""


static func from_document(document: Dictionary) -> CharismaModel:
	var model: CharismaModel = CharismaModel.new()
	model.name = DictRead.as_string(document["name"])
	for entry: Variant in DictRead.as_array(document["parts"]):
		var part: Dictionary = DictRead.as_dict(entry)
		model.part_meshes[DictRead.as_string(part["name"])] = \
			DictRead.as_string(part["mesh"])
	var skeleton: Dictionary = DictRead.as_dict(document["skeleton"])
	for entry: Variant in DictRead.as_array(skeleton["nodes"]):
		var node: Dictionary = DictRead.as_dict(entry)
		var bone: String = DictRead.as_string(node["name"])
		model.bones.append(bone)
		model.parent_of[bone] = DictRead.as_string(node["parent"])
		model.bind_of[bone] = CharismaTrack.floats_from_base64(
			DictRead.as_string(node["matrix"]))
	return model


## The mesh a bone draws, or `""` when it is a pure bone.
func mesh_of(bone: String) -> String:
	return part_meshes.get(bone, "")


## Whether `bone` is the one whose `.cho` parent is the `ROOT` sentinel.
##
## Written as "my parent is not itself a bone in this file", which is what
## `V100Part::Update` tests at `0x004A68D1` once the synthetic `ROOT` part
## `V100Model::ConstructModel` allocates is accounted for. Exactly one bone
## per model satisfies it, and `charisma_tables.py --check` asserts that over
## all 1 555 posed frames.
func is_top_level(bone: String) -> bool:
	return not parent_of.has(parent_of.get(bone, ""))


## The offset `ownerAnimation.GetOffset()` runs with: the top-level bone's own
## bind translation. See [CharismaSkeleton]'s `_offset` for why it is that and
## not the zero the descriptor carries.
func animation_offset() -> Vector3:
	for bone: String in bones:
		if is_top_level(bone):
			return CharismaTrack.mat_translation(bind_matrix(bone))
	return Vector3.ZERO


## The bind matrix, or the identity for a bone this model does not have.
func bind_matrix(bone: String) -> PackedFloat64Array:
	if not bind_of.has(bone):
		return CharismaTrack.identity()
	return bind_of[bone].duplicate()


## The bone chain from the model's top-level bone down to `bone`, inclusive.
##
## Root-first, which is the order [method CharismaBody.aim_pivot_of] compares
## two chains in. A bone this model does not carry answers empty.
func ancestors(bone: String) -> PackedStringArray:
	if not parent_of.has(bone):
		return PackedStringArray()
	var chain: PackedStringArray = PackedStringArray()
	var at: String = bone
	while parent_of.has(at):
		chain.append(at)
		at = parent_of[at]
	chain.reverse()
	return chain


## Whether `bone` is `ancestor` or sits under it.
func is_under(bone: String, ancestor: String) -> bool:
	var at: String = bone
	while parent_of.has(at):
		if at == ancestor:
			return true
		at = parent_of[at]
	return false


## The joint an aiming twist turns about, and the bones that turn with it.
##
## Resolved once per model by [CharismaBody] -- which is the class that can
## pose a bind skeleton -- and kept here because a model outlives the bodies
## built from it and the answer is the same for every one of them. Empty
## means "this model does not aim": see [method CharismaBody.aim].
var _aim_pivot: String = ""
var _aim_subtree: Dictionary[String, bool] = {}
var _aim_resolved: bool = false


## Whether [method resolve_aim] has already been asked of this model.
func aim_resolved() -> bool:
	return _aim_resolved


## The twist joint, or `""` for a model that does not aim.
func aim_pivot() -> String:
	return _aim_pivot


## Whether `bone` turns with the twist.
func turns_with_aim(bone: String) -> bool:
	return _aim_subtree.has(bone)


## How many bones the twist moves, for a measurement to report.
func aim_part_count() -> int:
	return _aim_subtree.size()


## Record the twist joint and expand its subtree. Idempotent.
func resolve_aim(pivot: String) -> void:
	_aim_resolved = true
	_aim_pivot = pivot
	_aim_subtree.clear()
	if pivot.is_empty():
		return
	for bone: String in bones:
		if is_under(bone, pivot):
			_aim_subtree[bone] = true
