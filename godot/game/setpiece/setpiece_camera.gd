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
## * `open_door` `0x00410A20`: a flight from the unit's head to the panel at
##   the unit's height (`0x0047AD70` twice), ten frames, a flight back --
##   only when a unit is named; the LCL wrapper passes none.
## * `open_tube` `0x00410F10`: nineteen frames turning the tube's object,
##   the puffs `0x00423770` at the tenth (`cmp esi, 0xA`); `OpenPlantTube`
##   and `OpenFrontDoor` are the same frames with no puffs. **The turn of
##   the tube's own object is not drawn** -- the remake's scenery has no
##   per-object rotation yet; the cell's state flips as it did.
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
##   own cell, the dust, the pool. The `L110EX00.3DI` object the routine
##   inserts is not in the cache (named).

const DOOR_FRAMES: int = SetpieceDriver.DOOR_FRAMES
## `cmp esi, 0xA` -- the tube's puffs come on this frame.
const TUBE_PUFF_FRAME: int = 10
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
const GROUND_DEBRIS_UP: int = 0x640
const GROUND_LAND_UP: int = 0xA0
const GROUND_FIFTH: int = 5
## The wait for the pool has no bound in the engine; **the remake's**.
const POOL_WAIT_FRAMES: int = 100

## `push 0x7D00` -- the statue's camera flies to twenty metres up.
const STATUE_HEIGHT: int = 32000
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
## The delay between bombs; **the remake's**, so a stick of them does not
## land in one frame -- the engine spaces them by the loop's own timing.
const BOMB_SPACING: int = 3
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


