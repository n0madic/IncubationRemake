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
## docs/42 section 6 -- the four idle slots.
var scheduler: IdleScheduler = IdleScheduler.new()
## The `aRandom2` stream the scheduler and the idle selector draw from: the
## pool's own, set by the scene; a fresh one for a suite.
var presentation_rng: IncRandom = null
## Whole displayed frames for the scheduler, carried like the pool's.
var _idle_carry: float = 0.0
## `cmp eax, 0x17700` in the refresh (docs/42 section 1.3): the camera eye's
## z at or above which the bodies stop being simulated.
const FREEZE_HEIGHT: int = 96000
## At most this many scheduler frames a displayed frame, the pool's own cap.
const MAX_IDLE_TICKS: int = 4


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
		# **A held record wins over the world's.** The slot may have been
		# refilled by a mission script while the turn that killed its owner
		# was being decided; until the death is shown, this is still the
		# casualty's tile and the casualty's body.
		var ghost: bool = _held_views.has(slot)
		if ghost:
			view = (_held_views[slot] as Dictionary).duplicate()
		if view.is_empty():
			continue
		# **A dead unit is not drawn.** `aKillUnit` (`0x00472920`) is the death
		# sequence *and* `aRemoveUnitElement`, which deletes the object -- so the
		# engine's picture loses it the moment it dies. `core` keeps the record,
		# because the hero counter and the mission conditions read it, and
		# [method UnitState.remove] only clears the map cell. Without this the
		# body stood there until some later rebuild happened to drop it, which
		# for a unit killed on the player's turn was the next hand-over.
		if DictRead.as_int(view["hp"]) == 0 and not _dying.has(slot):
			continue
		# **Not for a held record.** `seen` is keyed by slot, and a slot whose
		# record was refilled by a mission script answers for its *new* owner
		# -- so a reinforcement the player cannot see would take the casualty
		# being held on it out of the picture, which is the very defect the
		# hold exists to fix.
		if seen.has(slot) and not ghost:
			view["visibility"] = seen[slot]
		# **A unit held at its old cell keeps its old answer.** See
		# [member _held_visibility]: the live pass reads the end of the turn,
		# and this one has not walked yet.
		if _held_visibility.has(slot) and not ghost:
			view["visibility"] = _held_visibility[slot]
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
		# The idle is the scheduler's to start, never the state's to loop:
		# a fresh body holds its bind pose (docs/42 section 6.2).
		states[slot] = CharismaState.create(body, null, clips[1], clips[2])
		states[slot].clip_lookup = library.clip
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
## `frozen` is the refresh's 60 m rule: above [constant FREEZE_HEIGHT] the
## bodies are not simulated, but the scheduler still runs its four slots
## (it is called before the height test, docs/42 section 1.3).
func animate(delta: float, world: World, frozen: bool = false) -> void:
	_run_scheduler(delta, world)
	# **The freeze is the clip, not the walk.** docs/42 section 1.3 stops
	# Charisma above 60 m; `aExecuteMove` still steps the unit field to field,
	# and the picture's walk is what `is_walking()` reports -- which
	# `_picture_busy()` and the pending-reaction drain both gate on. Returning
	# here left `_walks` full for ever and stalled the computer's replay,
	# which is worse than a frozen body and is not what the engine does.
	if not frozen:
		for slot: int in states:
			var state: CharismaState = states[slot]
			var _busy: bool = state.advance(delta)
			# A one-shot that has ended -- clip stopped **and** its end pose
			# held for [constant CharismaState.HOLD_SECONDS] -- returns the
			# body to the idle, which is what plays when nothing else does
			# (docs/40 section 7.2).
			#
			# The test is the **mode**, not an edge of `is_busy()`. A type
			# with no `F` clip is never busy for a frame, so an edge test
			# never fired for it and left the body in `FIRE` for the rest of
			# the mission.
			if state.mode == CharismaState.Mode.FIRE and not state.is_busy():
				state.rest()
	for slot: int in _walks.keys():
		_advance_walk(slot, delta, world)


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


