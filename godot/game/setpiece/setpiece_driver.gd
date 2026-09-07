class_name SetpieceDriver
extends RefCounted

## What each set piece looks like while it happens, and for how long.
##
## `core` applies the whole state change and records an event; this turns that
## event into a queued sequence of the length the original's own loop ran for.
## Every frame count below is read out of the game rather than chosen:
##
## | Sequence | Frames | Per frame | Source |
## |---|---|---|---|
## | `OpenDoor` | 10 | the height step | docs/28 section 1.4's own listing |
## | `Elevator` | `steps` | ±800 | docs/20 section 7.4 |
## | `Platform` | `dist * 10` | ±0x140 | docs/20 section 7.4 |
## | `Bridge` | 80 | ±12 on the halves' joint words `+0x26`/`+0x2C` | docs/20 section 7.4, docs/42 section 8.3 |
## | `FootBridge`/`FootBridge2` | the `frames` argument | the block's own tilt and 0xD20 of drop | docs/42 section 8.1 |
## | `MoveWorld` | the `frames` argument | — | docs/20 section 7.4 |
## | `RoofUnit` | `height * 1600 / 3200` | one map field of drop | `0x00411E26` |
## | the three tubes | 19 | +51 on the hatch's joint word(s) | docs/42 section 8.3 |
## | the lever | 10 | ±80 on the handle's `+0x26` | docs/42 section 8.3 |
## | the supply box | 20 + 15 | +20 on the lid's `+0x26`, then a hold | docs/42 section 8.3 |
##
## The last is the one neither document gave. `tools/blob_tables.py` reads it
## out of the drop loop and pins it: the falling unit's z is reduced by a whole
## map field on every frame tick and the loop ends when it reaches the floor,
## so the count is the height divided by that step. Four checks hold it.
##
## **Everything else is instant, and says so.** What is not in
## [constant ANIMATED] applies its state change with its sound and no
## interpolation, and is listed in [constant INSTANT] rather than left to
## look implemented -- the statue, the barrier, the crush wall and the ground
## unit were that first cut once, and have been animated since docs/97
## section 33.

## The events this driver animates, and how it works out their length.
const ANIMATED: Array[String] = ["open_door", "elevator", "platform",
	"roof_unit", "bridge", "foot_bridge", "foot_bridge2", "open_tube",
	"open_plant_tube", "open_front_door", "ground_unit", "statue",
	"barrier_on", "fire_circle", "crush_wall", "teleporter", "para_bombs",
	"lever", "pickup"]

## The events that get their sound and their state change with no motion.
## Named rather than merely absent: an event that is silently unhandled and one
## that is deliberately instant look identical from outside.
## `Statue2` `0x004424B0` is a **loop**, not a sequence: `0x00413500` calls
## `aPlayRotateStatueSequence` once per cell whose action point falls in the
## command's range, so the animation belongs to the `statue` events `core`
## emits inside it (docs/97 section 41.1) and the `statue2` marker itself has
## nothing to draw. `statue_kill` is the same: the beam's stage already hides
## the victim and fires its `FireDeath`.
const INSTANT: Array[String] = ["fixed_statue_kill", "statue_kill", "statue2",
	"barrier_off",
	"falling_spores", "set_ground_fire", "growing_land",
	"move_objects", "move_fire_circles", "move_spores"]