## Queue the set piece `kind` of `frames` frames on `cell`, whose height
## goes from `from_h` to `to_h`. `unit` is the unit the routine is about
## (the door's user, the roof's cargo, the ground unit's victim), or -1;
## `extra` carries the ground unit's own cell as `own`. `paint` is the
## caller's per-frame picture. Answers the deterministic frames.
static func enqueue(queue: SequenceQueue, host: ShotHost, kind: String,
		frames: int, cell: Vector2i, from_h: int, to_h: int, unit: int,
		extra: Dictionary, paint: Callable, cues: Array[Dictionary]) -> int:
	var st: Dictionary = {"saved_eye": Vector3i.ZERO, "saved_target": Vector3i.ZERO,
		"at": Vector3i.ZERO}
	var centre: Vector3i = Vector3i(cell.x * WorldSpace.WORLD_UNITS_PER_FIELD,
		cell.y * WorldSpace.WORLD_UNITS_PER_FIELD, from_h)
	match kind:
		"open_door":
			if unit >= 0:
				queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
					func() -> bool: return not host.camera_flying(),
					func(frame: int, _total: int) -> void:
						if frame != 1:
							return
						st["saved_eye"] = host.camera_eye()
						st["saved_target"] = host.camera_target()
						var h: int = host.unit_height(unit)
						var _f: int = host.fly(host.object_of(unit) + Vector3i(0, 0, h),
							centre + Vector3i(0, 0, h)))
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
				cues)
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
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame != 1:
						return
					var h: int = host.unit_height(unit) if unit >= 0 else 0
					var ground: Vector3i = host.cell_object(cell.x, cell.y)
					var at: Vector3i = Vector3i(ground.x, ground.y,
						ground.z - GROUND_START_DOWN - h)
					st["at"] = at
					if unit >= 0:
						host.place_body(unit, at + Vector3i(0, 0, GROUND_LAND_UP))
					var _f: int = host.fly(host.camera_eye(),
						at + Vector3i(0, 0, GROUND_LAND_UP))
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
				cues)
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
			queue.enqueue(kind, frames, paint, cues)
			queue.enqueue(STAGE_BEAM, 1,
				func(_frame: int, _total: int) -> void:
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
								DictRead.as_int(beam["cells"])])))
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return frames + 1
		"barrier_on":
			# docs/42 section 8: the beam `0x00428990` along the barrier's
			# direction, a flight to it, forty frames, `0x0042AB40` and
			# `0x0042A9D0` on every unit it killed, a flight to the middle
			# victim, and the pool.
			queue.enqueue(STAGE_LEAD, 1,
				func(_frame: int, _total: int) -> void:
					host.spawn_program(BlobPrograms.LASER_BARRIER,
						PackedInt32Array([cell.x, cell.y,
							DictRead.as_int(extra.get("direction", 0)),
							DictRead.as_int(extra.get("cells", 1))])))
			queue.enqueue_until(STAGE_FLIGHT, ShotSequence.SAFETY_FRAMES,
				func() -> bool: return not host.camera_flying(),
				func(frame: int, _total: int) -> void:
					if frame == 1:
						var _f: int = host.fly(host.camera_eye(), centre))
			queue.enqueue(kind, frames, paint, cues)
			queue.enqueue(STAGE_BEAM, 1,
				func(_frame: int, _total: int) -> void:
					for entry: Variant in DictRead.as_array(extra.get("killed", [])):
						var victim: Dictionary = DictRead.as_dict(entry)
						var vx: int = DictRead.as_int(victim["x"])
						var vy: int = DictRead.as_int(victim["y"])
						var slot: int = DictRead.as_int(victim.get("slot", -1))
						if slot >= 0:
							host.hide_unit(slot)
						host.spawn_program(BlobPrograms.BLOOD_FLOOD,
							PackedInt32Array([vx, vy, vx, vy, 0]))
						host.spawn_program(BlobPrograms.FLYING_DEBRIS,
							PackedInt32Array([vx, vy])))
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return frames + 2
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
				cues)
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return frames + 1
		"crush_wall":
			# docs/42 section 8: `0x004238C0` on every cell, then the pool.
			queue.enqueue(kind, 1,
				func(_frame: int, _total: int) -> void:
					for entry: Variant in DictRead.as_array(extra.get("cells", [])):
						var at: PackedInt32Array = DictRead.as_int32_array(entry)
						if at.size() >= 2:
							host.spawn_program(BlobPrograms.WALL_DEBRIS,
								PackedInt32Array([at[0], at[1]])),
				cues)
			queue.enqueue_until(STAGE_POOL, frames,
				func() -> bool: return host.pool_live() == 0, paint)
			return 1
		"para_bombs":
			# docs/42 section 8: the bomber flies in from -16000 at 80000,
			# the camera target follows it, and one `0x0042B070` per tile.
			queue.enqueue(STAGE_LEAD, 1,
				func(_frame: int, _total: int) -> void:
					# `0x00415EE1`..`0x00415EFF` -- six **literals**, not
					# tiles: the fly-past is a fixed diagonal across the
					# scene and reads no cell at all.
					host.spawn_at(BlobPrograms.BOMBER, BOMBER_FROM,
						PackedInt32Array([BOMBER_TO.x, BOMBER_TO.y,
							BOMBER_TO.z]))
					# `0x00415F2C` reads all six camera numbers back and
					# `0x00415FB4` sets the eye on the flight path with the
					# **target it just read** -- so the two locals docs/97
					# section 32 left UNVERIFIED are the camera's own target,
					# and the bomber aims the camera nowhere.
					host.set_camera(Vector3i(BOMBER_START_X, 0,
						BOMBER_START_Z), host.camera_target())
					var index: int = 0
					for entry: Variant in DictRead.as_array(extra.get("tiles", [])):
						var at: PackedInt32Array = DictRead.as_int32_array(entry)
						if at.size() >= 2:
							host.spawn_program(BlobPrograms.PARA_BOMB,
								PackedInt32Array([at[0], at[1],
									index * BOMB_SPACING]))
						index += 1)
			queue.enqueue_until(kind, frames,
				func() -> bool: return host.pool_arrived() and host.pool_live() == 0,
				paint, cues)
			return 1
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
				cues)
			queue.enqueue_until(STAGE_POOL, POOL_WAIT_FRAMES,
				func() -> bool: return host.pool_live() == 0)
			return frames
		_:
			queue.enqueue(kind, frames, paint, cues)
			return frames
