class_name CommandPad
extends Control

## The 3x2 command pad -- `aUI.cpp`'s `0x00473680`/`0x00472570`/`0x00472330`,
## docs/29 section 1.1 and docs/43 section 5.
##
## Six sockets at `(404, 382)` on a 30 by 48 grid, each a `ui.LIB` element:
## the command's own icon when it is available, one element brighter under
## the pointer, and the empty socket (element 0) when it is not. The hint for
## the socket under the pointer is `Txtmod_h` 40..45.
##
## **Availability is recomputed at every refresh and asked again at the
## press** -- the original's gate (`0x00472570`) runs when the pad is drawn
## and again when it is clicked (`0x00473712`), so a socket that went dark
## between the two cannot fire.

## A command was pressed: one of the `COMMAND_*` values of [HudTables].
signal command(number: int)
## The hint to show, or "" when the pointer left.
signal hint(text: String)

var _art: Art = null
var _strings: Localization = null
var _buttons: Dictionary[int, TextureButton] = {}
var _available: Callable = Callable()


func setup(art: Art, strings: Localization) -> void:
	_art = art
	_strings = strings
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	for column: int in range(HudTables.PAD_COLUMNS):
		for row: int in range(HudTables.PAD_ROWS):
			var number: int = HudTables.pad_command(column, row)
			if number == 0:
				continue
			var button: TextureButton = TextureButton.new()
			button.ignore_texture_size = true
			button.stretch_mode = TextureButton.STRETCH_KEEP
			button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			button.mouse_filter = Control.MOUSE_FILTER_STOP
			button.focus_mode = Control.FOCUS_NONE
			button.pressed.connect(_on_pressed.bind(number))
			button.mouse_entered.connect(_on_entered.bind(number))
			button.mouse_exited.connect(_on_exited)
			add_child(button)
			_buttons[number] = button
	resized.connect(layout)
	layout()


## The sockets follow the bottom-right corner, as their piece of the plate
## does.
func layout() -> void:
	for column: int in range(HudTables.PAD_COLUMNS):
		for row: int in range(HudTables.PAD_ROWS):
			var number: int = HudTables.pad_command(column, row)
			if not _buttons.has(number):
				continue
			var button: TextureButton = _buttons[number]
			button.position = PlateLayout.anchored(
				Vector2(HudTables.pad_socket_at(column, row)), size, "bottom_right")
			button.size = Vector2(HudTables.PAD_STRIDE)


## Redraw the six faces. *available* answers `(command) -> bool`.
func refresh(available: Callable) -> void:
	_available = available
	for number: int in _buttons:
		var button: TextureButton = _buttons[number]
		var enabled: bool = DictRead.as_bool(available.call(number))
		var element: int = DictRead.as_int(HudTables.PAD_SPRITES[number]) \
			if enabled else HudTables.PAD_SOCKET
		button.disabled = not enabled
		button.texture_normal = _face(element)
		button.texture_hover = _face(element + 1) if enabled else _face(element)
		button.texture_pressed = button.texture_hover
		button.texture_disabled = _face(HudTables.PAD_SOCKET)


func _face(element: int) -> Texture2D:
	return _art.sprite("ui", element) if _art != null else null


## Whether a command's socket is lit, for a driver.
func is_enabled(number: int) -> bool:
	var button: TextureButton = _buttons.get(number, null)
	return button != null and not button.disabled


## Press a socket the way a click would. Answers whether it was lit.
func press(number: int) -> bool:
	if not is_enabled(number):
		return false
	_on_pressed(number)
	return true


func caption_for(number: int) -> String:
	if _strings == null:
		return ""
	var id: int = DictRead.as_int(HudTables.PAD_CAPTIONS.get(number, 0))
	if id == 0:
		return ""
	# The remake's key after the shipped words, from the table that **is**
	# the binding -- see [constant HudTables.COMMAND_KEYS].
	return HudTables.with_key(
		_strings.shipped(HudTables.BANK_INTERFACE, id),
		HudTables.command_key(number))


func _on_pressed(number: int) -> void:
	# The gate runs again at the press, as `0x00473712` does.
	if _available.is_valid() and not DictRead.as_bool(_available.call(number)):
		return
	command.emit(number)


func _on_entered(number: int) -> void:
	hint.emit(caption_for(number))


func _on_exited() -> void:
	hint.emit("")
