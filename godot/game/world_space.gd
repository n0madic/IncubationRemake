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


## A whole engine matrix -- 16 floats, row-major, applied as `M * v`
## (docs/40 section 5.1) -- as a Godot [Transform3D].
##
## This is [method to_godot] generalised from a point to a frame, and it is
## derived rather than guessed. A point maps as `g = S * P * e` with
## `P = [[1,0,0],[0,0,1],[0,-1,0]]` the axis permutation and `S` the metre
## scale, so a transform maps as
##
##     basis  = P * R * P^T          (the scale cancels: it is uniform)
##     origin = to_godot(translation)
##
## Written out, the columns below are that product. Godot's [Basis] takes
## **columns**, and the engine's matrix is stored by **rows**, which is the
## transposition that has to happen exactly once and here.
##
## The failure modes are unmistakable if looked at: a wrong permutation lays
## the body on its side, a wrong handedness mirrors it. `test_charisma.gd`
## checks the three properties that pin it -- identity, composition, and an
## engine yaw against [method yaw_basis].
static func engine_matrix(m: PackedFloat64Array) -> Transform3D:
	var basis: Basis = Basis(
		Vector3(m[0], m[8], -m[4]),
		Vector3(m[2], m[10], -m[6]),
		Vector3(-m[1], -m[9], m[5]))
	return Transform3D(basis, to_godot_v(Vector3(m[3], m[7], m[11])))


static func uv(u: int, v: int) -> Vector2:
	return Vector2(float(u), float(v)) / UV_SCALE
