class_name WorldSpace
extends RefCounted

## The one place the engine's coordinate convention meets Godot's.
##
## docs/30 section 2.5: engine world space is **X right, Y into the screen,
## Z up**, and one map field is 3200 world units, one metre 1600.  Godot is
## Y-up, -Z forward.  The mapping is
##
##     godot = Vector3(ex, ez, -ey) / 1600
##
## which preserves handedness -- `ex x ey = ez` still holds after it -- so a
## mesh does not come out mirrored.  Nothing else in `game/` is allowed to
## write this conversion out by hand.

const WORLD_UNITS_PER_METRE: float = 1600.0
const WORLD_UNITS_PER_FIELD: int = 3200
const FIELD_METRES: float = 2.0
## docs/10 -- a full turn in the engine's angle units.
const ANGLE_FULL_TURN: int = 4096
## docs/31 section 4.3 -- texture coordinates are 8.7 fixed point.
const UV_SCALE: float = 32768.0


static func to_godot(ex: int, ey: int, ez: int) -> Vector3:
	return Vector3(float(ex), float(ez), -float(ey)) / WORLD_UNITS_PER_METRE


static func to_godot_v(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y) / WORLD_UNITS_PER_METRE


## The centre of map field `(x, y)` at engine height `h`.
static func cell_centre(x: int, y: int, h: int) -> Vector3:
	return Vector3(float(x) * FIELD_METRES, float(h) / WORLD_UNITS_PER_METRE,
		-float(y) * FIELD_METRES)


## An engine yaw as a Godot basis.  Taken modulo a full turn because the corpus
## carries accumulated values well past 4096.
static func yaw_basis(yaw: int) -> Basis:
	var turns: float = float(posmod(yaw, ANGLE_FULL_TURN)) / float(ANGLE_FULL_TURN)
	return Basis(Vector3.UP, turns * TAU)


static func uv(u: int, v: int) -> Vector2:
	return Vector2(float(u), float(v)) / UV_SCALE
