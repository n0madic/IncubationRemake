class_name CacheFixture
extends RefCounted

## Loads the development cache from `res://generated/cache/`.
##
## Production reads exactly the same bytes from `user://caches/<id>/`; the
## development tree exists so the map, the meshes and the tables can be looked
## at in the editor and in external tools.  docs/92 section 10.1 item 4 asks
## that the *portable logical data* be diffed rather than an incidental Godot
## serialisation -- and there is none to diff around, because the two trees come
## out of the same function.

## The development tree.  Production is `user://caches/<id>/`, and that is
## looked at first: an exported build has no `res://generated/`, and the point
## of running the suites inside one is that they read what the game reads.
const DEV_CACHE_DIR: String = "res://generated/cache"
const SLICE_MISSION: String = "_C_115"


## The cache these fixtures read, production first.
static func cache_dir() -> String:
	var opened: Dictionary = CacheLoader.open_active()
	if DictRead.as_bool(opened["ok"]):
		return DictRead.as_string(opened["cache_dir"])
	return DEV_CACHE_DIR


static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return DictRead.as_dict(parsed)


static func manifest() -> Dictionary:
	return read_json(cache_dir() + "/manifest.json")


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
