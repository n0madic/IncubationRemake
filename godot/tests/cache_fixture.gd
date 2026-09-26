class_name CacheFixture
extends RefCounted

## Finds the cache the suites read, the way the game finds its own.
##
## A build reads its data from `res://data/cache` (or a player's
## `user://caches/<id>/`); the development tree `res://generated/cache/` exists
## so the map, the meshes and the tables can be looked at in the editor and in
## external tools.  docs/92 section 10.1 item 4 asks
## that the *portable logical data* be diffed rather than an incidental Godot
## serialisation -- and there is none to diff around, because the two trees come
## out of the same function.

const SLICE_MISSION: String = "_C_115"

## Where the answer of the first [method cache_dir] call is kept for the rest
## of the process.
##
## Opening a cache used to **verify the whole of it**: every file read and
## SHA-256'd, about a third of a second over a 100 MB campaign publish -- and
## every accessor below used to open one, which is why a run spent two thirds
## of its wall clock hashing the same bytes over and over (charisma alone:
## 68.4 s of its 72.0 s, for 0.5 s of actual posing).  Start-up now runs only
## [method CacheLoader.quick_check], and the full sweep is `test_cache.gd`'s;
## the answer is still found once and kept, because the cache does not change
## while the suites run -- nothing under `tests/` publishes or writes one.
##
## It is deliberately **not** a `static var`: a script that declares one is kept
## for the life of the process together with every script it names, and this one
## names [CacheLoader] and [World], which is most of `core/` and `game/`.  The
## exported `run_tests` build gates on exactly that (`N resources still in use at
## exit`) and `run_tests.sh` cannot see it.  A [String] on the [Engine]
## singleton's metadata holds no script reference and so cannot leak one.
const CACHE_DIR_META: StringName = &"incubation_test_cache_dir"


## The cache these fixtures read, in the game's own order
## ([method CacheLoader.locate]; `--cache=DIR` on the test run forces one).
##
## Found on the first call and remembered after it; see
## [constant CACHE_DIR_META].  `test_cache.gd` calls [method CacheLoader.verify]
## directly and is unaffected -- the refusal cases it covers are still measured
## against the real manifest.
static func cache_dir() -> String:
	if Engine.has_meta(CACHE_DIR_META):
		return DictRead.as_string(Engine.get_meta(CACHE_DIR_META))
	var opened: Dictionary = CacheLoader.locate(OS.get_cmdline_user_args())
	var dir: String = CacheLoader.DEV_CACHE
	if DictRead.as_bool(opened["ok"]):
		dir = DictRead.as_string(opened["cache_dir"])
	Engine.set_meta(CACHE_DIR_META, dir)
	return dir


static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return DictRead.as_dict(parsed)


static func manifest() -> Dictionary:
	return read_json(cache_dir() + "/manifest.json")


## The fixture cache's resolver for its **base** language: what every loader
## in `game/` takes instead of a bare directory (docs/92 section 7.6). A
## suite that wants a pack builds a [CachePaths] of its own from a hand-made
## manifest; the fixture is converted without one.
static func paths(language: String = "") -> CachePaths:
	return CachePaths.create(cache_dir(), manifest(), language)


static func balance() -> Dictionary:
	return read_json(cache_dir() + "/tables/balance.json")


static func mission(name: String) -> Dictionary:
	return read_json("%s/missions/%s/map.json" % [cache_dir(), name])


static func geometry(world_set: String) -> Dictionary:
	return read_json("%s/geometry/%s.json" % [cache_dir(), world_set])


static func texture_index(world_set: String) -> Dictionary:
	return read_json("%s/textures/%s/index.json" % [cache_dir(), world_set])


## `{"world": World, "document": Dictionary}`, or empty when the cache is absent.
static func load_world(name: String) -> Dictionary:
	var document: Dictionary = mission(name)
	var tables: Dictionary = balance()
	if document.is_empty() or tables.is_empty():
		return {}
	return {"world": World.create(document, tables, 1.0), "document": document}


static func load_slice_world() -> Dictionary:
	return load_world(SLICE_MISSION)


## The mission program, as `missions/<name>/script.json` holds it.
static func script_document(name: String) -> Dictionary:
	return read_json("%s/missions/%s/script.json" % [cache_dir(), name])


## A world with its mission program attached -- what a mission actually is.
##
## Separate from [method load_world] because the first slice had no
## interpreter, and a fixture that silently attached one would change what every
## suite built on it is testing.
static func load_mission(name: String) -> Dictionary:
	var loaded: Dictionary = load_world(name)
	if loaded.is_empty():
		return {}
	var world: World = loaded["world"]
	var attached: bool = world.attach_script(script_document(name))
	loaded["script_attached"] = attached
	return loaded
