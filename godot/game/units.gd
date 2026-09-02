class_name UnitsView
extends Node3D

## The mission's units: the marker the engine really places, and a body.
##
## `SetUnitInfo`'s model column is **not** a body for a living unit: 30 of the
## 36 shipped rows name `A_MK_0B.3DI`, which is four vertices and one face -- a
## box +-1600 on X and Y at Z = 80, a one-field ground marker.  It is still
## drawn, because the engine draws it.  The **body** comes through Charisma,
## chosen by `0x0042D070` on the unit's type, weapon *and* player (docs/40
## section 7.2 as amended by slice 4) and assembled by [CharismaBody].
##
## **The capsule is now the fallback, and it is meant to be seen.**  It stands
## in wherever the selector returns no body -- player `0xFC`, or a type the
## converted cache does not close over -- so a missing body looks like a
## missing body rather than like nothing at all.  Its height is
## `unitinfo[+0x7c] * 160` world units (docs/21 section 5), tinted by player.
##
## **Scene nodes are never authoritative.**  Every rebuild reads
## `World.unit_view(slot)`; nothing here is ever the source of a position, an
## occupancy or a movement state.

## docs/10 section 5.7 -- the players, and the tints that separate them.
const PLAYER_COLOURS: Dictionary = {
	0: Color8(90, 170, 255),
	1: Color8(255, 120, 90),
	2: Color8(120, 255, 140),
	3: Color8(240, 220, 100),
	252: Color8(180, 180, 180),
	255: Color8(200, 90, 220),
}
const UNKNOWN_PLAYER_COLOUR: Color = Color8(255, 255, 255)

## docs/10 -- the eight facings, as engine angles in a 4096 circle.
const FACING_ANGLES: Array[int] = [0, 0xC00, 0x800, 0x400,
	0x600, 0xE00, 0x200, 0xA00]

const CAPSULE_RADIUS: float = 0.35


## Set once by [method build]; the bodies and the clips of this mission.
var library: CharismaLibrary = null
## Slot -> the body node built for it this rebuild, so the animator can drive
## bodies without walking the scene tree looking for them.
var bodies: Dictionary[int, CharismaBody] = {}
## Slot -> what that body is playing.
var states: Dictionary[int, CharismaState] = {}
## Slot -> an in-progress walk, `{"cells": PackedInt32Array, "width": int,
## "elapsed": float, "seconds": float}`. Empty between walks.
var _walks: Dictionary[int, Dictionary] = {}
## Slots whose node is built but **not shown**, because a set piece is still
## delivering them.
##
## `core` inserts a `RoofUnit`'s alien the moment the command runs, so without
## this the unit appears at the *start* of its fall and the drop sequence plays
## over a body that is already standing there. The rule is not that the unit
## does not exist -- it does, and every rule can see it -- but that the picture
## catches up with the state when the sequence ends, which is the same contract
## the terrain diff has.
var _suppressed: Dictionary[int, bool] = {}
## Slots that crossed a footstep boundary since [method steps_taken] was last
## called, in the order they crossed.
##
## The walk is here and the audio is not: this view counts frames and says who
## put a foot down, and `main.gd` decides what that sounds like. docs/28
## section 5's period is a number handed in by [method start_walk], so nothing
## in this file knows a wave from a volume id.
var _steps: Array[int] = []
## Slot -> world units the unit's node is held away from where the world says
## it stands, while a set piece carries it. See [method lift].
var _lifts: Dictionary[int, int] = {}
## The world this view was last built from, so a lift can work out the height
## it is an offset *from* without the caller passing it in each frame.
var world_ref: World = null


