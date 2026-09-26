extends TestSuite

## Oracle boundary: specification-only.  docs/92 section 10.4, the cache half.
##
## The Python side owns the transactional publish and proves it on a temporary
## directory (`tools/remake_convert.py --check-cache`).  What has to be proved
## **here** is the other half of the same contract: the loader refuses a cache
## whose inventory does not verify -- by shape at every start
## ([method CacheLoader.quick_check]) and byte for byte on request
## ([method CacheLoader.verify]) -- and [method CacheLoader.locate] picks the
## source in a fixed order and refuses a broken one instead of skipping it.
##
## **The sweeps below are the expensive part of this suite** -- 342 ms each over
## a 100 MB campaign publish -- and four of the six reach the inventory, which
## is what they are for.  The other two do not: a `cache_schema_version` or a
## `converter_version` that is not this build's refuses the cache by name, and
## [method CacheLoader.verify] returns on that without hashing anything.  Both
## are asserted by the *reason* they come back with, so the early return is
## covered rather than merely permitted.  A caller that is not testing the
## refusals opens the cache once and keeps the answer ([CacheFixture]).

func run(h: TestHarness) -> void:
	h.begin("cache", TestHarness.ORACLE_SPEC)
	# **The cache every suite reads, named.**  A refused one is this failure,
	# not a fallback to whatever other cache the machine happens to hold.
	h.equal("fixture.bundled", CacheFixture.refusal(), "",
		"suites read %s" % CacheFixture.cache_dir())
	var manifest: Dictionary = CacheFixture.manifest()
	if manifest.is_empty():
		return

	h.equal("manifest.schema",
		DictRead.as_string(manifest["schema"]), "incubation.cache-manifest/1")
	h.equal("manifest.cache_schema_version",
		DictRead.as_int(manifest["cache_schema_version"]),
		CacheLoader.CACHE_SCHEMA_VERSION)
	h.equal("manifest.converter_version",
		DictRead.as_string(manifest["converter_version"]),
		CacheLoader.CONVERTER_VERSION)

	var problems: PackedStringArray = CacheLoader.verify(
		CacheFixture.cache_dir(), manifest)
	h.equal("verify.clean", ", ".join(problems), "")

	# A manifest from the future is refused by name, not by failing to parse.
	var future: Dictionary = manifest.duplicate(true)
	future["cache_schema_version"] = CacheLoader.CACHE_SCHEMA_VERSION + 1
	var future_problems: PackedStringArray = CacheLoader.verify(
		CacheFixture.cache_dir(), future)
	h.check("verify.schema_refused",
		_any_contains(future_problems, "cache schema"),
		", ".join(future_problems))

	# **And it refuses without sweeping.**  This manifest is refused by name
	# *and* declares a file that is not there, so a sweep would report both;
	# only the name comes back.  Without this the early return in
	# [method CacheLoader.verify] would be permitted rather than checked --
	# removing it leaves every other case in this suite green and costs 342 ms
	# on every start-up that meets a stale cache.
	var future_and_missing: Dictionary = manifest.duplicate(true)
	future_and_missing["cache_schema_version"] = \
		CacheLoader.CACHE_SCHEMA_VERSION + 1
	DictRead.as_array(future_and_missing["inventory"]).append(
		{"path": "missions/_C_999/map.json", "size": 1, "sha256": "00"})
	h.equal("verify.schema_refused_without_sweeping",
		", ".join(CacheLoader.verify(CacheFixture.cache_dir(),
			future_and_missing)),
		"cache schema %d != %d" % [CacheLoader.CACHE_SCHEMA_VERSION + 1,
			CacheLoader.CACHE_SCHEMA_VERSION],
		"a cache refused by name is not hashed file by file")

	var other_converter: Dictionary = manifest.duplicate(true)
	other_converter["converter_version"] = "0.0.0-not-this-one"
	h.check("verify.converter_refused",
		_any_contains(CacheLoader.verify(CacheFixture.cache_dir(),
			other_converter), "converter"),
		"a cache built by another converter is refused")

	# A partial cache: claim a file that is not there, and claim a wrong size
	# for one that is.
	var missing: Dictionary = manifest.duplicate(true)
	var inventory: Array = DictRead.as_array(missing["inventory"])
	inventory.append({"path": "missions/_C_999/map.json", "size": 1,
		"sha256": "00"})
	h.check("verify.missing_file_refused",
		_any_contains(CacheLoader.verify(CacheFixture.cache_dir(), missing),
			"missing"),
		"a declared file that is absent is refused")

	var wrong_size: Dictionary = manifest.duplicate(true)
	var entries: Array = DictRead.as_array(wrong_size["inventory"])
	var first: Dictionary = DictRead.as_dict(entries[0])
	first["size"] = DictRead.as_int(first["size"]) + 1
	h.check("verify.size_refused",
		_any_contains(CacheLoader.verify(CacheFixture.cache_dir(), wrong_size),
			"bytes"),
		"a declared size that does not match is refused")

	var wrong_digest: Dictionary = manifest.duplicate(true)
	var digest_entries: Array = DictRead.as_array(wrong_digest["inventory"])
	var target: Dictionary = DictRead.as_dict(digest_entries[0])
	target["sha256"] = "0000000000000000000000000000000000000000000000000000000000000000"
	h.check("verify.digest_refused",
		_any_contains(CacheLoader.verify(CacheFixture.cache_dir(), wrong_digest),
			"digest"),
		"a declared digest that does not match is refused")

	# **The start-up check** refuses the same shapes without reading a byte of
	# data -- and, by construction, not a digest: that is the one fault left to
	# `--verify-cache` and to [method CacheLoader.verify] above.
	var dir: String = CacheFixture.cache_dir()
	h.equal("quick.clean", ", ".join(CacheLoader.quick_check(dir, manifest)), "")
	h.check("quick.version_refused",
		_any_contains(CacheLoader.quick_check(dir, other_converter), "converter"))
	h.check("quick.missing_file_refused",
		_any_contains(CacheLoader.quick_check(dir, missing), "missing"))
	h.check("quick.size_refused",
		_any_contains(CacheLoader.quick_check(dir, wrong_size), "bytes"))
	h.equal("quick.digest_not_read",
		", ".join(CacheLoader.quick_check(dir, wrong_digest)), "",
		"a digest is only the full sweep's to check")
	_check_locate(h)

	# And the cache actually loads into a world.
	var loaded: Dictionary = CacheFixture.load_slice_world()
	h.check("load.world", not loaded.is_empty(), "the slice mission loads")
	if loaded.is_empty():
		return
	var world: World = loaded["world"]
	h.equal("load.mission", world.resource.mission, CacheFixture.SLICE_MISSION)
	var again: Dictionary = CacheFixture.load_slice_world()
	var second: World = again["world"]
	h.equal("load.hash_stable", world.canonical_hash_hex(),
		second.canonical_hash_hex(),
		"two loads of the same cache give the same canonical hash")

	# **Every column any accessor reads is in every published row.**
	# [method UnitTypeTable._field] and its weapon twin fall back on a missing
	# key, because a hand-built fixture in `tests/` carries only the columns it
	# is about. The real cache is held to the stricter standard here, so a
	# converter that dropped a column fails loudly instead of turning into a
	# silent default -- which is how `armour_front` reached [AIFire] as a
	# runtime error in four suites rather than as one failing check.
	_check_columns(h, CacheFixture.cache_dir())
	_check_frontend_documents(h, CacheFixture.cache_dir())
	_check_cache_paths(h)


