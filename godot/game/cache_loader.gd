class_name CacheLoader
extends RefCounted

## The only code in the remake that touches the filesystem.
##
## It reads `user://caches/active.json`, then the cache that names, and verifies
## the **whole** inventory -- every declared path present, the right size and
## the right SHA-256 -- before anything is loaded from it.  That happens on
## every load: a full pass over roughly two megabytes costs a few milliseconds,
## and verifying only once would make "a partial cache is never accepted" a
## statement about the happy path.
##
## Refusal is by name, never by loading something almost right:
## `active.json` absent means first run; a `cache_schema_version` or
## `converter_version` that is not this build's is refused; and any inventory
## entry that does not verify is refused.
##
## The converter is a CLI in this slice.  docs/92 section 9 defers the Python
## packaging and section 10.1 only asks that the converter be pointed at an
## installation, so the game consumes a published cache and prints the command
## to run when there is none.

## Must match `inclib/cache.py`.
const CACHE_SCHEMA_VERSION: int = 1
const CONVERTER_VERSION: String = "0.6.0"

const CACHES_DIR: String = "user://caches"
const ACTIVE_NAME: String = "active.json"
const MANIFEST_NAME: String = "manifest.json"

## What the game prints when there is no cache.  A diagnosable first run
## (docs/92 section 9) means naming the command, not just the failure.
const FIRST_RUN_HINT: String = \
	"No converted data yet.  Run:\n" + \
	"    python3 tools/remake_convert.py <game-install> -o %s"


static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return DictRead.as_dict(parsed)


static func active_cache_dir(caches_dir: String = CACHES_DIR) -> String:
	var pointer: Dictionary = read_json(caches_dir + "/" + ACTIVE_NAME)
	# A pointer that parses but does not carry a `cache_id` is refused by
	# name, like every other malformed input here.  Testing only
	# `is_empty()` let a non-empty dict of the wrong shape -- a future or
	# half-written pointer schema -- reach `pointer["cache_id"]` and take
	# the whole load down with a runtime error from a function typed
	# `-> String`, which is exactly the "loading something almost right"
	# this file's contract rules out.
	if not pointer.has("cache_id"):
		return ""
	var cache_id: String = DictRead.as_string(pointer["cache_id"])
	if cache_id.is_empty():
		return ""
	return "%s/%s" % [caches_dir, cache_id]


## Every reason to refuse this cache; empty means it is good.
static func verify(cache_dir: String, manifest: Dictionary) -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if manifest.is_empty():
		problems.append("no %s; it is not a cache" % MANIFEST_NAME)
		return problems
	if DictRead.as_int(manifest.get("cache_schema_version", -1)) \
			!= CACHE_SCHEMA_VERSION:
		problems.append("cache schema %s != %d"
			% [manifest.get("cache_schema_version", "-"), CACHE_SCHEMA_VERSION])
	if DictRead.as_string(manifest.get("converter_version", "")) \
			!= CONVERTER_VERSION:
		problems.append("converter %s != %s"
			% [manifest.get("converter_version", "-"), CONVERTER_VERSION])
	var inventory: Array = DictRead.as_array(manifest.get("inventory", []))
	if inventory.is_empty():
		problems.append("the manifest declares no files")
	for entry: Variant in inventory:
		var record: Dictionary = DictRead.as_dict(entry)
		var rel: String = DictRead.as_string(record["path"])
		var path: String = cache_dir + "/" + rel
		if not FileAccess.file_exists(path):
			problems.append("%s: missing" % rel)
			continue
		var data: PackedByteArray = FileAccess.get_file_as_bytes(path)
		if data.size() != DictRead.as_int(record["size"]):
			problems.append("%s: %d bytes, expected %d"
				% [rel, data.size(), DictRead.as_int(record["size"])])
			continue
		if _sha256(data) != DictRead.as_string(record["sha256"]):
			problems.append("%s: digest mismatch" % rel)
	return problems


## `{"ok": bool, "reason": String, "cache_dir": String, "manifest": Dictionary}`.
static func open_active(caches_dir: String = CACHES_DIR) -> Dictionary:
	var cache_dir: String = active_cache_dir(caches_dir)
	if cache_dir == "":
		return {"ok": false, "reason": FIRST_RUN_HINT % caches_dir,
			"cache_dir": "", "manifest": {}}
	var manifest: Dictionary = read_json(cache_dir + "/" + MANIFEST_NAME)
	var problems: PackedStringArray = verify(cache_dir, manifest)
	if not problems.is_empty():
		return {"ok": false,
			"reason": "cache %s refused: %s" % [cache_dir, ", ".join(problems)],
			"cache_dir": cache_dir, "manifest": manifest}
	return {"ok": true, "reason": "", "cache_dir": cache_dir,
		"manifest": manifest}


static func _sha256(data: PackedByteArray) -> String:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	ctx.update(data)
	return ctx.finish().hex_encode()
