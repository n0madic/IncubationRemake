class_name Radar
extends Control

## The radar in the plate's bottom-right screen -- `aMI.cpp`'s `0x00451E50`,
## docs/43 section 6.
##
## A picture of the map **around the selected unit**, turned the way the
## camera looks: every live unit the current player can see is a `sm.LIB`
## cross, own units white (dim with no points left, the selection's larger),
## the other side's red (brighter on a cell the target overlay marked), a
## contact a hollow one; four letters on a circle of 25 say where north is on
## the screen; a lamp beside the screen burns while an enemy is visible and
## glows while one is only detected. The *scale* is how many fields the
## screen's 90 pixels span -- 40 by default, stepped by five within 20..80 by
## a click on the screen's right or left half, which is what the plate's two
## arrows beside it are.
##
## With nothing selected the screen shows the compass alone, as the original
## does: the centre is the selection and there is none.

## The scale changed, to this many fields across.
signal rescaled(fields: int)

## The circle the compass letters sit on.
const COMPASS_RADIUS: float = 25.0

var fields: int = HudTables.RADAR_SCALE_DEFAULT
var _art: Art = null
var _items: Array[Control] = []
var _screen: Control = null


func setup(art: Art) -> void:
	_art = art
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# The screen takes the clicks that step the scale; everything drawn on it
	# is a child that lets them through.
	_screen = Control.new()
	_screen.mouse_filter = Control.MOUSE_FILTER_STOP
	_screen.gui_input.connect(_on_screen_input)
	add_child(_screen)
	resized.connect(layout)
	layout()


func layout() -> void:
	if _screen == null:
		return
	_screen.position = PlateLayout.anchored(Vector2(HudTables.RADAR_CLICK.position),
		size, "bottom_right")
	_screen.size = Vector2(HudTables.RADAR_CLICK.size)


## Redraw. *north* and *east* are the screen-space directions of the map's
## `+y` and `+x` as the camera shows them (unit vectors, y down), *bands*
## the selection's target overlay.
func refresh(world: World, selected: int, north: Vector2, east: Vector2,
		bands: Dictionary[Vector2i, int], current_player: int) -> void:
	for item: Control in _items:
		item.get_parent().remove_child(item)
		item.queue_free()
	_items.clear()
	if _art == null:
		return
	var centre: Vector2 = PlateLayout.anchored(Vector2(HudTables.RADAR_CENTRE),
		size, "bottom_right")
	# The compass: N, S, W, E on the circle, turned with the camera.
	var directions: Array[Vector2] = [north, -north, -east, east]
	for i: int in range(directions.size()):
		_mark(HudTables.RADAR_COMPASS_SPRITES[i],
			centre + directions[i] * COMPASS_RADIUS, false)
	if world == null:
		return
	# **The compass is all there is without a selection.** `0x00451FE3` tests
	# the selected slot against 0xFFFF and jumps to the epilogue `0x00452376`
	# -- past the marks *and* past both lamp blits (`0x00452329`,
	# `0x0045234D`), which is why an unlit lamp is what a fresh mission shows.
	if selected < 0 or not world.has_unit(selected):
		return
	var enemy_visible: bool = false
	var enemy_detected: bool = false
	var start: Dictionary = world.unit_view(selected)
	var origin: Vector2i = Vector2i(DictRead.as_int(start["x"]),
		DictRead.as_int(start["y"]))
	var clip: Rect2 = Rect2(PlateLayout.anchored(Vector2(HudTables.RADAR_CLIP.position),
		size, "bottom_right"), Vector2(HudTables.RADAR_CLIP.size))
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			continue
		if not Fog.is_drawn(view):
			continue
		var player: int = DictRead.as_int(view["player"])
		# `0x004521AE`: the props player is skipped outright -- it is neither
		# an enemy mark nor a reason to light the lamp.
		if player == TurnState.PLAYER_PROPS:
			continue
		var contact: bool = Fog.is_contact(view)
		var cell: Vector2i = Vector2i(DictRead.as_int(view["x"]),
			DictRead.as_int(view["y"]))
		var element: int = -1
		if contact:
			element = HudTables.RADAR_DETECTED
			if player != current_player:
				enemy_detected = true
		elif player == current_player:
			if slot == selected:
				element = HudTables.RADAR_OWN_SELECTED
			elif DictRead.as_int(view["mp"]) == 0:
				element = HudTables.RADAR_OWN_NO_MP
			else:
				element = HudTables.RADAR_OWN
		else:
			enemy_visible = true
			element = HudTables.RADAR_OTHER_MARKED if bands.has(cell) \
				else HudTables.RADAR_OTHER_PLAIN
		var at: Vector2 = centre + spot(cell - origin, north, east, fields)
		if clip.has_point(at):
			_mark(element, at, true)
	var lamp: int = -1
	if enemy_visible:
		lamp = HudTables.RADAR_LAMP_VISIBLE
	elif enemy_detected:
		lamp = HudTables.RADAR_LAMP_DETECTED
	if lamp >= 0:
		_mark(lamp, PlateLayout.anchored(Vector2(HudTables.RADAR_LAMP_AT), size,
			"bottom_right"), false)


## Where a field *delta* from the selection lands, relative to the centre:
## `x * 90 / scale` across and `y * 66 / scale` down (`0x00451E00`), after the
## turn that puts the map's north where the camera shows it.
static func spot(delta: Vector2i, north: Vector2, east: Vector2,
		scale_fields: int) -> Vector2:
	var turned: Vector2 = east * float(delta.x) + north * float(delta.y)
	return Vector2(turned.x * float(HudTables.RADAR_CLIP.size.x) / float(scale_fields),
		turned.y * float(HudTables.RADAR_CLIP.size.y) / float(scale_fields))


## One `sm.LIB` element, less its anchor when the original subtracted it.
func _mark(element: int, at: Vector2, anchored: bool) -> void:
	var texture: Texture2D = _art.sprite(HudTables.LIB_RADAR, element)
	if texture == null:
		return
	var view: TextureRect = TextureRect.new()
	view.texture = texture
	view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	view.stretch_mode = TextureRect.STRETCH_KEEP
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.position = at
	if anchored:
		view.position -= Vector2(_art.sprite_offset(HudTables.LIB_RADAR, element))
	view.size = texture.get_size()
	add_child(view)
	_items.append(view)


## `0x00452390` -- a click on the screen: the right half steps the scale up
## (more fields, a wider view), the left half down.
func _on_screen_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click == null or not click.pressed or click.button_index != MOUSE_BUTTON_LEFT:
		return
	var split: float = float(HudTables.RADAR_SPLIT_X - HudTables.RADAR_CLICK.position.x)
	step(1 if click.position.x >= split else -1)


## Step the scale by five within 20..80. Answers the new scale.
func step(direction: int) -> int:
	var before: int = fields
	if direction > 0 and fields < HudTables.RADAR_SCALE_MAX:
		fields += HudTables.RADAR_SCALE_STEP
	elif direction < 0 and fields > HudTables.RADAR_SCALE_MIN:
		fields -= HudTables.RADAR_SCALE_STEP
	if fields != before:
		rescaled.emit(fields)
	return fields


## How many marks the last refresh drew, compass included.
func mark_count() -> int:
	return _items.size()