## The scheduler at the engine's frame: whole ticks, the remainder carried.
func _run_scheduler(delta: float, world: World) -> void:
	if world == null or library == null:
		return
	if presentation_rng == null:
		presentation_rng = IncRandom.new()
		presentation_rng.randomize_seed(1.0)
	_idle_carry += delta * CharismaState.FRAMES_PER_SECOND
	var ticks: int = mini(int(_idle_carry), MAX_IDLE_TICKS)
	_idle_carry -= float(int(_idle_carry))
	var first: Dictionary = world.unit_view(0)
	var unit0_type: int = DictRead.as_int(first.get("type_id", -1)) \
		if not first.is_empty() else -1
	for _tick: int in range(ticks):
		scheduler.tick(presentation_rng, unit0_type,
			func(unit: int) -> String: return idle_refusal(unit, world),
			func(unit: int) -> float: return _start_idle(unit, world),
			func(unit: int) -> void: _free_idle(unit))


## The starter's guards, in its order (docs/42 section 6.1 item 3): the
## record, alive, `+0x4F` clear -- the **stored** byte, not the display
## pass, because the engine reads the record -- not animating, an idle clip
## the selector names, a model. `""` takes the unit.
func idle_refusal(unit: int, world: World) -> String:
	var view: Dictionary = world.unit_view(unit)
	if view.is_empty():
		return IdleScheduler.REFUSED_NO_RECORD
	if DictRead.as_int(view["hp"]) == 0:
		return IdleScheduler.REFUSED_DEAD
	if DictRead.as_int(view["visibility"]) != 0:
		return IdleScheduler.REFUSED_HIDDEN
	if states.has(unit):
		var state: CharismaState = states[unit]
		if state.mode != CharismaState.Mode.IDLE or state.is_idling():
			return IdleScheduler.REFUSED_ANIMATING
	# **Without drawing**: the start below spends the branch roll, and asking
	# twice let the guard approve one clip and the start play another.
	if not library.has_idle_clip(DictRead.as_int(view["type_id"]),
			DictRead.as_int(view["weapon"]), DictRead.as_int(view["player"])):
		return IdleScheduler.REFUSED_SELECTOR
	if not states.has(unit):
		return IdleScheduler.REFUSED_NO_MODEL
	return ""


func _start_idle(unit: int, world: World) -> float:
	var view: Dictionary = world.unit_view(unit)
	# The selector runs for the start (`0x0042DDF0`, docs/42 section 6.1 item
	# 4) and this is the **only** call that draws: the guard above asks
	# whether a clip exists without spending the branch roll.
	var clip: CharismaClip = library.idle_clip_for(
		DictRead.as_int(view["type_id"]), DictRead.as_int(view["weapon"]),
		DictRead.as_int(view["player"]), presentation_rng)
	return states[unit].start_idle(clip)


func _free_idle(unit: int) -> void:
	if states.has(unit):
		states[unit].detach_idle()


## The combat clip's frame counts at speed 6.0 for `slot` (docs/42 section
## 1.2), for [ShotSequence]: to the note, the spin after it, and from the
## note to the end. Zeros for a slot with no state or no `F` clip.
func body_frames(slot: int) -> Dictionary:
	if not states.has(slot):
		return {"to_break": 0, "spin": 0, "after_break": 0}
	var state: CharismaState = states[slot]
	var to_break: int = state.frames_to_break()
	var after: int = 0
	if to_break > 0 and state._fire != null:
		var stop: float = state._fire.break_time()
		if stop < 0.0:
			stop = state._fire.duration
		after = maxi(ceili((state._fire.duration - stop)
			/ CharismaState.SPEED_FIGHT), 0)
	return {"to_break": to_break, "spin": state.spin_frames(),
		"after_break": after}


## `aContCHAnimation` on one body; the frames left to its end.
func resume_past_break(slot: int) -> int:
	if not states.has(slot):
		return 0
	return states[slot].resume_past_break()


## `aStopCHAnimation` on one body: back to its idle.
func rest(slot: int) -> void:
	if states.has(slot):
		states[slot].rest()


func is_playing(slot: int) -> bool:
	return states.has(slot) and states[slot].is_playing()


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
		"seconds": seconds, "step_frames": step_frames,
		"steps": 0, "delay": maxf(delay, 0.0), "started": false}
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
	# **Not while the camera is still flying.** `aExecuteMove` runs its camera
	# arm first -- `aPlaySelectUnitAnimation3` `0x0040EDB0` at `0x0046E514`
	# and `0x0046E56F`, or one of the other three -- and every arm joins at
	# `0x0046E577`, where the clip is started (`0x004055E0(3, unit, 0)`,
	# docs/42 section 3.1) and then `aStartWalkAnimationSound` `0x0040E640`
	# at `0x0046E593`. Starting them here instead made every unit tread its
	# first step on the spot while the camera flew to it, and put a footstep
	# under it.
	if delay <= 0.0:
		_begin_walk_cycle(slot)