## The three tubes' own `cmp esi, 0x13` (docs/42 section 8).
const TUBE_FRAMES: int = 19
## `GroundUnit`'s eight frames of rise and six of carry (docs/42 section 8.1).
const GROUND_UNIT_FRAMES: int = 8 + 6
## `mov edi, 0xD` then one settling frame -- the statue's quarter turn
## (docs/42 section 8.1); `Statue2` has no turn and goes straight to its beam.
const STATUE_TURN_FRAMES: int = 13 + 1
const STATUE_TURN_STEP: int = 0x50
const STATUE_SETTLE: int = 0x400
## `mov ecx, 0x28` in `aPlayLaserBarrier` -- the beam's own count, which is
## also how long the routine holds before its second flight.
const BARRIER_FRAMES: int = 40
## `mov esi, 0xA` after `FireCircle`'s ring.
const FIRE_CIRCLE_FRAMES: int = 10
## `mov esi, 0x46` -- the teleporter counts down from seventy.
const TELEPORTER_FRAMES: int = 70
## The crush wall spins on the pool and on the *arrived* flag; the frames here
## are the picture's bound, **the remake's**.
const POOL_ONLY_FRAMES: int = 40
## `ParaBombs` -- the ticks between one bomb starting and the next.
##
## **The remake's**, and the one number in this set piece that is: `0x00416231`
## draws `aRandom2(0, 200)` per bomb, so the original's strike is spread over
## ten seconds of falling. Everything else about the sequence's length is read
## out of the game and derived from this.
const BOMB_SPACING: int = 3
## Where a `para_bombs` event's tile pairs start in its values.
const PARA_BOMB_TILES_AT: int = 5
## How long one bomb falls: `0x0042B070` starts it at `BOMB_CEILING` above the
## object and drops it `BOMB_FALL` a tick, and a floor at height zero is the
## longest fall a map can give it.
const BOMB_FALL_FRAMES: int = BlobPrograms.BOMB_CEILING / BlobPrograms.BOMB_FALL
## `0x0042A8E0` writes `life = 150` into the bomber's record (pinned as
## `creator.bomber.kind_52_life_150`), and 3200 world units a tick along its
## 520 000-unit diagonal would need 163 -- so the plane runs out of life
## before it arrives, and its own record is what ends the fly-past.
const BOMBER_LIFE_FRAMES: int = 150

## `aDoorOpenSequence`'s own `for (n = 10; n; n--)`.
const DOOR_FRAMES: int = 10
## docs/42 section 8.3 -- the door's family, each read off its own loop and
## pinned by `interaction_tables.py` (`family.*`).
## `aPlayUseLeverSequence` `0x00416AD0`: `mov [esp+0x34], 0xA` frames of
## `mov ebp, 0x50` / `mov ebx, -0x50` on the handle's `+0x26`; direction 0
## (the lever was up) takes the negative step.
const LEVER_FRAMES: int = 10
const LEVER_STEP: int = 0x50
const LEVER_THROW: int = LEVER_STEP * LEVER_FRAMES
## The supply box `0x00410780`: `mov ebx, 0x14` frames of `+0x26 += 0x14`
## on the lid, then `mov esi, 0xF` frames of nothing, with the box's text
## already up.
const PICKUP_LID_FRAMES: int = 0x14
const PICKUP_LID_STEP: int = 0x14
const PICKUP_HOLD_FRAMES: int = 0xF
## The three tubes: `mov ebx, 0x33` / `mov ebp, 0x33` / `mov ebx, -0x33` a
## frame on the hatch -- part 6 about x for `OpenTube`, parts 6 and 12
## about x for `OpenPlantTube`, parts 6 and 12 about **z** for
## `OpenFrontDoor`.
const TUBE_STEP: int = 0x33
## `Bridge`: `lea ×3` then `shl 2` = 12 a frame on both halves' `+0x26` and
## `+0x2C`, the sign read off the half that is already turned
## (`mov di, [esi+0x26]` / `neg` / `sbb`): a raised bridge lowers.
const BRIDGE_STEP: int = 12
## `aPlayLaserBarrier`: the emitter's `+0x2A` is `0x800` -- half a turn
## about z -- when the barrier goes **off** (`0x00413653`) and `bx`, which
## the prologue's `xor ebx, ebx` made zero, when it comes on
## (`0x00413670`). Instant, before the beam.
const BARRIER_EMITTER_PART: int = 6
const BARRIER_EMITTER_OFF: int = 0x800
## `aPlayCrushWallAnimation`: `mov ebx, 0x66` on the wall's own `+0x20`
## and `mov edi, -0x1E0` on its z, every frame until the pool is empty,
## then `aDeleteLand`.
const CRUSH_TURN_STEP: int = 0x66
const CRUSH_DROP_STEP: int = 0x1E0
## `aPlayFootBridgeSequence`: a tilt drawn once from `aRandom2(-2, 4)`, 0
## becoming -1, turns the block's `+0x22` by 17 and `+0x24` by 25 of it a
## frame while its z drops `0xD20` (docs/42 section 8.1), then the block
## is freed.
const FOOTBRIDGE_TILT_LOW: int = -2
const FOOTBRIDGE_TILT_SPAN: int = 4
const FOOTBRIDGE_TILT_Y: int = 17
const FOOTBRIDGE_TILT_Z: int = 25
const FOOTBRIDGE_DROP_STEP: int = 0xD20
## Every rider is read back off its own object, dropped `0xC80` and put
## back `0xA0` higher (`0x00414DD9` / `0x00414DE7`, and `0x004154A4` /
## `0x004154B2` in the second routine) -- so the fall is `0xBE0` a frame,
## 320 short of the block's own, and the map field the stored copy holds is
## not what the object gets. After the loop the rider is taken off the map.
## `FootBridge2` `0x00415110` is the same fall on the block its box search
## finds, which is the `L069EI00` standing on one of the group's two cells,
## so its event carries those cells.
const FOOTBRIDGE_RIDER_DROP: int = 0xC80 - 0xA0
## And it tumbles as it goes: the rider's **own** rotation words, not a
## joint's -- `+0x24` by 25 and `+0x22` by 12 a frame, both negative for an
## odd rider index (`test bl, 1` on the loop counter, `0x00414DFC` and
## `0x004154C7`). `interaction_tables.py` pins the two accessors the loop
## reads and writes them through, which is what says the third argument is
## the heading word.
const FOOTBRIDGE_RIDER_TURN_Z: int = 25
const FOOTBRIDGE_RIDER_TURN_Y: int = 12
## Where a `foot_bridge` event's rider slots start, and where a
## `foot_bridge2` event's `x, y` cell pairs start -- its riders follow the
## `hit` pairs (docs/42 section 8.3).
const FOOTBRIDGE_RIDERS_AT: int = 4
const FOOTBRIDGE2_CELLS_AT: int = 3
## The `joint_place` offsets the family's parts are authored under.
const PART_FIRST: int = 6
const PART_SECOND: int = 12
## `0x00411E26` -- `sub eax, 0xC80`, one map field per displayed frame.
const ROOF_DROP_STEP: int = 0xC80
## `RoofUnit (x, y, height, unitType)` starts `height * 1600` world units up.
const ROOF_HEIGHT_SCALE: int = 1600
## `Bridge` is 80 frames of ±12 on the halves' joint words (docs/42 section 8.3).
const BRIDGE_FRAMES: int = 80
## `Platform` runs `dist * 10` frames...
const PLATFORM_FRAMES_PER_FIELD: int = 10
## ...of `0x140` engine units each along its direction (`0x00412A00`'s loop
## adds it to every object it found on the block, to every rider and to the
## camera target), so ten frames are exactly one field.
const PLATFORM_STEP: int = 0x140
## A sequence never runs longer than this, whatever its arguments say. The
## shipped `FootBridge2` calls all pass 30, and `RoofUnit`'s largest shipped
## height is 65 -- 32 frames -- so nothing real is clipped; this bounds a
## malformed script rather than a shipped one.
const MAX_FRAMES: int = 200


