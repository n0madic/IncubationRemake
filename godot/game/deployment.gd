class_name Deployment
extends RefCounted

## The place interface's rules -- `aPI.cpp`, docs/43 section 5.5 -- as
## functions a suite can call without a tree.
##
## The original keeps one word of state, the selected pool index
## `[0x514064]`, beside the pool it indexes; the remake keeps the selected
## **roster slot** in [SliceMain] and treats a record's position in
## [method Roster.occupied_slots] as the original's index. The pool the
## original walks is compacted by `aRemoveUnitFromUnitPool` on every
## placement; the roster here keeps its gaps (docs/27 section 3.4), so the
## wraps below are written over positions, not slot numbers.

## The two steps the panel band answers with.
const PREV: int = -1
const NEXT: int = 1

## The band's answer for a click at *at*, in the canvas's units (plate
## units, the panel's piece anchored bottom-left): [constant PREV],
## [constant NEXT] or 0 for a click outside both halves -- which includes
## x 220, the column neither half claims.
static func band_side(at: Vector2, canvas: Vector2) -> int:
	var extra: float = canvas.y - float(HudTables.PLATE_SIZE.y)
	var y: int = floori(at.y - extra)
	var x: int = floori(at.x)
	if y < HudTables.PANEL_CLICK_Y.x or y > HudTables.PANEL_CLICK_Y.y:
		return 0
	if x >= HudTables.PANEL_PREV_X.x and x <= HudTables.PANEL_PREV_X.y:
		return PREV
	if x >= HudTables.PANEL_NEXT_X.x and x <= HudTables.PANEL_NEXT_X.y:
		return NEXT
	return 0


## The two halves as rectangles on *canvas*, `[previous, next]`, for the
## controls that take the clicks.
static func band_rects(canvas: Vector2) -> Array[Rect2]:
	var top: Vector2 = PlateLayout.anchored(
		Vector2(0.0, float(HudTables.PANEL_CLICK_Y.x)), canvas, "bottom_left")
	var height: float = float(HudTables.PANEL_CLICK_Y.y
		- HudTables.PANEL_CLICK_Y.x + 1)
	return [
		Rect2(float(HudTables.PANEL_PREV_X.x), top.y,
			float(HudTables.PANEL_PREV_X.y - HudTables.PANEL_PREV_X.x + 1),
			height),
		Rect2(float(HudTables.PANEL_NEXT_X.x), top.y,
			float(HudTables.PANEL_NEXT_X.y - HudTables.PANEL_NEXT_X.x + 1),
			height),
	]


## The selection after a step: the arms at `0x0046363D` (previous, wrapping
## to the last) and `0x004636B7` (next, wrapping to the first). Both leave
## an empty selection alone -- the original's `je 0x46371d`.
static func cycle(slots: PackedInt32Array, selected: int, step: int) -> int:
	if selected == Roster.NO_SLOT or slots.is_empty():
		return Roster.NO_SLOT
	var position: int = slots.find(selected)
	if position < 0:
		return slots[0]
	position = (position + step) % slots.size()
	if position < 0:
		position += slots.size()
	return slots[position]


## The selection after a placement, `0x004635E3..0x00463605`: nobody when the
## pool is empty, the same index while it still exists, else the last one.
static func after_placement(slots_after: PackedInt32Array,
		position_before: int) -> int:
	if slots_after.is_empty():
		return Roster.NO_SLOT
	return slots_after[mini(maxi(position_before, 0), slots_after.size() - 1)]


## The selection after a soldier came back, `0x004634EF..0x004634F8`: an
## empty selection becomes index 0; anyone still selected stays.
static func after_recall(slots: PackedInt32Array, selected: int) -> int:
	if slots.is_empty():
		return Roster.NO_SLOT
	if selected != Roster.NO_SLOT and slots.has(selected):
		return selected
	return slots[0]


## The facing a placement takes from the click's quadrant of the screen
## ([constant HudTables.DEPLOY_FACING_BY_QUADRANT]).
static func facing_for(at: Vector2, size: Vector2) -> int:
	var key: Vector2i = Vector2i(
		1 if at.x >= size.x / 2.0 else 0,
		1 if at.y >= size.y / 2.0 else 0)
	return HudTables.DEPLOY_FACING_BY_QUADRANT[key]
