class_name SequenceLibrary
extends CharismaLibrary

## One `Video/<dir>/` directory of the cache, as the bodies see a world set.
##
## A cutscene is a Charisma scene like a unit's body is (docs/41 section 1):
## a `.cho` naming meshes, a `.cha` driving its bones. What differs is where
## the meshes come from -- each directory ships its own `Objects/Prototyp.*`
## and `Textures/Texture.*`, which the converter writes under
## `sequences/<dir>/` and `textures/video_<dir>/` -- so this is
## [CharismaLibrary] pointed at that directory rather than a second loader:
## [method CharismaLibrary.model] reads `models/<name>.json` under the root it
## is given, [method CharismaLibrary.clip] `animations/<name>.json`, and
## [method CharismaLibrary.mesh] the geometry it was opened with.
##
## One instance per directory, freed with the part that opened it: `Seq_3` is
## 34 models over 1300 meshes, and a part's scenes are never on screen at the
## same time as another's.

## Where the converter puts a directory, relative to the cache root.
const SEQUENCES_DIR: String = "sequences"

## The directory this library reads -- `Seq_1`, `Dialog_09`, ...
var directory: String = ""
## `sequences/<dir>/index.json`, kept for what it lists.
var index: Dictionary = {}


## Open one directory, or `null` when the cache does not carry it -- a cache
## published by a converter before 0.29.0.
static func open_directory(cache_dir: String,
		video_directory: String) -> SequenceLibrary:
	var base: String = "%s/%s/%s" % [cache_dir, SEQUENCES_DIR, video_directory]
	var listing: Dictionary = CacheLoader.read_json(base + "/index.json")
	if listing.is_empty():
		return null
	var library: SequenceLibrary = SequenceLibrary.new()
	library.directory = video_directory
	library.index = listing
	# The base class reads `models/` and `animations/` under its root, which
	# is exactly how the converter lays a directory out.
	library._cache_dir = base
	library._rng.seed = hash(video_directory)
	var geometry: Dictionary = CacheLoader.read_json(base + "/geometry.json")
	library._unit_geometry = DictRead.as_dict(geometry.get("prototypes", {}))
	var texture_set: String = DictRead.as_string(listing.get("texture_set", ""))
	var textures: Dictionary = CacheLoader.read_json(
		"%s/textures/%s/index.json" % [cache_dir, texture_set])
	library._textures = MeshBuilder.load_textures(cache_dir, texture_set,
		textures)
	return library


## The models the directory carries, in the converter's order.
func model_names() -> PackedStringArray:
	return DictRead.to_strings(index.get("models", []))


## The clips the directory carries.
func animation_names() -> PackedStringArray:
	return DictRead.to_strings(index.get("animations", []))


## Whether the geometry document resolved every mesh the models name.
func mesh_count() -> int:
	return _unit_geometry.size()