func build(world: World, geometry: Dictionary, textures: Dictionary) -> void:
	# Freed synchronously, not queued: a rebuild has to leave the node list in
	# its final state before anything reads it back, and `queue_free` defers to
	# the end of the frame.
	for child: Node in get_children():
		remove_child(child)
		child.free()
	# What every body was playing, so the rebuild does not restart it. See
	# [method CharismaState.playback]: a command must not snap every idle on
	# the map back to frame 0, and a shot in flight must survive a fog change
	# that lands in the middle of it.
	var carried: Dictionary[int, Dictionary] = {}
	for slot: int in states:
		carried[slot] = states[slot].playback()
	bodies.clear()
	states.clear()
	_walks.clear()
	_steps.clear()
	var prototypes: Dictionary = DictRead.as_dict(geometry["prototypes"])
	var types: UnitTypeTable = world.unit_types()
	world_ref = world
	# **What is drawn is a fresh fog pass, not the stored one.** The rules read
	# `+0x4F` as the last hand-over left it; the picture does not. `0x00481F00`
	# rebuilds the fog before every player command and restores only the unit
	# byte, so the 3D object's draw flag keeps the fresh answer -- which is why
	# an alien walked into view appears the moment you walk, rather than when
	# the turn changes. [method World.display_visibility] is that query.
	var seen: Dictionary[int, int] = world.display_visibility()
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty():
			continue
		# **A dead unit is not drawn.** `aKillUnit` (`0x00472920`) is the death
		# sequence *and* `aRemoveUnitElement`, which deletes the object -- so the
		# engine's picture loses it the moment it dies. `core` keeps the record,
		# because the hero counter and the mission conditions read it, and
		# [method UnitState.remove] only clears the map cell. Without this the
		# body stood there until some later rebuild happened to drop it, which
		# for a unit killed on the player's turn was the next hand-over.
		if DictRead.as_int(view["hp"]) == 0 and not _linger.has(slot):
			continue
		if seen.has(slot):
			view["visibility"] = seen[slot]
		# docs/22 section 9: a hidden unit is not drawn and a contact is a blip.
		# The rule is [Fog]'s, so a change to what visibility means is one edit
		# and not a search through the renderer.
		if not Fog.is_drawn(view):
			continue
		add_child(_build_one(view, types, prototypes, textures, world,
			carried))
	# **After** the loop, not inside it: a rebuild recreates every node, so a
	# unit a set piece is still delivering has to be hidden again each time --
	# and so does one a lift is carrying.
	_apply_suppression()
	_apply_lifts()


func _build_one(view: Dictionary, types: UnitTypeTable,
		prototypes: Dictionary, textures: Dictionary,
		world: World, carried: Dictionary[int, Dictionary]) -> Node3D:
	var node: Node3D = Node3D.new()
	var slot: int = DictRead.as_int(view["slot"])
	var type_id: int = DictRead.as_int(view["type_id"])
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	# The replay's override, if this unit has not played its move yet.
	if _held_at.has(slot):
		x = _held_at[slot].x
		y = _held_at[slot].y
	node.name = "unit_%d" % slot
	var cell: Dictionary = world.cell_view(x, y)
	var h: int = DictRead.as_int(cell.get("height", 0))
	node.position = WorldSpace.cell_centre(x, y, h)
	var facing: int = DictRead.as_int(view["facing"])
	_face(node, null, facing)

	if Fog.is_contact(view):
		# A detection, not a sighting: the cell, and nothing about what is on
		# it. No body, no facing, no player colour.
		node.basis = Basis.IDENTITY
		node.add_child(Fog.contact_marker(prototypes, textures))
		return node

	var colour: Color = UNKNOWN_PLAYER_COLOUR
	var player: int = DictRead.as_int(view["player"])
	if PLAYER_COLOURS.has(player):
		colour = PLAYER_COLOURS[player]

	# The marker the engine really places, from the type's own model column.
	var model: String = types.model(type_id)
	if prototypes.has(model):
		var marker: MeshInstance3D = MeshInstance3D.new()
		marker.name = "marker"
		marker.mesh = MeshBuilder.build(DictRead.as_dict(prototypes[model]),
			textures)
		node.add_child(marker)

	# The body.  `weapon` matters as much as the type: a marine has 16 of them,
	# one per weapon, and the player byte picks the skin.
	var body: CharismaBody = _body_for(view)
	if body != null:
		bodies[slot] = body
		var clips: Array[CharismaClip] = library.clips_for(type_id,
			DictRead.as_int(view["weapon"]), player)
		states[slot] = CharismaState.create(body, clips[0], clips[1], clips[2])
		if carried.has(slot):
			var _resumed: bool = states[slot].resume(carried[slot])
		node.add_child(body)
		_face(node, body, facing)
		return node

	# No body: the capsule, sized from the type's own height column.  This is
	# a visible state, not a silent one -- see the class documentation.
	var metres: float = float(types.body_height_world(type_id)) \
		/ WorldSpace.WORLD_UNITS_PER_METRE
	if metres > 0.0:
		var capsule: CapsuleMesh = CapsuleMesh.new()
		capsule.radius = CAPSULE_RADIUS
		capsule.height = maxf(metres, CAPSULE_RADIUS * 2.0 + 0.01)
		var material: StandardMaterial3D = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = colour
		capsule.material = material
		var capsule_node: MeshInstance3D = MeshInstance3D.new()
		capsule_node.name = "fallback_capsule"
		capsule_node.mesh = capsule
		capsule_node.position = Vector3(0.0, capsule.height * 0.5, 0.0)
		node.add_child(capsule_node)
	return node


