class_name MapMarkers
extends Node3D

## The dots the original draws on a map: the campaign's locations and the
## deployment screen's free cells.
##
## **They are 3D and not projected [Control]s.** The alternative was to
## `unproject_position` each cell and move a [Button] there every frame, which
## needs the window-pixel to plate-unit conversion the `canvas_items` stretch
## introduces and re-derives the picking the game already does. A [Sprite3D]
## sits at the cell and the click goes through [method SliceMain.cell_under],
## so there is one answer to "which cell is that" rather than two.
##
## `fixed_size` keeps a marker the same size however far the camera is, which
## is what the shipped 10x10 sprites are drawn as, and `no_depth_test` puts
## them over the scenery.
##
## **Depth-testing them was tried and it hides them.** A campaign map's
## visible ground is the `.3DW` clones and the location's own height is the
## control map's, so a dot placed at the cell sits *under* the street it
## belongs to: with the depth buffer honoured, campaign 1's three open
## locations disappeared entirely. The original draws these as overlay
## sprites after the world for the same reason, so the overlay is the
## faithful reading as well as the working one.

## `Libs/map.LIB` -- the campaign map's own sprite library (docs/60).
const LIBRARY: String = "map"
## The four coloured 10x10 dots: 0 red, 1 white, 2 blue, 3 yellow. The
## mission's far view draws them as ownership flags (docs/43 section 3.3);
## the deployment screen's free cells wear the red one.
const DOT_BATTLE: int = 0
const DOT_VISITED: int = 1
const DOT_UPGRADE: int = 2
const DOT_DIALOGUE: int = 3
## The 17x17 white ring **every open location wears** -- `fcn.00418F40`
## blits `map[7]` on every state-3 cell of the campaign map (docs/27 section
## 2.6.3). The deployment screen rings the hovered free cell with it.
const RING_OPEN: int = 7
## The badge the same routine puts over the pointed-at location: a 50x43
## picture with a leader line ending in a ring, anchored at `(38, 34)` so the
## ring stands on the cell. Which of the three is the location's own id
## band, see [method CampaignMapScreen.badge_for].
const BADGE_NONE: int = -1

## Clear of the floor, in Godot units, so a marker on a cell with something
## standing on it is still the topmost thing drawn there.
const LIFT: float = 0.1


## How large one texel of a marker is drawn, with `fixed_size` on.
##
## A `fixed_size` sprite is held at a constant size on screen, and that size
## is `pixel_size` through the **projection's own scale** -- so it is not
## independent of the camera at all, and it changed the moment the rig took
## Eng3d's focal length instead of Godot's default field of view. The
## reciprocal of that focal length makes one texel exactly one pixel of the
## 640x480 layout space, which is what the shipped 10x10 dots and 17x17 ring
## are drawn at in the original -- so this is derived rather than tuned, and
## the ring stays the larger of the two by being larger.
static func pixel_size() -> float:
	return 1.0 / CameraRig.focal_length(CampaignScreen.PLATE_WINDOW.size.x)

## cell -> the marker standing on it, so a hover can ring one without
## rebuilding the set.
var _marks: Dictionary[Vector2i, Sprite3D] = {}
## The ring the deployment screen draws round the free cell the pointer is
## over. One sprite, moved, rather than one per cell.
var _ring: Sprite3D = null
## The badge over the campaign location the pointer is over, and which
## element it shows -- rebuilt when the band changes, moved otherwise.
var _badge: Sprite3D = null
var _badge_element: int = BADGE_NONE


## Replace every marker. *marks* is `cell -> sprite index in `map.LIB``, and
## *heights* the map's own height field, read as `y * width + x`.
func show_marks(art: Art, marks: Dictionary[Vector2i, int],
		heights: PackedInt32Array, width: int) -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_marks.clear()
	_ring = null
	_badge = null
	_badge_element = BADGE_NONE
	if art == null:
		return
	for cell: Vector2i in marks:
		var texture: Texture2D = art.sprite(LIBRARY, marks[cell])
		if texture == null:
			continue
		var mark: Sprite3D = _sprite(texture)
		var index: int = cell.y * width + cell.x
		var height: int = heights[index] \
			if index >= 0 and index < heights.size() else 0
		mark.position = WorldSpace.cell_centre(cell.x, cell.y, height) \
			+ Vector3(0.0, LIFT, 0.0)
		add_child(mark)
		_marks[cell] = mark


