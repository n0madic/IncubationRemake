class_name SplashScreen
extends CampaignScreen

## `aGameIntro` `0x0044BCA0`: `BlueByte.bmp`, a 1500 ms hold, then `title.bmp`
## with `Menu_a.lcl`'s window 13 (`:GameIntro;`) -- one line of text,
## `Txtmod_a` 5 *Start Game*, at (290, 420) in font 1 -- until a key or a click
## (docs/92 section 7.19).
##
## Two stages and two plates, so the host raises one instance per stage rather
## than repainting: the logo stage takes no input at all, as the original's
## `Sleep` takes none.

const STAGE_LOGO: int = 0
const STAGE_TITLE: int = 1

## `Graphics/Bluebyte.bmp` and `Graphics/Title.bmp`, baked since 0.17.0.
const PLATE_LOGO: String = "bluebyte"
const PLATE_TITLE: String = "title"
## `GUI_SetTextOnly2 (00_gdtID, 1_fntID, 05_WinText, 290_x, 420_y, 60_Width,
## 30_Height)`.
const ID_START_GAME: int = 5
const TEXT_AT: Vector2 = Vector2(290.0, 420.0)
const TEXT_SIZE: Vector2 = Vector2(60.0, 30.0)
const TEXT_FONT: int = 1
## What the host hears when the title is dismissed.
const DONE: String = "splash_done"

var stage: int = STAGE_LOGO


func plate_name() -> String:
	return PLATE_TITLE if stage == STAGE_TITLE else PLATE_LOGO


func build() -> void:
	if stage != STAGE_TITLE:
		return
	var line: Label = make_label(label_for(BANK_MENU, ID_START_GAME), 0,
		TEXT_FONT)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_theme_color_override("font_color", INK_TITLE)
	root().add_child(line)
	place_on_plate(line, TEXT_AT, TEXT_SIZE)


func _unhandled_input(event: InputEvent) -> void:
	if stage != STAGE_TITLE:
		return
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