## Advance every body's animation, and any walk in progress.
##
## Driven from `_process`. A rebuild throws the states away with the nodes, so
## nothing here outlives the world state it was built from.
func animate(delta: float, world: World) -> void:
	for slot: int in states:
		var state: CharismaState = states[slot]
		var _busy: bool = state.advance(delta)
		# A one-shot that has ended -- clip stopped **and** its end pose
		# held for [constant CharismaState.HOLD_SECONDS] -- returns the body
		# to the idle, which is what plays when nothing else does (docs/40
		# section 7.2).
		#
		# The test is the **mode**, not an edge of `is_busy()`. A type with
		# no `F` clip is never busy for a frame, so an edge test never fired
		# for it and left the body in `FIRE` for the rest of the mission.
		if state.mode == CharismaState.Mode.FIRE and not state.is_busy():
			state.rest()
	for slot: int in _walks.keys():
		_advance_walk(slot, delta, world)
	_age_the_dead(delta)


## Face `slot`'s body at `(tx, ty)` and play its combat clip once.
##
## Returns how long the whole shot occupies the body ([method
## CharismaState.fire]), so a caller pacing a sequence can wait for it. Zero
## for a slot with no state at all -- a unit the fog does not draw has no
## node and no body this rebuild, and a reaction from one presents nothing.
##
## **The turn is the picture's and is not written back.** `Reaction.drain`
## saves the reactor's facing and restores it after the shot (`core/
## reaction.gd`), so the world never reports a reactor as looking at what it
## shot at; the body is turned for the clip and the next rebuild puts it
## back where the world says it looks.
func fire(slot: int, tx: int, ty: int) -> float:
	if not states.has(slot):
		return 0.0
	var node: Node3D = _node_of(slot)
	if node != null and world_ref != null:
		var view: Dictionary = world_ref.unit_view(slot)
		if not view.is_empty() or _held_at.has(slot):
			# `Combat.direction` is the engine's own octant rule (docs/22
			# section 7.4), and a target is rarely a neighbouring cell -- which
			# is the one case [method _facing_of]'s step table covers. Reading
			# a `core` routine mutates nothing.
			# From where the body **is drawn**, which during the computer's
			# replay is not where the world says it is.
			var from_x: int = _held_at[slot].x if _held_at.has(slot) \
				else DictRead.as_int(view["x"])
			var from_y: int = _held_at[slot].y if _held_at.has(slot) \
				else DictRead.as_int(view["y"])
			var facing: int = Combat.direction(from_x, from_y, tx, ty)
			_face(node, _body_of(slot), facing)
	return states[slot].fire()


