class_name BackdropBodies
extends Node3D

## The marines an upgrade base's own scene walks, docs/27 §2.7.1.
##
## **An upgrade location is not an empty landing pad.** Every `upgrade_N.lev`
## places two or three living player-0 marines, and
## `aPlayLocationAnimation_Upgrade` `0x00417510` starts one animation on each of
## them between `aCreateBattleMap(3)` and the flight: it walks the unit array
## with `aUnitMap.cpp`'s own pair -- `0x00477C20(0)` for the first slot whose
## hit points are non-zero and whose owning player is 0, `0x00477C60(0, id)` for
## the next -- and calls the start-animation entry point `fcn.004055e0` with
## `kind = 4` and the animation slot `id + 7`.
##
## `kind == 4` is the one arm of that entry point that names its clip as a
## **literal** rather than asking a selector (docs/40 §7.2, fourth row):
## `P0_M2_000`, at `0x004C030C`. Its arm `0x00405B88` loops it 100000 times,
## runs it at speed 1.0 and then sets the clip's time to `aRandom2(0, 10)`
## before starting it, so three marines started in the same frame are not in
## step. `aRandom2` is the `GetTickCount`-seeded generator (docs/22 §3.2) --
## the engine never meant this to repeat run to run, which is also what says it
## is cosmetic and outside every hash.
##
## **Nothing moves the units.** The march is the clip's own: `P0_M2_000` is 452
## frames long and carries its top-level bone 3017.7 skeleton units down engine
## -Y, so the body walks and the record stays on the cell it was placed on.
## That is why the clip is played with [method CharismaBody.pose]'s `in_place`
## left false here and set true in a mission -- there the picture moves the node
## and the stride would be counted twice (docs/96, [method UnitsView.pose]).
##
## The clock is the front end's own 20 a second ([constant SliceMain.FLY_FPS],
## `0x0047F2E0(10, 20)`), one clip unit a displayed frame, and it keeps running
## after the flight has landed: `0x00455A40(0)` pushes the camera on every
## Mission Control frame and the 3D behind `plate_3`'s window is refreshed with
## it, so the marines are still walking behind the Unit Menu. That was read
## rather than measured and is now **confirmed against the original** -- a
## frame of its Item List has the three on the pad mid-stride, and the same
## screen here walks them the same way to the shuttle (docs/101 section 13.6).

## `docs/40` §7.2's fixed literal at `0x004C030C`. A cache published before
## 0.31.0 does not carry it, and [method build] then stands nobody up rather
## than failing -- the same fallback every other slice-9 reader takes.
const CLIP: String = "P0_M2_000"

## The player `0x00417607` and `0x0041763F` push: the loop asks for player 0's
## units and no others, which is what leaves `upgrade_4`'s six dead alien
## records out of it.
const PLAYER: int = 0

## `push 10; push 0; call aRandom2` at `0x00405BF2`, whose float goes straight
## into the animation's own time setter.
const START_MAX: float = 10.0

## `0x00405BDE` and `0x00405BE8`: the loop count and the speed. The count is
## large enough to be a loop forever and is kept as the measurement it is.
const LOOPS: int = 100000
const SPEED: float = 1.0

## The front end's frame limiter, `0x0040B82D`'s `0x0047F2E0(10, 20)`.
const FPS: float = 20.0

## The bodies, in the slot order the engine's own loop would reach them.
var bodies: Array[CharismaBody] = []

## Each body's clip time, in the clip's own frames.
var times: PackedFloat32Array = PackedFloat32Array()

var _clip: CharismaClip = null
var _carry: float = 0.0
var _loops: int = 0


## Stand up every marine `world` places for player 0, and return how many.
##
## `rng` is the draw for each one's starting time. It is injected rather than
## taken from a singleton so the suite can seed it; the original's own draw is
## clock-seeded and repeats nothing.
func build(world: World, library: CharismaLibrary,
		rng: RandomNumberGenerator) -> int:
	for child: Node in get_children():
		remove_child(child)
		child.free()
	bodies.clear()
	times.clear()
	_carry = 0.0
	_loops = 0
	if world == null or library == null or not library.is_ready():
		return 0
	_clip = library.clip(CLIP)
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["player"]) != PLAYER:
			continue
		# `0x00477C20`'s own test, and the one `0x00477AE0` repeats: a slot
		# with no hit points holds nobody. `World.create` drops those already
		# -- this is the rule stated where it is read, not a second filter.
		if DictRead.as_int(view["hp"]) == 0:
			continue
		var body: CharismaBody = _body_for(view, library)
		if body == null:
			continue
		var node: Node3D = Node3D.new()
		node.name = "marine_%d" % slot
		var x: int = DictRead.as_int(view["x"])
		var y: int = DictRead.as_int(view["y"])
		var cell: Dictionary = world.cell_view(x, y)
		node.position = WorldSpace.cell_centre(x, y,
			DictRead.as_int(cell.get("height", 0)))
		node.add_child(body)
		UnitsView.face(node, body, DictRead.as_int(view["facing"]))
		add_child(node)
		bodies.append(body)
		times.append(rng.randf() * START_MAX)
	_pose()
	return bodies.size()


## Advance every marine by `delta` seconds of drawn time.
##
## The accumulator is the front end's frame and not Godot's: the original steps
## Charisma once per displayed frame with the limiter holding that at 20 a
## second, so a machine drawing faster must not walk them faster.
func tick(delta: float) -> void:
	if bodies.is_empty() or _clip == null:
		return
	_carry += delta * FPS
	var steps: int = int(_carry)
	if steps <= 0:
		return
	_carry -= float(steps)
	var span: float = _clip.duration
	for i: int in range(times.size()):
		var t: float = times[i] + SPEED * float(steps)
		# The loop count is 100000 rather than an endless flag, so the wrap is
		# counted: it is what a suite can read to say the clip looped at all.
		while span > 0.0 and t >= span:
			t -= span
			_loops += 1
		times[i] = t
	_pose()


## How many times a clip has wrapped since [method build] -- the loop count
## `0x00405BDE` sets, seen from the other end.
func loops() -> int:
	return _loops


func _pose() -> void:
	for i: int in range(bodies.size()):
		bodies[i].pose(_clip, times[i])


## The body a marine's `(type, weapon, player)` selects, or null.
##
## The three-level selector is [CharismaLibrary]'s and is not restated here:
## docs/96 found it the hard way and a second copy would be a second thing to
## get wrong. Null is an ordinary answer for a cache without this world set.
static func _body_for(view: Dictionary,
		library: CharismaLibrary) -> CharismaBody:
	var model_name: String = library.name_for(
		CharismaLibrary.SELECTOR_MODEL,
		DictRead.as_int(view["type_id"]), DictRead.as_int(view["weapon"]),
		DictRead.as_int(view["player"]))
	var model: CharismaModel = library.model(model_name)
	if model == null:
		return null
	return CharismaBody.create(model, library)
