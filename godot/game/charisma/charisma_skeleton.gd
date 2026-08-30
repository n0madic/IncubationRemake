class_name CharismaSkeleton
extends RefCounted

## `V100Part::Update` (`0x004A6807`) and `StdPart::GetWorldMatrix`
## (`0x0049DB84`): what a clip does to a bind pose at one instant.
##
## The twin of `tools/inclib/pose.py`, diffed against it bone by bone by
## `godot/tests/test_charisma.gd` over
## `tests/fixtures/charisma/cases_pose.json`.
##
## The rule, and the three halves of it that are easy to get backwards:
##
## * a bound **rotation** channel *replaces* the bind rotation rather than
##   composing with it, and the bind translation is stripped before the track's
##   translation is written in;
## * for an ordinary bone a bound **position** channel is a **delta added to**
##   the bind translation (`0x004828FF` adds, it does not set). Over the
##   corpus' 1 153 position tracks the first key is below 1e-3 in 80.3 % of
##   them, while `firstKey - bindTranslation` is never near zero;
## * for the **top-level** bone -- the one and only bone whose `.cho` parent is
##   the `ROOT` sentinel -- the position channel is **absolute** and the bind
##   translation is not added at all (docs/40 section 6.2). Getting this wrong
##   moves the whole figure: for `P0_000` the root sits at z = 29 with the rule
##   and z = 129 without it.
##
## Everything stays in the engine's row-major `M * v` representation
## ([CharismaTrack]); [CharismaBody] is the one place it becomes a
## [Transform3D].

## `StdModel`'s per-instance placement, through its `"StandardModel"` interface
## (`0x0049FC2D` GetFlag, `0x0049FC6A` GetScale). The constructor at
## `0x0049ED2C` leaves the flag 0 and the scale `(1, 1, 1)`, and the owning
## animation's offset (`0x0049C5AC`) is zero. Nothing in a shipped `.cho` or
## `.cha` can change either, so these are the values the whole corpus runs
## with -- they are named rather than folded away because the engine does
## multiply and add by them, and a mission that set them would need them.
const MODEL_SCALE: Vector3 = Vector3(1.0, 1.0, 1.0)
const ANIM_OFFSET: Vector3 = Vector3.ZERO

var _model: CharismaModel = null
## Bone name -> its 16-float local matrix.
var _local: Dictionary[String, PackedFloat64Array] = {}
## Bone name -> its 16-float world matrix.
var _world: Dictionary[String, PackedFloat64Array] = {}
## Bone name -> whether its Visibility channel is positive.
var _visible: Dictionary[String, bool] = {}


## Pose `model` with `clip` at `time` in key-time units. A null clip is the
## bind pose.
static func pose(model: CharismaModel, clip: CharismaClip,
		time: float) -> CharismaSkeleton:
	var out: CharismaSkeleton = CharismaSkeleton.new()
	out._model = model
	for bone: String in model.bones:
		out._local[bone] = out._local_of(model, clip, bone, time)
	for bone: String in model.bones:
		out._accumulate(bone)
	return out


func _local_of(model: CharismaModel, clip: CharismaClip, bone: String,
		time: float) -> PackedFloat64Array:
	var bind: PackedFloat64Array = model.bind_matrix(bone)
	var translation: Vector3 = CharismaTrack.mat_translation(bind)

	var position: CharismaTrack = null if clip == null \
		else clip.track(bone, CharismaTrack.CHANNEL_POSITION)
	if position != null and position.count > 0:
		var sampled: Vector3 = position.sample_vector(time)
		if model.is_top_level(bone):
			translation = Vector3(
				sampled.x * MODEL_SCALE.x + ANIM_OFFSET.x,
				sampled.y * MODEL_SCALE.y + ANIM_OFFSET.y,
				sampled.z * MODEL_SCALE.z + ANIM_OFFSET.z)
		else:
			translation += sampled

	var rotation: CharismaTrack = null if clip == null \
		else clip.track(bone, CharismaTrack.CHANNEL_ROTATION)
	var local: PackedFloat64Array
	if rotation != null and rotation.count > 0:
		local = rotation.sample_rotation(time)
	else:
		local = CharismaTrack.mat_with_translation(bind, Vector3.ZERO)

	var visibility: CharismaTrack = null if clip == null \
		else clip.track(bone, CharismaTrack.CHANNEL_VISIBILITY)
	_visible[bone] = true if visibility == null or visibility.count == 0 \
		else visibility.sample_float(time) > 0.0
	return CharismaTrack.mat_with_translation(local, translation)


func _accumulate(bone: String) -> PackedFloat64Array:
	if _world.has(bone):
		return _world[bone]
	var parent: String = _model.parent_of.get(bone, "")
	var out: PackedFloat64Array
	if not _local.has(parent):
		out = _local[bone].duplicate()
	else:
		out = CharismaTrack.mat_mul(_accumulate(parent), _local[bone])
	_world[bone] = out
	return out


## One bone's local matrix, 16 floats, engine layout.
func local_matrix(bone: String) -> PackedFloat64Array:
	if not _local.has(bone):
		return CharismaTrack.identity()
	return _local[bone].duplicate()


## One bone's world matrix, 16 floats, engine layout.
func world_matrix(bone: String) -> PackedFloat64Array:
	if not _world.has(bone):
		return CharismaTrack.identity()
	return _world[bone].duplicate()


## Where a bone's joint sits, in engine world units.
func joint(bone: String) -> Vector3:
	return CharismaTrack.mat_translation(world_matrix(bone))


## Whether a bone's Visibility channel is positive at this instant.
##
## A part whose track has gone to zero is switched off *by the animation* and
## must not be drawn. No gameplay clip has a Visibility track at all -- the 272
## that dip to zero are all in `Video/` -- so on the bodies this slice draws
## the answer is always true; it is implemented because the channel exists and
## a silently-ignored one would be a bug waiting for the cutscene slice.
func is_visible(bone: String) -> bool:
	return _visible.get(bone, true)
