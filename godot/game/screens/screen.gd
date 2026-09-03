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

## The layer the screens draw on. Above the HUD, so a screen covers the mission
## view rather than sharing it.
const SCREEN_LAYER: int = 8

## Emitted when a button is pressed; the host decides what it means.
signal chose(action: String)

var art: Art = null
var strings: Localization = null
var font: FontFile = null

var _root: Control = null
var _body: Control = null
var _buttons: HBoxContainer = null


func setup(screen_art: Art, text: Localization, screen_font: FontFile) -> void:
	art = screen_art
	strings = text
	font = screen_font
	layer = SCREEN_LAYER
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var backdrop: TextureRect = TextureRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.stretch_mode = TextureRect.STRETCH_SCALE
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if art != null:
		backdrop.texture = art.plate(PLATE)
	if backdrop.texture == null:
		# A cache with no art still shows a legible screen: the frame is what
		# is missing, not the campaign.
		var solid: ColorRect = ColorRect.new()
		solid.set_anchors_preset(Control.PRESET_FULL_RECT)
		solid.color = Color(0.05, 0.05, 0.06)
		solid.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(solid)
	_root.add_child(backdrop)

	_body = Control.new()
	_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.offset_left = 48.0
	_body.offset_top = 40.0
	_body.offset_right = -48.0
	_body.offset_bottom = -72.0
	_root.add_child(_body)

	_buttons = HBoxContainer.new()
	_buttons.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_buttons.offset_left = 56.0
	_buttons.offset_top = -60.0
	_buttons.offset_right = -56.0
	_buttons.offset_bottom = -18.0
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_buttons.add_theme_constant_override("separation", 16)
	_root.add_child(_buttons)
	build()


## Subclasses fill [member _body] and add their buttons here.
func build() -> void:
	pass


## What a screen shows on top of the plate.
func body() -> Control:
	return _body


## One shipped string. A bank or id the catalogue has no line for renders as
## its marker, which is a great deal easier to diagnose than a blank.
func label_for(module: String, id: int) -> String:
	if strings == null:
		return "%s/%d" % [module, id]
	return strings.shipped(module, id)


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
	if art != null and sprite_index >= 0:
		var face: Texture2D = art.sprite(BUTTON_LIBRARY, sprite_index)
		if face != null:
			button.icon = face
			button.expand_icon = true
	button.custom_minimum_size = Vector2(140.0, 34.0)
	button.pressed.connect(_on_pressed.bind(action))
	_buttons.add_child(button)
	return button


func _on_pressed(action: String) -> void:
	chose.emit(action)


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