## Start the walk cycle and its first footstep -- the join at `0x0046E577`.
##
## The original starts the walk sound with the walk animation and repeats it
## every `step_frames` frames after that. That the *first* step is at frame
## zero rather than at the first boundary is this remake's reading of
## `aStartWalkAnimationSound`, whose caller is not decompiled; a walk shorter
## than one period would otherwise be silent, and the shortest shipped path
## is one field, which is six frames against periods of 2 to 8.
func _begin_walk_cycle(slot: int) -> void:
	if states.has(slot):
		states[slot].walk()
	if not _walks.has(slot):
		return
	var walk: Dictionary = _walks[slot]
	walk["started"] = true
	_walks[slot] = walk
	if DictRead.as_int(walk["step_frames"]) > 0:
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
	# The flight is over: the cycle and the first footstep begin here, as
	# they do past `0x0046E577`.
	if not DictRead.as_bool(walk.get("started", false)):
		walk["started"] = true
		_walks[slot] = walk
		_begin_walk_cycle(slot)
		walk = _walks[slot]
	if elapsed >= seconds:
		_snap_to_end(slot, world)
		_walks.erase(slot)
		return
	# **Counted from the walk, not from the tick.** The frames are read off
	# `elapsed`, which is already the time past the camera's flight, so the
	# tick that crosses the flight's end contributes only its own remainder;
	# accumulating whole deltas gave that tick a step it had not walked.
	var step_frames: int = DictRead.as_int(walk["step_frames"])
	if step_frames > 0:
		var frames: float = elapsed * CharismaState.FRAMES_PER_SECOND
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


## What a held unit's `+0x4F` was **before** the computer's turn ran.
##
## The other half of the same defect [member _held_at] fixes, and the same
## argument: [method World.display_visibility] is computed from where the
## units are *now*, and after `submit_end_turn` that is where they end the
## turn. An alien that walks out of sight was therefore a contact beam --
## docs/22 section 9.1's `+0x4F == 1` -- from the very first frame of the
## replay, standing on the cell it had not left yet.
##
## The set is the **caller's**, not [member _held_at]'s. Two units are in one
## and not the other and both were drawn wrong while the two were the same
## test: the unit whose event is on screen *now* has left `_held_at` -- the
## playback advances its index before it calls back -- so a walker heading out
## of sight turned into a beam the instant its own walk began; and a marine
## the computer kills mid-turn is an observer the world has already lost, so
## the aliens only it could see were hidden from the first frame although the
## marine is still standing on screen. [method SliceMain._visibility_hold]
## decides which slots are in it and releases each one after its own event has
## been shown.
var _held_visibility: Dictionary[int, int] = {}


## Draw these slots on these cells until told otherwise. An empty dictionary
## puts everyone back where the world says they are.
func hold_at(cells: Dictionary[int, Vector2i]) -> void:
	_held_at = cells.duplicate()


## The visibility a held slot is drawn with -- see [member _held_visibility].
## Cleared with the same empty dictionary [method hold_at] takes.
func hold_visibility(seen: Dictionary[int, int]) -> void:
	_held_visibility = seen.duplicate()


## Slot -> the cell it is held on, for a caller and a suite.
func held_at() -> Dictionary[int, Vector2i]:
	return _held_at.duplicate()


## Slot -> the visibility it is held at, for a caller and a suite.
func held_visibility() -> Dictionary[int, int]:
	return _held_visibility.duplicate()

## The casualties of the shot now on screen, kept drawn although the world
## says they are dead, until the shot's own death stage hides them.
##
## The rebuild that drops a casualty runs *before* the event that killed it is
## presented -- for the computer's replay always -- so without this a marine
## vanished and the sound of what killed it arrived afterwards. The engine
## hides the object **at once** in the death stage of `aPlayFightAnimation`
## (`0x00405320(obj, 5)`, docs/42 section 4.8), which is the moment
## [method hide_now] reproduces; there is no timer, and the 0.7 s linger this
## replaced was the remake's number.
var _dying: Dictionary[int, bool] = {}
## The record a dying slot is drawn from, where the world's own is no longer
## the unit that died -- see [method mark_dying] and
## [member SliceMain._views_before_turn]. Empty for the ordinary case, where
## the world still carries the casualty's own record with its hit points at
## zero.
var _held_views: Dictionary[int, Dictionary] = {}


