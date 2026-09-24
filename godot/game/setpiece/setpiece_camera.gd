class_name SetpieceCamera
extends RefCounted

## The camera and the effects of the set pieces (docs/42 section 8), over
## the [SetpieceDriver]'s frame counts and on the same [ShotHost] the shot
## uses, so a suite can run them on a recording double (docs/97 section 32).
##
## Every `aPlay*Sequence` has one shape: read the camera, fly to the object,
## run its frames with the camera set each one where the routine does, wait
## for the pool, fly back where the routine does. `core` has applied the
## state change already; `paint(frame, frames)` is the caller's picture of
## the cell and its rider, and this adds the camera and the creators around
## it. What each kind does is read out of its routine:
##
## * `open_door` `0x00410A20`: a flight from above the unit's object to the
##   **panel** -- the object `0x00406F20` finds beside the cell's marker --
##   with both ends at the panel's z plus the unit's height (`0x0047AD70`
##   twice, `0x00410C10`), ten frames, a flight back -- only when a unit is
##   named; the LCL wrapper passes none. The target used to stand at the
##   *cell's* height, 3200 on a closed door, which tipped the camera up at
##   the lintel (2026-09-06); `extra["object"]` is the panel's position now,
##   and the cell centre at its height is the fallback for a door with no
##   object, which the shipped corpus has none of.
## * `open_tube` `0x00410F10`: nineteen frames turning the tube's object,
##   the puffs `0x00423770` at the tenth (`cmp esi, 0xA`); `OpenPlantTube`
##   and `OpenFrontDoor` are the same frames with no puffs. The turn of the
##   hatch itself is the caller's `paint` ([method SliceMain._paint_setpiece]
##   through [method Scenery.paint_joint], docs/42 section 8.3), as the
##   door's leaves are.
## * `lever` `0x00416AD0`: a flight from the user's object to the lever's
##   **object** -- `0x00406F20`'s find beside the marker, `extra["object"]`
##   -- with both ends `0xC80` above that object's own z (`add eax, 0xC80`,
##   `0x00416BCB`, over `[esi+0x18]`), ten frames of the handle, the flight
##   back.
## * `pickup` `0x00410780`: the box's text goes up first (`aActivateInfo`
##   at `0x004107AC`), then a flight from `0xFA0` above the user's marker
##   to `0x320` above the **box object's** own z (`0x004108DA`,
##   `0x004108C5`), twenty frames of the lid, fifteen of nothing, and the
##   flight back.
## * `foot_bridge` `0x00414A70`: a flight to the block (the object within
##   5 000 units), then every frame the eye `0x960` and the target `0xD20`
##   lower while the block tilts and drops under the caller's `paint`; the
##   block is freed at the end (docs/42 section 8.1).
## * `ground_fire` `0x004157B0`: the flight the **round sweep** asks for --
##   the camera's own eye lifted to at least `0x3200`, turned free of the
##   burning cell's land marker -- then every victim hidden with a
##   `BloodFlood` and a `FlyingDebris` on its own tile, one
##   `aBlob_CreateTubeSmoke` on the cell whether or not there were any, and
##   the pool (docs/42 section 9.1).
## * `crush_wall` `0x00415C70`: the debris, then the wall turns and sinks
##   under `paint` until the pool is empty, and `extra["finish"]` -- the
##   caller's `aDeleteLand` -- runs when that stage ends, early or not.
## * `elevator` `0x004125D0`, `platform` `0x00412A00`: the eye kept, a
##   flight of the target to the object, then the target set on it every
##   frame; the platform raises `0x004234C0` at the block every frame.
## * `roof_unit` `0x00411B00`: the eye kept, the target flown to the drop's
##   start, `0x00422460` there, five frames, then the fall with the target
##   on the body every frame, the landing dust, the pool waited for. The
##   four-frame wait for an odd type's scream is not taken: the remake's
##   sound layer plays the cue without holding the picture (named).
## * `ground_unit` `0x00411FB0`: the body at the ground cell 3200 below its
##   top less its height, `0x00422610` 1600 above the object, eight frames
##   of 1120 up drawn 1280 higher, six frames of a fifth of the way to its
##   own cell, the dust, the pool, with the inserted `L110EX00.3DI` hole
##   left at the emergence cell.

const DOOR_FRAMES: int = SetpieceDriver.DOOR_FRAMES
## `cmp esi, 0xA` -- the tube's puffs come on this frame.
const TUBE_PUFF_FRAME: int = 10
## `add eax, 0xC80` -- the lever's flight, both ends above the marker.
const LEVER_CAMERA_UP: int = 0xC80
## `add ecx, 0xFA0` / `add edx, 0x320` -- the supply box's flight starts
## above the user's marker and aims just above the box's.
const PICKUP_EYE_UP: int = 0xFA0
const PICKUP_TARGET_UP: int = 0x320
## `sub edx, 0x960` / `sub ecx, 0xD20` -- the footbridge's camera follows
## the block down, the eye slower than the target.
const FOOTBRIDGE_EYE_DROP: int = 0x960
const FOOTBRIDGE_TARGET_DROP: int = 0xD20
## `mov edi, 5` -- the frames between the debris and the drop.
const ROOF_LEAD_FRAMES: int = 5
const ROOF_DROP_STEP: int = SetpieceDriver.ROOF_DROP_STEP
## `add eax, 0xA0` -- the falling object is drawn this far above its z.
const ROOF_DRAWN_UP: int = 0xA0
## `0x00411FB0`: the ground unit's rise and its carry.
const GROUND_RISE_FRAMES: int = 8
const GROUND_CARRY_FRAMES: int = 6
const GROUND_RISE: int = 0x460
const GROUND_DRAWN_UP: int = 0x500
const GROUND_START_DOWN: int = 0xC80
const GROUND_HOLE_MODEL: String = "L110EX00.3DI"
const GROUND_DEBRIS_UP: int = 0x640
const GROUND_LAND_UP: int = 0xA0
const GROUND_FIFTH: int = 5
## The wait for the pool has no bound in the engine; **the remake's**.
const POOL_WAIT_FRAMES: int = 100

