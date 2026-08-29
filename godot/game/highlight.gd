class_name Highlight
extends MeshInstance3D

## The move map, drawn as its own mesh over the terrain overlay.
##
## Separate from [TerrainOverlay] on purpose.  The overlay's job is to agree
## with `tools/lev_parse.py --png` -- same field-type ramp, same amber action
## points -- so it has to stay faithful and subtle.  The highlight's job is to
## be *seen* on top of dark, unshaded 1997 scenery, so it is built only from
## the marked cells and drawn without depth testing.
##
## docs/10 section 4.5: cell state 10 is walkable and 60 is a warp target.

const HALF: float = 0.92
const LIFT: float = 0.06

const REACH_NEAR: Color = Color(0.30, 0.95, 0.45, 0.72)
const REACH_FAR: Color = Color(0.10, 0.45, 0.20, 0.72)
const WARP_COLOUR: Color = Color(0.35, 0.60, 1.00, 0.72)

var _mesh: ArrayMesh = null


func _init() -> void:
	_mesh = ArrayMesh.new()
	mesh = _mesh
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = material


func clear() -> void:
	_mesh.clear_surfaces()


func show_result(result: MoveMapResult, heights: PackedInt32Array) -> void:
	_mesh.clear_surfaces()
	var vertices: PackedVector3Array = PackedVector3Array()
	var colours: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()
	var span: float = maxf(1.0, float(result.mp))
	for y: int in range(result.height):
		for x: int in range(result.width):
			var i: int = y * result.width + x
			var state: int = result.state_at(i)
			if state == MoveMapResult.STATE_NONE:
				continue
			var colour: Color = WARP_COLOUR
			if state == MoveMapResult.STATE_REACHABLE:
				var spent: float = float(result.cost_to(x, y)) / span
				colour = REACH_NEAR.lerp(REACH_FAR, clampf(spent, 0.0, 1.0))
			var centre: Vector3 = WorldSpace.cell_centre(x, y, heights[i])
			centre.y += LIFT
			var base: int = vertices.size()
			vertices.append(centre + Vector3(-HALF, 0.0, -HALF))
			vertices.append(centre + Vector3(HALF, 0.0, -HALF))
			vertices.append(centre + Vector3(HALF, 0.0, HALF))
			vertices.append(centre + Vector3(-HALF, 0.0, HALF))
			for _corner: int in range(4):
				colours.append(colour)
			indices.append_array(PackedInt32Array(
				[base, base + 1, base + 2, base, base + 2, base + 3]))
	if vertices.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