## Keep drawing `slot` although the world says it is dead, until [method
## hide_now].
## `view` is the record to draw it from, and is given only where the world's
## own record for the slot has already been taken by somebody else: a mission
## script's `InsertUnit` reuses a slot the same turn emptied.
func mark_dying(slot: int, view: Dictionary = {}) -> void:
	_dying[slot] = true
	if not view.is_empty():
		_held_views[slot] = view.duplicate()


## The part a Charisma model puts at the end of the weapon, and the name six
## of the seven muzzle call sites push: the one-character string `"M"`
## (`0x004C10D8`), which 89 of the 114 shipped models carry a part for.
##
## It is the **default and not the only one**. The seventh site --
## `0x0040D230`, weapon 12's second call -- pushes `"MM"`, and exactly one
## shipped model has a part by that name (`P0_020.cho`), so that weapon
## really does fire its second burst from a second barrel. Which name a shot
## uses comes from `tables/blobs.json`'s `weapon_muzzle_joint`, per call, and
## is passed in rather than assumed here.
const MUZZLE_PART: String = "M"


## Whether `slot` has a body whose model carries the named part.
func has_muzzle(slot: int, part: String = MUZZLE_PART) -> bool:
	if part.is_empty() or not bodies.has(slot):
		return false
	var body: CharismaBody = bodies[slot]
	return body != null and body.has_part(part)


## Where that part is now, in the engine's own world units.
##
## The engine takes this branch when the shooter's `+0x56` says it is playing
## an animation (docs/42 section 6.2.1 -- the byte is the running Charisma
## animation handle, which a fight animation sets), so this is what an
## ordinary shot comes out of, and the body's axis at eye height is the
## fallback for a body that is standing still.
func muzzle_point(slot: int, part: String = MUZZLE_PART) -> Vector3i:
	if not has_muzzle(slot, part):
		return Vector3i.ZERO
	var body: CharismaBody = bodies[slot]
	return WorldSpace.from_godot(body.part_position(part))


## Whether this slot is being held on screen past its death.
func is_dying(slot: int) -> bool:
	return _dying.has(slot)


## The record a dying slot is being drawn from, or an empty dictionary where
## the world's own record is still the casualty's. See [member _held_views].
func held_view(slot: int) -> Dictionary:
	if not _held_views.has(slot):
		return {}
	return (_held_views[slot] as Dictionary).duplicate()


## The slots still drawn past their death, for a caller and a suite.
func dying() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for slot: int in _dying:
		out.append(slot)
	out.sort()
	return out


## `0x00405320(obj, 5)` -- the object leaves the picture in this frame.
## Answers whether a node was there to remove.
func hide_now(slot: int) -> bool:
	_dying.erase(slot)
	_held_views.erase(slot)
	bodies.erase(slot)
	states.erase(slot)
	_walks.erase(slot)
	var node: Node3D = _node_of(slot)
	if node == null:
		return false
	remove_child(node)
	node.free()
	return true


## Drop every death hold -- a new command's rebuild, which is where the
## dead leave the picture whether or not their shot was shown to the end.
func clear_dying() -> void:
	_dying.clear()
	_held_views.clear()


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
## The body drawn at a world position this frame -- the jump's parabola
## and the push's slide (docs/42 sections 7.1 and 7.2). A slot with no node
## is left alone; [method settle] puts a moved body back on its cell.
func place_at(slot: int, at: Vector3i) -> bool:
	var node: Node3D = _node_of(slot)
	if node == null:
		return false
	node.position = WorldSpace.to_godot(at.x, at.y, at.z)
	return true


## The body turned to a yaw in 4096ths (`0x004051E0`), not to one of the
## eight facings.
func turn_to(slot: int, yaw: int) -> bool:
	var node: Node3D = _node_of(slot)
	if node == null:
		return false
	node.basis = WorldSpace.yaw_basis(yaw)
	var body: CharismaBody = _body_of(slot)
	if body != null:
		body.basis = node.basis.inverse() * WorldSpace.charisma_yaw_basis(yaw)
	return true


## The body back on the cell the world has it on, as a rebuild would put it.
func settle(slot: int) -> bool:
	var node: Node3D = _node_of(slot)
	if node == null or world_ref == null:
		return false
	var view: Dictionary = world_ref.unit_view(slot)
	if view.is_empty():
		return false
	var index: int = world_ref.state.index_of(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))
	node.position = _cell_position(index, world_ref.resource.width, world_ref)
	_place(slot, DictRead.as_int(_lifts.get(slot, 0)))
	return true


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