## True while any body is still playing a one-shot, so a caller can wait for
## the shot before it shows what came back.
func any_busy() -> bool:
	for slot: int in states:
		if states[slot].is_busy():
			return true
	return false


## Walk a unit's node along `cells` -- map indices, source first -- over
## `seconds`, playing its `M` clip for the duration.
##
## The **clock is the caller's**: the walk is told how long it has and fits
## itself into that window. It never decides when the next thing happens, which
## is what keeps [AIPlayback]'s `skip()` meaning "stop drawing" rather than
## "stop simulating".
func start_walk(slot: int, cells: PackedInt32Array, width: int,
		seconds: float, step_frames: int = 0, delay: float = 0.0) -> void:
	if cells.size() < 2 or seconds <= 0.0:
		return
	# `delay` is the camera's: the engine flies the camera to the walker
	# **before** the first step and that flight blocks (docs/42 section 2.2),
	# so the body waits on its first cell for as long as the flight takes.
	_walks[slot] = {"cells": cells, "width": width, "elapsed": 0.0,
		"seconds": seconds, "step_frames": step_frames, "frames": 0.0,
		"steps": 0, "delay": maxf(delay, 0.0)}
	# **On its own first cell, now, and not on the next frame.** The node was
	# left wherever the rebuild put it, which for the computer's replay is
	# where the unit stands at the *end* of the whole turn -- so an alien
	# appeared at its destination, then jumped back and walked to it.
	# `_advance_walk` only writes the position on the frame after this one.
	var start: Node3D = _node_of(slot)
	if start != null and world_ref != null:
		start.position = _cell_position(cells[0], width, world_ref)
		var heading: int = _facing_of(cells[0], cells[1], width)
		if heading >= 0:
			_face(start, _body_of(slot), heading)
	if states.has(slot):
		states[slot].walk()
	# The original starts the walk sound with the walk animation and repeats it
	# every `step_frames` frames after that. That the *first* step is at frame
	# zero rather than at the first boundary is this remake's reading of
	# `aStartWalkAnimationSound`, whose caller is not decompiled; a walk shorter
	# than one period would otherwise be silent, and the shortest shipped path
	# is one field, which is six frames against periods of 2 to 8.
	if step_frames > 0:
		_steps.append(slot)


## The slots that put a foot down since the last call, and clear the list.
##
## Returned by value and emptied here: a caller that forgets to drain it would
## otherwise hear every step of the mission at once, which is exactly the sort
## of thing an aliasing `Array` return would hide.
func steps_taken() -> Array[int]:
	var taken: Array[int] = _steps.duplicate()
	_steps.clear()
	return taken


## True while any body is still walking, so a caller can wait for it.
func is_walking() -> bool:
	return not _walks.is_empty()


## Put every unit where the world says it is and stop every walk.
##
## `AIPlayback.skip()` must leave the map in exactly the state the last frame
## would have shown, and a walk half way between two cells is not that.
func finish_walks(world: World) -> void:
	for slot: int in _walks.keys():
		_snap_to_end(slot, world)
	_walks.clear()
	_steps.clear()


