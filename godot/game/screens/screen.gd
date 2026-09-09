class_name CampaignScreen
extends CanvasLayer

## The base every campaign screen sits on: the plate, the font, buttons drawn
## on `buttons.LIB` sprites, and the localisation seam.
##
## **No string literal reaches a label from here.** Every caption goes through
## [method label_for], which is `Localization.shipped(module, id)` -- docs/92
## section 7.6: a localisation seam retrofitted later means finding every
## literal, and the shipped banks already carry these screens' own captions.

## The library the buttons are drawn from.
const BUTTON_LIBRARY: String = "buttons"
## The plate a framed screen sits on.
const PLATE: String = Art.PLATE_FRAMED

## The banks docs/27 section 1.2 names.
const BANK_MENU: String = "Txtmod_a"
const BANK_MISSION: String = "Txtmod_b"
const BANK_REPORT: String = "Txtmod_d"
const BANK_LOCATIONS: String = "Campaign"
const BANK_SQUAD: String = "Txtmod_h"

## Ids used by more than one screen.
const ID_CONTINUE: int = 4
const ID_BACK: int = 2
const ID_CANCEL: int = 1
## `Txtmod_h` 24/25 -- *Save game* and *Load game*, the in-mission pair.
const ID_SAVE_GAME: int = 24
const ID_LOAD_GAME: int = 25
## `Txtmod_b` 140 -- *Main Map*, the way back to the location map. Read by the
## deployment screen, which backs out of a sortie that has not started, and by
## the pause menu, which leaves one that has.
const ID_MAIN_MAP: int = 140

## `Txtmod_d` 60/61/62 -- *Back to the Main Menu without saving?* and its two
## answers, which the original asks before it drops a campaign.
const ID_CONFIRM: int = 60
const ID_YES: int = 61
const ID_NO: int = 62
## The remake's own action name for the *No* half; the two shipped words are
## the captions and the original action is what the host sees on *Yes*.
const CANCEL: String = "cancel"

## The remake's own keys these screens use. The original reached its options
## through icons with hover hints and never named the screen, so there is no
## shipped caption to read; [method Localization.text] is the seam docs/92
## section 7.6 provides for exactly that, and it is not a literal.
const OWN_OPTIONS: String = "shell.options"

## The layer the screens draw on. Above the HUD, so a screen covers the mission
## view rather than sharing it.
const SCREEN_LAYER: int = 8

## The plates' own size. Every one of the twelve is 640x480, and the shipped
## layout tables in `DATA/GUI/*.lcl` are written in that space.
const PLATE_SIZE: Vector2 = Vector2(640.0, 480.0)

## What [method plate_name] answers for a screen that wants **no** plate at
## all -- the deployment screen, which is the mission's own view with a
## caption over it. It is not the same as a plate the cache does not carry:
## that one degrades to the base class's [ColorRect], and this one deliberately
## draws nothing so the world behind stays visible.
const PLATE_NONE: String = ""

## The 3D window the original opens inside a campaign plate, **read out of the
## executable**: `(65, 57)`, 518 x 306. `aMissionControl.cpp` sets it with
## `0x0040B670` on the way into the campaign screens (`0x00454102`) and again
## on every frame the map is up (`0x004559FA`), with the centre `0x0040B6B0`
## takes at half of it. docs/27 section 2.3 read the same numbers as the
## sequence screen's; they are the campaign screens' generally, and the dark
## interior of `plate_3` is exactly that rectangle.
##
## It used to be `(34, 36, 570, 356)` -- the whole interior of `plate_1`'s
## frame, measured off the bitmap -- which is a **different plate** and put
## world over the inner bevel the original leaves painted.
##
## A screen that answers this from [method plate_window] gets the plate drawn
## as **four strips around the rectangle** instead of one full-screen picture,
## so what is behind the [CanvasLayer] -- the 3D view -- shows through it. The
## shipped plates are opaque 8-bit bitmaps with no alpha, so a hole cannot be
## painted; it has to be left.
const PLATE_WINDOW: Rect2 = Rect2(65.0, 57.0, 518.0, 306.0)

## The plate Mission Control loads **once**, at `aInitGUI` `0x00454245`, and
## which every window after it inherits: `Menu_b.lcl`'s HQ, Unit Menu, Item
## List, Briefing, Recruit and the campaign map all reach `aBuildGUI` with no
## plate load of their own (the writes to the window selector `0x00510A38` at
## `0x004578D0`, `0x0045A187`, `0x0045C13D`, `0x00456D03` and `0x0045664D`
## carry none). It is the one shipped plate with a picture frame inset, which
## is why those screens show the 3D behind them.
const PLATE_MISSION_CONTROL: String = "plate_3"
## The one window that loads a plate of its own -- `0x0045BFBB`, immediately
## before `[0x510A38] = 2`. Its panels are painted: the portrait, the model
## window, the column of five skill boxes and the item window.
const PLATE_UPGRADE: String = "plate_6"

## `GUI_SetButton`'s `Width` column. Every button in the three windows of
## docs/27 section 5 is written `6_Width`.
const GUI_BUTTON_WIDTH: int = 6
## `GUI_SetButton`'s own height, which is `buttons.LIB` element 0's.
const GUI_BUTTON_HEIGHT: float = 31.0
## How far a listbox row's caption sits inside its left cap.
const LIST_ROW_INSET: float = 8.0
## `GUI_SetListbox`'s own row: `Menu_a.lcl` steps its ten by exactly this.
const LIST_ROW_HEIGHT: float = 22.0

## The `fntID` column of `Menu_b.lcl`, which is what decides how wide a line
## comes out: `font_0` is 5.5 units to a capital, `font_1` 6.3 and `font_2`
## 10.2. The campaign screens use three of the four.
const FNT_LABEL: int = 0
const FNT_VALUE: int = 1
const FNT_TITLE: int = 2

