class_name ButtonColumns
extends Control

## The two columns of nine buttons on the battle plate -- `aMI.cpp`'s
## `0x00451240`/`0x00451A70`/`0x00451D50`, docs/43 section 5.
##
## Each slot is a `mi.LIB` element blitted at `(11 | 594, 66 + 31 row)`, dim
## when available and one element brighter under the pointer; an empty or
## unavailable slot wears element 31. A click raises one of the sixteen
## interface events of `0x00453900` (docs/29 section 1.2), and the hint for
## the slot under the pointer is written at (60, 22) from `Txtmod_h`.
##
## **Availability is asked, not kept.** [method refresh] takes a callable
## that answers whether an event can run right now -- the undo events need
## their autosave to exist, the briefing needs a campaign -- so the buttons
## never hold a copy of a rule that lives in [SliceMain].

## An event was clicked.
signal event(number: int)
## The hint to show for the slot under the pointer, or "" when none.
signal hint(text: String)
## The pointer moved onto a lit slot -- `fcn.004518E0`'s tick, raised when
## the hovered slot changes to one with a sprite behind it (docs/28 section
## 2.5); an empty or unavailable slot wears `mi[31]` and raises none.
signal hovered

var _art: Art = null
var _strings: Localization = null
var _buttons: Dictionary[Vector2i, TextureButton] = {}
var _events: Dictionary[Vector2i, int] = {}
var _magnifier: bool = false


func setup(art: Art, strings: Localization) -> void:
	_art = art
	_strings = strings
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	for column: int in range(HudTables.COLUMN_X.size()):
		for row: int in range(HudTables.COLUMN_ROWS):
			var slot: Vector2i = Vector2i(column, row)
			var number: int = HudTables.column_event(column, row)
			var button: TextureButton = TextureButton.new()
			button.ignore_texture_size = true
			button.stretch_mode = TextureButton.STRETCH_KEEP
			button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			button.mouse_filter = Control.MOUSE_FILTER_STOP
			button.focus_mode = Control.FOCUS_NONE
			button.pressed.connect(_on_pressed.bind(slot))
			button.mouse_entered.connect(_on_entered.bind(slot))
			button.mouse_exited.connect(_on_exited)
			add_child(button)
			_buttons[slot] = button
			_events[slot] = number
	resized.connect(layout)
	layout()


## Put every slot where the plate's units say, the right column following
## the right edge.
func layout() -> void:
	for slot: Vector2i in _buttons:
		var at: Vector2i = HudTables.column_slot_at(slot.x, slot.y)
		var anchor: String = "top_right" if slot.x == 1 else "top_left"
		var button: TextureButton = _buttons[slot]
		button.position = PlateLayout.anchored(Vector2(at), size, anchor)
		button.size = Vector2(HudTables.COLUMN_WIDTH, HudTables.COLUMN_ROW_HEIGHT)


## Whether event 13's mode is on, as the last [method refresh] was told.
func magnifier() -> bool:
	return _magnifier


## Redraw the faces. *available* answers `(event) -> bool`; *magnifier* is
## whether event 13's mode is on, which chooses its hint -- and, in this
## remake, its face ([method lit_element]).
func refresh(available: Callable, magnifier: bool) -> void:
	_magnifier = magnifier
	for slot: Vector2i in _buttons:
		var button: TextureButton = _buttons[slot]
		var number: int = _events[slot]
		var element: int = HudTables.COLUMN_EMPTY
		var enabled: bool = number != 0 and DictRead.as_bool(available.call(number))
		if enabled:
			element = DictRead.as_int(HudTables.COLUMN_SPRITES[number])
		button.disabled = not enabled
		button.texture_normal = _face(
			lit_element(number, element, enabled, _magnifier))
		button.texture_hover = _face(element + 1) if enabled else _face(element)
		button.texture_pressed = button.texture_hover
		button.texture_disabled = _face(HudTables.COLUMN_EMPTY)


## Which `mi` element a slot rests at: its own, or the **pointer's** face
## while the magnifier's mode is on.
##
## **This is the remake's, and the original does not do it.** Only two things
## in the image read `[0x005106CC]` besides the toggle and the click: the gate
## `0x00451230` and the caption chooser `0x00451815`. The sprite chooser
## `0x00451A70` takes the event alone, so the original's button looks exactly
## the same lit or dark and the mode is told by the caption under the pointer
## (`Txtmod_h` 33) and by the cursor. Both are still there; this adds the one
## thing a player can see without hovering, and it uses the shipped hover
## face -- `element + 1`, what `0x00451D50` blits under the pointer -- rather
## than a tint of the remake's own invention.
static func lit_element(number: int, element: int, enabled: bool,
		magnifier: bool) -> int:
	if number != HudTables.EVENT_MAGNIFIER or not enabled or not magnifier:
		return element
	return element + 1


func _face(element: int) -> Texture2D:
	return _art.sprite("mi", element) if _art != null else null


## The event a slot raises, for a driver.
func event_at(column: int, row: int) -> int:
	return DictRead.as_int(_events.get(Vector2i(column, row), 0))


## Whether a slot is enabled, for a driver.
func is_enabled(column: int, row: int) -> bool:
	var button: TextureButton = _buttons.get(Vector2i(column, row), null)
	return button != null and not button.disabled


## Press the slot that raises *number*, the way a click would. Answers
## whether such a slot exists and is enabled.
func press_event(number: int) -> bool:
	for slot: Vector2i in _events:
		if _events[slot] == number and not _buttons[slot].disabled:
			_on_pressed(slot)
			return true
	return false


## The hint for an event, out of `Txtmod_h`.
func caption_for(number: int) -> String:
	if _strings == null or number == 0:
		return ""
	var id: int = DictRead.as_int(HudTables.COLUMN_CAPTIONS.get(number, 0))
	if number == HudTables.EVENT_MAGNIFIER and _magnifier:
		id = HudTables.CAPTION_MAGNIFIER_OFF
	if id == 0:
		return ""
	# The remake's key after the shipped words, from the table that **is**
	# the binding -- see [constant HudTables.EVENT_KEYS].
	return HudTables.with_key(
		_strings.shipped(HudTables.BANK_INTERFACE, id),
		HudTables.event_key(number))


func _on_pressed(slot: Vector2i) -> void:
	var number: int = _events[slot]
	if number != 0:
		event.emit(number)


func _on_entered(slot: Vector2i) -> void:
	hint.emit(caption_for(_events[slot]))
	if not _buttons[slot].disabled:
		hovered.emit()


func _on_exited() -> void:
	hint.emit("")
