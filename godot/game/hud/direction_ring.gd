class_name DirectionRing
extends Control

## The direction ring -- `dir.LIB` letters around a cell, docs/43 section 4.
##
## The original raises it after a click on a reachable cell (mode 1), on a
## warp cell (mode 3) or on the selected unit itself (mode 2): nine records
## are built around the clicked cell's object (`fcn.00406AA0`), each is
## projected every frame and its letter blitted at the projected point, and
## the next click picks the nearest record (`fcn.00406CA0`). The letter's
## facing is then written by `aChangeUnitViewDirection` after the move or the
## jump, or on its own in mode 2. The X on the ninth record cancels.
##
## **Drawn in 2D**, unlike [GroundSprites]: the engine clamps each letter to
## the 3D window (`0x00418CB9`), which a sprite standing in the world cannot
## do, and the letters are read against the pointer in screen space anyway.
## Under the `canvas_items` stretch a [Camera3D]'s `unproject_position`, a
## mouse event and this layer all speak the plate's own units, so no
## conversion happens here -- `test_hud.gd` pins the projection and the agent
## reports the visible rectangle so a driver can see that it stays true.

## The nine records: eight facings and the cancel.
const RECORDS: int = 9
const CANCEL_RECORD: int = 8

var _art: Art = null
var _points: Array[Vector3] = []
var _blocked: Array[bool] = []
var _letters: Array[TextureRect] = []
var _elements: Array[int] = []
var _anchors: Array[Vector2i] = []
var _hovered: int = -1
var _hover_distance: float = INF
var _blink: bool = false
## Which command the ring completes: one of the `RING_MODE_*` values.
var mode: int = HudTables.RING_MODE_NONE
## The cell the ring stands on.
var cell: Vector2i = Vector2i(-1, -1)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false


## Raise the ring around *at* for *ring_mode*.
##
## A record is *blocked* -- drawn in the yellow tier and blinking -- when the
## neighbour cell it names is off the map, holds a unit, carries an action
## point in 10..70 or a mine (`0x00418B8C`..`0x00418BF0`).
func place(art: Art, world: World, at: Vector2i, ring_mode: int) -> void:
	take_down()
	_art = art
	if art == null or world == null or not world.state.in_bounds(at.x, at.y):
		return
	mode = ring_mode
	cell = at
	var index: int = world.state.index_of(at.x, at.y)
	var centre: Vector3 = WorldSpace.cell_centre(at.x, at.y,
		world.state.height_at(index))
	for d: int in range(RECORDS):
		var offset: Vector2i = HudTables.RING_OFFSETS[d]
		_points.append(centre + WorldSpace.to_godot_v(Vector3(float(offset.x),
			float(offset.y), -float(HudTables.RING_DROP))))
		_blocked.append(d < CANCEL_RECORD and _neighbour_blocked(world, at, d))
		var element: int = HudTables.RING_CANCEL if d == CANCEL_RECORD \
			else HudTables.RING_LETTERS[d]
		_elements.append(element)
		var letter: TextureRect = TextureRect.new()
		letter.mouse_filter = Control.MOUSE_FILTER_IGNORE
		letter.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		letter.stretch_mode = TextureRect.STRETCH_KEEP
		add_child(letter)
		_letters.append(letter)
		_anchors.append(art.sprite_offset(HudTables.LIB_RING, element))
	visible = true


static func _neighbour_blocked(world: World, at: Vector2i, d: int) -> bool:
	var next: Vector2i = at + Vector2i(Interact.FACING_DX[d], Interact.FACING_DY[d])
	if not world.state.in_bounds(next.x, next.y):
		return true
	var index: int = world.state.index_of(next.x, next.y)
	if world.state.unit_at(index) != MapState.NO_UNIT:
		return true
	var action_point: int = world.state.action_point_at(index)
	if action_point >= 10 and action_point <= 70:
		return true
	return world.state.obstacle_at(index) == MapState.OBSTACLE_MINE


