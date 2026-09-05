class_name PlateLayout
extends Control

## `plate_5` as a layout rather than a picture -- docs/43 section 7.
##
## The shipped battle plate is 640x480 with a 520x340 hole, and the original
## draws it as four strips around that hole (`0x0041A980`). A modern window is
## rarely 4:3, and stretching the plate to it -- what [method
## CampaignScreen.place_on_plate] does for the campaign screens -- distorts
## every rivet. The canvas is `canvas_items` with `expand`
## (`project.godot`), so it is always at least 640 by at least 480 of the
## plate's own units at one uniform scale, and whatever it has beyond that is
## **extra units, not a stretch**. The plate is therefore cut into pieces
## ([constant HudTables.PLATE_SEGMENTS]): the corners and the columns keep
## their pixel size and their corner, a slice of the top ribbon and of the
## panel's dark inset is tiled across the extra width, and a slice of each
## column is tiled down the extra height. The 3D window is what is left --
## `(60, 34)` by the canvas less 120 by the canvas less 140 -- which on 4:3
## is the original's own rectangle to the pixel.
##
## The pieces **stop** mouse input: a click on the frame meant nothing to the
## original but the pad and the columns, which are controls of their own on
## top of this. (The campaign screens' strips let clicks through, because
## their window is what their frame is for.)

## The plate's own name, and a solid stand-in for a cache without it.
const FALLBACK_COLOUR: Color = Color(0.09, 0.09, 0.1)

var _pieces: Array[Control] = []


## Build the frame from *art*'s plate. With no plate, the frame is drawn as
## solid pieces of the same layout so the window still shows.
func build(art: Art) -> void:
	for piece: Control in _pieces:
		remove_child(piece)
		piece.queue_free()
	_pieces.clear()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var picture: Texture2D = art.plate(HudTables.PLATE) if art != null else null
	var image: Image = picture.get_image() if picture != null else null
	for segment: Dictionary in HudTables.PLATE_SEGMENTS:
		var region: Rect2i = segment["region"]
		var kind: String = DictRead.as_string(segment["kind"])
		var anchor: String = DictRead.as_string(segment["anchor"])
		var piece: Control = _piece(picture, image, region, kind)
		_anchor(piece, region, anchor, kind)
		add_child(piece)
		_pieces.append(piece)


## One piece: an [AtlasTexture] of the plate for a fixed piece, and a tiled
## [ImageTexture] cut out of it for a band or a filler -- an atlas cannot be
## tiled, it repeats the whole plate.
static func _piece(picture: Texture2D, image: Image, region: Rect2i,
		kind: String) -> Control:
	if picture == null or image == null:
		var solid: ColorRect = ColorRect.new()
		solid.color = FALLBACK_COLOUR
		solid.mouse_filter = Control.MOUSE_FILTER_STOP
		return solid
	var view: TextureRect = TextureRect.new()
	view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	if kind == "fixed":
		var slice: AtlasTexture = AtlasTexture.new()
		slice.atlas = picture
		slice.region = Rect2(region)
		view.texture = slice
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_SCALE
	else:
		view.texture = ImageTexture.create_from_image(image.get_region(region))
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_TILE
	return view


## Pin a piece to its corner with offsets in the plate's units, so it keeps
## its size and its place while the canvas grows.
static func _anchor(piece: Control, region: Rect2i, anchor: String,
		kind: String) -> void:
	var plate: Vector2i = HudTables.PLATE_SIZE
	var right_side: bool = anchor.ends_with("right")
	var bottom_side: bool = anchor.begins_with("bottom")
	# Horizontal.
	if kind == "band":
		# From the left piece's edge to the right piece's edge, tiled.
		piece.anchor_left = 0.0
		piece.anchor_right = 1.0
		piece.offset_left = float(region.position.x)
		piece.offset_right = -float(plate.x - region.position.x - region.size.x)
	elif right_side:
		piece.anchor_left = 1.0
		piece.anchor_right = 1.0
		piece.offset_left = -float(plate.x - region.position.x)
		piece.offset_right = -float(plate.x - region.position.x - region.size.x)
	else:
		piece.anchor_left = 0.0
		piece.anchor_right = 0.0
		piece.offset_left = float(region.position.x)
		piece.offset_right = float(region.position.x + region.size.x)
	# Vertical.
	if kind == "filler":
		# From the column's bottom to the bottom strip's top, tiled.
		var column_bottom: int = HudTables.WINDOW.position.y + HudTables.WINDOW.size.y
		piece.anchor_top = 0.0
		piece.anchor_bottom = 1.0
		piece.offset_top = float(column_bottom)
		piece.offset_bottom = -float(plate.y - column_bottom)
	elif bottom_side:
		piece.anchor_top = 1.0
		piece.anchor_bottom = 1.0
		piece.offset_top = -float(plate.y - region.position.y)
		piece.offset_bottom = -float(plate.y - region.position.y - region.size.y)
	else:
		piece.anchor_top = 0.0
		piece.anchor_bottom = 0.0
		piece.offset_top = float(region.position.y)
		piece.offset_bottom = float(region.position.y + region.size.y)


## The rectangles the pieces occupy on a canvas of *canvas* units, in the
## order of [constant HudTables.PLATE_SEGMENTS]. Static, so a suite can lay
## the frame out on any canvas without a tree.
static func rects_for(canvas: Vector2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var plate: Vector2 = Vector2(HudTables.PLATE_SIZE)
	var extra: Vector2 = canvas - plate
	var column_bottom: float = float(HudTables.WINDOW.position.y
		+ HudTables.WINDOW.size.y)
	for segment: Dictionary in HudTables.PLATE_SEGMENTS:
		var cut: Rect2i = segment["region"]
		var kind: String = DictRead.as_string(segment["kind"])
		var anchor: String = DictRead.as_string(segment["anchor"])
		var rect: Rect2 = Rect2(cut)
		if kind == "band":
			rect.size.x += extra.x
		elif anchor.ends_with("right"):
			rect.position.x += extra.x
		if kind == "filler":
			rect.position.y = column_bottom
			rect.size.y = extra.y
		elif anchor.begins_with("bottom"):
			rect.position.y += extra.y
		out.append(rect)
	return out


## Where a plate-unit point of the original's 640x480 lands on *canvas*: a
## point in a right-anchored piece moves with the right edge, one in a
## bottom-anchored piece with the bottom edge. What the pad, the radar and the
## turn window use to stay on their piece.
static func anchored(at: Vector2, canvas: Vector2, anchor: String) -> Vector2:
	var extra: Vector2 = canvas - Vector2(HudTables.PLATE_SIZE)
	var out: Vector2 = at
	if anchor.ends_with("right"):
		out.x += extra.x
	if anchor.begins_with("bottom"):
		out.y += extra.y
	return out