## [method CacheLoader.locate]'s order over caches of this suite's own:
## `--cache=`, then the bundled data, then the player's published cache -- and
## a source that exists but does not check out is refused, never skipped for
## the next one.
static func _check_locate(h: TestHarness) -> void:
	var root: String = "user://tests/cache_locate"
	_remove_tree(ProjectSettings.globalize_path(root))
	var bundled: String = root + "/bundled"
	var caches: String = root + "/caches"
	var published: String = caches + "/1-test"
	var forced: String = root + "/forced"
	for cache: String in [bundled, published, forced]:
		_write_tiny_cache(cache)
	_write_text(caches + "/" + CacheLoader.ACTIVE_NAME,
		JSON.stringify({"cache_id": "1-test"}))
	var none: PackedStringArray = PackedStringArray()

	h.equal("locate.bundled_first", _located(
		CacheLoader.locate(none, bundled, caches)), bundled)
	h.equal("locate.forced_wins", _located(CacheLoader.locate(
		PackedStringArray([CacheLoader.CACHE_ARG + forced]), bundled,
		caches)), forced)
	h.equal("locate.published_second", _located(
		CacheLoader.locate(none, root + "/absent", caches)), published)
	var nothing: Dictionary = CacheLoader.locate(none, root + "/absent",
		root + "/no-caches")
	h.check("locate.first_run_hint",
		not DictRead.as_bool(nothing["ok"]) and DictRead.as_string(
			nothing["reason"]).contains("remake_convert.py"))

	# A bundled cache that fails its check is refused by name: the published
	# cache behind it does not quietly take its place.
	_write_text(bundled + "/tables/tiny.json", "{}")
	var broken: Dictionary = CacheLoader.locate(none, bundled, caches)
	h.check("locate.broken_refused_not_skipped",
		not DictRead.as_bool(broken["ok"])
		and DictRead.as_string(broken["reason"]).contains("bytes"),
		DictRead.as_string(broken["reason"]))
	# The same bytes pass the quick check when the length is right and only the
	# full sweep (`--verify-cache`) sees the digest.
	_write_text(bundled + "/tables/tiny.json", '{"x":2}')
	h.check("locate.quick_misses_same_size_damage", DictRead.as_bool(
		CacheLoader.locate(none, bundled, caches)["ok"]))
	var full: Dictionary = CacheLoader.locate(PackedStringArray(
		[CacheLoader.VERIFY_ARG]), bundled, caches)
	h.check("locate.verify_arg_sweeps", not DictRead.as_bool(full["ok"])
		and DictRead.as_string(full["reason"]).contains("digest"),
		DictRead.as_string(full["reason"]))
	_remove_tree(ProjectSettings.globalize_path(root))