func _advance_walk(slot: int, delta: float, world: World) -> void:
	var walk: Dictionary = _walks[slot]
	var total: float = DictRead.as_float(walk["elapsed"]) + delta
	var seconds: float = DictRead.as_float(walk["seconds"])
	var cells: PackedInt32Array = DictRead.as_int32_array(walk["cells"])
	var width: int = DictRead.as_int(walk["width"])
	walk["elapsed"] = total
	# Still waiting for the camera: the body stays on its first cell, the
	# walk cycle has not begun and no foot comes down.
	var elapsed: float = total - DictRead.as_float(walk.get("delay", 0.0))
	if elapsed < 0.0:
		_walks[slot] = walk
		return
	if elapsed >= seconds:
		_snap_to_end(slot, world)
		_walks.erase(slot)
		return
	var step_frames: int = DictRead.as_int(walk["step_frames"])
	if step_frames > 0:
		var frames: float = DictRead.as_float(walk["frames"]) \
			+ delta * CharismaState.FRAMES_PER_SECOND
		walk["frames"] = frames
		var due: int = int(frames) / step_frames
		var taken: int = DictRead.as_int(walk["steps"])
		while taken < due:
			taken += 1
			_steps.append(slot)
		walk["steps"] = taken
	_walks[slot] = walk
	# Where along the whole path the body is, as a cell pair and a fraction.
	var travelled: float = (elapsed / seconds) * float(cells.size() - 1)
	var step: int = clampi(int(travelled), 0, cells.size() - 2)
	var into: float = travelled - float(step)
	var node: Node3D = _node_of(slot)
	if node == null:
		return
	var from: Vector3 = _cell_position(cells[step], width, world)
	var to: Vector3 = _cell_position(cells[step + 1], width, world)
	node.position = from.lerp(to, into)
	var facing: int = _facing_of(cells[step], cells[step + 1], width)
	if facing >= 0:
		_face(node, _body_of(slot), facing)


## Put a walking body on its **last cell** and stop the walk cycle.
##
## Calling `rest()` alone -- which is all this did at first -- leaves the node
## wherever the last interpolated frame put it, short of the destination. For
## the player's move that off-centre idle persists until the next command's
## rebuild; for `AIPlayback.skip()` it leaves bodies stranded between cells,
## which is precisely the state `skip()` promises cannot happen.
func _snap_to_end(slot: int, world: World) -> void:
	if states.has(slot):
		states[slot].rest()
	if not _walks.has(slot):
		return
	var walk: Dictionary = _walks[slot]
	var cells: PackedInt32Array = DictRead.as_int32_array(walk["cells"])
	var width: int = DictRead.as_int(walk["width"])
	var node: Node3D = _node_of(slot)
	if node == null or cells.size() < 2:
		return
	node.position = _cell_position(cells[cells.size() - 1], width, world)
	var facing: int = _facing_of(cells[cells.size() - 2],
		cells[cells.size() - 1], width)
	if facing >= 0:
		_face(node, _body_of(slot), facing)


func _node_of(slot: int) -> Node3D:
	return get_node_or_null(NodePath("unit_%d" % slot)) as Node3D


## Where a slot's body is **drawn** this frame, in engine units -- part way
## along a walk when it is walking, else its node's position -- or the cell
## the world puts it on when it has no node. The camera tracks this, never
## the world's record: during the computer's replay the two differ by design.
func drawn_position(slot: int) -> Vector3i:
	var node: Node3D = _node_of(slot)
	if node != null:
		return WorldSpace.from_godot(node.position)
	if world_ref == null:
		return Vector3i.ZERO
	var view: Dictionary = world_ref.unit_view(slot)
	if view.is_empty():
		return Vector3i.ZERO
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	return WorldSpace.from_godot(_cell_position(
		world_ref.state.index_of(x, y), world_ref.resource.width, world_ref))


## The map index a slot's walk ends on, or -1 when it is not walking.
func walk_destination(slot: int) -> int:
	if not _walks.has(slot):
		return -1
	var cells: PackedInt32Array = DictRead.as_int32_array(
		DictRead.as_dict(_walks[slot])["cells"])
	return cells[cells.size() - 1] if not cells.is_empty() else -1


## The slots walking right now, for the camera to pick its subject from.
func walking_slots() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for slot: int in _walks.keys():
		out.append(slot)
	return out


func _cell_position(index: int, width: int, world: World) -> Vector3:
	var x: int = index % width
	var y: int = index / width
	var cell: Dictionary = world.cell_view(x, y)
	return WorldSpace.cell_centre(x, y, DictRead.as_int(cell.get("height", 0)))


## The body built for a slot this rebuild, or null. Typed, because a `Dictionary`
## lookup is a `Variant` and an untyped call argument does not compile here.
func _body_of(slot: int) -> CharismaBody:
	return bodies[slot] if bodies.has(slot) else null


