class_name FlyInScreen
extends CampaignScreen

## The plate an upgrade base's arrival flight is drawn behind --
## `aPlayLocationAnimation_Upgrade` `0x00417510`, docs/27 section 2.7.
##
## The routine builds `upgrade_N`'s scene, draws `GUI\plate_7.bmp` into both
## surfaces (`aLoadAndOutputBitmap(0, ...)` twice, `0x0041757f` and
## `0x004175c3`) and then **blocks** in `0x00417000` until the camera has
## flown down the base's own `CreateCameraPath` waypoints. Only when that
## returns does mission control raise the Upgrade Menu. So the flight is a
## transition the player watches, not something happening behind a menu: the
## same framed presentation a dialogue cutscene uses, on the same plate, in
## the same 518x306 window -- `0x00417000` opens by setting exactly that
## window (`0x0040b670(65, 57, 518, 306)`).
##
## There is no caption and no button. The only input it takes is the one that
## ends it: `0x0040b6f0` sets `0x004fcbdc` on `WM_KEYDOWN`, `WM_CHAR` and
## `WM_LBUTTONDOWN`, and the flight's own loop reads that flag and stops.

## `GUI\plate_7.bmp` -- the same one [SequenceScreen] uses framed.
const PLATE_FLY_IN: String = "plate_7"
## What the host hears when the flight is skipped or has landed.
const DONE: String = "fly_in_done"


func plate_name() -> String:
	return PLATE_FLY_IN


func plate_window() -> Rect2:
	return PLATE_WINDOW


func build() -> void:
	pass


## Any key or click lands the flight -- `0x004fcbdc`, the flag the front end's
## own frame function sets and the flight loop reads.
func _unhandled_input(event: InputEvent) -> void:
	var pressed: bool = false
	if event is InputEventKey:
		var key: InputEventKey = event
		pressed = key.is_pressed() and not key.is_echo()
	elif event is InputEventMouseButton:
		var button: InputEventMouseButton = event
		pressed = button.is_pressed()
	if not pressed:
		return
	var viewport: Viewport = get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()
	chose.emit(DONE)
