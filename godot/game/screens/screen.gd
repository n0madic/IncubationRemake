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
const ACTION_FONT_SIZE: int = 13

## Emitted when a button is pressed; the host decides what it means.
signal chose(action: String)

var art: Art = null
var strings: Localization = null
var font: FontFile = null
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


func setup(screen_art: Art, text: Localization, screen_font: FontFile) -> void:
	art = screen_art
	strings = text
	font = screen_font
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
		# window exists to show.
		var solid: ColorRect = ColorRect.new()
		solid.color = Color(0.05, 0.05, 0.06)
		solid.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if plate_window().size == Vector2.ZERO:
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
	var title: Label = make_label(text)
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


## A label in the game's own bitmap font.
func make_label(text: String, size: int = 0) -> Label:
	var out: Label = Label.new()
	out.text = text
	if font != null:
		out.add_theme_font_override("font", font)
	if size > 0:
		out.add_theme_font_size_override("font_size", size)
	return out


## A button captioned from the shipped banks and drawn on a `buttons.LIB`
## sprite where the cache has one.
func add_button(action: String, module: String, id: int,
		sprite_index: int = -1) -> Button:
	var button: Button = Button.new()
	button.text = label_for(module, id)
	if font != null:
		button.add_theme_font_override("font", font)
	else:
		# The row divides the plate five ways at most, so a caption is drawn
		# to fit its share rather than being cut: *Enter Location* at the
		# default size came out as *Enter Locati*.
		button.add_theme_font_size_override("font_size", ACTION_FONT_SIZE)
	if art != null and sprite_index >= 0:
		var face: Texture2D = art.sprite(BUTTON_LIBRARY, sprite_index)
		if face != null:
			button.icon = face
			button.expand_icon = true
	# A caption or an icon wider than the button's share is cut, rather than
	# pushing its neighbours off the plate.
	button.clip_text = true
	button.pressed.connect(_on_pressed.bind(action))
	_buttons.add_child(button)
	return button


## A button for the screen's **body** rather than for the action row at the
## bottom.
##
## The shell's screens are lists -- a menu of five, eight save slots, a
## catalogue of missions -- and a list is not what [member _buttons] is: that
## one is a centred row of at most a handful. The caption is passed in already
## resolved, because a list row is usually a shipped string with a number or a
## name beside it.
func make_button(action: String, text: String) -> Button:
	var button: Button = Button.new()
	button.text = text
	if font != null:
		button.add_theme_font_override("font", font)
	button.pressed.connect(_on_pressed.bind(action))
	return button


## A row button that is going into the action row rather than into a list, so
## it takes the row's caption size and its clipping.
func make_action_button(action: String, text: String) -> Button:
	var button: Button = make_button(action, text)
	button.clip_text = true
	if font == null:
		button.add_theme_font_size_override("font_size", ACTION_FONT_SIZE)
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
		var at: Vector2 = Vector2(
			BUTTON_ROW_MARGIN + float(index) * (width + BUTTON_ROW_GAP),
			BUTTON_ROW_TOP)
		place_on_plate(row[index], at, Vector2(width, BUTTON_ROW_HEIGHT))


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