## How many displayed frames this event's sequence runs for, or `0` when it is
## instant. `event` is the dictionary `core` recorded.
static func frames_for(event: Dictionary) -> int:
	var kind: String = AudioEvents.name_of(event)
	if not is_animated(kind):
		return 0
	var values: PackedInt32Array = _numbers(event)
	match kind:
		"open_door":
			return DOOR_FRAMES
		"elevator":
			# `Elevator (x, y, dir, steps)` -- one frame per step, each of
			# ±800 world units, so `steps * 5` height levels in `steps`
			# frames.
			return mini(_at(values, 3, 1), MAX_FRAMES)
		"platform":
			# `Platform (x, y, dir, dist)` -- `dist * 10` frames of ±0x140.
			return mini(_at(values, 3, 1) * PLATFORM_FRAMES_PER_FIELD,
				MAX_FRAMES)
		"roof_unit":
			# The drop is `height * 1600` world units at one map field a
			# frame, and the last partial frame still costs a frame.
			var height: int = _at(values, 2, 1)
			var total: int = height * ROOF_HEIGHT_SCALE
			return mini(maxi(1, (total + ROOF_DROP_STEP - 1) / ROOF_DROP_STEP),
				MAX_FRAMES)
		"bridge":
			return BRIDGE_FRAMES
		"foot_bridge":
			return mini(_at(values, 2, 1), MAX_FRAMES)
		"foot_bridge2":
			return mini(_at(values, 1, 1), MAX_FRAMES)
		"open_tube", "open_plant_tube", "open_front_door":
			return TUBE_FRAMES
		"ground_unit":
			return GROUND_UNIT_FRAMES
		"statue":
			return STATUE_TURN_FRAMES
		"barrier_on":
			return BARRIER_FRAMES
		"fire_circle":
			return FIRE_CIRCLE_FRAMES
		"crush_wall":
			return POOL_ONLY_FRAMES
		"para_bombs":
			# The strike's own length rather than a flat bound: the last
			# bomb starts `(tiles - 1) * BOMB_SPACING` ticks in and then
			# falls. `core` carries the tiles it actually mined (docs/97
			# section 33), so this counts the bombs that will be laid and
			# not the command's sixty attempts.
			var tiles: int = (values.size() - PARA_BOMB_TILES_AT) / 2
			return mini(maxi(1, maxi(0, tiles - 1) * BOMB_SPACING
				+ BOMB_FALL_FRAMES + 1), MAX_FRAMES)
		"teleporter":
			return TELEPORTER_FRAMES
		"lever":
			return LEVER_FRAMES
		"pickup":
			return PICKUP_LID_FRAMES + PICKUP_HOLD_FRAMES
	return 0


