class_name TurnProgress
extends Control

## The watched player's progress bar -- `aViewPlayer.cpp`'s `fcn.0047DA00`,
## docs/43 section 7.
##
## While another player moves, the original does not draw the battle interface
## at all: `aInitViewPlayer` loads `plate_5.bmp` whole and the frame callback
## blits it back, so every column icon, every pad face and the whole unit panel
## are gone and this bar is the only thing on top of the bare plate. Twenty-two
## `vp.LIB` capsules on row 406 from x 59, one element width apart; `vp[0]` is
## lit and `vp[1]` is not.
##
## The fill is `acted * 21 / live` and the bar lights `fill + 1`, so one capsule
## burns from the first frame of the turn -- which is what the shipped game
## shows the moment the aliens take over.
##
## **It counts nothing itself.** [method tally] is a pure function of the world
## and of which events the replay has already played, because `core` decides
## the whole computer turn before any of it is drawn: the world holds every
## spent movement point from the first frame, and a bar read straight off it
## would be full before the first alien moved.

## The last fill drawn. `0x00522E18` -- the engine draws the larger of this and
## the new one, so a bar that shrinks takes a frame to do it.
var _previous: int = 0
var _lit: int = 0
var _art: Art = null
var _items: Array[Control] = []


func setup(art: Art) -> void:
	_art = art
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false


## Draw the bar for *acted* of *live* units, or clear it when *live* is none,
## and answer whether the fill moved this frame -- `0x0047DA5F`'s compare, the
## one thing that makes `progress.wav` sound. An unchanged fill is silent, and
## so is the first frame of a turn on which nobody has moved yet.
func refresh(acted: int, live: int) -> bool:
	for item: Control in _items:
		remove_child(item)
		item.queue_free()
	_items.clear()
	if live <= 0 or _art == null:
		# **And the memory of the last fill goes with it.** The engine zeroes
		# `0x00522E18` once, at mission init, so its second alien turn opens on
		# one frame of the first one's last fill and a stray `progress.wav`.
		# That is a defect of a frame and is not reproduced.
		_previous = 0
		_lit = 0
		visible = false
		return false
	var fill: int = fill_for(acted, live)
	var stepped: bool = fill != _previous
	_lit = mini(maxi(fill, _previous) + 1, HudTables.PROGRESS_SEGMENTS)
	_previous = fill
	var lit: Texture2D = _art.sprite(HudTables.LIB_PROGRESS,
		HudTables.PROGRESS_LIT)
	var dark: Texture2D = _art.sprite(HudTables.LIB_PROGRESS,
		HudTables.PROGRESS_DARK)
	if lit == null or dark == null:
		visible = false
		return stepped
	var step: float = lit.get_size().x
	var origin: Vector2 = PlateLayout.anchored(
		Vector2(HudTables.PROGRESS_ORIGIN), size, "bottom_left")
	for i: int in range(HudTables.PROGRESS_SEGMENTS):
		_capsule(lit if i < _lit else dark,
			origin + Vector2(float(i) * step, 0.0))
	visible = true
	return stepped


## `0x0047DA38`..`0x0047DA4C`: no live unit is no bar, and a side that has not
## moved yet is fill zero -- the multiply is skipped rather than rounded.
static func fill_for(acted: int, live: int) -> int:
	if live <= 0 or acted <= 0:
		return 0
	@warning_ignore("integer_division")
	var fill: int = acted * HudTables.PROGRESS_STEPS / live
	return mini(fill, HudTables.PROGRESS_SEGMENTS - 1)


## `(acted, live)` for *player*, as the engine's two sweeps of the unit array
## read them -- `fcn.00477BF0` counts the side's live units and `fcn.00477FB0`
## the ones whose `+0x15` is no longer their own allowance.
##
## *played* is the slots the replay has already shown and *doomed* the ones it
## is still holding on their feet: a unit the computer is going to kill is dead
## in the world from the first frame, and the divisor it belongs to is the one
## the turn started with.
static func tally(world: World, player: int, played: PackedInt32Array,
		doomed: PackedInt32Array) -> Vector2i:
	if world == null or player < 0:
		return Vector2i.ZERO
	var acted: int = 0
	var live: int = 0
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["player"]) != player:
			continue
		if DictRead.as_int(view["hp"]) <= 0 and not doomed.has(slot):
			continue
		live += 1
		if not played.has(slot):
			continue
		if DictRead.as_int(view["mp"]) != world.movement_allowance(slot,
				world.turn.ai_level):
			acted += 1
	return Vector2i(acted, live)


## How many capsules are lit, for a driver and for the suites.
func lit_count() -> int:
	return _lit if visible else 0


func _capsule(texture: Texture2D, at: Vector2) -> void:
	var view: TextureRect = TextureRect.new()
	view.texture = texture
	view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	view.stretch_mode = TextureRect.STRETCH_KEEP
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.position = at
	view.size = texture.get_size()
	add_child(view)
	_items.append(view)
