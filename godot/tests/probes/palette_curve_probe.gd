extends SceneTree
## The windowed oracle behind [PaletteCurve]: what the running renderer draws
## for every texel value, read back from the frame.
##
## Run with a window (the frame is read from the viewport's texture):
##
##     godot --path godot --script res://tests/probes/palette_curve_probe.gd
##
## It prints the 256-entry output table for an unshaded `albedo_texture`,
## the same for a compensated texture, and the mismatch counts, so an engine
## upgrade can be checked against `test_mesh.gd`'s `GL_OUTPUT_HEAD` in one
## run.  Under Mobile or Forward+ the first table shows the linear buffer's
## quantisation instead (docs/92 section 7.25) and the compensation is off.

const SAMPLE_FRAMES: int = 2


func _quad(root: Window, x: float, material: Material) -> void:
	var instance: MeshInstance3D = MeshInstance3D.new()
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.6, 1.0)
	instance.mesh = quad
	instance.material_override = material
	instance.position = Vector3(x, 0.0, 0.0)
	root.add_child(instance)


func _init() -> void:
	var root: Window = get_root()
	var camera: Camera3D = Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 1.0)
	root.add_child(camera)
	camera.current = true
	var plain: StandardMaterial3D = StandardMaterial3D.new()
	plain.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plain.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_quad(root, -0.4, plain)
	var compensated: StandardMaterial3D = StandardMaterial3D.new()
	compensated.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	compensated.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_quad(root, 0.4, compensated)
	var curve: PackedByteArray = PaletteCurve.table() \
		if PaletteCurve.is_active() else PackedByteArray()
	var drawn: PackedInt32Array = PackedInt32Array()
	var drawn_compensated: PackedInt32Array = PackedInt32Array()
	var model_off: int = 0
	var compensated_off: int = 0
	for v: int in range(PaletteCurve.LEVELS):
		var image: Image = Image.create_empty(1, 1, false, Image.FORMAT_RGB8)
		image.set_pixel(0, 0, Color8(v, v, v))
		plain.albedo_texture = ImageTexture.create_from_image(image)
		compensated.albedo_texture = ImageTexture.create_from_image(
			PaletteCurve.remap(image, curve) if not curve.is_empty() else image)
		for _frame: int in range(SAMPLE_FRAMES):
			await process_frame
		var shot: Image = root.get_texture().get_image()
		var y: int = shot.get_height() / 2
		var left: int = shot.get_pixel(int(shot.get_width() * 0.35), y).r8
		var right: int = shot.get_pixel(int(shot.get_width() * 0.65), y).r8
		drawn.append(left)
		drawn_compensated.append(right)
		if absi(roundi(PaletteCurve.forward(float(v) / 255.0) * 255.0) - left) > 1:
			model_off += 1
		if absi(right - v) > 1:
			compensated_off += 1
	print("method ", RenderingServer.get_current_rendering_method(),
		" driver ", RenderingServer.get_current_rendering_driver_name())
	print("drawn ", drawn)
	print("drawn_compensated ", drawn_compensated)
	print("model off by more than one level: ", model_off,
		"; compensated off by more than one level: ", compensated_off)
	quit()
