class_name CharismaBody
extends Node3D

## One unit's body: a [MeshInstance3D] per meshed part, posed by a clip.
##
## A `.cho` holds no geometry (docs/40 section 8) -- a part names a mesh, and
## the mesh comes from `geometry/units.json` through [CharismaLibrary], built
## once and shared by every body that draws it.
##
## **The mesh nodes are flat, not nested under one another.** The plan called
## for meshes hung on the bone hierarchy; that is what a renderer does when it
## wants the engine to compose the parent chain for it. [CharismaSkeleton]
## already accumulates every bone's world matrix -- because the diff against
## `inclib/pose.py` is stated in world matrices -- so nesting would compose the
## chain a second time, in a second convention, for the same answer. Each part
## is therefore a direct child carrying its bone's world transform.
##
## That is also why the conversion out of engine space happens exactly once per
## part, in [method WorldSpace.engine_matrix], and nowhere else: the whole pose
## is computed in the engine's row-major `M * v` representation and only the
## final placement is Godot's.
##
## **Bodies are not authoritative.** A body draws what [World] says; it is
## never asked where a unit is.

## Bone translations are in **1/16 of a world unit**; a mesh's vertices are in
## world units. Multiply one by this to reach the other.
##
## docs/40 never states the skeleton's unit relative to the geometry's, and the
## two are genuinely different: `P0_000`'s whole skeleton spans 171 units while
## a single torso mesh is 536 tall, so drawn raw a marine is a 10 cm pile of
## 30 cm parts.
##
## The factor is **measured, not assumed**, and it is measured off the one
## thing that must be true of a standing figure -- its lowest vertex touches
## the ground. Solving `min(16 * z_bone + z_meshmin) = 0` over every meshed
## part gives 16.01 for `P0_000`, and at exactly 16 the lowest vertex of
## `P0_000`, `P0_003`, `P1_000` and `P1_003` sits at **z = -0.1** world units
## -- 0.06 mm, from four independent models -- with body heights of 1.83 m to
## 1.91 m against the 1.8 m the type's own height column implies. `PC_000`
## lands at 9.3. `charisma_tables.py --check` asserts this.
##
## 16 is `1 << 4`, the same fixed-point shift docs/30 section 2.5 records for
## `.3DW` positions, which is corroboration rather than coincidence.
##
## **Where the engine applies it is UNVERIFIED.** It is not `StdModel`'s scale
## (docs/40 section 6.2: that defaults to 1 and no shipped file changes it), so
## it lives in the Charisma-to-Eng3d bridge, which is not decompiled. What is
## verified is the number.
const SKELETON_TO_WORLD: float = 16.0

## Bone name -> the node drawing its mesh. Bones without a mesh -- more than
## half of a biped's -- get no node at all.
var _nodes: Dictionary[String, MeshInstance3D] = {}
var _model: CharismaModel = null


## Build the body of `model`, unposed. Returns null when the model names no
## mesh the cache carries, so the caller can fall back visibly.
static func create(model: CharismaModel,
		library: CharismaLibrary) -> CharismaBody:
	var body: CharismaBody = CharismaBody.new()
	body._model = model
	body.name = "body_" + model.name
	for bone: String in model.bones:
		var mesh_name: String = model.mesh_of(bone)
		if mesh_name == "":
			continue
		var mesh: ArrayMesh = library.mesh(mesh_name)
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var instance: MeshInstance3D = MeshInstance3D.new()
		instance.mesh = mesh
		# Bone names carry spaces and dots (`Bip01 L Finger0`); Godot node
		# names may not contain `.`, and a clash would be renamed silently.
		instance.name = bone.replace(".", "_")
		body.add_child(instance)
		body._nodes[bone] = instance
	return null if body._nodes.is_empty() else body


## How many parts this body actually draws, for a measurement to report.
func part_count() -> int:
	return _nodes.size()


## Put the body in one pose.
##
## A part whose bone the pose does not know keeps its last transform rather
## than jumping to the origin -- that can only happen if a body and a clip
## disagree about the skeleton, which the converter's closure prevents, and
## snapping a limb to the model's feet would be a louder wrong answer than
## leaving it where it was.
func apply(pose: CharismaSkeleton) -> void:
	for bone: String in _nodes:
		var instance: MeshInstance3D = _nodes[bone]
		var world: PackedFloat64Array = pose.world_matrix(bone)
		# Scaling the *world* translation is exactly equivalent to scaling
		# every local one, because a rotation does not change a length and
		# `t_world = R_parent * t_local + t_parent` is linear in the
		# translations. So the bridge is applied once, here, and the pose
		# itself stays in the engine's own units -- which is what keeps it
		# diffable against `inclib/pose.py` element for element.
		world[3] *= SKELETON_TO_WORLD
		world[7] *= SKELETON_TO_WORLD
		world[11] *= SKELETON_TO_WORLD
		instance.transform = WorldSpace.engine_matrix(world)
		# docs/40 section 6: a Visibility track that has gone to zero switches
		# the part off. No gameplay clip has one -- the 272 tracks that dip to
		# zero are all in `Video/` -- so this is always true on the bodies this
		# slice draws, and it is here because a channel the runtime silently
		# ignored would be a bug waiting for the cutscene slice.
		instance.visible = pose.is_visible(bone)


## Pose the body with `clip` at `time`, or in its bind pose when `clip` is null.
##
## A null clip is not a failure: nine unit types get fewer than three clips and
## two get none at all (docs/40 section 7.2 as amended), so a body that stands
## in its bind pose is the engine's own behaviour for them.
func pose(clip: CharismaClip, time: float) -> void:
	apply(CharismaSkeleton.pose(_model, clip, time))