static func is_animated(kind: String) -> bool:
	return ANIMATED.has(kind)


static func is_instant(kind: String) -> bool:
	return INSTANT.has(kind)


## Whether this driver has anything at all to say about the event -- a set
## piece it animates, or one it deliberately applies at once.
static func handles(kind: String) -> bool:
	return is_animated(kind) or is_instant(kind)


## The cell an event happens on, as `(x, y)`, or `(-1, -1)`.
##
## Every animated set piece but `MoveWorld` and `FootBridge2` names its tile
## in the first two values, because that is the shape the LCL commands
## share. `FootBridge2`'s first two are the group and the frames, so its
## cell is the first of the group cells `core` carried -- the one the
## routine's own search starts from.
static func cell_of(event: Dictionary) -> Vector2i:
	var values: PackedInt32Array = _numbers(event)
	if AudioEvents.name_of(event) == "foot_bridge2":
		var cells: Array[Vector2i] = group_cells(event)
		return cells[0] if not cells.is_empty() else Vector2i(-1, -1)
	if values.size() < 2:
		return Vector2i(-1, -1)
	return Vector2i(values[0], values[1])


## Where a `Platform (x, y, dir, dist)` ride has carried its block after
## `frame` of its frames, in engine units: [constant PLATFORM_STEP] a frame
## along the direction docs/20 section 7.4 encodes as 0=N 1=W 2=S 3=E --
## [constant Platform.DIR_DX] / [constant Platform.DIR_DY], the same table
## `core`'s ride reads. Zero for a malformed event.
static func platform_offset(values: PackedInt32Array, frame: int) -> Vector3i:
	if values.size() < 4:
		return Vector3i.ZERO
	var direction: int = values[2]
	if direction < 0 or direction >= Platform.DIR_DX.size():
		return Vector3i.ZERO
	var step: int = PLATFORM_STEP * maxi(frame, 0)
	return Vector3i(Platform.DIR_DX[direction] * step,
		Platform.DIR_DY[direction] * step, 0)


## The whole ride, in fields: `dist` along the direction.
static func platform_travel(values: PackedInt32Array) -> Vector2i:
	if values.size() < 4:
		return Vector2i.ZERO
	var direction: int = values[2]
	if direction < 0 or direction >= Platform.DIR_DX.size():
		return Vector2i.ZERO
	return Vector2i(Platform.DIR_DX[direction] * values[3],
		Platform.DIR_DY[direction] * values[3])