## Point a unit at `facing`: the node the engine's own way, and the body its own.
##
## **The two are not the same rotation**, and that is a finding rather than a
## workaround.  The ground marker is Eng3d geometry and takes the engine's own
## yaw, the same one the scenery takes.  A Charisma body is authored facing
## engine -Y and only lines up with `docs/10` section 5.10's facing table under
## [method WorldSpace.charisma_yaw_basis]; applying that to the node instead
## would drag the marker round with it.  A unit with no body -- the capsule,
## the contact blip -- is the `null` case and keeps the node's own basis.
##
## Without this a walking body faced away from wherever it was going, which is
## how it was found: it walked backwards.
func _face(node: Node3D, body: CharismaBody, facing: int) -> void:
	var angle: int = FACING_ANGLES[facing % FACING_ANGLES.size()]
	node.basis = WorldSpace.yaw_basis(angle)
	if body != null:
		body.basis = node.basis.inverse() * WorldSpace.charisma_yaw_basis(angle)


## The facing index of one step, or -1 when the two cells are not neighbours.
##
## `ExecuteMove.FACING_OF_STEP` **is** the table, so it is read rather than
## restated. Writing the inverse out by hand here got it wrong on the first
## try -- the eight facings are not in compass order and never were -- and a
## second copy of a table is a second thing to get wrong. Reading a `core`
## constant mutates nothing.
func _facing_of(from_index: int, to_index: int, width: int) -> int:
	var step: Vector2i = Vector2i(
		(to_index % width) - (from_index % width),
		(to_index / width) - (from_index / width))
	if not ExecuteMove.FACING_OF_STEP.has(step):
		return -1
	return DictRead.as_int(ExecuteMove.FACING_OF_STEP[step])


## The Charisma body a unit's `(type, weapon, player)` selects, or null.
##
## Null is an ordinary answer here.  Player `0xFC` genuinely has no body in the
## engine either, and a cache converted for other missions may not carry the
## one this type wants; both come back as the capsule.
func _body_for(view: Dictionary) -> CharismaBody:
	if library == null or not library.is_ready():
		return null
	var model_name: String = library.name_for(
		CharismaLibrary.SELECTOR_MODEL,
		DictRead.as_int(view["type_id"]), DictRead.as_int(view["weapon"]),
		DictRead.as_int(view["player"]))
	var model: CharismaModel = library.model(model_name)
	if model == null:
		return null
	return CharismaBody.create(model, library)


## Hide `slot` until [method reveal] is called for it, or for everything.
##
## Applied on every rebuild rather than once, because `UnitsView.build` frees
## and recreates every node on each fog change -- a node hidden once would come
## back visible on the next one.
func suppress(slot: int) -> void:
	_suppressed[slot] = true
	_apply_suppression()


func reveal(slot: int) -> void:
	if _suppressed.erase(slot):
		_apply_suppression()


func reveal_all() -> int:
	var count: int = _suppressed.size()
	_suppressed.clear()
	_apply_suppression()
	return count


func suppressed() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for slot: int in _suppressed:
		out.append(slot)
	out.sort()
	return out


func _apply_suppression() -> void:
	for child: Node in get_children():
		var node: Node3D = child as Node3D
		if node == null:
			continue
		var slot: int = node.name.get_slice("_", 1).to_int()
		node.visible = not _suppressed.has(slot)


## Hold a unit `world_units` away from where the world says it stands, while a
## set piece carries it.
##
## `core` applies a lift's whole travel the instant the command runs, so a unit
## standing on it is already at the top before the platform has started to
## move. The offset is the difference between where the picture is and where
## the state is; it decays to zero as the sequence plays, and [method
## drop_lifts] puts everyone back. **The world is never consulted about it and
## never told** -- this is the same contract the terrain diff and the
## suppression have, and it is why a rebuild mid-sequence re-applies rather
## than resets.
##
## **Only the lifted slot is touched.** An earlier draft wrote every child's
## `y` on every lifted frame, which put a walking body back on its start cell's
## floor once a set piece anywhere on the map began -- a walk and a script
## sequence do run in the same playback.
func lift(slot: int, world_units: int) -> void:
	if world_units == 0:
		if _lifts.erase(slot):
			_place(slot, 0)
		return
	_lifts[slot] = world_units
	_place(slot, world_units)


