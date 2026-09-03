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
