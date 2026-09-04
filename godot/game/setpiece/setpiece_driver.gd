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
## | `Bridge` | 80 | ±12 of rotation | docs/20 section 7.4 |
## | `FootBridge`/`FootBridge2` | the `frames` argument | — | docs/20 section 7.4 |
## | `MoveWorld` | the `frames` argument | — | docs/20 section 7.4 |
## | `RoofUnit` | `height * 1600 / 3200` | one map field of drop | `0x00411E26` |
##
## The last is the one neither document gave. `tools/blob_tables.py` reads it
## out of the drop loop and pins it: the falling unit's z is reduced by a whole
## map field on every frame tick and the loop ends when it reaches the floor,
## so the count is the height divided by that step. Four checks hold it.
##
## **Everything else is instant, and says so.** The sequences no converted
## mission reaches -- the statue, the barrier, the crush wall, the ground unit
## -- apply their state change with their sound and no interpolation, and are
## listed in [constant INSTANT] rather than left to look implemented. That is
## the plan's own first cut, taken on the sequences the demo missions do not
## need rather than on the ones they do.

## The events this driver animates, and how it works out their length.
const ANIMATED: Array[String] = ["open_door", "elevator", "platform",
	"roof_unit", "bridge", "foot_bridge", "foot_bridge2", "open_tube",
	"open_plant_tube", "open_front_door", "ground_unit", "statue",
	"barrier_on", "fire_circle", "crush_wall", "teleporter", "para_bombs"]

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
## `0x00411E26` -- `sub eax, 0xC80`, one map field per displayed frame.
const ROOF_DROP_STEP: int = 0xC80
## `RoofUnit (x, y, height, unitType)` starts `height * 1600` world units up.
const ROOF_HEIGHT_SCALE: int = 1600
## `Bridge` is 80 frames of ±12 on the object's rotation word.
const BRIDGE_FRAMES: int = 80
## `Platform` runs `dist * 10` frames.
const PLATFORM_FRAMES_PER_FIELD: int = 10
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
## Every animated set piece but `MoveWorld` names its tile in the first two
## values, because that is the shape the LCL commands share.
static func cell_of(event: Dictionary) -> Vector2i:
	var values: PackedInt32Array = _numbers(event)
	if values.size() < 2:
		return Vector2i(-1, -1)
	return Vector2i(values[0], values[1])


## The fraction of the way through a sequence, as the original would have been
## after `frame` of `frames` ticks.
##
## Linear, and that is the original's own shape rather than an easing choice:
## every sequence in the table above adds a **constant** per frame -- ±800,
## ±0x140, ±12, one map field -- so the position at frame *n* is *n* steps from
## the start. An eased curve would look smoother and be wrong.
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
