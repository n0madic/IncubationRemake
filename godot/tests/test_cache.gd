extends TestSuite

## Oracle boundary: specification-only.  docs/92 section 10.4, the cache half.
##
## The Python side owns the transactional publish and proves it on a temporary
## directory (`tools/remake_convert.py --check-cache`).  What has to be proved
## **here** is the other half of the same contract: the loader refuses a cache
## whose inventory does not verify, and it does the verification on every load
## rather than only on the first.  Verifying once would make "a partial cache is
## never accepted" a claim about the happy path; a full pass over roughly two
## megabytes costs a few milliseconds.

func run(h: TestHarness) -> void:
	h.begin("cache", TestHarness.ORACLE_SPEC)
	var manifest: Dictionary = CacheFixture.manifest()
	if manifest.is_empty():
		h.check("fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
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


## Columns [UnitTypeTable] reads, and the [AIFire] recompute among them.
const UNIT_COLUMNS: Array[String] = ["id", "mp_max", "fp_max", "hp_max",
	"special", "size", "species", "height", "model", "description",
	"armour_front", "armour_rear"]
## Columns [WeaponTable] reads, `ap` and `param` included -- both are what the
## computer's fire routine and its jam fallback need.
const WEAPON_COLUMNS: Array[String] = ["id", "heat", "toggle", "mun", "hit",
	"damage", "range_min", "range_max", "type", "special", "def_mode",
	"mun_per_fight", "ap", "param"]


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
