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


func build(world: World, geometry: Dictionary, textures: Dictionary) -> void:
	# Freed synchronously, not queued: a rebuild has to leave the node list in
	# its final state before anything reads it back, and `queue_free` defers to
	# the end of the frame.
	for child: Node in get_children():
		remove_child(child)
		child.free()
	bodies.clear()
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
	node.basis = WorldSpace.yaw_basis(
		FACING_ANGLES[facing % FACING_ANGLES.size()])

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
		body.pose(null, 0.0)
		node.add_child(body)
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