## `GUI_SetText`'s `cX` column: where *x* is on the line. Read off the shipped
## pairs -- a caption is written `2_cX` at 220 and its value `0_cX` at 225, so
## 2 ends at *x* and 0 starts there; the titles are `1_cX` at 320, the centre.
const ALIGN_LEFT: int = 0
const ALIGN_CENTRE: int = 1
const ALIGN_RIGHT: int = 2
## How wide a [Label] is given to align inside. Nothing on these screens is
## anywhere near this long; it exists so right- and centre-alignment have a box
## to work in.
const TEXT_BOX_WIDTH: float = 320.0
const TEXT_LINE_HEIGHT: float = 18.0

## The ink these screens write in.
##
## `GUI_SetText`'s `cA`/`cB`/`cC` columns select the GUI's own font ramp and
## are **not** palette indices -- entries 2, 3 and 8 of every shipped plate are
## dark greys, and the captions are not. What the ramp resolves to is
## **UNVERIFIED**; these are read off the shipped screens, and are named for
## the role rather than for the column so that a later measurement replaces
## them in one place.
const INK_TITLE: Color = Color(0.86, 0.86, 0.82)
const INK_LABEL: Color = Color(0.72, 0.72, 0.68)
const INK_VALUE: Color = Color(1.0, 1.0, 1.0)
## The roster's own colour, and the catalogue's.
const INK_ROSTER: Color = Color(0.35, 0.95, 0.35)
const INK_ITEM: Color = Color(0.85, 0.18, 0.18)
## Anything the soldier cannot be given now, and the row that is already theirs.
const INK_DISABLED: Color = Color(0.45, 0.45, 0.45)

## **The remake's own reading aids, and marked as such.** The original paints
## these lists straight onto the 3D and gets away with it because what stands
## behind them is a still, dark general view of the base -- the resting point
## of `upgrade_N.lcl`'s own camera path. The remake draws the same scene, but
## a screenshot is not a guarantee: a bright building or a lit ramp behind a
## row makes the row unreadable, and the original has no answer for that
## because it never happens there. So a screen that writes across the window
## backs its text with [method shade], and a row the pointer is over or the
## screen has chosen lights under [method row_hit]. Neither is in the shipped
## game; both are what docs/92 section 7.4 calls keeping the rule and dropping
## the silence.
const SHADE_BACKING: Color = Color(0.0, 0.0, 0.02, 0.55)
const ROW_HOVER: Color = Color(0.85, 0.86, 0.80, 0.24)
const ROW_CHOSEN: Color = Color(0.85, 0.86, 0.80, 0.14)
const ROW_CLEAR: Color = Color(0.0, 0.0, 0.0, 0.0)

## The cartouche across the top of `plate_1`, between the two gargoyles: the
## band the original writes every framed screen's own name in.
const TITLE_TOP: float = 6.0
const TITLE_HEIGHT: float = 24.0

## Where the action row sits on the plate, in the plate's own units. Inside
## the frame, which is about 40 units deep on `plate_1`.
const BUTTON_ROW_MARGIN: float = 46.0
const BUTTON_ROW_TOP: float = 424.0
const BUTTON_ROW_HEIGHT: float = 30.0
const BUTTON_ROW_GAP: float = 6.0
## The action row's caption size when the readable face is in use, in the
## plate's units. The widest shipped caption is *Enter Location*.

## Emitted when a button is pressed; the host decides what it means.
signal chose(action: String)

var art: Art = null
var strings: Localization = null
var font: FontFile = null
## The four shipped faces, indexed by `Menu_b.lcl`'s `fntID` column.
##
## **The layout depends on which one a line is drawn in.** `font_0` is 5.5
## units to a capital and `font_2` is 10.2, and the campaign screens write
## `0_fntID` for their captions and `2_fntID` only for the title -- so a screen
## that drew everything in one face has captions nearly twice the width the
## plate leaves them, and the Item List's two bottom lines walk off the frame.
## Empty when the caller supplies none, and then everything falls back to
## [member font].
var faces: Array[FontFile] = []
## What the plates click with. Null in the suites, where nothing sounds.
var audio: AudioSystem = null
## The action a second press will let through, or `""`.
##
## Two buttons in this shell drop something that may never have been saved --
## the map's *End game* and the pause menu's *Main Menu* -- and docs/92
## section 7.4 counts a click that cannot be undone and says nothing as a
## defect. Both ask once: the first press records the action and rebuilds the
## buttons through [method _show_actions], the second lets it through.
var pending: String = ""

var _root: Control = null
var _body: Control = null
var _buttons: Control = null


func setup(screen_art: Art, text: Localization, screen_font: FontFile,
		screen_faces: Array[FontFile] = [],
		screen_audio: AudioSystem = null) -> void:
	art = screen_art
	strings = text
	font = screen_font
	faces = screen_faces
	audio = screen_audio
	layer = SCREEN_LAYER
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# **Neither the root nor the body eats a click.** A [Control] stops mouse
	# events by default, and a screen with a window in its plate needs the
	# clicks that land in the window to reach the 3D pick behind it. The
	# buttons keep their own [constant Control.MOUSE_FILTER_STOP], so what
	# passes through is exactly what nothing on the plate wanted.
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_draw_plate()

	_body = Control.new()
	_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.offset_left = 48.0
	_body.offset_top = 40.0
	_body.offset_right = -48.0
	_body.offset_bottom = -72.0
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_body)

	# A plain [Control] and not a container. See [method _lay_out_buttons].
	_buttons = Control.new()
	_buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	_buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_buttons)
	build()
	_lay_out_buttons()


## Subclasses fill [member _body] and add their buttons here.
func build() -> void:
	pass


# --- the wheel and the trackpad -----------------------------------------------

## How far one trackpad pan moves a list, in rows per unit of `delta.y`.
##
## Pan deltas arrive in "lines" and a flick sends many, so a notch of the wheel
## is one row and a pan is metered: a slow drag of about a row's height comes
## to about a row.
const PAN_ROWS: float = 0.5

