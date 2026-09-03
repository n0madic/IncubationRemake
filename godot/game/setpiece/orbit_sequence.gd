class_name OrbitSequence
extends RefCounted

## The six orbits of docs/42 section 7.5 -- skill `0x00410190`, heal
## `0x0040FBE0`, poison `0x0040F8F0`, overheat `0x0040F420`, the reaction
## jam `0x004104A0` (section 7.4) and `RotatingCamera` `0x0040FF30` -- as
## steps on the [SequenceQueue].
##
## One shape, read out of all six: the camera is read (`0x00403780`), the
## marker is raised (the arrows, or a flash circle for heal and poison), the
## camera flies to a point beside the unit, a centred caption is set
## (overlay type 3), and for **forty frames** the eye's offset from the
## target is turned by a fixed step through `0x004039A0` and the camera set
## again; then a flight back to the six numbers read at the start. The
## numbers are `tools/presentation_tables.py`'s `orbit.*` pins.
##
## The flights are open-ended steps bounded by [constant
## ShotSequence.SAFETY_FRAMES]; the forty frames and the raise are
## deterministic, and [method enqueue] answers those alone.

## `mov dword [...], 0x28` in all six.
const FRAMES: int = 40
## `mov word [...], 0x64` -- skill, jam, overheat and rotating; `0xFFD8` --
## heal and poison.
const STEP_FORWARD: int = 100
const STEP_BACK: int = -40
## The eye's start beside the unit, relative to the target on its head:
## `(0, +0xC80, +0xC80)` for skill, jam and overheat, `(0, +0x1900, +0xC80)`
## for heal and poison, `(0, +0xC80, 0)` for `RotatingCamera`.
const START_NEAR: Vector3i = Vector3i(0, 0xC80, 0xC80)
const START_FAR: Vector3i = Vector3i(0, 0x1900, 0xC80)
const START_ROTATING: Vector3i = Vector3i(0, 0xC80, 0)

const KIND_SKILL: String = "skill"
const KIND_HEAL: String = "heal"
const KIND_POISON: String = "poison"
const KIND_OVERHEAT: String = "overheat"
const KIND_JAM: String = "jam"
const KIND_ROTATING: String = "rotating"
## `0x0040F420`'s kind argument (docs/22 section 8): 1 the carrier is
## destroyed, 2 a jam, 3 damage. Kind 1 also hides the unit behind
## `FireExplosion` and `BloodFlood` (`0x0040F71E`, `0x0040F747`, `0x0040F776`).
const OVERHEAT_DESTROYED: int = 1
const OVERHEAT_JAM: int = 2
const OVERHEAT_DAMAGE: int = 3

const STAGE_RAISE: String = "orbit.raise"
const STAGE_FLIGHT: String = "orbit.flight"
const STAGE_TURN: String = "orbit.turn"
const STAGE_BACK: String = "orbit.back"


## The start offset, the step and the marker of one kind.
static func spec(kind: String) -> Dictionary:
	match kind:
		KIND_HEAL:
			return {"start": START_FAR, "step": STEP_BACK,
				"marker": BlobPrograms.HEAL_FLASH}
		KIND_POISON:
			return {"start": START_FAR, "step": STEP_BACK,
				"marker": BlobPrograms.POISON_FLASH}
		KIND_ROTATING:
			return {"start": START_ROTATING, "step": STEP_FORWARD,
				"marker": BlobPrograms.ARROWS}
		_:
			return {"start": START_NEAR, "step": STEP_FORWARD,
				"marker": BlobPrograms.ARROWS}


## The offset after `frames` steps of `step`, from a start -- the same
## arithmetic the turn stage runs, for a suite to compare against.
static func turned(host: ShotHost, start: Vector3i, step: int,
		frames: int) -> Vector3i:
	var offset: Vector3i = start
	for _i: int in range(frames):
		offset = host.rotate(offset, Vector3i(0, 0, step))
	return offset


