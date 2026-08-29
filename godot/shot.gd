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
			var view: Dictionary = _main.world.unit_view(slots[0])
			var x: int = DictRead.as_int(view["x"])
			var y: int = DictRead.as_int(view["y"])
			var cell: Dictionary = _main.world.cell_view(x, y)
			_main.camera_rig().focus_on(x, y, DictRead.as_int(cell["height"]))
			_main.camera_rig().set_zoom(26.0)
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
