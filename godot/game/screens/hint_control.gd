class_name HintControl
extends Control

## A hover hint drawn at the plate's own scale.
##
## Godot's tooltip is a [PopupPanel] **embedded in the same viewport**, so
## `project.godot`'s `canvas_items` stretch scales it like everything else --
## and the theme's default size of 16 is therefore 16 *plate units*, half again
## the largest caption any of these screens draws and about three times the
## body text beside it. There is no theme seam that reaches it: the popup is a
## child of the viewport, not of the screen that owns the hint, so a [Theme] on
## the screen is not in its lookup chain.
##
## [method Control._make_custom_tooltip] is the seam that does reach it. The
## control returned there is used as it stands, with its own overrides, so the
## hint is drawn in the same face and at the same size as the caption it
## belongs to.

## What the panel puts between its border and the words, in plate units.
const PAD_X: float = 5.0
const PAD_Y: float = 2.0
## The panel behind the words. The shipped screens have no hint art of their
## own -- `Txtmod_h` 50..58 are strings and nothing is known about the box the
## original drew them in -- so this is the remake's, kept to the plates' own
## near-black so it reads as part of them.
const BACKING: Color = Color(0.04, 0.04, 0.05, 0.92)
const BORDER: Color = Color(0.35, 0.36, 0.32, 1.0)

## The face the owning screen draws its captions in, or null for the readable
## one at [member readable_size].
var face: FontFile = null
var readable_size: int = 0
var ink: Color = Color.WHITE


## Everything a screen needs to hand over, in one call.
static func over(target: Control, text: String, chosen: FontFile,
		size: int, colour: Color) -> HintControl:
	var hint: HintControl = HintControl.new()
	hint.tooltip_text = text
	hint.face = chosen
	hint.readable_size = size
	hint.ink = colour
	# **`PASS`, not `STOP`.** A hint is laid over a control that is often a
	# button; passing the event on keeps it clickable.
	hint.mouse_filter = Control.MOUSE_FILTER_PASS
	hint.set_anchors_preset(Control.PRESET_FULL_RECT)
	target.add_child(hint)
	return hint


func _make_custom_tooltip(text: String) -> Object:
	var panel: PanelContainer = PanelContainer.new()
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = BACKING
	box.border_color = BORDER
	box.set_border_width_all(1)
	box.content_margin_left = PAD_X
	box.content_margin_right = PAD_X
	box.content_margin_top = PAD_Y
	box.content_margin_bottom = PAD_Y
	panel.add_theme_stylebox_override("panel", box)
	var line: Label = Label.new()
	line.text = text
	line.add_theme_color_override("font_color", ink)
	if face != null:
		line.add_theme_font_override("font", face)
	else:
		line.add_theme_font_size_override("font_size", readable_size)
	panel.add_child(line)
	return panel