## Queue one orbit around `slot`'s body. `caption` is the centred text;
## `cues` the routine's own wave; `overheat_kind` only for
## [constant KIND_OVERHEAT]; `height` overrides the unit's for
## `RotatingCamera`'s `h * 160` argument. Answers the deterministic frames.
static func enqueue(queue: SequenceQueue, host: ShotHost, slot: int,
		kind: String, caption: String, cues: Array[Dictionary],
		overheat_kind: int = 0, height: int = -1,
		cell: Vector2i = Vector2i(-1, -1)) -> int:
	var shape: Dictionary = spec(kind)
	var start: Vector3i = shape["start"]
	var step: int = DictRead.as_int(shape["step"])
	var marker: String = DictRead.as_string(shape["marker"])
	var st: Dictionary = {"saved_eye": Vector3i.ZERO,
		"saved_target": Vector3i.ZERO, "target": Vector3i.ZERO,
		"offset": Vector3i.ZERO, "cell": Vector2i.ZERO}

	# The camera read and the marker raised, at the unit's cell.
	queue.enqueue(STAGE_RAISE, 1,
		func(_frame: int, _total: int) -> void:
			st["saved_eye"] = host.camera_eye()
			st["saved_target"] = host.camera_target()
			var at: Vector3i = host.object_of(slot) if slot >= 0 \
				else host.cell_object(cell.x, cell.y)
			var on: Vector2i = cell if slot < 0 else Vector2i(
				IncInt.div_trunc(at.x, WorldSpace.WORLD_UNITS_PER_FIELD),
				IncInt.div_trunc(at.y, WorldSpace.WORLD_UNITS_PER_FIELD))
			st["cell"] = on
			host.spawn_program(marker, PackedInt32Array([on.x, on.y])))

	# The flight to the point beside the unit; the caption and the wave
	# come once it lands, as the routine orders them.
	queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
		func() -> bool: return not host.camera_flying(),
		func(frame: int, _total: int) -> void:
			if frame != 1:
				return
			var on: Vector2i = st["cell"]
			var at: Vector3i = host.object_of(slot) if slot >= 0 \
				else host.cell_object(on.x, on.y)
			var lift: int = host.unit_height(slot) if height < 0 else height
			var target: Vector3i = at + Vector3i(0, 0, lift)
			st["target"] = target
			st["offset"] = start
			var _frames: int = host.fly(target + start, target))

	# Forty frames: the offset turned by the step, the camera set each frame.
	queue.enqueue(STAGE_TURN, FRAMES,
		func(frame: int, _total: int) -> void:
			if frame == 1:
				host.set_centred_caption(caption)
				host.play_cues(cues)
				if kind == KIND_OVERHEAT and overheat_kind == OVERHEAT_DESTROYED:
					var here: Vector2i = st["cell"]
					host.spawn_program(BlobPrograms.FIRE_EXPLOSION,
						PackedInt32Array([here.x, here.y]))
					host.spawn_program(BlobPrograms.BLOOD_FLOOD,
						PackedInt32Array([here.x, here.y, here.x, here.y, 0]))
					host.hide_unit(slot)
			var was: Vector3i = st["offset"]
			var offset: Vector3i = host.rotate(was, Vector3i(0, 0, step))
			st["offset"] = offset
			var target: Vector3i = st["target"]
			host.set_camera(target + offset, target))

	# The flight back to the six numbers read at the start.
	queue.enqueue_until(STAGE_BACK, ShotSequence.SAFETY_FRAMES,
		func() -> bool: return not host.camera_flying(),
		func(frame: int, _total: int) -> void:
			if frame == 1:
				host.set_centred_caption("")
				var saved_eye: Vector3i = st["saved_eye"]
				var saved_target: Vector3i = st["saved_target"]
				var _back: int = host.fly(saved_eye, saved_target))
	return 1 + FRAMES
