extends SceneTree

## A screenshot of the slice, for the "agrees with the inspection tools" check.
##
##     godot --path godot --script res://shot.gd --resolution 1280x800
const SHOT_PATH: String = "user://slice_shot.png"

var _frames: int = 0
var _main: SliceMain = null


func _initialize() -> void:
	var packed: PackedScene = load("res://game/main.tscn") as PackedScene
	_main = packed.instantiate() as SliceMain
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 4 and _main.world != null:
		var slots: PackedInt32Array = _main.world.unit_slots()
		print("units=", slots, " scenery=", _main.scenery_count())
		var result: MoveMapResult = _main.select_unit(slots[0], false)
		print("reachable=", result.reachable_count(),
			" warp=", result.warp_count(), " mp=", result.mp)
		if OS.get_cmdline_user_args().has("--focus"):
			# The engine's own "on the unit" placement, settled at once.
			var _flight: float = _main.camera_director().cycle(_main.world,
				slots[0])
			_main.camera_rig().settle()
		if OS.get_cmdline_user_args().has("--eyes"):
			var _flight: float = _main.camera_director().view_eyes(_main.world,
				slots[0])
			_main.camera_rig().settle()
		if OS.get_cmdline_user_args().has("--map"):
			# `--at=x,y` puts the map view over another cell -- one under a
			# ceiling, say -- instead of the first unit's.
			var view: Dictionary = _main.world.unit_view(slots[0])
			var at_x: int = DictRead.as_int(view["x"])
			var at_y: int = DictRead.as_int(view["y"])
			for arg: String in OS.get_cmdline_user_args():
				if arg.begins_with("--at="):
					var pair: PackedStringArray = arg.substr(5).split(",")
					if pair.size() == 2:
						at_x = pair[0].to_int()
						at_y = pair[1].to_int()
			var _flight: float = _main.camera_director().view_map(_main.world,
				at_x, at_y)
			_main.camera_rig().settle()
	if _frames == 5:
		var rig: CameraRig = _main.camera_rig()
		print("camera eye=", rig.eye(), " target=", rig.target(),
			" quadrant=", rig.quadrant(), " flying=", rig.is_flying())
	if _frames < 16:
		return false
	var image: Image = root.get_texture().get_image()
	var target: String = SHOT_PATH
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			target = arg.substr(6)
	var saved: Error = image.save_png(target)
	print("saved=", saved, " path=", ProjectSettings.globalize_path(target))
	return true
