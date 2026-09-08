class_name Art
extends RefCounted

## The screen plates, the briefing pictures and the interface sprites.
##
## All three come out of the cache the converter baked: `art/plates/*.png` and
## `art/briefing/*.png` are the shipped 8-bit BMPs and `ui/<lib>/NNN.png` the
## shape libraries, each drawn with the palette `liblib.find_palette` resolved.
## `art/index.json` says what is there.
##
## Textures are built once and kept: a screen rebuilt on every click would
## otherwise decode the same 640x480 plate each time.

const INDEX_PATH: String = "art/index.json"
const PLATE_DIR: String = "art/plates"
const BRIEFING_DIR: String = "art/briefing"
const UI_DIR: String = "ui"

## The plate every framed screen sits on -- `GUI\plate_1.bmp`, which `aInitGUI`
## loads at `0x0044B290` and the debriefing at `0x0045D492`.
const PLATE_FRAMED: String = "plate_1"

## The library `Menu_b.lcl`'s `GUI_SetButton` and `GUI_SetIcon` index. Both
## take it as a bare number -- `0_Library` for a button and `30_Library`,
## `44_Library`, `48_Library`, `50_Library`, `52_Library` for the icons -- and
## every one of those is an element of `buttons.LIB`.
const BUTTON_LIBRARY: String = "buttons"
## The three pieces a gadget of type 3 is drawn from, as `aPrintGadget`
## `0x0043a4ab` lays them: **`base + 0` is the left cap, `base + 1` the right
## cap and `base + 2` the fill**, and the fill is repeated `Width - 2` times
## with no overlap at all (`0x0043a334`; the same arithmetic answers
## `0x0043a9d0`, which is what the engine measures the gadget with).
##
## `base` is `GUI_SetButton`'s / `GUI_SetTextButton`'s `Library` column: 0 for
## the action buttons (27x31, 18x31, 31x31) and 6 for the Upgrade Menu's name
## field (three 32x32 panel pieces). So `Width` 6 over base 0 is
## `27 + 4*31 + 18 = 169`, and `Width` 5 over base 6 is `32 + 3*32 + 32 = 160`.
const BUTTON_LEFT: int = 0
const BUTTON_RIGHT: int = 1
const BUTTON_MIDDLE: int = 2
## The lit trio, three along. **Hover and not press:** `0x0043a06d` compares
## the gadget's id with `0x00509a30`, which `0x0043a8b0` writes from the
## hit-test under the *pointer* with no button involved, repainting the one
## that was lit and the one that now is. `GUI_SetIcon`'s type 4 lights the same
## way with a single `base + 1` (`0x0043a259`).
const BUTTON_LIT_OFFSET: int = 3
const ICON_LIT_OFFSET: int = 1
## The `Library` columns the shipped windows ask for.
##
## `GUI_SetListbox` composes exactly as a button does -- `0x0043D610` builds
## the same type-3 gadget -- and `Menu_a.lcl`'s *Leveloptions* names three
## bases for one list: 12 for the top row, 18 for every row between and 24 for
## the last, each a trio of 32x22 pieces with its own lit twin three along.
const BUTTON_BASE_ACTION: int = 0
const BUTTON_BASE_FIELD: int = 6
const BUTTON_BASE_LIST_FIRST: int = 12
const BUTTON_BASE_LIST_MIDDLE: int = 18
const BUTTON_BASE_LIST_LAST: int = 24

var _cache_dir: String = ""
var _index: Dictionary = {}
var _textures: Dictionary = {}
## library name -> its `sprites` array out of the index.
var _libraries: Dictionary = {}


static func open(cache_dir: String) -> Art:
	var art: Art = Art.new()
	art._cache_dir = cache_dir
	art._index = CacheLoader.read_json(cache_dir + "/" + INDEX_PATH)
	for entry: Variant in DictRead.as_array(art._index.get("libraries", [])):
		var row: Dictionary = entry
		art._libraries[DictRead.as_string(row["name"])] = \
			DictRead.as_array(row["sprites"])
	return art


## Whether the cache carries the art at all. A cache from an older converter
## does not, and a screen then draws its frame and its text without pictures
## rather than failing to open.
func has_art() -> bool:
	return not _index.is_empty()