func take_down() -> void:
	for letter: TextureRect in _letters:
		remove_child(letter)
		letter.queue_free()
	_letters.clear()
	_points.clear()
	_blocked.clear()
	_elements.clear()
	_anchors.clear()
	_hovered = -1
	_hover_distance = INF
	mode = HudTables.RING_MODE_NONE
	cell = Vector2i(-1, -1)
	visible = false


func is_up() -> bool:
	return visible and not _letters.is_empty()


## Re-project every letter and choose its tier. *window* is the 3D window in
## the plate's units, *odd* bit 0 of the 100 ms counter.
func update(camera: Camera3D, window: Rect2, odd: bool) -> void:
	if camera == null or _letters.is_empty():
		return
	_blink = odd
	for d: int in range(RECORDS):
		var letter: TextureRect = _letters[d]
		if camera.is_position_behind(_points[d]):
			letter.visible = false
			continue
		var on: Vector2 = camera.unproject_position(_points[d])
		var element: int = _elements[d] + _tier(d)
		var texture: Texture2D = _art.sprite(HudTables.LIB_RING, element)
		if texture == null:
			letter.visible = false
			continue
		letter.texture = texture
		letter.size = texture.get_size()
		var anchor: Vector2i = _anchors[d]
		var at: Vector2 = on - Vector2(anchor)
		at.x = clampf(at.x, window.position.x + HudTables.RING_CLAMP_LOW,
			window.position.x + window.size.x + HudTables.RING_CLAMP_HIGH)
		at.y = clampf(at.y, window.position.y + HudTables.RING_CLAMP_LOW,
			window.position.y + window.size.y + HudTables.RING_CLAMP_HIGH)
		letter.position = at
		letter.visible = true


## The colour tier of record *d*, `0x00418C51`..`0x00418D60`: the hovered
## record is green, or blinks green when its cell is blocked; a blocked record
## that is not hovered blinks yellow; a free one is plain.
func _tier(d: int) -> int:
	if d == CANCEL_RECORD:
		return HudTables.RING_TIER_HOVER if d == _hovered else 0
	if d == _hovered:
		if _hover_distance > HudTables.RING_HOVER_DISTANCE:
			return HudTables.RING_TIER_HOVER
		if _blocked[d]:
			return HudTables.RING_TIER_HOVER if _blink else 0
		return HudTables.RING_TIER_HOVER
	if _blocked[d]:
		return HudTables.RING_TIER_BLOCKED if _blink else 0
	return 0


## The record nearest *at* within [constant HudTables.RING_HIT_RADIUS], or -1.
func hit(camera: Camera3D, at: Vector2) -> int:
	if camera == null or _letters.is_empty():
		return -1
	var best: int = -1
	var best_distance: float = HudTables.RING_HIT_RADIUS
	for d: int in range(RECORDS):
		if camera.is_position_behind(_points[d]):
			continue
		var distance: float = camera.unproject_position(_points[d]).distance_to(at)
		if distance < best_distance:
			best_distance = distance
			best = d
	return best


## Remember which record the pointer is nearest, for the tiers. Answers
## whether the hovered record changed, which is when the original plays its
## click.
func hover(camera: Camera3D, at: Vector2) -> bool:
	var before: int = _hovered
	_hovered = hit(camera, at)
	_hover_distance = INF
	if _hovered >= 0:
		_hover_distance = camera.unproject_position(_points[_hovered]).distance_to(at)
	return _hovered != before


## The facing a record stands for, or -1 for the cancel.
static func facing_of(record: int) -> int:
	if record < 0 or record >= CANCEL_RECORD:
		return -1
	return record


## Where the letters are, for a driver: `record -> [x, y, element]`.
func report() -> Array:
	var out: Array = []
	for d: int in range(_letters.size()):
		var letter: TextureRect = _letters[d]
		out.append([letter.position.x, letter.position.y,
			_elements[d] + _tier(d), letter.visible])
	return out