static func _located(opened: Dictionary) -> String:
	if not DictRead.as_bool(opened["ok"]):
		return "refused: " + DictRead.as_string(opened["reason"])
	return DictRead.as_string(opened["cache_dir"])


## One document, `{"x":1}`, and a manifest that declares it with this build's
## versions.
static func _write_tiny_cache(cache: String) -> void:
	var body: String = '{"x":1}'
	_write_text(cache + "/tables/tiny.json", body)
	_write_text(cache + "/" + CacheLoader.MANIFEST_NAME, JSON.stringify({
		"cache_schema_version": CacheLoader.CACHE_SCHEMA_VERSION,
		"converter_version": CacheLoader.CONVERTER_VERSION,
		"inventory": [{"path": "tables/tiny.json",
			"size": body.to_utf8_buffer().size(),
			"sha256": CacheLoader.sha256_hex(body.to_utf8_buffer())}],
	}))


static func _write_text(path: String, text: String) -> void:
	var _made: Error = DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path.get_base_dir()))
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


static func _remove_tree(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for name: String in dir.get_files():
		var _gone: Error = dir.remove(name)
	for sub: String in dir.get_directories():
		_remove_tree(path + "/" + sub)
	var _dropped: Error = DirAccess.remove_absolute(path)


## [CachePaths] -- the per-file language resolver of docs/92 section 7.6, on
## a hand-built manifest: the fixture is converted without a pack, and the
## rules are the resolver's, not the Russian release's.
static func _check_cache_paths(h: TestHarness) -> void:
	var manifest: Dictionary = {
		"language": "English",
		"languages": ["English", "Russian"],
		"inventory": [
			{"path": "text/gui.json"},
			{"path": "fonts/index.json"},
			{"path": "lang/Russian/text/gui.json"},
			{"path": "lang/Russian/names.json"},
			{"path": "missions/_C_100/map.json"},
		],
	}
	var base: CachePaths = CachePaths.create("/c", manifest)
	h.equal("paths.base_language", base.language, "English")
	h.check("paths.base_has_no_pack", not base.has_pack())
	h.equal("paths.base_neutral", base.path("text/gui.json"), "/c/text/gui.json")

	var pack: CachePaths = CachePaths.create("/c", manifest, "Russian")
	h.equal("paths.pack_language", pack.language, "Russian")
	h.check("paths.pack_has_pack", pack.has_pack() and not pack.fallback)
	h.equal("paths.pack_hit", pack.path("text/gui.json"),
		"/c/lang/Russian/text/gui.json", "the pack carries this file")
	h.equal("paths.pack_neutral_fallback", pack.path("fonts/index.json"),
		"/c/fonts/index.json", "the pack does not, so the neutral one serves")
	h.equal("paths.pack_neutral_only", pack.path("missions/_C_100/map.json"),
		"/c/missions/_C_100/map.json")
	h.equal("paths.neutral_path_ignores_pack",
		pack.neutral_path("text/gui.json"), "/c/text/gui.json")
	h.check("paths.is_pack_file", pack.is_pack_file("text/gui.json")
		and not pack.is_pack_file("fonts/index.json"))

	var unknown: CachePaths = CachePaths.create("/c", manifest, "Klingon")
	h.equal("paths.unknown_falls_back", unknown.language, "English")
	h.check("paths.unknown_says_so", unknown.fallback and not unknown.has_pack())

	# `languages()` answers a copy, like every `Packed*Array` accessor here.
	var offered: PackedStringArray = pack.languages()
	offered.append("Klingon")
	h.equal("paths.languages_duplicated", pack.languages(),
		PackedStringArray(["English", "Russian"]),
		"appending to the answer does not reach the resolver")

	# A manifest from before the pack model lists no `languages`: the base
	# language is the whole list.
	var old: CachePaths = CachePaths.create("/c", {"language": "English",
		"inventory": []})
	h.equal("paths.old_manifest_one_language", old.languages(),
		PackedStringArray(["English"]))

	# The names overlay, on hand-built tables: four name columns and nothing
	# else move, by id; a slot the pack did not vouch for keeps its name.
	var named: CachePaths = CachePaths.create("/c", manifest, "Russian")
	named._names = {
		"balance": {"units": {"1": "Боец"}, "weapons": {"0": "Пушка"},
			"equipment": {}, "ctrlmap": {"2": "Пол"}},
		"missions": {"_C_100": {"3": "Лягушонок"}},
	}
	named._names_read = true
	var balance: Dictionary = {
		"units": [{"id": 0, "description": "Soldier", "mp_max": 3},
			{"id": 1, "description": "Marine", "mp_max": 4}],
		"weapons": [{"id": 0, "name": "Gun", "damage": 5}],
		"equipment": [{"id": 0, "name": "Kit"}],
		"ctrlmap": [{"index": 2, "name": "Floor", "delay": 1}],
	}
	var overlaid: Dictionary = named.apply_balance_names(balance)
	h.equal("names.unit_renamed",
		DictRead.as_dict(DictRead.as_array(overlaid["units"])[1])["description"],
		"Боец")
	h.equal("names.unit_kept",
		DictRead.as_dict(DictRead.as_array(overlaid["units"])[0])["description"],
		"Soldier", "no overlay for id 0")
	h.equal("names.weapon_renamed",
		DictRead.as_dict(DictRead.as_array(overlaid["weapons"])[0])["name"],
		"Пушка")
	h.equal("names.ctrlmap_renamed",
		DictRead.as_dict(DictRead.as_array(overlaid["ctrlmap"])[0])["name"],
		"Пол")
	h.equal("names.numbers_untouched",
		DictRead.as_dict(DictRead.as_array(overlaid["weapons"])[0])["damage"],
		5)
	h.equal("names.input_untouched",
		DictRead.as_dict(DictRead.as_array(balance["units"])[1])["description"],
		"Marine", "the overlay is a copy, not an edit in place")
	var map: Dictionary = {"units": [{"slot": 3, "name": "Frog"},
		{"slot": 4, "name": "Toad"}]}
	var renamed: Dictionary = named.apply_unit_names("_C_100", map)
	h.equal("names.slot_renamed",
		DictRead.as_dict(DictRead.as_array(renamed["units"])[0])["name"],
		"Лягушонок")
	h.equal("names.slot_kept",
		DictRead.as_dict(DictRead.as_array(renamed["units"])[1])["name"],
		"Toad", "a slot the pack did not vouch for keeps the base's name")
	h.equal("names.other_mission_untouched",
		named.apply_unit_names("_C_101", map), map)
	h.equal("names.base_is_identity", base.apply_balance_names(balance),
		balance, "the base language overlays nothing")


## Columns [UnitTypeTable] reads, and the [AIFire] recompute among them.
const UNIT_COLUMNS: Array[String] = ["id", "mp_max", "fp_max", "hp_max",
	"special", "size", "species", "exp", "height", "model", "description",
	"armour_front", "armour_rear",
	# The weapon `aGenerateUnitElement` gives a spawned unit (docs/20 section
	# 7.4).
	"weapon",
	# The magnifier's letter into `Data.txt` (docs/43 section 5.2).
	"key"]
## Columns [WeaponTable] reads, `ap` and `param` included -- both are what the
## computer's fire routine and its jam fallback need.
const WEAPON_COLUMNS: Array[String] = ["id", "heat", "toggle", "mun", "hit",
	"damage", "range_min", "range_max", "type", "special", "def_mode",
	"mun_per_fight", "ap", "param"]


## The ninth slice's two documents (docs/92 section 7.19), read by name
## rather than assumed: a cache that lacks them plays no cutscene and shows
## no splash, and the loader would say nothing.
static func _check_frontend_documents(h: TestHarness, cache_dir: String) -> void:
	var sequences: Dictionary = CacheLoader.read_json(
		cache_dir + "/tables/sequences.json")
	h.equal("documents.sequences_schema",
		DictRead.as_string(sequences.get("schema", "")),
		"incubation.sequences/1")
	var frontend: Dictionary = CacheLoader.read_json(
		cache_dir + "/tables/frontend.json")
	h.equal("documents.frontend_schema",
		DictRead.as_string(frontend.get("schema", "")), "incubation.frontend/1")
	var holds: Array = DictRead.as_dict(frontend.get("holds_ms", {})).keys()
	holds.sort()
	h.equal("documents.frontend_holds", holds,
		["after_extro", "after_sequence", "logo"])
	var programs: Array = DictRead.as_dict(frontend.get("cd_programs", {})).keys()
	programs.sort()
	h.equal("documents.frontend_programs", programs,
		["credits", "debriefing", "load", "menu", "mission_control"],
		"seq_parse.FRONTEND's five")
	h.check("documents.voice_overs",
		DictRead.as_array(frontend.get("voice_overs", [])).size() == 74,
		"MB100..133 and MB140..179")
	h.check("documents.extro_wave",
		FileAccess.file_exists(cache_dir + "/audio/briefing/extro.wav"))


static func _check_columns(h: TestHarness, cache_dir: String) -> void:
	var balance: Dictionary = CacheLoader.read_json(
		cache_dir + "/tables/balance.json")
	if balance.is_empty():
		h.check("columns.balance", false, "tables/balance.json is missing")
		return
	h.equal("columns.units",
		_missing(DictRead.as_array(balance["units"]), UNIT_COLUMNS), "",
		"every SetUnitInfo row carries every column an accessor reads")
	h.equal("columns.weapons",
		_missing(DictRead.as_array(balance["weapons"]), WEAPON_COLUMNS), "",
		"every SetWeaponInfo row carries every column an accessor reads")


static func _missing(rows: Array, columns: Array[String]) -> String:
	var gaps: PackedStringArray = PackedStringArray()
	for entry: Variant in rows:
		var row: Dictionary = DictRead.as_dict(entry)
		for column: String in columns:
			if not row.has(column):
				gaps.append("%s on row %s" % [column,
					str(row.get("id", "?"))])
	return ", ".join(gaps)


func _any_contains(values: PackedStringArray, needle: String) -> bool:
	for value: String in values:
		if value.contains(needle):
			return true
	return false