## `push 0x7D00` -- the statue's camera flies to twenty metres up.
const STATUE_HEIGHT: int = 32000
## `mov eax, 0x3200 / cmp ecx, eax / jge` at `0x004158FC` -- the ground fire's
## flight will not start below twelve and a half metres.
const GROUND_FIRE_EYE_FLOOR: int = 0x3200
## `push 0x14` -- `FireCircle` passes 20 as `KillFire`'s delay.
const FIRE_CIRCLE_DELAY: int = 20
## The eight cells `FireCircle` sets alight (`cmp ebx, 7`).
const NEIGHBOURS: Array[Vector2i] = [Vector2i(-1, -1), Vector2i(0, -1),
	Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1),
	Vector2i(0, 1), Vector2i(1, 1)]
## `mov edi, 0xFFFFC180` -- the bomber enters from x = -16000, and its
## height is one of **two** arms the routine's own `flightpath` argument
## picks: `mov ebp, 0x13880` = 80000 for path 1 and `mov ebp, 0x4E200` =
## 320000 for path 0 (`0x00415F59`; anything else is the routine's own
## *unknown flightpath* assertion). `ParaBombs` passes 0 in all four shipped
## call sites (docs/20's camera family), so the second is what a script
## reaches -- and `docs/42` §8's "-320 000" had the sign of the **x** on the
## height. The remake takes path 0.
## `0x00415EE1` -- `aBlob_CreateBomber(-320000, -320000, 320000, 48000,
## 48000, 320000)`, six literals the routine never varies.
const BOMBER_FROM: Vector3i = Vector3i(-320000, -320000, 320000)
const BOMBER_TO: Vector3i = Vector3i(48000, 48000, 320000)
const BOMBER_START_X: int = -16000
const BOMBER_START_Z: int = 320000
const BOMBER_START_Z_PATH_1: int = 80000
## The delay between bombs -- [constant SetpieceDriver.BOMB_SPACING], which is
## where the compression of `0x00416231`'s `aRandom2(0, 200)` is written down.
const BOMB_SPACING: int = SetpieceDriver.BOMB_SPACING
## `push 0xC80 / push 0 / push 0` at `0x00416319` -- the bomb run is watched
## from the **ground**: the eye stands at the world's own corner, one field
## up, and does not move for the length of the strike.
const BOMB_RUN_EYE: Vector3i = Vector3i(0, 0, 3200)
## `cmp eax, 0x1F40` at `0x004162F6` -- and the target is the falling bomb
## with its z clamped to this, so the camera looks at where the bomb is going
## rather than craning up at the sky it fell out of.
const BOMB_RUN_CEILING: int = 8000
## `mov edi, 3` at `0x00416271` -- the bomb run creates **three** `crush.wav`
## buffers before its loop and plays them in turn (`0x004163A1`'s
## `inc esi / cmp esi, 3`), the index advancing on every raised *arrived*
## whether or not the buffer it lands on was free. A buffer that is still
## sounding swallows the play whole, `aDirectSoundPlayBuffer` `0x00436EF0`
## being `IDirectSoundBuffer::Play` with no `Stop` in front of it -- so a
## stick of sixty mines is a few thuds, not sixty laid over each other.
const BOMB_BUFFERS: int = 3
## How long the fly-past holds the picture, at most.
##
## `0x00415E90` has no count of its own: it spins on the *arrived* flag of
## docs/42 section 4.6 until something raises it. In the engine that is the
## first para bomb the plane drops in flight (`aRandom(0, 8) == 0` in
## [BlobKinds]' kind 52, through `0x0042B150`, life **200**) reaching the end
## of its life, which puts the original's fly-past at some two hundred ticks.
##
## The remake drops those bombs too -- `0x0042B150` is transcribed since
## docs/97 section 49 and [GameBlobHooks] runs the request -- but it does not
## wait for one to land: their kind-25 record carries a life of 200 and the
## plane's carries 150, so no bomb the plane drops raises the flag inside this
## stage, and a two-hundred-tick fly-past would in any case sit oddly against
## [constant SetpieceDriver.BOMB_SPACING]'s deliberate compression of the
## strike. What ends it here is the bomber's **own record**:
## [constant SetpieceDriver.BOMBER_LIFE_FRAMES] is the life `0x0042A8E0`
## gives it. The engine's condition is still asked first, and it is a real
## question rather than a formality -- the creator clears the flag, as
## `0x0042A938` does, so anything the pool was already holding can still end
## the fly-past early, exactly as it would in the original.
const BOMBER_FRAMES: int = SetpieceDriver.BOMBER_LIFE_FRAMES
## `cmp esi, 0x28` and `cmp esi, 0xA` -- the teleporter's two marks, counted
## from its end.
const TELEPORT_HIDE_AT: int = 40
const TELEPORT_MOVE_AT: int = 10

const STAGE_FLIGHT: String = "setpiece.flight"
const STAGE_BEAM: String = "setpiece.beam"
const STAGE_BACK: String = "setpiece.back"
const STAGE_LEAD: String = "setpiece.lead"
const STAGE_LAND: String = "setpiece.land"
const STAGE_POOL: String = "setpiece.pool"
const STAGE_DROP: String = "setpiece.drop"


## Queue the set piece `kind` of `frames` frames on `cell`, whose height
## goes from `from_h` to `to_h`. `unit` is the unit the routine is about
## (the door's user, the roof's cargo, the ground unit's victim), or -1;
## `extra` carries the ground unit's own cell as `own`. `paint` is the
## caller's per-frame picture. Answers the deterministic frames.
##
## `cues` are the sounds of the routine the set piece starts with; `cues_late`
## those of the **second** routine, for the one command that runs two
## ([constant AudioEvents.EVENT_PHASES]). When and how often the second
## routine's sounds are heard is that routine's own business -- the bomb run
## plays them once per bomb, not once per stage -- so `cues_late` is handed to
## the arm rather than to the queue. Every other kind ignores it.
## One landing's crump, into the bomb run's own three buffers.
##
## The index advances every time, as `0x004163A1` does; the play happens only
## when the buffer it lands on has finished, which is what
## `IDirectSoundBuffer::Play` decides for the engine. So the first three
## crumps of a strike sound and the rest thin out to the sample's own length
## -- against one fresh voice per bomb, which on a stick of sixty was a wall
## with a tail of reverberation on it. Public for the suite.
static func crump(host: ShotHost, cues: Array[Dictionary],
		st: Dictionary) -> void:
	if cues.is_empty():
		return
	var at: int = DictRead.as_int(st["crump"])
	var buffers: PackedInt32Array = DictRead.as_int32_array(st["buffers"])
	if at < buffers.size() and not host.sound_playing(buffers[at]):
		var took: PackedInt32Array = host.play_cues_slots(cues)
		buffers[at] = took[0] if took.size() > 0 else -1
		st["buffers"] = buffers
	st["crump"] = (at + 1) % BOMB_BUFFERS


