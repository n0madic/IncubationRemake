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


func build(world: World, geometry: Dictionary, textures: Dictionary) -> void:
	# Freed synchronously, not queued: a rebuild has to leave the node list in
	# its final state before anything reads it back, and `queue_free` defers to
	# the end of the frame.
	for child: Node in get_children():
		remove_child(child)
		child.free()
	bodies.clear()
	states.clear()
	_walks.clear()
	var prototypes: Dictionary = DictRead.as_dict(geometry["prototypes"])
	var types: UnitTypeTable = world.unit_types()
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty():
			continue
		# docs/22 section 9: a hidden unit is not drawn and a contact is a blip.
		# The rule is [Fog]'s, so a change to what visibility means is one edit
		# and not a search through the renderer.
		if not Fog.is_drawn(view):
			continue
		add_child(_build_one(view, types, prototypes, textures, world))


func _build_one(view: Dictionary, types: UnitTypeTable,
		prototypes: Dictionary, textures: Dictionary,
		world: World) -> Node3D:
	var node: Node3D = Node3D.new()
	var slot: int = DictRead.as_int(view["slot"])
	var type_id: int = DictRead.as_int(view["type_id"])
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
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
		node.add_child(Fog.contact_marker())
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
		var was_firing: bool = state.is_busy()
		state.advance(delta)
		# A one-shot that has just ended returns the body to the idle, which is
		# what plays when nothing else does (docs/40 section 7.2).
		if was_firing and not state.is_busy():
			state.rest()
	for slot: int in _walks.keys():
		_advance_walk(slot, delta, world)


## Walk a unit's node along `cells` -- map indices, source first -- over
## `seconds`, playing its `M` clip for the duration.
##
## The **clock is the caller's**: the walk is told how long it has and fits
## itself into that window. It never decides when the next thing happens, which
## is what keeps [AIPlayback]'s `skip()` meaning "stop drawing" rather than
## "stop simulating".
func start_walk(slot: int, cells: PackedInt32Array, width: int,
		seconds: float) -> void:
	if cells.size() < 2 or seconds <= 0.0:
		return
	_walks[slot] = {"cells": cells, "width": width, "elapsed": 0.0,
		"seconds": seconds}
	if states.has(slot):
		states[slot].walk()


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


func _advance_walk(slot: int, delta: float, world: World) -> void:
	var walk: Dictionary = _walks[slot]
	var elapsed: float = DictRead.as_float(walk["elapsed"]) + delta
	var seconds: float = DictRead.as_float(walk["seconds"])
	var cells: PackedInt32Array = DictRead.as_int32_array(walk["cells"])
	var width: int = DictRead.as_int(walk["width"])
	if elapsed >= seconds:
		_snap_to_end(slot, world)
		_walks.erase(slot)
		return
	walk["elapsed"] = elapsed
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
