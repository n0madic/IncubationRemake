class_name CachePaths
extends RefCounted

## Where one cache-relative file is read from, for one language -- docs/92
## section 7.6.
##
## The cache holds every language at once: the base data at its neutral paths
## and each **language pack** mirrored under `lang/<Name>/`, holding only the
## files that differ from the neutral ones (`tools/inclib/convert.py`,
## `convert_language_pack`). So a reader asks this for `text/gui.json` and
## gets `lang/Russian/text/gui.json` when the pack carries one and the neutral
## file otherwise -- per file, out of the manifest's inventory, **without a
## filesystem probe**: the manifest already lists every path the cache holds,
## and a probe would make a cache with a stray file behave differently from
## the one its manifest describes.
##
## Pure and engine-free apart from the path strings; nothing here opens a
## file. Every loader in `game/` takes one of these instead of a bare
## `cache_dir`, so the language decision is made in one place.

## The prefix a pack's files live under, before the language name.
const LANG_DIR: String = "lang"
## The pack's names document (`incubation.names/1`).
const NAMES_DOCUMENT: String = "names.json"

var cache_dir: String = ""
## The language every path resolves for. The base language when no pack was
## chosen, or when the one asked for is not in the manifest.
var language: String = ""
## True when *language* was not one the manifest lists and the base is used
## instead -- the caller says so, this only records it.
var fallback: bool = false
var _base: String = ""
var _languages: PackedStringArray = PackedStringArray()
## The pack's relative paths, without the `lang/<Name>/` prefix.
var _pack_files: Dictionary = {}
var _names: Dictionary = {}
var _names_read: bool = false


## Build from a verified cache: *manifest* is what [CacheLoader] returned.
##
## An empty *wanted* means the base language. A name the manifest does not
## list falls back to the base with [member fallback] set, so a settings file
## naming a language the current cache lacks still starts the game.
static func create(directory: String, manifest: Dictionary,
		wanted: String = "") -> CachePaths:
	var out: CachePaths = CachePaths.new()
	out.cache_dir = directory
	out._base = DictRead.as_string(manifest.get("language", ""))
	out._languages = DictRead.to_strings(manifest.get("languages", []))
	if out._languages.is_empty() and out._base != "":
		out._languages.append(out._base)
	out.language = out._base
	if wanted != "" and wanted != out._base:
		if out._languages.has(wanted):
			out.language = wanted
		else:
			out.fallback = true
	if out.language != out._base:
		var prefix: String = "%s/%s/" % [LANG_DIR, out.language]
		for entry: Variant in DictRead.as_array(manifest.get("inventory", [])):
			var record: Dictionary = DictRead.as_dict(entry)
			var rel: String = DictRead.as_string(record.get("path", ""))
			if rel.begins_with(prefix):
				out._pack_files[rel.substr(prefix.length())] = true
	return out


## The base language the cache was converted from.
func base_language() -> String:
	return _base


## Whether any pack file is resolved for the chosen language.
func has_pack() -> bool:
	return not _pack_files.is_empty()


## Every language the cache offers, the base first. A copy: the caller may
## not reach the manifest's list through it.
func languages() -> PackedStringArray:
	return _languages.duplicate()


## The absolute path *rel* is read from: the pack's copy when it carries one,
## the neutral file otherwise.
func path(rel: String) -> String:
	if _pack_files.has(rel):
		return "%s/%s/%s/%s" % [cache_dir, LANG_DIR, language, rel]
	return "%s/%s" % [cache_dir, rel]


## Whether *rel* resolves to a pack file rather than the neutral one.
func is_pack_file(rel: String) -> bool:
	return _pack_files.has(rel)


## The neutral path of *rel*, regardless of the language.
func neutral_path(rel: String) -> String:
	return "%s/%s" % [cache_dir, rel]


## The pack's `names.json`, read once; empty for the base language and for a
## pack without one. See [method apply_balance_names] and
## [method apply_unit_names].
func names() -> Dictionary:
	if not _names_read:
		_names_read = true
		if _pack_files.has(NAMES_DOCUMENT):
			_names = CacheLoader.read_json(path(NAMES_DOCUMENT))
	return _names


## `tables/balance.json` with the pack's unit, weapon, equipment and cell-type
## names written over the base's. The tables' numbers are the base's by
## construction -- the converter refuses a pack whose balance differs in
## anything but a name -- so this touches only the four name columns.
##
## **Before [method World.create]**: [method UnitState.generate] fills a
## spawned unit's name from `types.description`, so a world built on the
## un-overlaid table would speak the base language for every reinforcement.
## Names enter no hash ([method UnitState.hash_into] skips `name`), so the
## overlay moves no canonical hash and no campaign digest.
func apply_balance_names(balance: Dictionary) -> Dictionary:
	var overlay: Dictionary = DictRead.as_dict(names().get("balance", {}))
	if overlay.is_empty():
		return balance
	var out: Dictionary = balance.duplicate(true)
	_overlay_rows(out, overlay, "units", "id", "description")
	_overlay_rows(out, overlay, "weapons", "id", "name")
	_overlay_rows(out, overlay, "equipment", "id", "name")
	_overlay_rows(out, overlay, "ctrlmap", "index", "name")
	return out


## A mission's `map.json` with the pack's unit names written over the base's,
## by slot. Only slots the pack's own `.lev` carried an otherwise identical
## record for are listed, so a map the localised release ships in an older
## authored state keeps the base's names where the records differ.
func apply_unit_names(mission: String, map_document: Dictionary) -> Dictionary:
	var missions: Dictionary = DictRead.as_dict(names().get("missions", {}))
	if not missions.has(mission):
		return map_document
	var by_slot: Dictionary = DictRead.as_dict(missions[mission])
	if by_slot.is_empty():
		return map_document
	var out: Dictionary = map_document.duplicate(true)
	var units: Array = DictRead.as_array(out.get("units", []))
	for entry: Variant in units:
		var unit: Dictionary = DictRead.as_dict(entry)
		var key: String = str(DictRead.as_int(unit.get("slot", -1)))
		if by_slot.has(key):
			unit["name"] = DictRead.as_string(by_slot[key])
	return out


static func _overlay_rows(balance: Dictionary, overlay: Dictionary,
		table: String, id_field: String, column: String) -> void:
	var by_id: Dictionary = DictRead.as_dict(overlay.get(table, {}))
	if by_id.is_empty():
		return
	for entry: Variant in DictRead.as_array(balance.get(table, [])):
		var row: Dictionary = DictRead.as_dict(entry)
		var key: String = str(DictRead.as_int(row.get(id_field, -1)))
		if by_id.has(key):
			row[column] = DictRead.as_string(by_id[key])
