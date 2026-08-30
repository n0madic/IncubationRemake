class_name CharismaLibrary
extends RefCounted

## Which body and which clips a unit gets, and one copy of each in memory.
##
## The four selectors of docs/40 section 7.2 are not re-derived here. They were
## read out of `Incubation.exe` by `tools/inclib/charisma_tables.py` -- an
## interpreter over the `switch` cascades themselves -- and the converter
## copies the result into `tables/charisma.json`, so the player prefixes, the
## hero rewrite and the neutral player's refusal have **one** reading in this
## repository rather than two. This class looks the answer up.
##
## **An absent name is data, not a gap.** The document deliberately carries an
## explicit `null` where a selector returns nothing, and it does so for real
## reasons the engine has: player `0xFC` gets no body at all, the Spider walks
## with no idle and no fire, and the Norc'Yn's two detachable arms have no clip
## of any family -- which fits docs/40 section 6, where a limb aimed by an
## `External*Movement` is driven by the game writing a matrix rather than by a
## clip. Nine unit types are in that state. A caller must handle `""`.
##
## Everything is cached per mission: `UnitsView.build` frees and rebuilds every
## unit node on each fog change, and re-parsing a 26-part body or re-building
## its meshes each time would be a cost this slice invented for itself.

## The selectors, by the name the cache uses.
const SELECTOR_MODEL: String = "model"
const SELECTOR_MOVE: String = "move"
const SELECTOR_IDLE: String = "idle"
const SELECTOR_FIRE: String = "fire"

var _cache_dir: String = ""
var _selectors: Dictionary = {}
var _models: Dictionary[String, CharismaModel] = {}
var _clips: Dictionary[String, CharismaClip] = {}
var _meshes: Dictionary[String, ArrayMesh] = {}
var _unit_geometry: Dictionary = {}
var _textures: Dictionary = {}
## Names the cache does not carry, reported once rather than per rebuild.
var _missing: PackedStringArray = PackedStringArray()


static func open(cache_dir: String, textures: Dictionary) -> CharismaLibrary:
	var library: CharismaLibrary = CharismaLibrary.new()
	library._cache_dir = cache_dir
	library._textures = textures
	library._selectors = CacheLoader.read_json(
		cache_dir + "/tables/charisma.json")
	library._unit_geometry = DictRead.as_dict(CacheLoader.read_json(
		cache_dir + "/geometry/units.json").get("prototypes", {}))
	return library


## True when the cache carries the bodies at all -- a cache built by an older
## converter does not, and the caller falls back rather than failing.
func is_ready() -> bool:
	return not _selectors.is_empty() and not _unit_geometry.is_empty()


## The name one selector returns for a unit, or `""` when it returns nothing.
##
## `roll` is a presentation random draw in `[0, 10)`. Exactly one arm of the
## idle selector uses it (`0x0042DF77`, comparing `frand(0, 10)` against the
## `5.0` at `0x004B1380`) and the cache carries that condition rather than a
## probability, so the choice is reproduced instead of invented. Every other
## entry ignores it.
func name_for(selector: String, type_id: int, weapon: int, player: int,
		roll: float = 0.0) -> String:
	var table: Dictionary = DictRead.as_dict(_selectors.get(selector, {}))
	var entries: Dictionary = DictRead.as_dict(table.get("entries", {}))
	var key: String = "%d,%d,%d" % [type_id, weapon, player]
	if not entries.has(key):
		return ""
	var outcomes: Array = DictRead.as_array(entries[key])
	for entry: Variant in outcomes:
		var outcome: Dictionary = DictRead.as_dict(entry)
		if not outcome.has("branches"):
			return _name_of(outcome)
		var branches: Array = DictRead.as_array(outcome["branches"])
		if branches.is_empty():
			continue
		var branch: Dictionary = DictRead.as_dict(branches[0])
		var below: bool = roll <= DictRead.as_float(branch["threshold"])
		if below == (DictRead.as_string(branch["taken"]) == "below_or_equal"):
			return _name_of(outcome)
	return ""


## An outcome's name, with a **present but null** one read as "no name".
##
## `get("name", "")` is not enough and the difference is the whole point of the
## document's shape: the converter writes an explicit `null` where a selector
## returns nothing, so the key is there and the default never fires. Player
## `0xFC` is the first unit built on `_C_140` and it took this straight to a
## "cannot return Nil as String" the moment a body was first drawn.
static func _name_of(outcome: Dictionary) -> String:
	var value: Variant = outcome.get("name", null)
	return "" if value == null else DictRead.as_string(value)


func model(model_name: String) -> CharismaModel:
	if model_name == "":
		return null
	if _models.has(model_name):
		return _models[model_name]
	var document: Dictionary = _read("models/%s.json" % model_name)
	var loaded: CharismaModel = null if document.is_empty() \
		else CharismaModel.from_document(document)
	if loaded == null:
		_note_missing(model_name)
	_models[model_name] = loaded
	return loaded


func clip(clip_name: String) -> CharismaClip:
	if clip_name == "":
		return null
	if _clips.has(clip_name):
		return _clips[clip_name]
	var document: Dictionary = _read("animations/%s.json" % clip_name)
	var loaded: CharismaClip = null if document.is_empty() \
		else CharismaClip.from_document(document)
	if loaded == null:
		_note_missing(clip_name)
	_clips[clip_name] = loaded
	return loaded


## One part's [ArrayMesh], built once and shared by every body that draws it.
##
## `P0_000_KOPF` is one mesh whether one marine or ten are on the map, and a
## body is up to 130 parts. Building per instance is the difference between
## one mesh build and a hundred on every fog change.
func mesh(mesh_name: String) -> ArrayMesh:
	if mesh_name == "":
		return null
	if _meshes.has(mesh_name):
		return _meshes[mesh_name]
	var built: ArrayMesh = null
	if _unit_geometry.has(mesh_name):
		built = MeshBuilder.build(
			DictRead.as_dict(_unit_geometry[mesh_name]), _textures)
	else:
		_note_missing(mesh_name)
	_meshes[mesh_name] = built
	return built


## What the cache could not supply, for the status line to say once.
func missing() -> PackedStringArray:
	return _missing.duplicate()


func _note_missing(what: String) -> void:
	if not _missing.has(what):
		_missing.append(what)


func _read(relative: String) -> Dictionary:
	var path: String = _cache_dir + "/" + relative
	if not FileAccess.file_exists(path):
		return {}
	return CacheLoader.read_json(path)