## Both statues' beam pass: every victim hidden under its `FireDeath`, then
## `0x00428BF0` from the statue's cell to each arm's endpoint.
static func _statue_beam(host: ShotHost, cell: Vector2i,
		extra: Dictionary) -> void:
	for entry: Variant in DictRead.as_array(extra.get("killed", [])):
		var victim: Dictionary = DictRead.as_dict(entry)
		var slot: int = DictRead.as_int(victim.get("slot", -1))
		if slot >= 0:
			host.hide_unit(slot)
		host.spawn_program(BlobPrograms.FIRE_DEATH,
			PackedInt32Array([DictRead.as_int(victim["x"]),
				DictRead.as_int(victim["y"])]))
	for entry: Variant in DictRead.as_array(extra.get("beams", [])):
		var beam: Dictionary = DictRead.as_dict(entry)
		host.spawn_program(BlobPrograms.STATUE_BEAM,
			PackedInt32Array([cell.x, cell.y,
				DictRead.as_int(beam["x"]), DictRead.as_int(beam["y"]),
				DictRead.as_int(beam["cells"])]))


## Whether a routine that turns the camera only for a far object would turn
## it: the camera's target more than [constant SetpieceDriver.TURN_RANGE]
## from the object on x or on y (`cmp eax, 0x3840` twice).
static func _far(target: Vector3i, at: Vector3i) -> bool:
	return absi(target.x - at.x) > SetpieceDriver.TURN_RANGE \
		or absi(target.y - at.y) > SetpieceDriver.TURN_RANGE


## One of `FallingSpores`' drops, `0x00414550`: the camera turned to look
## [constant SetpieceDriver.DROP_LOOK_UP] above the object when it is far
## off (`0x0041469F`, the eye kept), the model inserted at 32000 under a
## heading drawn from the effect stream (`aRandom2(0, 0xFFF)`, `0x004146B3`)
## and lowered frame by frame onto the marker, then the landing dust
## `0x004227C0` and `drop.wav`, killed three frames in (`0x00414785`).
## Answers the frames it queued, the flight's aside.
static func _enqueue_drop(queue: SequenceQueue, host: ShotHost, model: String,
		drop: Dictionary, cues: Array[Dictionary]) -> int:
	var tile: Vector2i = Vector2i(DictRead.as_int(drop["x"]),
		DictRead.as_int(drop["y"]))
	var at: Vector3i = Vector3i(tile.x * WorldSpace.WORLD_UNITS_PER_FIELD,
		tile.y * WorldSpace.WORLD_UNITS_PER_FIELD, DictRead.as_int(drop["z"]))
	var heights: PackedInt32Array = SetpieceDriver.drop_heights(at.z)
	var st: Dictionary = {}
	queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
		func() -> bool: return not host.camera_flying(),
		func(_frame: int, _total: int) -> void:
			if st.has("turned"):
				return
			st["turned"] = true
			if _far(host.camera_target(), at):
				var _f: int = host.fly(host.camera_eye(),
					at + Vector3i(0, 0, SetpieceDriver.DROP_LOOK_UP)))
	var falling: int = maxi(heights.size(), 1)
	queue.enqueue(STAGE_DROP, falling,
		func(frame: int, _total: int) -> void:
			if not st.has("inserted"):
				st["inserted"] = true
				var _made: bool = host.insert_object(model, at,
					host.draw2(0, SetpieceDriver.DROP_HEADING_SPAN))
			var index: int = clampi(frame, 1, heights.size()) - 1
			var z: int = heights[index] if not heights.is_empty() else at.z
			var _lifted: bool = host.lift_object(model, at, maxi(z - at.z, 0)))
	queue.enqueue(STAGE_LAND, SetpieceDriver.DROP_SOUND_FRAMES,
		func(frame: int, _total: int) -> void:
			if frame != 1 or st.has("landed"):
				return
			st["landed"] = true
			if not st.has("inserted"):
				st["inserted"] = true
				var _made: bool = host.insert_object(model, at,
					host.draw2(0, SetpieceDriver.DROP_HEADING_SPAN))
			var _lifted: bool = host.lift_object(model, at, 0)
			host.spawn_program(BlobPrograms.LANDING_DUST,
				PackedInt32Array([tile.x, tile.y])),
		cues)
	return falling + SetpieceDriver.DROP_SOUND_FRAMES


