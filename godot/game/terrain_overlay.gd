class_name TerrainOverlay
extends MeshInstance3D

## One quad per map field, at the field's own height, tinted by field type.
##
## This is an **overlay**, not the ground: the visible ground is the `.3DW`
## clones.  The `.lev` carries no terrain surface at all -- its lattice records
## are one 320-unit octagon marker per cell, carrying the height -- so nothing
## has to be generated to fill the gaps between heights, and the steps a height
## difference produces are correct rather than missing walls.
##
## The tints are the same ramp `tools/lev_parse.py --png` uses, so "the rendered
## map agrees with the inspection tools" can be checked by eye rather than only
## by hash.

const HALF: float = 1.0
## Lifted clear of the scenery so the overlay does not z-fight with the ground.
const LIFT: float = 0.02

## The `type_hue` ramp of `tools/lev_parse.py:179`, **all eleven entries and in
## the same order** -- one per field type, `Undefined` first.  It was copied
## from `type_hue[4:]` once, which painted every cell as the type four along and
## wrapped at seven: the three converted missions hold only types 0, 1 and 2, so
## every cell on every one of them was the wrong colour, which is exactly what
## makes this file's whole purpose -- being eye-checkable against
## `lev_parse.py --png` -- not work.
const TYPE_HUE: Array[Color] = [
	Color8(70, 90, 110), Color8(60, 120, 70), Color8(120, 100, 60),
	Color8(90, 90, 140), Color8(110, 110, 110), Color8(140, 80, 60),
	Color8(60, 130, 130), Color8(130, 60, 130), Color8(150, 150, 90),
	Color8(80, 160, 200), Color8(200, 120, 200),
]
## `lev_parse.py` paints a cell with a unit red and one with an action point
## amber, before the field-type ramp.
const UNIT_COLOUR: Color = Color8(255, 60, 60)
const ACTION_POINT_COLOUR: Color = Color8(255, 210, 60)

var _width: int = 0
var _height: int = 0
var _mesh: ArrayMesh = null


func build(snapshot: Dictionary) -> void:
	_width = DictRead.as_int(snapshot["width"])
	_height = DictRead.as_int(snapshot["height"])
	var heights: PackedInt32Array = snapshot["height_map"]
	var field_types: PackedByteArray = snapshot["field_type"]
	var action_points: PackedByteArray = snapshot["action_point"]
	var units: PackedInt32Array = snapshot["unit"]

	var lo: int = heights[0]
	var hi: int = heights[0]
	for value: int in heights:
		lo = mini(lo, value)
		hi = maxi(hi, value)
	var span: float = maxf(1.0, float(hi - lo))

	var vertices: PackedVector3Array = PackedVector3Array()
	var colours: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()
	for y: int in range(_height):
		for x: int in range(_width):
			var i: int = y * _width + x
			var centre: Vector3 = WorldSpace.cell_centre(x, y, heights[i])
			centre.y += LIFT
			var base: int = vertices.size()
			vertices.append(centre + Vector3(-HALF, 0.0, -HALF))
			vertices.append(centre + Vector3(HALF, 0.0, -HALF))
			vertices.append(centre + Vector3(HALF, 0.0, HALF))
			vertices.append(centre + Vector3(-HALF, 0.0, HALF))
			var colour: Color = _cell_colour(field_types[i], action_points[i],
				units[i], heights[i], lo, span)
			for _corner: int in range(4):
				colours.append(colour)
			indices.append_array(PackedInt32Array(
				[base, base + 1, base + 2, base, base + 2, base + 3]))

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.40)
	_mesh.surface_set_material(0, material)
	mesh = _mesh
	# **Off until asked for.**  This is a debug view of the *logical* map -- one
	# translucent quad per cell, coloured by field type with action points in
	# amber -- and it sits two centimetres above whatever geometry occupies the
	# cell, so leaving it on tints every surface in the mission.  `T` shows it.
	visible = false


func toggle() -> void:
	visible = not visible


func _cell_colour(field_type: int, action_point: int, unit: int, height: int,
		lo: int, span: float) -> Color:
	if unit != MapState.NO_UNIT:
		return UNIT_COLOUR
	if action_point != 0:
		return ACTION_POINT_COLOUR
	var base: Color = TYPE_HUE[field_type % TYPE_HUE.size()]
	var k: float = 0.45 + 0.55 * float(height - lo) / span
	return Color(base.r * k, base.g * k, base.b * k)