## What is left of a pan too small to have moved a row yet. A trackpad sends
## many small deltas and dropping each one made a slow drag do nothing at all.
var _scroll_carry: float = 0.0


## How many list rows one input turns -- positive **downwards**, towards the
## end of the list -- or zero when it is not a scroll input.
##
## The sibling of [method SliceMain.zoom_delta_for], written the same way and
## for the same reason: pure and static so it can be checked without a scene
## tree, and covering the event classes the platform actually sends. A wheel
## mouse sends `WHEEL_UP`/`WHEEL_DOWN`; a macOS trackpad and a Magic Mouse send
## a pan gesture instead, and a list that answered only the first looked
## unscrollable on exactly the hardware this is developed on.
##
## **The pan's sign is taken from the measurement already in the tree**, not
## reasoned about again: [method SliceMain.zoom_delta_for] records that two
## fingers pushed away from the body zoom *in*, and it computes that from
## `-delta.y`, so a push away is a **positive** `delta.y` on this hardware.
## Under macOS's natural scrolling a push away shows later rows, so `delta.y`
## is taken as it comes. The same routine's comment records that the derived
## sign was wrong the first time; this one is derived from its measurement
## rather than from the platform's documentation, which is the nearest thing
## to measuring it without a second pair of hands on the trackpad.
static func scroll_rows_for(event: InputEvent) -> float:
	if event is InputEventMouseButton:
		var click: InputEventMouseButton = event
		if not click.pressed:
			return 0.0
		if click.button_index == MOUSE_BUTTON_WHEEL_UP:
			return -1.0
		if click.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return 1.0
		return 0.0
	if event is InputEventPanGesture:
		var pan: InputEventPanGesture = event
		return pan.delta.y * PAN_ROWS
	return 0.0


## Whether this screen carries a list the wheel turns.
##
## **The default is no, and that is what keeps the camera's zoom.** The map and
## the deployment screen are drawn around a hole and the wheel there is
## [method SliceMain.zoom_delta_for]'s; a screen that took the event because it
## happened to have rows on it would have made the map unzoomable.
func scrolls() -> bool:
	return false


## Turn one scroll input into whole rows and move the list by them.
##
## Answers whether the event was this screen's to take. A pan too small to have
## moved a row yet is still taken -- letting it through would zoom the camera
## behind the plate a fraction of a step at a time.
func take_scroll(event: InputEvent) -> bool:
	if not scrolls():
		return false
	var rows: float = scroll_rows_for(event)
	if is_zero_approx(rows):
		return false
	_scroll_carry += rows
	# Truncation toward zero, which is what a carry wants on both signs.
	var whole: int = int(_scroll_carry)
	_scroll_carry -= float(whole)
	if whole != 0:
		step_rows(whole)
	return true


## Move the list by *rows*, positive towards its end. Overridden by the screens
## that have one; **one row at a time**, where the shipped listbox's two arrows
## turn a whole page -- a wheel notch that jumped a page would be a different
## control.
func step_rows(_rows: int) -> void:
	pass


## Whether a click inside [method plate_window] means something to this screen.
##
## The two screens drawn around a hole answer yes, and [SliceMain] then turns
## the click into a map field and hands it here. Everything else answers no
## and keeps the old rule: a plate up means the world behind it takes no
## input at all.
func takes_world_clicks() -> bool:
	return false


## A map field the player clicked in the window, `(-1, -1)` for a click that
## landed on no cell.
func world_click(_cell: Vector2i) -> void:
	pass


## The map field the pointer is over, for a screen that names what is under
## it. `(-1, -1)` when the pointer is on no cell.
func world_hover(_cell: Vector2i) -> void:
	pass


## The plate this screen sits on. Overridden where a screen has one of its own
## -- the shell's menu sits on `Title` -- and answered as a **name** rather
## than a texture so a cache that does not carry it degrades to the base
## class's [ColorRect] instead of failing to open.
func plate_name() -> String:
	return PLATE


## The rectangle the plate must leave clear, in the plate's own units, or an
## empty [Rect2] for a plate drawn whole.
##
## The two screens that answer it -- the location map and the deployment view
## -- are pictures of the world with a frame around them, and the world is a
## 3D scene in the root viewport rather than anything this [CanvasLayer] can
## hold. So the frame is drawn around a hole and the scene shows through.
func plate_window() -> Rect2:
	return Rect2()


## Draw the plate: whole, as a frame around [method plate_window], or not at
## all when [method plate_name] answers [constant PLATE_NONE].
func _draw_plate() -> void:
	var name: String = plate_name()
	if name == PLATE_NONE:
		return
	var picture: Texture2D = art.plate(name) if art != null else null
	if picture == null:
		# A cache with no art still shows a legible screen: the frame is what
		# is missing, not the campaign. A screen that asked for a window keeps
		# it, because painting the hole over would hide the very thing the
		# window exists to show -- so the backing is **built inside that
		# test**. Building it first and parenting it only in one arm left an
		# unowned `ColorRect` behind on every windowed screen, which Godot
		# reports at exit as a leaked `CanvasItem` RID and two leaked objects
		# (the node and its theme owner).
		if plate_window().size != Vector2.ZERO:
			return
		var solid: ColorRect = ColorRect.new()
		solid.color = Color(0.05, 0.05, 0.06)
		solid.mouse_filter = Control.MOUSE_FILTER_IGNORE
		solid.set_anchors_preset(Control.PRESET_FULL_RECT)
		_root.add_child(solid)
		return
	var window: Rect2 = plate_window()
	if window.size == Vector2.ZERO:
		_root.add_child(_plate_piece(picture,
			Rect2(Vector2.ZERO, PLATE_SIZE)))
		return
	# Four strips, each one the plate's own pixels put back where they came
	# from: top, bottom, left and right of the window.
	var right: float = window.position.x + window.size.x
	var below: float = window.position.y + window.size.y
	for piece: Rect2 in [
			Rect2(0.0, 0.0, PLATE_SIZE.x, window.position.y),
			Rect2(0.0, below, PLATE_SIZE.x, PLATE_SIZE.y - below),
			Rect2(0.0, window.position.y, window.position.x, window.size.y),
			Rect2(right, window.position.y, PLATE_SIZE.x - right,
				window.size.y)]:
		if piece.size.x <= 0.0 or piece.size.y <= 0.0:
			continue
		_root.add_child(_plate_piece(picture, piece))


