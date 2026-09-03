class_name PushSequence
extends RefCounted

## The push `0x0046D530` (docs/42 section 7.2) as steps on the
## [SequenceQueue]: a flight to the pusher, four frames a cell moving the
## pushed object by a third of the way with a dust puff (`0x0042A6E0`) at
## its position each frame, the object snapped to the cell after them; a
## hole swallows it in fifty steps of `z -= 320`; the pool is waited for at
## the end, and there is no flight back. `core` has already moved the record
## and, for a hole, removed it; this is the picture of that.
##
## The numbers are `presentation_tables.py`'s `push.*` pins; the flight's
## eye and target come from the same reading of the routine (docs/97
## section 31).

## `cmp eax, 4` -- frames a cell.
const FRAMES_PER_CELL: int = 4
## The magic divide by three of the remaining delta, each frame.
const THIRD: int = 3
## `cmp edi, 0x32` and the `320` a step -- the hole.
const HOLE_STEPS: int = 50
const HOLE_DROP: int = 320
## The object is put down this far above the cell.
const LAND_UP: int = 0xA0
## `0x0047AD30(unit)` -- half the type's height plus 800: the flight's eye
## is this far above the pusher's object, and its target this far above
## the pushed one.
const FULL_HEIGHT_EXTRA: int = 800
## The wait for the pool has no bound in the engine; **the remake's**,
## longer than the dust lives (20 ticks).
const POOL_WAIT_FRAMES: int = 60

const STAGE_FLIGHT: String = "push.flight"
const STAGE_CELL: String = "push.cell"
const STAGE_HOLE: String = "push.hole"
const STAGE_POOL: String = "push.pool"


## `0x0047AD30(unit)`.
static func full_height(unit_height: int) -> int:
	return IncInt.div_trunc(unit_height, 2) + FULL_HEIGHT_EXTRA


## Queue one push by `pusher` of `pushed`, which stood at `from` and is
## moved through `cells` in order; `hole` when the last cell swallowed it.
## Answers the deterministic frames.
static func enqueue(queue: SequenceQueue, host: ShotHost, pusher: int,
		pushed: int, from: Vector2i, cells: Array[Vector2i], hole: bool) -> int:
	var st: Dictionary = {"at": Vector3i.ZERO}
	var height: int = full_height(host.unit_height(pusher))
	var total: int = 0

	queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
		func() -> bool: return not host.camera_flying(),
		func(frame: int, _total: int) -> void:
			if frame != 1:
				return
			var start: Vector3i = host.cell_object(from.x, from.y)
			st["at"] = start
			host.place_body(pushed, start)
			var _frames: int = host.fly(
				host.object_of(pusher) + Vector3i(0, 0, height),
				start + Vector3i(0, 0, height)))

	for cell: Vector2i in cells:
		var goal: Vector3i = host.cell_object(cell.x, cell.y)
		queue.enqueue(STAGE_CELL, FRAMES_PER_CELL,
			func(frame: int, frames: int) -> void:
				var at: Vector3i = st["at"]
				var delta: Vector3i = goal - at
				at = Vector3i(at.x + IncInt.div_trunc(delta.x, THIRD),
					at.y + IncInt.div_trunc(delta.y, THIRD),
					at.z + IncInt.div_trunc(delta.z, THIRD))
				host.spawn_at(BlobPrograms.PUSH_DUST, at)
				if frame == frames:
					at = goal + Vector3i(0, 0, LAND_UP)
				st["at"] = at
				host.place_body(pushed, at))
		total += FRAMES_PER_CELL

	if hole:
		queue.enqueue(STAGE_HOLE, HOLE_STEPS,
			func(frame: int, frames: int) -> void:
				var at: Vector3i = st["at"]
				at = Vector3i(at.x, at.y, at.z - HOLE_DROP)
				st["at"] = at
				host.place_body(pushed, at)
				if frame == frames:
					host.hide_unit(pushed))
		total += HOLE_STEPS

	queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
		func() -> bool: return host.pool_live() == 0,
		func(frame: int, frames: int) -> void:
			if not hole and (frame == frames or host.pool_live() == 0):
				host.settle_body(pushed))
	return total
