class_name JumpSequence
extends RefCounted

## `aPlayJumpAnimaion` `0x00411460` (docs/42 section 7.1) as steps on the
## [SequenceQueue]: the Jet Pack's jump, the player's and the computer's.
##
## The body is turned to face the landing cell; the flight is a parabola --
## `steps = max(|dx|, |dy|) / 480`, a rise of `(steps / 2) * 160` falling by
## 160 a frame, the position by the direction `0x0046D400` gives times 480 a
## step -- and every frame the camera keeps its eye and looks at the flyer.
## A player's unit leaves the trail `0x00423670` at `z + 0x640` each frame
## and raises the landing dust `0x004227C0` at both ends, with `jump.wav`
## and `drop.wav`; a computer unit screams `S_ALI_n` (`aRandom2(0, 3)`)
## instead of the trail. The routine then waits for the pool to empty.
##
## The frames and the constants are `presentation_tables.py`'s `jump.*`
## pins; the parabola's arithmetic is **read, not measured** -- the routine
## renders inside the frame loop and cannot be called under `dbgcall`
## (docs/97 section 31).

## `0x0046D400(src, dst, 1)` times this, a step.
const STEP_UNITS: int = 480
## `sub eax, 0xA0` a frame.
const GRAVITY: int = 160
## `0x0047AD30(0)` -- the source object is lifted by the null-unit default.
const LIFT: int = 0x960
## `lea edx, [esi + 0x640]` -- the trail is spawned this far above the flyer.
const TRAIL_UP: int = 0x640
## `lea eax, [esi + 0xA0]` -- the object is put down this far above the cell.
const LAND_UP: int = 0xA0
## `aRandom2(0, 3)` -- the three screams.
const SCREAMS: int = 3
## The wait for the pool has no bound in the engine; **the remake's**, and
## longer than any trail or dust record lives (11 and 10 ticks).
const POOL_WAIT_FRAMES: int = 60

const STAGE_LEAVE: String = "jump.leave"
const STAGE_FLY: String = "jump.fly"
const STAGE_LAND: String = "jump.land"
const STAGE_POOL: String = "jump.pool"


## The flight's frames for two object positions.
static func steps_between(source: Vector3i, target: Vector3i) -> int:
	return IncInt.div_trunc(
		maxi(absi(target.x - source.x), absi(target.y - source.y)), STEP_UNITS)


## Queue one jump of `slot` from cell `from` to cell `to`. `own` chooses
## the trail over the scream; `cues_jump` and `cues_drop` are the two waves,
## `screams` the three the computer draws among. Answers the deterministic
## frames: the leave, the flight and the landing.
static func enqueue(queue: SequenceQueue, host: ShotHost, slot: int,
		from: Vector2i, to: Vector2i, own: bool, cues_jump: Array[Dictionary],
		cues_drop: Array[Dictionary], screams: Array) -> int:
	var source: Vector3i = host.cell_object(from.x, from.y) + Vector3i(0, 0, LIFT)
	var target: Vector3i = host.cell_object(to.x, to.y)
	var steps: int = maxi(1, steps_between(source, target))
	var direction: PackedFloat64Array = Eng3dGeometry.direction(source, target, 1)
	var dx: int = Eng3dGeometry.ftol(direction[0] * float(STEP_UNITS))
	var dy: int = Eng3dGeometry.ftol(direction[1] * float(STEP_UNITS))
	var dz: int = 0 if is_nan(direction[2]) or is_inf(direction[2]) \
		else Eng3dGeometry.ftol(direction[2] * float(STEP_UNITS))
	var st: Dictionary = {"at": source, "vz": (steps / 2) * GRAVITY + dz}

	queue.enqueue(STAGE_LEAVE, 1,
		func(_frame: int, _total: int) -> void:
			var aim: Vector2i = host.orient(source, target)
			host.turn_body(slot, aim.y)
			host.place_body(slot, source)
			host.spawn_program(BlobPrograms.LANDING_DUST,
				PackedInt32Array([from.x, from.y]))
			if own:
				host.play_cues(cues_jump)
			else:
				var pick: int = host.draw2(0, SCREAMS)
				if pick < screams.size():
					var scream: Array[Dictionary] = []
					for cue: Variant in DictRead.as_array(screams[pick]):
						scream.append(DictRead.as_dict(cue))
					host.play_cues(scream))

	queue.enqueue(STAGE_FLY, steps,
		func(_frame: int, _total: int) -> void:
			var at: Vector3i = st["at"]
			var vz: int = DictRead.as_int(st["vz"])
			at = Vector3i(at.x + dx, at.y + dy, at.z + vz)
			st["at"] = at
			st["vz"] = vz - GRAVITY
			host.place_body(slot, at)
			host.set_camera_target(at)
			if own:
				host.spawn_at(BlobPrograms.TRAIL, at + Vector3i(0, 0, TRAIL_UP)))

	queue.enqueue(STAGE_LAND, 1,
		func(_frame: int, _total: int) -> void:
			host.place_body(slot, target + Vector3i(0, 0, LAND_UP))
			host.set_camera_target(target + Vector3i(0, 0, LAND_UP))
			host.spawn_program(BlobPrograms.LANDING_DUST,
				PackedInt32Array([to.x, to.y]))
			host.play_cues(cues_drop))

	queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
		func() -> bool: return host.pool_live() == 0,
		func(frame: int, total: int) -> void:
			if frame == total or host.pool_live() == 0:
				host.settle_body(slot))
	return 1 + steps + 1