## One rectangle of the plate, drawn where it belongs.
func _plate_piece(picture: Texture2D, piece: Rect2) -> TextureRect:
	var view: TextureRect = TextureRect.new()
	var slice: AtlasTexture = AtlasTexture.new()
	slice.atlas = picture
	# The plate is 640x480 and so is the layout space, so a rectangle in the
	# one is the same rectangle in the other.
	slice.region = piece
	view.texture = slice
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_SCALE
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(view, piece.position, piece.size)
	return view


## The screen's own name, centred in the plate's top band.
##
## Every framed screen in the original writes it there and nowhere else, which
## is why it is here rather than in each screen's [method build].
func place_title(text: String) -> Label:
	var title: Label = make_label(text, 0, FNT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(title, Vector2(0.0, TITLE_TOP),
		Vector2(PLATE_SIZE.x, TITLE_HEIGHT))
	_root.add_child(title)
	return title


## What a screen shows on top of the plate.
func body() -> Control:
	return _body


## One shipped string. A bank or id the catalogue has no line for renders as
## its marker, which is a great deal easier to diagnose than a blank.
##
## A screen set up with **no** catalogue at all takes the same marker, prefix
## and all. It used to return a bare `module/id`, which reads as a caption and
## slipped straight through the suites' gate on
## [constant Localization.MISSING_PREFIX] -- so the one case where every
## caption is missing was the one the gate could not see.
func label_for(module: String, id: int) -> String:
	if strings == null:
		return "%s%s/%d" % [Localization.MISSING_PREFIX, module, id]
	return strings.shipped(module, id)


## One of the remake's own strings, by key -- the other half of the seam.
##
## Used only where the original has no caption to read, and it takes the same
## missing marker as [method label_for] when there is no catalogue, so the
## suites' one gate covers both halves.
func strings_own(key: String) -> String:
	if strings == null:
		return Localization.MISSING_PREFIX + key
	return strings.text(key)


## One of the four shipped faces by `fntID`, or [member font] when the caller
## supplied none.
func face(fnt: int) -> FontFile:
	if fnt >= 0 and fnt < faces.size() and faces[fnt] != null:
		return faces[fnt]
	return font


## The readable face's size, per `fntID`.
##
## **The shipped coordinates are the shipped font's.** `Menu_b.lcl` writes a
## caption at `464` and its value at `469`, five units apart, with the next
## column starting at `557` -- spacings that only work while a capital is the
## six-odd units `font_0` draws one in. `project.godot` stretches a 640x480
## canvas, so a font size *is* in those units, and Godot's default 16 measured
## 9.2 units to `font_0`'s 6.4: every readout on the Upgrade Menu ran into the
## one beside it and the Item List walked off its own plate.
##
## **The size is each face's own cap height, not one number.** A capital is 7
## units in `font_0`, 8 in `font_1` and 14 in `font_2`, and the vector face
## draws one at about 0.71 of its size -- so 10 and 11 are what stand the same
## height as the shipped faces they replace. Eleven for everything, which is
## what stood here, drew the body an eighth too large and read as visibly
## bigger than the original beside it. Face 2 stays at 16 rather than the 20
## its cap height asks for: a plate's heading strip is the height the shipped
## art gives it, and only the window titles use that face.
const READABLE_SIZE: Array[int] = [10, 11, 16, 10]


## A label in the game's own bitmap font, or in the readable one at the size
## the plate's own coordinates leave for it.
## **`fntID` 0 by default.** Of `Menu_*.lcl`'s 121 `GUI_SetText` calls 68 name
## font 0 and 28 name font 2, and those 28 are the window titles -- which go
## through [method place_title] and ask for [constant FNT_TITLE] by name. A
## screen that took the title face for everything drew its captions at roughly
## twice the size the original gives them.
func make_label(text: String, size: int = 0, fnt: int = FNT_LABEL) -> Label:
	var out: Label = Label.new()
	out.text = text
	var chosen: FontFile = face(fnt)
	if chosen != null:
		out.add_theme_font_override("font", chosen)
		if size > 0:
			out.add_theme_font_size_override("font_size", size)
		return out
	out.add_theme_font_size_override("font_size",
		size if size > 0 else readable_size(fnt))
	return out


## One `fntID`'s readable size.
static func readable_size(fnt: int) -> int:
	if fnt >= 0 and fnt < READABLE_SIZE.size():
		return READABLE_SIZE[fnt]
	return READABLE_SIZE[FNT_LABEL]


## A button captioned from the shipped banks and drawn on a `buttons.LIB`
## sprite where the cache has one.
func add_button(action: String, module: String, id: int,
		sprite_index: int = -1) -> Button:
	var button: Button = Button.new()
	button.text = label_for(module, id)
	# **`fntID` 0, like every shipped button.** `Menu_a/b/c.lcl` carry 89
	# `GUI_SetButton` calls and not one of them names font 2 -- 81 use 0 and 8
	# use 1 -- so a caption drawn in the title face was roughly twice the size
	# the original gives it, and filled the whole plate of a button.
	var chosen: FontFile = face(FNT_LABEL)
	if chosen != null:
		button.add_theme_font_override("font", chosen)
	else:
		# The row divides the plate five ways at most, so a caption is drawn
		# to fit its share rather than being cut: *Enter Location* at the
		# default size came out as *Enter Locati*.
		button.add_theme_font_size_override("font_size",
			readable_size(FNT_LABEL))
	button.add_theme_color_override("font_color", INK_TITLE)
	# **No icon.** The row is dressed in the composed face by
	# [method _lay_out_buttons], and an icon beside the caption is a widget the
	# original does not have; the argument is kept because the call sites name
	# a sprite and one day a screen may want a different `Library` column.
	if sprite_index >= 0 and art == null:
		pass
	# A caption or an icon wider than the button's share is cut, rather than
	# pushing its neighbours off the plate.
	button.clip_text = true
	button.pressed.connect(_on_pressed.bind(action))
	arm_sounds(button)
	_buttons.add_child(button)
	return button


## A button for the screen's **body** rather than for the action row at the
## bottom.
##
## The shell's screens are lists -- a menu of five, a page of save slots, a
## catalogue of missions -- and a list is not what [member _buttons] is: that
## one is a centred row of at most a handful. The caption is passed in already
## resolved, because a list row is usually a shipped string with a number or a
## name beside it.
func make_button(action: String, text: String) -> Button:
	var button: Button = Button.new()
	button.text = text
	var chosen: FontFile = face(FNT_LABEL)
	if chosen != null:
		button.add_theme_font_override("font", chosen)
	else:
		button.add_theme_font_size_override("font_size",
			readable_size(FNT_LABEL))
	button.pressed.connect(_on_pressed.bind(action))
	arm_sounds(button)
	button.resized.connect(_dress_when_sized.bind(button))
	return button


## Put the shipped face on a button the moment something decides how wide it
## is -- a container, a list's own placement, or the action row.
##
## **Not once -- once per width.** The meta holds the piece count the face was
## composed at, and a resize that would compose a different one dresses again.
##
## A latch on the *first* call was a real defect, and only on a screen that
## rebuilds itself: [method MainMenuScreen._show_actions] adds its buttons and
## places them afterwards, which off the tree is one layout pass with the
## anchors already set and **on** the tree is two -- the first at the caption's
## own minimum width. *No* measures some 25 plate units, which is narrower than
## the two caps, so the face composed for it was `27 + 18` with no fill at all;
## the nine-slice then smeared that zero-width middle across the button's real
## 190 units, and the confirmation dialogue's two answers were a pair of caps
## with a stripe between them. Nothing re-dressed, because the latch had
## already been set at the wrong size.
##
## Re-dressing cannot oscillate: [method _face_box]'s content margins are the
## two caps whatever the piece count is, so a wider face does not make the
## button's minimum wider. A `flat` button opts out: the grids' click targets
## are text rows in the original too, not gadgets.
const DRESSED: StringName = &"dressed"


func _dress_when_sized(button: Button) -> void:
	if button.flat or art == null or _root == null or _root.size.x <= 0.0:
		return
	# The button's rectangle is in the canvas's units and the face is measured
	# in the plate's, which is what the root spans.
	var pieces: int = face_pieces(button.size.x * PLATE_SIZE.x / _root.size.x)
	if pieces < 0 or DictRead.as_int(button.get_meta(DRESSED, -1)) == pieces:
		return
	button.set_meta(DRESSED, pieces)
	var _face: float = _face_onto(button, pieces)


## A translucent backing over *area*, so text drawn across the 3D window can
## be read whatever stands behind it. See [constant SHADE_BACKING].
func shade(area: Rect2, into: Control = null) -> ColorRect:
	var backing: ColorRect = ColorRect.new()
	backing.color = SHADE_BACKING
	backing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(backing, area.position, area.size)
	var parent: Control = into if into != null else root()
	parent.add_child(backing)
	return backing


## One list row's click target: a flat button over a rectangle that lights
## under the pointer and, when *chosen*, stays lit.
##
## The rows are text in the original too, not gadgets -- which is why the
## button is `flat` and takes no composed face. What it gains here is the
## feedback a painted row cannot have.
##
## **The light is a rectangle of its own, not the button's `normal` box.** A
## `flat` button does not draw that box, which is exactly what `flat` means, so
## a chosen row dressed through the theme showed nothing at all; and driving
## the colour from the two pointer signals keeps the hover independent of what
## `flat` does to the rest of the states.
func row_hit(action: String, area: Rect2, into: Control,
		chosen: bool = false) -> Button:
	var resting: Color = ROW_CHOSEN if chosen else ROW_CLEAR
	var lit: ColorRect = ColorRect.new()
	lit.color = resting
	lit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(lit, area.position, area.size)
	into.add_child(lit)
	var button: Button = make_button(action, "")
	button.flat = true
	place_on_plate(button, area.position, area.size)
	into.add_child(button)
	button.mouse_entered.connect(func() -> void:
		if is_instance_valid(lit):
			lit.color = ROW_HOVER)
	button.mouse_exited.connect(func() -> void:
		if is_instance_valid(lit):
			lit.color = resting)
	return button


## A row button that is going into the action row rather than into a list, so
## it takes the row's caption size and its clipping.
func make_action_button(action: String, text: String) -> Button:
	var button: Button = make_button(action, text)
	button.clip_text = true
	return button


## Whether *action* is one the screen asks about before doing.
func needs_confirming(_action: String) -> bool:
	return false


## Rebuild whatever carries this screen's buttons. Called by [method build]
## and again on each side of a confirmation. A screen with a fixed row does
## not need it.
func _show_actions() -> void:
	pass


func _on_pressed(action: String) -> void:
	if action == CANCEL:
		pending = ""
		_show_actions()
		refresh()
		return
	if needs_confirming(action) and pending != action:
		pending = action
		_show_actions()
		refresh()
		return
	pending = ""
	chose.emit(action)


## Redraw what the screen shows. The base does nothing; the screens that have
## something to redraw override it, and the confirmation calls it so the
## question can be written where the screen writes its own lines.
func refresh() -> void:
	pass


## Put a control where the plate's own layout space says, rather than where
## the pixel count would.
##
## The plate is stretched to the whole viewport, so a coordinate read out of a
## shipped layout table is a **fraction** of 640x480 and not a pixel count:
## the viewport is whatever window the player opened, and twice that again on
## a display with a 2x backing scale -- measured here at 2560x1600 for a
## window asked for as 1280x800. Anchors carry the fraction, so nothing has to
## know the size and nothing has to wait for a layout pass to learn it.
##
## A zero *size* keeps the control's own, which is what a label wants.
func place_on_plate(control: Control, at: Vector2,
		size: Vector2 = Vector2.ZERO) -> void:
	control.anchor_left = at.x / PLATE_SIZE.x
	control.anchor_top = at.y / PLATE_SIZE.y
	control.anchor_right = (at.x + size.x) / PLATE_SIZE.x
	control.anchor_bottom = (at.y + size.y) / PLATE_SIZE.y
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0


## The full-screen [Control] a screen's own layout hangs off -- the one the
## plate covers, so [method place_on_plate]'s fractions are of the plate.
func root() -> Control:
	return _root


## The action row itself, for a screen adding a button whose caption is not a
## shipped one and so cannot go through [method add_button].
func _buttons_row() -> Control:
	return _buttons


## Spread the action buttons along the bottom of the plate, in its own units.
##
## **Measured, not left to a container.** An [HBoxContainer] sizes its children
## from their minimum, and a `buttons.LIB` face plus a caption like *Enter
## Location* makes that ~144 of the plate's 640 units -- so a row of five ran
## 116 units past the right edge of its own frame, and `clip_text` does not
## help because the icon is in the minimum too. Five buttons is what the
## briefing has, so the row divides what there is by however many there are
## and each one gets an explicit rectangle.
func _lay_out_buttons() -> void:
	var row: Array[Button] = []
	for child: Node in _buttons.get_children():
		var button: Button = child as Button
		if button != null:
			row.append(button)
	if row.is_empty():
		return
	var span: float = PLATE_SIZE.x - 2.0 * BUTTON_ROW_MARGIN
	var width: float = (span - BUTTON_ROW_GAP * float(row.size() - 1)) \
		/ float(row.size())
	for index: int in range(row.size()):
		var share: float = BUTTON_ROW_MARGIN \
			+ float(index) * (width + BUTTON_ROW_GAP)
		# The composed face is a whole number of pieces wide, so it is narrower
		# than the share; it is centred in what the share leaves. And it never
		# grows past the shipped `6_Width`: a row of one used to hand its only
		# button the whole plate, and no `GUI_SetButton` in the shipped data is
		# wider than six pieces.
		var face: float = dress_button(row[index],
			minf(width, float(shipped_face_width())))
		var at: Vector2 = Vector2(share + (width - face) * 0.5,
			BUTTON_ROW_TOP)
		place_on_plate(row[index], at,
			Vector2(face, float(face_height(Art.BUTTON_BASE_ACTION))))


## A button where `GUI_SetButton` puts one: the plate's own coordinates, the
## `buttons.LIB` face composed at the width the layout asks for, and the
## caption from the shipped bank.
##
## Unlike [method add_button] this does **not** join the centred action row --
## the three windows of docs/27 section 5 place every button by hand, at pairs
## like `(410, 418)` and `(60, 384)`, and a row that spread them evenly would
## be a different screen.
func gui_button(action: String, module: String, id: int, at: Vector2,
		width: int = GUI_BUTTON_WIDTH) -> Button:
	return gui_text_button(action, label_for(module, id), at, width)



## The same, captioned with a string the screen has already resolved.
func gui_text_button(action: String, text: String, at: Vector2,
		width: int = GUI_BUTTON_WIDTH, into: Control = null,
		base: int = Art.BUTTON_BASE_ACTION) -> Button:
	var button: Button = Button.new()
	button.text = text
	button.clip_text = true
	var chosen: FontFile = face(FNT_LABEL)
	if chosen != null:
		button.add_theme_font_override("font", chosen)
	else:
		button.add_theme_font_size_override("font_size",
			readable_size(FNT_LABEL))
	button.add_theme_color_override("font_color", INK_TITLE)
	var span: float = _face_onto(button, width, base)
	button.pressed.connect(_on_pressed.bind(action))
	arm_sounds(button)
	place_on_plate(button, at, Vector2(span, float(face_height(base))))
	# **`into` matters for a button a redraw replaces.** The Upgrade Menu's
	# shared `(405, 384)` is rebuilt on every refresh, and parented to the root
	# it piled a second *Buy Item* on top of the first every time -- with the
	# stale one still taking the click.
	var parent: Control = into if into != null else root()
	parent.add_child(button)
	return button


## The two sounds `aInitGUI` `0x0043BF30` loads, and what plays them.
##
## `click_1.wav` is the **pointer's**: `0x0043C500` calls the hit-test, and when
## the gadget under the cursor has *changed* it plays that buffer panned by the
## cursor's x (`320 - pointer_x`). `click_2.wav` is what a gadget's own handler
## asks for -- `aPlayGUIClickSound(1)` at `0x0043E5E0`, from four screens'
## button arms. `aPlayGUIClickSound(0)` plays the first one again.
const SOUND_HOVER: String = "click_1.wav"
const SOUND_CLICK: String = "click_2.wav"


## Give *button* the pointer's sound and the press's.
##
## Every button goes through here, the flat list rows included: the original's
## hover sound is fired by the gadget system for **any** gadget the pointer
## crosses, not only the ones with a face.
func arm_sounds(button: Button) -> void:
	button.mouse_entered.connect(_play_gui_sound.bind(SOUND_HOVER))
	button.button_down.connect(_play_gui_sound.bind(SOUND_CLICK))


func _play_gui_sound(wave: String) -> void:
	if audio == null:
		return
	# `NO_SCALING` because the engine hands `aDirectSoundPlay` its own volume
	# rather than a table id -- there is no `SetVolume` entry for these two.
	var _slot: int = audio.play_cue({
		"wave": wave, "volume_id": AudioTables.NO_SCALING})


## One row of a listbox, where `GUI_SetListbox` puts one.
##
## `Menu_a.lcl`'s *Leveloptions* is ten of these at `(60, 120 + 22i)` with
## `8_Width`, so a row is `32 + 6*32 + 32` = 256 by 22 and its caption is
## **left-aligned inside it** -- a list is a list, not a row of buttons.
func gui_list_row(action: String, text: String, at: Vector2, width: int,
		index: int, count: int, into: Control = null) -> Button:
	var base: int = Art.BUTTON_BASE_LIST_MIDDLE
	if index == 0:
		base = Art.BUTTON_BASE_LIST_FIRST
	elif index == count - 1:
		base = Art.BUTTON_BASE_LIST_LAST
	var row: Button = gui_text_button(action, text, at, width, into, base)
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.add_theme_color_override("font_color", INK_ROSTER)
	row.add_theme_color_override("font_hover_color", INK_VALUE)
	# The caption clears the row's own left cap rather than starting on it.
	for state: String in ["normal", "hover", "pressed", "disabled"]:
		var face: StyleBoxTexture = row.get_theme_stylebox(state) \
			as StyleBoxTexture
		if face != null:
			face.content_margin_left = LIST_ROW_INSET
	return row


## Dress *button* in the widest composed face that fits *span* plate units, and
## answer the face's own width so the caller can place it.
##
## `Width` counts pieces and not units, so a row that divides the plate into
## five does not land on a whole number of them; the face that fits is the one
## used, and the button is then placed at exactly that width rather than
## stretched to the share.
func dress_button(button: Button, span: float,
		base: int = Art.BUTTON_BASE_ACTION) -> float:
	var pieces: int = face_pieces(span, base)
	if pieces < 0:
		return span
	return _face_onto(button, pieces, base)


## How many pieces the widest face that fits *span* plate units is made of, or
## -1 when the cache carries no such library.
##
## Its own function because [method _dress_when_sized] has to ask the question
## without answering it: dressing again at the width it is already wearing
## would compose the same picture on every layout pass.
func face_pieces(span: float, base: int = Art.BUTTON_BASE_ACTION) -> int:
	if art == null:
		return -1
	var left: Texture2D = art.sprite(Art.BUTTON_LIBRARY,
		base + Art.BUTTON_LEFT)
	var right: Texture2D = art.sprite(Art.BUTTON_LIBRARY,
		base + Art.BUTTON_RIGHT)
	var fill: Texture2D = art.sprite(Art.BUTTON_LIBRARY,
		base + Art.BUTTON_MIDDLE)
	if left == null or right == null or fill == null or fill.get_width() <= 0:
		return -1
	var caps: float = left.get_size().x + right.get_size().x
	var fills: int = floori((span - caps) / float(fill.get_width()))
	return maxi(fills, 0) + 2


## Dress *button* in the composed `buttons.LIB` face and answer how wide it is.
##
## A cache with no art leaves the default theme's box, which is legible and
## says plainly that the pictures are missing.
func _face_onto(button: Button, width: int,
		base: int = Art.BUTTON_BASE_ACTION) -> float:
	var span: float = float(27 + maxi(width - 2, 0) * 31 + 18)
	if art == null:
		return span
	var normal: Texture2D = art.button_face(base, width, false)
	var lit: Texture2D = art.button_face(base, width, true)
	if normal == null:
		return span
	span = float(normal.get_width())
	# **The lit trio is the pointer's, not the mouse button's** (`0x0043a8b0`),
	# so it dresses `hover` and `focus`; `pressed` takes it too, because a click
	# is a hover the engine never had to draw differently.
	button.add_theme_stylebox_override("normal", _face_box(normal, base))
	for state: String in ["hover", "pressed"]:
		button.add_theme_stylebox_override(state,
			_face_box(lit if lit != null else normal, base))
	button.add_theme_stylebox_override("disabled", _face_box(normal, base))
	# **`focus` is drawn on top of whichever of the others is showing**, so it
	# has to be nothing at all: dressed in the lit face it left a button lit
	# for as long as it kept the keyboard focus, which is not what the pointer
	# said.
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return span


## How wide `GUI_SetButton`'s own `6_Width` comes out, in plate units.
func shipped_face_width() -> int:
	var face: Texture2D = art.button_face(Art.BUTTON_BASE_ACTION,
		GUI_BUTTON_WIDTH, false) if art != null else null
	return int(face.get_size().x) if face != null else 169


## How tall a composed face of this library is, in plate units.
func face_height(base: int) -> int:
	if art == null:
		return int(GUI_BUTTON_HEIGHT)
	var piece: Texture2D = art.sprite(Art.BUTTON_LIBRARY, base)
	return int(piece.get_size().y) if piece != null else int(GUI_BUTTON_HEIGHT)


## The composed face as a **nine-slice**: the two caps are pinned to their own
## widths and the fill between them is tiled, so a button whose rectangle is
## not a whole number of pieces still has round caps and an unstretched fill.
## That is what the engine does by construction -- it lays whole pieces -- and
## it is the only way to get the same picture out of a rectangle a container
## chose.
func _face_box(texture: Texture2D, base: int = -1) -> StyleBoxTexture:
	var box: StyleBoxTexture = StyleBoxTexture.new()
	box.texture = texture
	if base < 0 or art == null:
		return box
	var left: Texture2D = art.sprite(Art.BUTTON_LIBRARY,
		base + Art.BUTTON_LEFT)
	var right: Texture2D = art.sprite(Art.BUTTON_LIBRARY,
		base + Art.BUTTON_RIGHT)
	if left == null or right == null:
		return box
	box.texture_margin_left = left.get_size().x
	box.texture_margin_right = right.get_size().x
	box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	return box


## One `buttons.LIB` element as a button -- the arrows, the *i* and the roster's
## red cross.
##
## `GUI_SetIcon` is gadget type 4, and `aPrintGadget` `0x0043a223` draws
## `base + 1` while the pointer is over it and `base` otherwise -- 44/45,
## 48/49, 50/51, 52/53 are those pairs -- so one index names both.
func gui_icon(action: String, index: int, at: Vector2,
		into: Control = null) -> Button:
	var button: Button = Button.new()
	# **Not `flat`.** A flat `Button` draws no style box at all, so the lit
	# twin would never appear -- the picture is the box here, because only a
	# box can differ between the pointer being over it and not.
	var size: Vector2 = icon_faces(button, index)
	button.pressed.connect(_on_pressed.bind(action))
	arm_sounds(button)
	place_on_plate(button, at, size)
	var parent: Control = into if into != null else root()
	parent.add_child(button)
	return button


## Dress *button* in one `buttons.LIB` element and its lit twin, and answer how
## big the element is. A style box rather than [member Button.icon] because
## only the box can differ per state.
func icon_faces(button: Button, index: int) -> Vector2:
	var picture: Texture2D = art.sprite(Art.BUTTON_LIBRARY, index) \
		if art != null else null
	if picture == null:
		return Vector2(16.0, 16.0)
	var lit: Texture2D = art.sprite(Art.BUTTON_LIBRARY,
		index + Art.ICON_LIT_OFFSET)
	button.add_theme_stylebox_override("normal", _face_box(picture))
	for state: String in ["hover", "pressed"]:
		button.add_theme_stylebox_override(state,
			_face_box(lit if lit != null else picture))
	button.add_theme_stylebox_override("disabled", _face_box(picture))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return picture.get_size()


## An invisible rectangle whose only job is to carry a hover hint.
##
## The original's help mode prints its eight strings somewhere; where is
## unknown, and a caption laid across a plate this dense is unreadable however
## it is placed. A tooltip puts each string on the region it names, which is
## what the strings are for.
func hint_region(rect: Rect2, text: String, into: Control = null) -> Control:
	var area: HintControl = HintControl.new()
	area.tooltip_text = text
	area.face = face(FNT_LABEL)
	area.readable_size = readable_size(FNT_LABEL)
	area.ink = INK_LABEL
	# **`PASS`, not `STOP`.** The regions are laid over the plate and a couple
	# of them cover a widget; passing the event on keeps the widget clickable.
	area.mouse_filter = Control.MOUSE_FILTER_PASS
	place_on_plate(area, rect.position, rect.size)
	var parent: Control = into if into != null else root()
	parent.add_child(area)
	return area


## The same hint, laid over a control that is already placed -- the caller has
## no plate rectangle to give, only the widget.
func hint_over(target: Control, text: String) -> HintControl:
	return HintControl.over(target, text, face(FNT_LABEL),
		readable_size(FNT_LABEL), INK_LABEL)


## A line where `GUI_SetText` puts one, aligned the way its `cX` column says.
func gui_text(text: String, at: Vector2, align: int = ALIGN_LEFT,
		ink: Color = INK_LABEL, into: Control = null,
		fnt: int = FNT_LABEL) -> Label:
	var line: Label = make_label(text, 0, fnt)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_color_override("font_color", ink)
	line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var left: float = at.x
	match align:
		ALIGN_CENTRE:
			line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			left = at.x - TEXT_BOX_WIDTH * 0.5
		ALIGN_RIGHT:
			line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			left = at.x - TEXT_BOX_WIDTH
		_:
			line.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	place_on_plate(line, Vector2(left, at.y),
		Vector2(TEXT_BOX_WIDTH, TEXT_LINE_HEIGHT))
	var parent: Control = into if into != null else root()
	parent.add_child(line)
	return line


## One sprite out of any interface library, put where the plate wants it.
##
## *at* is the top-left in the plate's own units and the sprite keeps its own
## size unless *size* says otherwise -- the item icons of the Item List are
## drawn at their natural 35x17, and the rotating item at whatever the window
## it sits in allows.
func gui_sprite(library: String, index: int, at: Vector2,
		size: Vector2 = Vector2.ZERO, into: Control = null) -> TextureRect:
	var view: TextureRect = TextureRect.new()
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var picture: Texture2D = art.sprite(library, index) if art != null else null
	view.texture = picture
	var span: Vector2 = size
	if span == Vector2.ZERO:
		span = picture.get_size() if picture != null else Vector2(16.0, 16.0)
	place_on_plate(view, at, span)
	var parent: Control = into if into != null else root()
	parent.add_child(view)
	return view


## A transparent [Control] a screen rebuilds the whole of: the rows of a list,
## the panel of a selected item.
##
## Full-rect and click-through, so what it holds is placed by
## [method place_on_plate] like everything else and nothing on it eats a click
## meant for the window behind.
func gui_layer(into: Control = null) -> Control:
	var layer: Control = Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var parent: Control = into if into != null else root()
	parent.add_child(layer)
	return layer


## Empty a container that is about to be rebuilt.
##
## **`remove_child` and then `queue_free`, never a bare `free`.** A list is
## almost always rebuilt from inside one of its own rows' `pressed` signals,
## and Godot locks an object while it is emitting: `free` then fails with
## "Attempted to free a locked object", the row stays alive off the list, and
## the rebuild that follows silently loses every row after it -- which is what
## a click on the difficulty row did to the two volume rows above it. Removing
## first is what makes the deferred delete safe: the children are out of the
## tree in this frame, so a later `get_children()` cannot see them, and gone
## by the end of it.
func clear_children(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()


## A titled panel, which is the shape every one of these screens uses.
func add_panel(title: String, position: Vector2, size: Vector2) -> VBoxContainer:
	var panel: PanelContainer = PanelContainer.new()
	panel.position = position
	panel.custom_minimum_size = size
	var column: VBoxContainer = VBoxContainer.new()
	panel.add_child(column)
	if title != "":
		column.add_child(make_label(title))
	_body.add_child(panel)
	return column