static func enqueue(queue: SequenceQueue, host: ShotHost, kind: String,
		frames: int, cell: Vector2i, from_h: int, to_h: int, unit: int,
		extra: Dictionary, paint: Callable, cues: Array[Dictionary],
		cues_late: Array[Dictionary] = []) -> int:
	var st: Dictionary = {"saved_eye": Vector3i.ZERO, "saved_target": Vector3i.ZERO,
		"at": Vector3i.ZERO, "landed": false, "crump": 0,
		"buffers": PackedInt32Array([-1, -1, -1])}
	var centre: Vector3i = Vector3i(cell.x * WorldSpace.WORLD_UNITS_PER_FIELD,
		cell.y * WorldSpace.WORLD_UNITS_PER_FIELD, from_h)
	match kind:
		"open_door":
			if unit >= 0:
				var panel: Vector3i = DictRead.as_vector3i(extra["object"]) \
					if extra.has("object") else centre
				queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
					func() -> bool: return not host.camera_flying(),
					func(frame: int, _total: int) -> void:
						if frame != 1:
							return
						st["saved_eye"] = host.camera_eye()
						st["saved_target"] = host.camera_target()
						var h: int = host.unit_height(unit)
						var opener: Vector3i = host.object_of(unit)
						var _f: int = host.fly(
							Vector3i(opener.x, opener.y, panel.z + h),
							panel + Vector3i(0, 0, h)))
			queue.enqueue(kind, frames, paint, cues)
			if unit >= 0:
				queue.enqueue_until(STAGE_BACK, ShotSequence.SAFETY_FRAMES,
					func() -> bool: return not host.camera_flying(),
					func(frame: int, _total: int) -> void:
						if frame == 1:
							var saved_eye: Vector3i = st["saved_eye"]
							var saved_target: Vector3i = st["saved_target"]
							var _b: int = host.fly(saved_eye, saved_target))
			return frames
		"lever", "pickup":
			# The door's shape, with each routine's own two heights: the
			# lever flies from the user's object to the marker with both
			# ends `0xC80` up; the box from `0xFA0` above the user to
			# `0x320` above the box's marker, the marker being the cell's
			# centre at its height. Neither routine has a wrapper that
			# passes no unit, but the guard is kept for symmetry with the
			# door: no unit, no flight.
			# **Both aim at the object, not at the cell.** `0x00416BC2`
			# reads `[esi+0x10/0x14/0x18]` of the object `0x00406F20` found
			# beside the marker and adds `0xC80` to *that* z for both ends
			# of the flight; the box's `0x004108BF` does the same with
			# `0x320`. On `_C_115` the lever's `L109EX00` stands at 12 800
			# where its cell is 15 999, so taking the cell's height put the
			# camera a whole field above the handle and looked over it at
			# the wall behind -- the door's own defect of 2026-09-06, in
			# the two routines beside it. The cell centre at its height is
			# the fallback, for a cell whose object the search misses.
			if unit >= 0:
				var object: Vector3i = DictRead.as_vector3i(extra["object"]) \
					if extra.has("object") else centre
				queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
					func() -> bool: return not host.camera_flying(),
					func(frame: int, _total: int) -> void:
						if frame != 1:
							return
						st["saved_eye"] = host.camera_eye()
						st["saved_target"] = host.camera_target()
						var user: Vector3i = host.object_of(unit)
						var eye: Vector3i = Vector3i(user.x, user.y,
							object.z + LEVER_CAMERA_UP)
						var at: Vector3i = object + Vector3i(0, 0, LEVER_CAMERA_UP)
						if kind == "pickup":
							eye = user + Vector3i(0, 0, PICKUP_EYE_UP)
							at = object + Vector3i(0, 0, PICKUP_TARGET_UP)
						var _f: int = host.fly(eye, at))
			queue.enqueue(kind, frames, paint, cues)
			if unit >= 0:
				queue.enqueue_until(STAGE_BACK, ShotSequence.SAFETY_FRAMES,
					func() -> bool: return not host.camera_flying(),
					func(frame: int, _total: int) -> void:
						if frame == 1:
							var saved_eye: Vector3i = st["saved_eye"]
							var saved_target: Vector3i = st["saved_target"]
							var _b: int = host.fly(saved_eye, saved_target))
			return frames
		"open_tube", "open_plant_tube", "open_front_door":
			queue.enqueue(kind, frames,
				func(frame: int, total: int) -> void:
					paint.call(frame, total)
					if kind == "open_tube" and frame == TUBE_PUFF_FRAME:
						host.spawn_program(BlobPrograms.TUBE_PUFFS,
							PackedInt32Array([cell.x, cell.y])),
				cues)
			return frames
		"foot_bridge", "foot_bridge2":
			# docs/42 section 8.1: the flight to the block, then the camera
			# lowered every frame -- the eye by `0x960`, the target by
			# `0xD20` -- while the block tilts and drops under `paint`, and
			# the flight back. The tilt itself is the caller's, drawn once
			# from `aRandom2(-2, 4)` through the host's `draw2`.
			var block: Vector3i = DictRead.as_vector3i(extra["object"]) \
				if extra.has("object") else centre
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame == 1:
						st["saved_eye"] = host.camera_eye()
						st["saved_target"] = host.camera_target()
						var _f: int = host.fly(host.camera_eye(), block))
			queue.enqueue(kind, frames,
				func(frame: int, total: int) -> void:
					if frame == 1:
						st["at"] = host.camera_eye()
					var eye: Vector3i = st["at"]
					host.set_camera(
						eye - Vector3i(0, 0, FOOTBRIDGE_EYE_DROP * frame),
						block - Vector3i(0, 0, FOOTBRIDGE_TARGET_DROP * frame))
					paint.call(frame, total),
				cues)
			queue.enqueue_until(STAGE_BACK, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame == 1:
						var saved_eye: Vector3i = st["saved_eye"]
						var saved_target: Vector3i = st["saved_target"]
						var _b: int = host.fly(saved_eye, saved_target))
			return frames
		"elevator", "platform":
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame == 1:
						var _f: int = host.fly(host.camera_eye(), centre))
			queue.enqueue(kind, frames,
				func(frame: int, total: int) -> void:
					paint.call(frame, total)
					var h: int = from_h + roundi(float(to_h - from_h)
						* SetpieceDriver.progress(frame, total))
					var at: Vector3i = Vector3i(centre.x, centre.y, h)
					# The platform's loop adds its step to the camera
					# target as to the block (docs/20 section 7.4 step 2),
					# so the target -- and the dust -- travel with the deck.
					if kind == "platform" and extra.has("travel"):
						var travel: Vector3i = DictRead.as_vector3i(extra["travel"])
						at += Vector3i(Vector3(travel)
							* SetpieceDriver.progress(frame, total))
					host.set_camera_target(at)
					if kind == "platform":
						host.spawn_at(BlobPrograms.PLATFORM_DUST, at),
				cues)
			return frames
		"roof_unit":
			var start_z: int = to_h + frames * ROOF_DROP_STEP
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame == 1:
						var _f: int = host.fly(host.camera_eye(),
							Vector3i(centre.x, centre.y, start_z)))
			queue.enqueue(STAGE_LEAD, ROOF_LEAD_FRAMES,
				func(frame: int, _total: int) -> void:
					if frame == 1:
						host.spawn_program(BlobPrograms.ROOF_DEBRIS,
							PackedInt32Array([cell.x, cell.y, start_z]))
						if unit >= 0:
							host.show_unit(unit)
							host.place_body(unit, Vector3i(centre.x, centre.y,
								start_z + ROOF_DRAWN_UP)))
			queue.enqueue(kind, frames,
				func(frame: int, total: int) -> void:
					paint.call(frame, total)
					var z: int = maxi(to_h, start_z - frame * ROOF_DROP_STEP)
					var at: Vector3i = Vector3i(centre.x, centre.y, z)
					host.set_camera_target(at)
					if unit >= 0:
						host.place_body(unit, at + Vector3i(0, 0, ROOF_DRAWN_UP)),
				# `RoofUnit` `0x00411B00` keeps its buffers through the landing
				# and the pool it then drains: the drop is a stage of the
				# routine, not the routine (docs/28 section 1.4).
				cues, true)
			queue.enqueue(STAGE_LAND, 1,
				func(_frame: int, _total: int) -> void:
					host.spawn_program(BlobPrograms.LANDING_DUST,
						PackedInt32Array([cell.x, cell.y]))
					if unit >= 0:
						host.settle_body(unit))
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return ROOF_LEAD_FRAMES + frames + 1
		"ground_unit":
			var own: Vector2i = extra.get("own", cell)
			var goal: Vector3i = host.cell_object(own.x, own.y)
			# GroundUnit mutates the world before its presentation routine runs.  Hide
			# every queued arrival now, while all of the script's set pieces are being
			# assembled, so a picture rebuild for an earlier camera move cannot reveal
			# the alien standing at its destination.  The flight stage below reveals
			# just this unit after placing it below the floor.
			if unit >= 0:
				host.suppress_unit(unit)
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					# The script has already inserted the alien, but the picture's
					# mirror lands that insertion only when this set piece begins.
					# Materialise its suppressed body before trying to place it below
					# the floor; otherwise every placement is a no-op and only the
					# debris is seen until the ordinary rebuild creates the unit.
					# A dedicated flag rather than `frame == 1` also covers a skipped sequence,
					# whose first paint is its last frame.
					if st.has("ground_started"):
						return
					st["ground_started"] = true
					var h: int = host.unit_height(unit) if unit >= 0 else 0
					var ground: Vector3i = host.cell_object(cell.x, cell.y)
					var at: Vector3i = Vector3i(ground.x, ground.y,
						ground.z - GROUND_START_DOWN - h)
					st["at"] = at
					if unit >= 0:
						host.show_unit(unit)
						host.place_body(unit, at + Vector3i(0, 0, GROUND_LAND_UP))
					var _f: int = host.fly(host.camera_eye(),
						at + Vector3i(0, 0, GROUND_LAND_UP))
					var _hole: bool = host.insert_object(GROUND_HOLE_MODEL, ground)
					host.spawn_program(BlobPrograms.GROUND_DEBRIS,
						PackedInt32Array([cell.x, cell.y, ground.z + GROUND_DEBRIS_UP])))
			queue.enqueue(kind, GROUND_RISE_FRAMES,
				func(frame: int, total: int) -> void:
					paint.call(frame, total)
					var at: Vector3i = st["at"]
					at = Vector3i(at.x, at.y, at.z + GROUND_RISE)
					st["at"] = at
					host.set_camera_target(at + Vector3i(0, 0, GROUND_DRAWN_UP))
					if unit >= 0:
						host.place_body(unit, at + Vector3i(0, 0, GROUND_DRAWN_UP)),
				# `GroundUnit` `0x00411FB0` carries the body after the rise and
				# drains its pool after that, all inside one routine, so the
				# rise holds its sound rather than ending it.
				cues, true)
			queue.enqueue(STAGE_LEAD, GROUND_CARRY_FRAMES,
				func(frame: int, _total: int) -> void:
					var at: Vector3i = st["at"]
					# `not st.has("step")` and not only `frame == 1`: a key
					# press makes [method SequenceQueue.skip] paint every
					# remaining step once at its **last** frame, so this
					# closure can be entered for the first time with
					# `frame == GROUND_CARRY_FRAMES` and must still have a
					# step to walk.
					if frame == 1 or not st.has("step"):
						st["step"] = Vector3i(IncInt.div_trunc(goal.x - at.x, GROUND_FIFTH),
							IncInt.div_trunc(goal.y - at.y, GROUND_FIFTH),
							IncInt.div_trunc(goal.z - at.z, GROUND_FIFTH))
					var step: Vector3i = st["step"]
					at = at + step
					st["at"] = at
					host.set_camera_target(at + Vector3i(0, 0, GROUND_LAND_UP))
					if unit >= 0:
						host.place_body(unit, at + Vector3i(0, 0, GROUND_LAND_UP)))
			queue.enqueue(STAGE_LAND, 1,
				func(_frame: int, _total: int) -> void:
					if unit >= 0:
						host.place_body(unit, goal + Vector3i(0, 0, GROUND_LAND_UP))
						host.settle_body(unit)
					host.spawn_program(BlobPrograms.LANDING_DUST,
						PackedInt32Array([own.x, own.y])))
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return GROUND_RISE_FRAMES + GROUND_CARRY_FRAMES + 1
		"statue":
			# docs/42 section 8.1: the flight to 32000 above the camera's own
			# position looking at the statue, thirteen frames of +80 on the
			# object's rotation word and a fourteenth writing the original
			# plus a quarter turn, then the
			# beam -- `FireDeath` on every unit in its path, hidden, and
			# `0x00428BF0` from the statue to the last cell each way.
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame == 1:
						var eye: Vector3i = host.camera_eye()
						var _f: int = host.fly(
							Vector3i(eye.x, eye.y, STATUE_HEIGHT), centre))
			# **Two sounds, two phases** (`0x00413A40`'s listing):
			# `stone.wav` starts looping after the flight (`0x00413BD1`,
			# `push 1`) and is killed once the beam is drawn (`0x00413EBD`);
			# `stonefire.wav` starts there, once (`0x00413EE7`, `push 0`), and
			# is killed when the pool drains (`0x00413F22`). Both were queued
			# on the turn and cut with the beam's frame, so the fire was never
			# heard. The cues come in load order -- the grind, then the fire.
			var grind: Array[Dictionary] = cues.slice(0, 1)
			var fire: Array[Dictionary] = cues.slice(1)
			queue.enqueue(kind, frames, paint, grind)
			queue.enqueue(STAGE_BEAM, 1,
				func(_frame: int, _total: int) -> void:
					_statue_beam(host, cell, extra), fire, true)
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return frames + 1
		"fixed_statue":
			# `aPlayStatueSequence` `0x00414000`: the rotating statue's
			# routine without the turn. The flight to 32000 above
			# (`0x0041410C`), then in one pass the victim hidden under its
			# `FireDeath` (`0x004141D9`, `0x00414208`), the beam `0x00428BF0`
			# from the statue to where the walk stopped -- drawn with nobody
			# on it too -- and `stonefire.wav` (`0x00414275`), then the pool.
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame == 1:
						var eye: Vector3i = host.camera_eye()
						var _f: int = host.fly(
							Vector3i(eye.x, eye.y, STATUE_HEIGHT), centre))
			queue.enqueue(STAGE_BEAM, frames,
				func(frame: int, _total: int) -> void:
					if frame != 1:
						return
					_statue_beam(host, cell, extra), cues, true)
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return frames
		"falling_spores":
			# `0x00441F60` runs `0x00414550` once per drop, each to its end,
			# then holds on the pool (`0x00441FD4`..`0x00441FE0`).
			var model: String = DictRead.as_string(extra.get("model", ""))
			var total: int = 0
			for entry: Variant in DictRead.as_array(extra.get("drops", [])):
				total += _enqueue_drop(queue, host, model, DictRead.as_dict(entry),
					cues)
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return total
		"spores":
			# The hatch `0x004147D0`, one event per cell that hatched: the
			# camera turned to the cell's marker when it is far off
			# (`0x0041493C`), then in one pass the spore freed
			# (`aDeleteLand`), the unit put on the map, the splash
			# `0x0042B3B0` from the marker and `msqueether.wav`, held until
			# the pool drains (`0x00414A28`).
			var slot: int = DictRead.as_int(extra.get("slot", -1))
			var gone: Vector2i = DictRead.as_vector2i(extra.get("object_cell",
				Vector2i(cell.x, cell.y)))
			var splash_z: int = DictRead.as_int(extra.get("splash_z", to_h))
			var mark: Vector3i = Vector3i(centre.x, centre.y, from_h)
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame != 1 or st.has("turned"):
						return
					st["turned"] = true
					if _far(host.camera_target(), mark):
						var _f: int = host.fly(host.camera_eye(), mark))
			queue.enqueue(STAGE_LEAD, frames,
				func(frame: int, _total: int) -> void:
					if frame != 1:
						return
					var _freed: int = host.remove_cell_objects(gone.x, gone.y)
					if slot >= 0:
						host.show_unit(slot)
					host.spawn_at(BlobPrograms.SPORE_HATCH,
						Vector3i(centre.x, centre.y, splash_z)),
				cues, true)
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return frames
		"barrier_on":
			# `aPlayLaserBarrier` `0x00413560`'s on arm (docs/42 section 8):
			# the beam `0x00428990` along the barrier's direction and, in the
			# same breath, `lbarrier.wav` (`0x0041379F`, before any tick);
			# then **one** flight, chosen at `0x004137FE` on the victim count
			# -- to the emitter's marker when the beam found nobody, or, after
			# `0x0042AB40` and `0x0042A9D0` and the removal on every victim,
			# to the middle victim's marker, `victims[n / 2]` at
			# `0x00413926`; then the pool-drain loop the routine returns
			# from. There is no frame count: the `mov ecx, 0x28` the first
			# transcription took for forty frames is the `rep stosd` that
			# clears the forty-slot victim array at `[esp+0x44]`.
			var victims: Array = DictRead.as_array(extra.get("killed", []))
			var no_cues: Array[Dictionary] = []
			queue.enqueue(STAGE_LEAD, 1,
				func(_frame: int, _total: int) -> void:
					host.spawn_program(BlobPrograms.LASER_BARRIER,
						PackedInt32Array([cell.x, cell.y,
							DictRead.as_int(extra.get("direction", 0)),
							DictRead.as_int(extra.get("cells", 1))]))
					for entry: Variant in victims:
						var victim: Dictionary = DictRead.as_dict(entry)
						var vx: int = DictRead.as_int(victim["x"])
						var vy: int = DictRead.as_int(victim["y"])
						var slot: int = DictRead.as_int(victim.get("slot", -1))
						host.spawn_program(BlobPrograms.BLOOD_FLOOD,
							PackedInt32Array([vx, vy, vx, vy, 0]))
						host.spawn_program(BlobPrograms.FLYING_DEBRIS,
							PackedInt32Array([vx, vy]))
						if slot >= 0:
							host.hide_unit(slot),
				cues, true)
			# The flight is a stage inside the routine, so it holds the
			# sound on to the pool wait rather than ending it.
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame != 1:
						return
					var at: Vector3i = centre
					if not victims.is_empty():
						var middle: Dictionary = DictRead.as_dict(
							victims[victims.size() / 2])
						at = host.cell_object(DictRead.as_int(middle["x"]),
							DictRead.as_int(middle["y"]))
					var _f: int = host.fly(host.camera_eye(), at),
				no_cues, Callable(), true)
			queue.enqueue_until(STAGE_POOL, frames,
				func() -> bool: return host.pool_live() == 0, paint, no_cues)
			return 1
		"fire_circle":
			# docs/42 section 8: `KillFire` with delay 20 on the eight
			# neighbours, a flight, the ring `0x00422F00`, ten frames, the
			# pool.
			queue.enqueue(STAGE_LEAD, 1,
				func(_frame: int, _total: int) -> void:
					for step: Vector2i in NEIGHBOURS:
						host.spawn_program(BlobPrograms.KILL_FIRE,
							PackedInt32Array([cell.x + step.x, cell.y + step.y,
								FIRE_CIRCLE_DELAY])))
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame == 1:
						var _f: int = host.fly(host.camera_eye(), centre))
			queue.enqueue(kind, frames,
				func(frame: int, total: int) -> void:
					if frame == 1:
						host.spawn_program(BlobPrograms.FIRE_CIRCLE,
							PackedInt32Array([cell.x, cell.y]))
					paint.call(frame, total),
				# The ring's sound is `aPlayRotateStatueSequence`'s and lives
				# until it returns -- past these ten frames and the pool.
				cues, true)
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return frames + 1
		"ground_fire":
			# `aPlayGroundFireAnimation` `0x004157B0` (docs/42 section 9.1),
			# on the branch the **round sweep** takes: `0x00470AB0` passes 1
			# for the third argument, so the flight is the computed one and
			# not the `(9, 7, 1)` unit camera of the other branch.
			#
			# The eye is the camera's own, lifted to at least `0x3200`
			# (`cmp ecx, 0x3200` at `0x004158FC`), the target is the cell's
			# land marker, and `0x00453510` turns the eye until the line to
			# it is clear before `0x0040EEE0` flies it.
			#
			# Then, in the routine's own order: every victim's object hidden
			# with a `BloodFlood` and a `FlyingDebris` on its **own** tile,
			# and -- **outside** that loop, so it happens whether or not
			# anything was standing there -- one `aBlob_CreateTubeSmoke` on
			# the burning cell. That last one is the flash on a red patch
			# with nobody on it, and the remake used to draw none of this.
			var lit: Vector3i = host.cell_object(cell.x, cell.y)
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame == 1:
						var eye: Vector3i = host.camera_eye()
						eye.z = maxi(eye.z, GROUND_FIRE_EYE_FLOOR)
						var _f: int = host.fly(
							host.free_position(eye, lit), lit))
			queue.enqueue(STAGE_LEAD, 1,
				func(_frame: int, _total: int) -> void:
					for entry: Variant in DictRead.as_array(extra.get("killed", [])):
						var victim: Dictionary = DictRead.as_dict(entry)
						var vx: int = DictRead.as_int(victim["x"])
						var vy: int = DictRead.as_int(victim["y"])
						var slot: int = DictRead.as_int(victim.get("slot", -1))
						if slot >= 0:
							host.hide_unit(slot)
						host.spawn_program(BlobPrograms.BLOOD_FLOOD,
							PackedInt32Array([vx, vy, vx, vy, 1]))
						host.spawn_program(BlobPrograms.FLYING_DEBRIS,
							PackedInt32Array([vx, vy]))
					host.spawn_program(BlobPrograms.TUBE_SMOKE,
						PackedInt32Array([cell.x, cell.y])),
				# One frame, and `gfire.wav` @84 belongs to the whole routine:
				# the stage hands its sound to the pool below (docs/28
				# section 1.4), as the crush wall's does.
				cues, true)
			queue.enqueue_until(STAGE_POOL, frames,
				func() -> bool: return host.pool_live() == 0)
			return 1
		"crush_wall":
			# docs/42 section 8: `0x004238C0` on every cell, then the pool --
			# under which the wall turns and sinks (`paint`), and at whose
			# end, early or not, the caller's `aDeleteLand` runs.
			#
			# The debris stage lasts **one frame** and the routine does not:
			# `crushwall.wav` @86 is `aPlayCrushWallAnimation`'s own and dies
			# when the routine returns (docs/28 section 1.4), so the stage
			# holds its sound for the pool rather than stopping it on the
			# frame it started it -- which is what made the wall silent.
			var finish: Callable = extra.get("finish", Callable())
			var no_cues: Array[Dictionary] = []
			queue.enqueue(kind, 1,
				func(_frame: int, _total: int) -> void:
					for entry: Variant in DictRead.as_array(extra.get("cells", [])):
						var at: PackedInt32Array = DictRead.as_int32_array(entry)
						if at.size() >= 2:
							host.spawn_program(BlobPrograms.WALL_DEBRIS,
								PackedInt32Array([at[0], at[1]])),
				cues, true)
			queue.enqueue_until(STAGE_POOL, frames,
				func() -> bool: return host.pool_live() == 0, paint, no_cues,
				finish)
			return 1
		"para_bombs":
			# docs/42 section 8, and **two routines rather than one**:
			# `0x00470790` runs the fly-past `0x00415E90` to completion and
			# only then the bomb run `0x004160F0` (docs/20 section 7.4).
			# Each is a blocking routine with a sound of its own, so each is
			# a stage of its own here -- the fly-past's looping `bomber.wav`
			# dies with its stage, and the bombs' `crush.wav` starts with
			# theirs. One stage carrying both could only ever play the first,
			# whatever the picture did.
			queue.enqueue_until(STAGE_LEAD, BOMBER_FRAMES,
				# `0x00416086` -- the fly-past's loop asks one question, and
				# the creator's own `0x0042A938` is what makes it a question
				# rather than a formality. The second half is the remake's:
				# with the plane gone there is nothing left to show, and no
				# world set that lacks `L069EE00.3DI` holds the picture for
				# a hundred and fifty frames of empty sky.
				func() -> bool: return host.pool_arrived() or host.pool_live() == 0,
				func(frame: int, _total: int) -> void:
					if frame == 1:
						# `0x00415EE1`..`0x00415EFF` -- six **literals**, not
						# tiles: the fly-past is a fixed diagonal across the
						# scene and reads no cell at all.
						host.spawn_at(BlobPrograms.BOMBER, BOMBER_FROM,
							PackedInt32Array([BOMBER_TO.x, BOMBER_TO.y,
								BOMBER_TO.z]))
						# `0x00415F2C` reads all six camera numbers back and
						# `0x00415FB4` sets the eye on the flight path with
						# the target it just read. That set is never drawn --
						# no frame tick stands between it and the loop -- so
						# what it is really for is the target the loop starts
						# from, before `0x0042B4B0` has answered once.
						st["at"] = host.camera_target()
					# **The camera follows the plane, every frame.**
					# `0x00415FE6`..`0x00416014` is the whole of the loop's
					# picture: `0x0042B4B0` writes the pool's first live
					# record into the three target locals and `0x00403560`
					# then sets the eye on the flight path with **that** as
					# its target. The eye's z is the bomber's own -- both are
					# `0x4E200` -- so the fly-past is watched level with the
					# plane and not from above it, and a target left on the
					# ground is what made it a view straight down at the map.
					# `0x0042B4B0` writes nothing when the pool is empty, so
					# the last answer stands.
					if host.pool_live() > 0:
						st["at"] = host.pool_first()
					host.set_camera(Vector3i(BOMBER_START_X, 0,
						BOMBER_START_Z), DictRead.as_vector3i(st["at"])),
				cues,
				# `0x004160B4` -- the fly-past's last act, so the bomb run
				# starts with an empty pool. It is the routine's tail and not
				# its last frame: the loop above leaves on the *arrived* flag
				# as readily as on its bound, and the engine clears the pool
				# either way. A **total** sweep in the original too --
				# anything else the pool held, the selection's own arrows
				# included, goes with it.
				func() -> void: host.clear_pool())
			# The bombs are laid **in the second routine**, not with the
			# bomber: `0x004160F0` picks its tiles and calls `0x0042B070`
			# once each, after the fly-past has returned and emptied the pool.
			#
			# The stage ends the way `0x004163A9` does -- `while (live)`, and
			# nothing else. The *arrived* flag is not part of that test in the
			# original either: it is what selects a **sound**, below.
			queue.enqueue_until(kind, frames,
				func() -> bool: return host.pool_live() == 0,
				func(frame: int, total: int) -> void:
					if frame == 1:
						var index: int = 0
						for entry: Variant in DictRead.as_array(
								extra.get("tiles", [])):
							var at: PackedInt32Array = DictRead.as_int32_array(entry)
							if at.size() >= 2:
								host.spawn_program(BlobPrograms.PARA_BOMB,
									PackedInt32Array([at[0], at[1],
										index * BOMB_SPACING]))
							index += 1
					# **One crump per bomb, and the run opens silent.**
					# `0x004162D6` spins with the camera on the first live
					# record until a bomb lands, and only then does
					# `0x0041633F` play. After that `0x00416364`'s loop plays
					# the next of three `crush.wav` buffers (`0x00416271`,
					# `mov edi, 3`) on every raised *arrived*, acknowledging
					# each with `0x0042B490` -- so the first landing reaches
					# both plays, one frame apart and both on `buffer[0]`,
					# which restarts one sound rather than making two. A para
					# bomb raises the flag from its own arm when its life runs
					# out ([method BlobKinds._kind_25]), so a stick of nine is
					# nine crumps. The three buffers are the original's cap on
					# how many may overlap; the remake's [AudioPool] owns that
					# question and is not told it here.
					#
					# The flag read here is **this** frame's:
					# [method Main._tick_effects] runs before the queue, as
					# the engine's own loop ticks before it asks
					# (`0x00416364` then `0x00416369`).
					elif host.pool_arrived():
						crump(host, cues_late, st)
						host.clear_arrived()
						st["landed"] = true
					# **And the run is watched from the ground.** The camera
					# lives in `0x004162D6`'s loop and nowhere else: eye at
					# [constant BOMB_RUN_EYE], target on the pool's first
					# live record with its z clamped to
					# [constant BOMB_RUN_CEILING]. That loop ends at the
					# first landing -- `0x00416364`'s, which plays the rest
					# of the crumps, sets no camera at all -- so the view
					# holds where the first bomb came down while the stick
					# finishes falling around it.
					if not DictRead.as_bool(st.get("landed", false)):
						if host.pool_live() > 0:
							st["at"] = host.pool_first()
						var at: Vector3i = DictRead.as_vector3i(st["at"])
						host.set_camera(BOMB_RUN_EYE, Vector3i(at.x, at.y,
							mini(at.z, BOMB_RUN_CEILING)))
					paint.call(frame, total))
			return BOMBER_FRAMES
		"teleporter":
			# docs/42 section 8.1: the stream `0x0042A120`, seventy frames
			# with the camera target on the first live record between 40 and
			# 10, the traveller hidden at 40 and moved at 10.
			queue.enqueue(kind, frames,
				func(frame: int, total: int) -> void:
					if frame == 1:
						host.spawn_program(BlobPrograms.TELEPORT_STREAM,
							PackedInt32Array([cell.x, cell.y,
								DictRead.as_int(extra.get("tx", cell.x)),
								DictRead.as_int(extra.get("ty", cell.y))]))
					var left: int = total - frame
					if left <= TELEPORT_HIDE_AT and left > TELEPORT_MOVE_AT:
						host.set_camera_target(host.pool_first())
					# **Suppressed, not destroyed**: the traveller comes
					# back thirty frames later, and [method
					# ShotHost.hide_unit] frees the node.
					if left == TELEPORT_HIDE_AT and unit >= 0:
						host.suppress_unit(unit)
					# `0x00416554` -- at ten the unit is **moved to the target
					# object** and only then shown again. `core` relinked it
					# when the walk ended, but the body was left standing on
					# the entry cell by the walk's own last step, so without
					# this it blinks out and back in on the wrong cell.
					if left == TELEPORT_MOVE_AT and unit >= 0:
						host.place_body(unit, host.cell_object(
							DictRead.as_int(extra.get("tx", cell.x)),
							DictRead.as_int(extra.get("ty", cell.y))))
						host.show_unit(unit)
					paint.call(frame, total),
				# `aPlayTeleporterSequence` `0x004164F0` drains its pool after
				# the seventy frames; its sound belongs to the whole routine.
				cues, true)
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return frames
		_:
			queue.enqueue(kind, frames, paint, cues)
			return frames
