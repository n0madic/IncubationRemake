class_name CacheLoader
extends RefCounted

## The only code in the remake that decides *which* cache is read.
##
## [method locate] walks the sources in a fixed order and opens the first that
## exists; a source that exists but does not check out is refused by name
## rather than skipped, so a broken cache is never papered over by another:
##
## 1. `--cache=DIR` -- development: force a directory, whatever else is there;
## 2. `res://data/cache` -- the data a build carries in its own package;
## 3. `user://caches/<id>` named by `user://caches/active.json` -- what the
##    player converts themselves for a build made with `NO_CACHE=1`.
##
## **Start-up checks shape, not bytes:** [method quick_check] reads the
## versions and each entry's presence and length; the SHA-256 sweep,
## [method verify], runs only on request (`--verify-cache`) and in the suites.
## docs/92 section 3.2 has the order's reasons, how the data reaches the
## package, and what each check costs.
##
## Refusal is by name, never by loading something almost right.

## Must match `inclib/cache.py`.
const CACHE_SCHEMA_VERSION: int = 1
const CONVERTER_VERSION: String = "0.46.0"

const CACHES_DIR: String = "user://caches"
const ACTIVE_NAME: String = "active.json"
const MANIFEST_NAME: String = "manifest.json"
## The data a build carries in its own package (`make data`, docs/92 3.2).
const BUNDLED_CACHE: String = "res://data/cache"
## `--cache=DIR` opens that directory and nothing else.
const CACHE_ARG: String = "--cache="
## `--verify-cache` makes the start-up check the full SHA-256 sweep.
const VERIFY_ARG: String = "--verify-cache"

## What the game prints when there is no cache.  A diagnosable first run
## (docs/92 section 9) means naming the command, not just the failure.
const FIRST_RUN_HINT: String = \
	"No converted data yet.  In a checkout run `make data`; otherwise:\n" + \
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


## Every reason to refuse this cache; empty means it is good.  The full
## sweep: every file is read and its SHA-256 recomputed.
static func verify(cache_dir: String, manifest: Dictionary) -> PackedStringArray:
	return _problems(cache_dir, manifest, true)


## Every reason to refuse this cache that can be found without reading its
## files: the versions, and each inventory entry's presence and length.
static func quick_check(cache_dir: String, manifest: Dictionary) \
		-> PackedStringArray:
	return _problems(cache_dir, manifest, false)


## Opens the cache in `cache_dir`: the quick check, or the full sweep when
## `full` is set.
## `{"ok": bool, "reason": String, "cache_dir": String, "manifest": Dictionary}`.
static func open_dir(cache_dir: String, full: bool = false) -> Dictionary:
	var manifest: Dictionary = read_json(cache_dir + "/" + MANIFEST_NAME)
	var problems: PackedStringArray = verify(cache_dir, manifest) if full \
		else quick_check(cache_dir, manifest)
	if not problems.is_empty():
		return {"ok": false,
			"reason": "cache %s refused: %s" % [cache_dir, ", ".join(problems)],
			"cache_dir": cache_dir, "manifest": manifest}
	return {"ok": true, "reason": "", "cache_dir": cache_dir,
		"manifest": manifest}


## The first cache source that exists, in the order the header gives, opened.
## `args` are the command-line arguments (`--cache=`, `--verify-cache`); the
## other parameters exist so the suites can walk the order over directories
## of their own.
static func locate(args: PackedStringArray,
		bundled: String = BUNDLED_CACHE,
		caches_dir: String = CACHES_DIR) -> Dictionary:
	var full: bool = args.has(VERIFY_ARG)
	var forced: String = forced_dir(args)
	if not forced.is_empty():
		return open_dir(forced, full)
	if has_manifest(bundled):
		return open_dir(bundled, full)
	var active: String = active_cache_dir(caches_dir)
	if not active.is_empty():
		return open_dir(active, full)
	return {"ok": false, "reason": FIRST_RUN_HINT % caches_dir,
		"cache_dir": "", "manifest": {}}


## The directory `--cache=DIR` names, or `""` when no argument does.
static func forced_dir(args: PackedStringArray) -> String:
	for arg: String in args:
		if arg.begins_with(CACHE_ARG):
			return arg.trim_prefix(CACHE_ARG)
	return ""


## **The manifest, not the directory**, says a cache is there: an interrupted
## `make data` leaves the directory standing with nothing in it.
static func has_manifest(cache_dir: String) -> bool:
	return FileAccess.file_exists(cache_dir + "/" + MANIFEST_NAME)


static func _problems(cache_dir: String, manifest: Dictionary, full: bool) \
		-> PackedStringArray:
	var problems: PackedStringArray = _document_problems(manifest)
	# **A cache already refused by name is not swept.**  A missing manifest or
	# a wrong version refuses the whole cache, so the sweep below could only add
	# per-file noise to a message that is already decided -- and a cache
	# another converter built is *expected* to differ file by file.
	if not problems.is_empty():
		return problems
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
		# The static size is a stat, not an open: 30 ms over the 3 742-file
		# bundled cache where opening each file took 100 to 400.
		var length: int = FileAccess.get_size(path)
		# **Android has no stat for a file inside the APK**: `get_size` answers
		# -1 for every `res://` asset there, stored or deflated alike, while an
		# opened file reports its length (Godot 4.7.2, API 36 emulator,
		# 2026-09-26). So there, and only where the stat fails, the file is
		# opened.
		if length < 0:
			var file: FileAccess = FileAccess.open(path, FileAccess.READ)
			if file != null:
				length = file.get_length()
				file.close()
		if length != DictRead.as_int(record["size"]):
			problems.append("%s: %d bytes, expected %d"
				% [rel, length, DictRead.as_int(record["size"])])
			continue
		if full and sha256_hex(FileAccess.get_file_as_bytes(path)) \
				!= DictRead.as_string(record["sha256"]):
			problems.append("%s: digest mismatch" % rel)
	return problems


static func _document_problems(manifest: Dictionary) -> PackedStringArray:
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
	return problems


static func sha256_hex(data: PackedByteArray) -> String:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	ctx.update(data)
	return ctx.finish().hex_encode()