## The 3x3 block the ride collects, centred on `(x, y)`, **x outer, y
## inner** (`0x00412AAA`) -- the order its objects and riders are moved in.
static func platform_block(values: PackedInt32Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if values.size() < 2:
		return out
	for ox: int in [-1, 0, 1]:
		for oy: int in [-1, 0, 1]:
			out.append(Vector2i(values[0] + ox, values[1] + oy))
	return out


## The cells a `foot_bridge2` event carries, in the engine's own scan order:
## `hit` pairs from [constant FOOTBRIDGE2_CELLS_AT].
static func group_cells(event: Dictionary) -> Array[Vector2i]:
	var values: PackedInt32Array = _numbers(event)
	var out: Array[Vector2i] = []
	if AudioEvents.name_of(event) != "foot_bridge2" \
			or values.size() < FOOTBRIDGE2_CELLS_AT:
		return out
	var hit: int = values[2]
	for i: int in range(hit):
		var at: int = FOOTBRIDGE2_CELLS_AT + 2 * i
		if at + 1 >= values.size():
			break
		out.append(Vector2i(values[at], values[at + 1]))
	return out


## The unit slots a footbridge event carries -- the riders the routine listed
## before its loop and took off the map after it. Empty for any other kind.
static func riders_of(event: Dictionary) -> PackedInt32Array:
	var values: PackedInt32Array = _numbers(event)
	var kind: String = AudioEvents.name_of(event)
	var at: int = -1
	if kind == "foot_bridge":
		at = FOOTBRIDGE_RIDERS_AT
	elif kind == "foot_bridge2" and values.size() >= FOOTBRIDGE2_CELLS_AT:
		at = FOOTBRIDGE2_CELLS_AT + 2 * values[2]
	if at < 0 or at > values.size():
		return PackedInt32Array()
	return values.slice(at)


## How far the `order`-th rider has tumbled after `frame` frames, as the
## rotation triple to add to its heading: `+0x24` by 25 a frame and `+0x22`
## by 12, negated for an odd rider so that two riders on one bridge turn
## opposite ways. The x word is never written, which is why it is zero here
## rather than read.
static func rider_turn(order: int, frame: int) -> Vector3i:
	var sign: int = -1 if order % 2 == 1 else 1
	return Vector3i(0, sign * FOOTBRIDGE_RIDER_TURN_Y * frame,
		sign * FOOTBRIDGE_RIDER_TURN_Z * frame)


## The fraction of the way through a sequence, as the original would have been
## after `frame` of `frames` ticks.
##
## Linear, and that is the original's own shape rather than an easing choice:
## every sequence in the table above adds a **constant** per frame -- ±800,
## ±0x140, ±12, one map field -- so the position at frame *n* is *n* steps from
## the start. An eased curve would look smoother and be wrong.
## The lever's handle after `frame` of its ten frames, as an x angle: the
## rest pose the direction starts from -- zero when the lever was up
## (direction 0), the thrown -800 when it was down -- plus the signed step.
## **Absolute in the direction, not read off the object**: `core` has
## already flipped the action point when the picture starts, so the pose
## [method Scenery.apply_state] derives is the *end* of the throw, and a
## start read back from it would run the handle a whole throw too far.
static func lever_pose(direction: int, frame: int) -> int:
	var from: int = 0 if direction == 0 else -LEVER_THROW
	var step: int = -LEVER_STEP if direction == 0 else LEVER_STEP
	return from + step * clampi(frame, 0, LEVER_FRAMES)


## One frame of the door's family on the scenery (docs/42 section 8.3):
## the object on `index` at the joint or rotation words `name`'s routine
## reaches after `frame` of `frames` ticks. Every pose is `start + step *
## frame`, never accumulated; `picture["starts"]` is what the routine read
## off the object on its first frame, kept by the caller between frames.
## The lever alone does not read a start: `core` has flipped its action
## point already, so the state paints the *end* of the throw before this
## runs ([method lever_pose]). Answers how many parts or objects were
## painted; a kind outside the family paints nothing.
static func paint_family(scenery: Scenery, index: int, name: String,
		values: PackedInt32Array, frame: int, frames: int,
		picture: Dictionary, host: ShotHost) -> int:
	if scenery == null or name == "":
		return 0
	var starts: Dictionary = DictRead.as_dict(picture.get("starts", {}))
	if starts.is_empty():
		starts[PART_FIRST] = scenery.joint_of(index, PART_FIRST)
		starts[PART_SECOND] = scenery.joint_of(index, PART_SECOND)
		picture["starts"] = starts
	var first: Vector3i = starts[PART_FIRST]
	var second: Vector3i = starts[PART_SECOND]
	match name:
		"lever":
			# `aExecuteUse` passes 0 for a lever that was up (action point
			# 36) and 1 for one that was down; direction 0 is `mov ebx,
			# -0x50`, the handle going over.
			var direction: int = 1 if values.size() > 2 and values[2] == 1 else 0
			return scenery.paint_joint(index, PART_FIRST,
				Vector3i(lever_pose(direction, frame), 0, 0))
		"pickup":
			# Twenty frames of the lid, then the hold with the lid open.
			var lifted: int = mini(frame, PICKUP_LID_FRAMES)
			return scenery.paint_joint(index, PART_FIRST,
				first + Vector3i(PICKUP_LID_STEP * lifted, 0, 0))
		"open_tube":
			return scenery.paint_joint(index, PART_FIRST,
				first + Vector3i(TUBE_STEP * frame, 0, 0))
		"open_plant_tube":
			return scenery.paint_joint(index, PART_FIRST,
					first + Vector3i(TUBE_STEP * frame, 0, 0)) \
				+ scenery.paint_joint(index, PART_SECOND,
					second - Vector3i(TUBE_STEP * frame, 0, 0))
		"open_front_door":
			return scenery.paint_joint(index, PART_FIRST,
					first + Vector3i(0, 0, TUBE_STEP * frame)) \
				+ scenery.paint_joint(index, PART_SECOND,
					second - Vector3i(0, 0, TUBE_STEP * frame))
		"bridge":
			# `mov di, [esi+0x26]` / `neg` / `sbb` / `and -2` / `inc`: a half
			# already turned lowers, one at zero rises.
			var step: int = -BRIDGE_STEP if first.x != 0 else BRIDGE_STEP
			return scenery.paint_joint(index, PART_FIRST,
					first + Vector3i(step * frame, 0, 0)) \
				+ scenery.paint_joint(index, PART_SECOND,
					second - Vector3i(step * frame, 0, 0))
		"statue":
			# `aPlayRotateStatueSequence` `0x00413C10`: thirteen frames of
			# `add word [esi+0x2A], bp` with `bp` 0x50 -- part 6's z word --
			# and a fourteenth that writes the value it read at the start
			# plus 0x400. The quarter turn is 0x400, so the settle is
			# sixteen units *back* from where the thirteenth frame left it.
			var turned: int = STATUE_SETTLE if frame >= STATUE_TURN_FRAMES \
				else STATUE_TURN_STEP * clampi(frame, 0, STATUE_TURN_FRAMES - 1)
			return scenery.paint_joint(index, PART_FIRST,
				first + Vector3i(0, 0, turned))
		"crush_wall":
			return scenery.paint_pose(index,
				Vector3i(CRUSH_TURN_STEP * frame, 0, 0), CRUSH_DROP_STEP * frame)
		"foot_bridge", "foot_bridge2":
			if not starts.has("tilt"):
				var drawn: int = host.draw2(FOOTBRIDGE_TILT_LOW, FOOTBRIDGE_TILT_SPAN)
				starts["tilt"] = -1 if drawn == 0 else drawn
			var tilt: int = DictRead.as_int(starts["tilt"])
			var posed: int = scenery.paint_pose(index,
				Vector3i(0, FOOTBRIDGE_TILT_Y * tilt * frame,
					FOOTBRIDGE_TILT_Z * tilt * frame),
				FOOTBRIDGE_DROP_STEP * frame)
			if frame >= frames:
				var _gone: int = scenery.remove_objects(index)
			return posed
	return 0


static func progress(frame: int, frames: int) -> float:
	if frames <= 0:
		return 1.0
	return clampf(float(frame) / float(frames), 0.0, 1.0)


## An event's numeric arguments.
##
## **Not every event carries numbers.** `CDTrackProgram` and the `OBJ` family
## record a string, and `to_int32` on those takes the whole run down with a
## type error from inside `core`'s own narrowing helper. Non-numeric entries
## are skipped rather than coerced: an event whose arguments are text is not an
## event this driver has a frame count for.
static func _numbers(event: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for value: Variant in DictRead.as_array(event.get("values", [])):
		var kind: int = typeof(value)
		if kind == TYPE_INT or kind == TYPE_FLOAT or kind == TYPE_BOOL:
			out.append(DictRead.as_int(value))
	return out


static func _at(values: PackedInt32Array, index: int, fallback: int) -> int:
	if index < 0 or index >= values.size():
		return fallback
	var value: int = values[index]
	return fallback if value <= 0 else value