## Put the ring round *cell*, or take it down for a cell with no marker.
##
## A dot alone says *there is a location here* and nothing about which one the
## pointer is on, which is what the original's 17x17 ring is for. It has to
## come down when the pointer leaves the picture, or the last one hovered
## reads as a selection.
func ring(art: Art, cell: Vector2i) -> void:
	if not _marks.has(cell):
		clear_ring()
		return
	if _ring == null:
		var texture: Texture2D = art.sprite(LIBRARY, RING_OPEN) \
			if art != null else null
		if texture == null:
			return
		_ring = _sprite(texture)
		add_child(_ring)
	_ring.visible = true
	_ring.position = _marks[cell].position


## The campaign map's own hover: `fcn.00418F40` blits the location's band
## badge at the pointed-at cell less the element's anchor, so the ring at the
## badge's foot stands where the open-location ring already is and the
## picture rises up and to the left of it. *element* is
## [method CampaignMapScreen.badge_for]'s answer; [constant BADGE_NONE] or a
## cell with no marker takes the badge down.
func badge(art: Art, cell: Vector2i, element: int) -> void:
	if not _marks.has(cell) or element < 0 or art == null:
		clear_ring()
		return
	if _badge == null or _badge_element != element:
		var texture: Texture2D = art.sprite(LIBRARY, element)
		if texture == null:
			clear_ring()
			return
		if _badge != null:
			remove_child(_badge)
			_badge.queue_free()
		_badge = _sprite(texture)
		_badge.centered = false
		_badge.offset = GroundSprites.anchor_offset(
			art.sprite_offset(LIBRARY, element), texture.get_height())
		_badge_element = element
		add_child(_badge)
	_badge.visible = true
	_badge.position = _marks[cell].position


## Take the hover down -- the ring and the badge both.
func clear_ring() -> void:
	if _ring != null:
		_ring.visible = false
	if _badge != null:
		_badge.visible = false


func has_ring() -> bool:
	return (_ring != null and _ring.visible) or (_badge != null and _badge.visible)


## The element the hover badge shows, or [constant BADGE_NONE].
func badge_element() -> int:
	return _badge_element if _badge != null and _badge.visible else BADGE_NONE


## Which cells carry a marker, so a click can be checked against them.
func cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cell: Vector2i in _marks:
		out.append(cell)
	return out


func has_cell(cell: Vector2i) -> bool:
	return _marks.has(cell)


## How near a marker's own place on the screen a pointer has to be for
## [method cell_at] to answer with it, in the plate's units. The shipped ring
## is 17x17, so this is its radius and a little.
const PICK_RADIUS: float = 10.0


## The marked cell nearest *at* **on the screen**, or `(-1, -1)`.
##
## [method SliceMain.cell_under] answers the other question -- which cell of
## the map is under the pointer -- by crossing the ray with each cell's own
## height. That is the right answer for a mission, whose camera looks down at
## the floor, and a fragile one for the campaign map: its authored eyes include
## shallow views across steep height changes (docs/27 section 2.6), where one
## pixel of pointer movement can cover much of a field. A dot two pixels across
## became unclickable.
##
## These are **overlay sprites**: `no_depth_test`, `fixed_size`, drawn after
## the world. What the player aims at is the sprite, so the pick is the
## sprite's -- the nearest projected marker inside [constant PICK_RADIUS].
func cell_at(camera: Camera3D, at: Vector2, radius: float = PICK_RADIUS
		) -> Vector2i:
	if camera == null:
		return Vector2i(-1, -1)
	var best: Vector2i = Vector2i(-1, -1)
	var best_distance: float = radius
	for cell: Vector2i in _marks:
		var mark: Sprite3D = _marks[cell]
		if camera.is_position_behind(mark.global_position):
			continue
		var distance: float = camera.unproject_position(
			mark.global_position).distance_to(at)
		if distance < best_distance:
			best_distance = distance
			best = cell
	return best


func _sprite(texture: Texture2D) -> Sprite3D:
	var mark: Sprite3D = Sprite3D.new()
	mark.texture = texture
	mark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mark.fixed_size = true
	mark.no_depth_test = true
	mark.shaded = false
	mark.double_sided = true
	mark.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mark.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	mark.pixel_size = pixel_size()
	return mark