## Put every lifted unit back where the world says it is.
func drop_lifts() -> int:
	var count: int = _lifts.size()
	for slot: int in _lifts.keys():
		_place(slot, 0)
	_lifts.clear()
	return count


## Slot -> the cell the picture draws that unit on, whatever the world says.
##
## The computer's replay is the only user: `core` resolves the whole turn
## before any of it is shown, so a unit that has not played its move event yet
## is already standing where it will end up. [method AIPlayback.pending_starts]
## says where each of them still is, and this holds them there until their own
## event comes round.
##
## It is the same contract [method lift] and [method suppress] have: the world
## is never consulted about it and never told, and a rebuild re-applies rather
## than resets.
var _held_at: Dictionary[int, Vector2i] = {}


## Draw these slots on these cells until told otherwise. An empty dictionary
## puts everyone back where the world says they are.
func hold_at(cells: Dictionary[int, Vector2i]) -> void:
	_held_at = cells.duplicate()


## Slot -> the cell it is held on, for a caller and a suite.
func held_at() -> Dictionary[int, Vector2i]:
	return _held_at.duplicate()

## Slot -> how many seconds a **dead** unit is still drawn for.
##
## `aKillUnit` removes the object at once and there is no death clip in
## Charisma at all (docs/40 section 7.2.1), so a corpse is not a thing the
## engine has. What it does have is an order: the shot is drawn, and *then* the
## unit is gone. Dropping the record the moment `core` reports the kill put the
## removal **before** the shot that caused it -- the computer's rebuild runs
## ahead of its own event -- so a marine vanished and only afterwards came the
## sound of what killed it.
##
## The duration is therefore the remake's and not the engine's: long enough
## that the shot is seen first, short enough to still read as dying at once.
var _linger: Dictionary[int, float] = {}


## Keep drawing `slot` for `seconds` although the world says it is dead.
func linger(slot: int, seconds: float) -> void:
	_linger[slot] = maxf(DictRead.as_float(_linger.get(slot, 0.0)), seconds)


## Slot -> the time left, for a caller and a suite.
func lingering() -> Dictionary[int, float]:
	return _linger.duplicate()


## Count the lingering down and drop whoever has run out.
func _age_the_dead(delta: float) -> void:
	for slot: int in _linger.keys():
		var left: float = _linger[slot] - delta
		if left > 0.0:
			_linger[slot] = left
			continue
		_linger.erase(slot)
		bodies.erase(slot)
		states.erase(slot)
		_walks.erase(slot)
		var node: Node3D = _node_of(slot)
		if node != null:
			remove_child(node)
			node.free()

## Slot -> the offset currently in force, for a caller and a suite.
func lifts() -> Dictionary[int, int]:
	return _lifts.duplicate()


## Re-apply every lift after a rebuild, which recreated the nodes.
func _apply_lifts() -> void:
	for slot: int in _lifts:
		_place(slot, _lifts[slot])


func _place(slot: int, world_units: int) -> void:
	var node: Node3D = get_node_or_null(NodePath("unit_%d" % slot)) as Node3D
	if node == null:
		return
	node.position.y = _floor_y(slot) \
		+ float(world_units) / WorldSpace.WORLD_UNITS_PER_METRE


## The height the world puts this unit's node at, before any lift.
func _floor_y(slot: int) -> float:
	if world_ref == null:
		return 0.0
	var view: Dictionary = world_ref.unit_view(slot)
	if view.is_empty():
		return 0.0
	var cell: Dictionary = world_ref.cell_view(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))
	return float(DictRead.as_int(cell.get("height", 0))) \
		/ WorldSpace.WORLD_UNITS_PER_METRE