func plate(name: String) -> Texture2D:
	return _texture("%s/%s.png" % [PLATE_DIR, name])


func briefing_picture(name: String) -> Texture2D:
	return _texture("%s/%s.png" % [BRIEFING_DIR, name.to_lower()])


## One sprite out of an interface library, by index.
func sprite(library: String, index: int) -> Texture2D:
	var sprites: Array = DictRead.as_array(_libraries.get(library, []))
	if index < 0 or index >= sprites.size():
		return null
	var row: Dictionary = sprites[index]
	var file: Variant = row["file"]
	if file == null:
		# An empty element: the library has the slot and no pixels. Not a
		# failure -- `lib_extract` records the same shape.
		return null
	return _texture("%s/%s/%s" % [UI_DIR, library, DictRead.as_string(file)])


func sprite_count(library: String) -> int:
	return DictRead.as_array(_libraries.get(library, [])).size()


## The offset a sprite is drawn at -- `delta_x`/`delta_y` out of the library.
func sprite_offset(library: String, index: int) -> Vector2i:
	var sprites: Array = DictRead.as_array(_libraries.get(library, []))
	if index < 0 or index >= sprites.size():
		return Vector2i.ZERO
	var row: Dictionary = sprites[index]
	return Vector2i(DictRead.as_int(row["x"]), DictRead.as_int(row["y"]))


## A button face of *width* middle segments, composed the way `aBuildGUI` draws
## one: the left cap, that many copies of the middle, then the right cap.
##
## **Edge to edge, and *width* is already the middle count.** `0x0043A9D0` is
## the engine's own measurement: it takes the left cap's width, adds the
## middle's `Width - 2` times and the right cap's once, and subtracts nothing
## anywhere. `Menu_b.lcl` writes the count as `6_Width`, so the four middles of
## [constant CampaignScreen.GUI_BUTTON_WIDTH] make 27 + 4*31 + 18 = 169 --
## which is what `screens.button_face_width` pins. An earlier reading here had
## the pieces overlapping by a column, on piece widths that were not these.
##
## Cached under a name of its own, because a composed face is an [Image] walk
## and these screens rebuild on every click.
func button_face(base: int, width: int, lit: bool = false) -> Texture2D:
	var key: String = "composed/button-%d-%d-%s" % [base, width, str(lit)]
	if _textures.has(key):
		return _textures[key]
	var shift: int = base + (BUTTON_LIT_OFFSET if lit else 0)
	var left: Image = _sprite_image(shift + BUTTON_LEFT)
	var middle: Image = _sprite_image(shift + BUTTON_MIDDLE)
	var right: Image = _sprite_image(shift + BUTTON_RIGHT)
	if left == null or middle == null or right == null:
		_textures[key] = null
		return null
	var fills: int = maxi(width - 2, 0)
	var span: int = left.get_width() + fills * middle.get_width() \
		+ right.get_width()
	var tall: int = maxi(left.get_height(),
		maxi(middle.get_height(), right.get_height()))
	var face: Image = Image.create_empty(span, tall, false,
		Image.FORMAT_RGBA8)
	var at: int = _blit(face, left, 0)
	for _piece: int in range(fills):
		at = _blit(face, middle, at)
	at = _blit(face, right, at)
	var texture: ImageTexture = ImageTexture.create_from_image(face)
	_textures[key] = texture
	return texture


## Draw *piece* into *face* at *at*, and answer where the next one goes.
static func _blit(face: Image, piece: Image, at: int) -> int:
	face.blend_rect(piece, Rect2i(Vector2i.ZERO, piece.get_size()),
		Vector2i(at, 0))
	return at + piece.get_width()


func _sprite_image(index: int) -> Image:
	var texture: Texture2D = sprite(BUTTON_LIBRARY, index)
	if texture == null:
		return null
	return texture.get_image()


func _texture(relative: String) -> Texture2D:
	if _textures.has(relative):
		return _textures[relative]
	var path: String = _cache_dir + "/" + relative
	if not FileAccess.file_exists(path):
		_textures[relative] = null
		return null
	var image: Image = Image.new()
	var loaded: Error = image.load_png_from_buffer(
		FileAccess.get_file_as_bytes(path))
	if loaded != OK:
		_textures[relative] = null
		return null
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	_textures[relative] = texture
	return texture
