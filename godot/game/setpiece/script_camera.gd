class_name ScriptCamera
extends RefCounted

## The mission script's own camera commands (docs/42 section 2.4, docs/20's
## camera family), as steps on the [SequenceQueue] over the same [ShotHost]
## every other driver uses (docs/97 section 34).
##
## Six commands, each read out of its handler:
##
## * `MoveCamera (fromX, fromY, toX, toY, h)` `0x00441AA0` -- the camera to
##   the object on the first tile at `h * 1600`, looking at the object on
##   the second at z 0. 230 uses, the most-used of them.
## * `MoveTarget (x, y)` `0x00441C40` -- the position kept, the target on
##   that tile's object at z 0.
## * `MovePosition (x, y, h)` `0x00441D00` -- the mirror: the target kept,
##   the camera to that object at `h * 3200`.
## * `RotatingCamera (x, y, h)` `0x00440FC0` -- the orbit of docs/42
##   section 7.5 around the tile, at `h * 160`.
## * `SaveCamera ()` / `LoadCamera ()` `0x00441B90` / `0x00441C00` -- all six
##   numbers pushed to and popped from the globals at `0x0050C088`.
##
## Every one of them goes through `0x0040EEE0`, the **flight**, so each is a
## step that waits for the camera rather than a snap; the queue is what
## makes a script that moves the camera twice show both moves.
##
## `MoveWorld` is not here: it translates the scene itself (`0x00407E30`),
## which is the scenery's business and not the camera's.

## docs/20's height scales, one per command.
const MOVE_CAMERA_SCALE: int = 1600
const MOVE_POSITION_SCALE: int = 3200
const ROTATING_SCALE: int = 160

const STAGE: String = "script.camera"

## The commands this driver answers to.
const KINDS: Array[String] = ["move_camera", "move_target", "move_position",
	"rotating_camera", "save_camera", "load_camera"]


static func handles(kind: String) -> bool:
	return KINDS.has(kind)


## Queue one camera command. `saved` is the caller's stack of six-number
## views, which `save_camera` pushes to and `load_camera` pops from -- the
## engine's globals, held by the scene. Answers the deterministic frames,
## which for a flight is zero: the step is open-ended and waits for it.
static func enqueue(queue: SequenceQueue, host: ShotHost, kind: String,
		values: PackedInt32Array, saved: Array[Array]) -> int:
	match kind:
		"save_camera":
			queue.enqueue(STAGE, 1,
				func(_frame: int, _total: int) -> void:
					var eye: Vector3i = host.camera_eye()
					var target: Vector3i = host.camera_target()
					saved.append([eye.x, eye.y, eye.z, target.x, target.y,
						target.z]))
			return 1
		"load_camera":
			# `once` and not `frame == 1`: [method SequenceQueue.skip] paints a
			# remaining step once at its **last** frame, so a command skipped
			# by a key press must still pop the view it was going to load --
			# otherwise the stack keeps an entry and every later `LoadCamera`
			# in the mission restores an older one.
			var once: Dictionary = {}
			queue.enqueue_until(STAGE, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(_frame: int, _total: int) -> void:
					if once.has("done") or saved.is_empty():
						return
					once["done"] = true
					var six: Array = saved.pop_back()
					var _f: int = host.fly(
						Vector3i(DictRead.as_int(six[0]), DictRead.as_int(six[1]),
							DictRead.as_int(six[2])),
						Vector3i(DictRead.as_int(six[3]), DictRead.as_int(six[4]),
							DictRead.as_int(six[5]))))
			return 0
		"rotating_camera":
			# docs/42 section 7.5's sixth orbit, with the script's own height.
			return OrbitSequence.enqueue(queue, host, -1,
				OrbitSequence.KIND_ROTATING, "", [], 0,
				_at(values, 2, 0) * ROTATING_SCALE,
				Vector2i(_at(values, 0, 0), _at(values, 1, 0)))
		_:
			# Same reason as `load_camera` above: a skipped command must still
			# leave the view the script asked for.
			var once: Dictionary = {}
			queue.enqueue_until(STAGE, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(_frame: int, _total: int) -> void:
					if once.has("done"):
						return
					once["done"] = true
					var eye: Vector3i = host.camera_eye()
					var target: Vector3i = host.camera_target()
					match kind:
						"move_camera":
							eye = host.cell_object(_at(values, 0, 0), _at(values, 1, 0))
							eye.z = _at(values, 4, 0) * MOVE_CAMERA_SCALE
							target = host.cell_object(_at(values, 2, 0),
								_at(values, 3, 0))
							target.z = 0
						"move_target":
							target = host.cell_object(_at(values, 0, 0),
								_at(values, 1, 0))
							target.z = 0
						"move_position":
							eye = host.cell_object(_at(values, 0, 0), _at(values, 1, 0))
							eye.z = _at(values, 2, 0) * MOVE_POSITION_SCALE
					var _f: int = host.fly(eye, target))
			return 0


static func _at(values: PackedInt32Array, index: int, fallback: int) -> int:
	return values[index] if index >= 0 and index < values.size() else fallback
