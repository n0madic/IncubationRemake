class_name SequenceScreen
extends CampaignScreen

## The screen a cutscene plays in -- `Menu_b.lcl`'s window 8 (`:Sequence;`,
## a bare `GUI_SetWindow (0,0,640,480)`) with the two presentations mission
## control chooses between (docs/41 section 3, docs/27 section 2.3):
##
## * **full screen**, `(0, 0, 640, 480)` and no plate -- the intro on a new
##   campaign 1 and the animated extro of mission id 255;
## * **framed**, `(65, 57, 518, 306)` inside `plate_7` -- the dialogue
##   locations 10..23, over the map.
##
## The 3D itself is a [SequencePlayer] the host parents to its own tree, so it
## renders through the hole like the campaign map does; this layer is the
## plate around it, the loading caption and the way out. **Any key or click
## ends the whole sequence**, not a part: `0x00455600` and `0x004557A0` both
## call `0x00457180`, which destroys the player, on `WM_LBUTTONDOWN` and the
## key path while window 8 is up.

## `GUI\plate_7.bmp`, the one `0x00457063` loads for the framed presentation.
const PLATE_SEQUENCE: String = "plate_7"
## The framed background callback `0x00456F30`: text 0 of the loaded bank
## (*Please Wait...*) at (320, 210), colours `0xFFFF` / `0x632C`.
const ID_CAPTION: int = 0
const CAPTION_AT: Vector2 = Vector2(320.0, 210.0)
## What the host hears when the sequence is dismissed.
const DONE: String = "sequence_done"

## Full screen, or framed over the map.
var full: bool = false
## The player, for the caption to know when the first frame has drawn.
var player: SequencePlayer = null

var _caption: Label = null


func plate_name() -> String:
	return PLATE_NONE if full else PLATE_SEQUENCE


func plate_window() -> Rect2:
	return Rect2() if full else PLATE_WINDOW


func build() -> void:
	if full:
		return
	_caption = gui_text(label_for(BANK_MISSION, ID_CAPTION), CAPTION_AT,
		ALIGN_CENTRE, INK_VALUE)


## The caption is the background callback's, drawn until the player has a
## picture of its own to put in the window.
func hide_caption() -> void:
	if _caption != null:
		_caption.visible = false


## Any key or click ends the sequence -- the GUI loop's two exit call sites.
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
