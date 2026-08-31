extends TestSuite

## Oracle boundary: **executable Python**.
##
## `tools/inclib/sound.py` is docs/28 sections 1 to 5 as running code, and
## `tools/blob_tables.py --check` compares it against what it read out of
## `Incubation.exe` -- the pool bound, the four attenuation constants, the 103
## `SetVolumeCtrl` percentages, the partition of all 62 call sites into events,
## the nine looping play sites, the eight footstep arms, both voice cursors and
## the weapon-id-is-volume-id rule. So the model is anchored to the binary by
## checks that share no code with it.
##
## This suite replays the trace that model emits and requires [AudioTables],
## [AudioPool] and [AudioEvents] to answer identically. That makes it a
## transcription check, which is the honest description: nothing about the
## sound layer has been measured in a running `Incubation.exe`, and no check
## here claims otherwise.
##
## **Every number in it is integer.** DirectSound attenuation is in hundredths
## of a decibel and the whole formula is integer arithmetic, so unlike the
## Charisma diff this one is exact and has no tolerance to argue about. A
## mismatch is a mismatch.

const CASES: String = "res://generated/sound/sound.json"
const SCHEMA: String = "incubation.sound-cases/1"


func run(h: TestHarness) -> void:
	h.begin("sound", TestHarness.ORACLE_PYTHON)
	if not FileAccess.file_exists(CASES):
		h.check("fixture", false,
			"run python3 tools/blob_tables.py --emit-sound-cases "
			+ "tests/fixtures/sound/cases_sound.json --root gog_incubation")
		return
	var document: Dictionary = CacheLoader.read_json(CASES)
	if document.is_empty():
		h.check("fixture", false, "%s did not parse" % CASES)
		return
	# By name, not by shape: a stale copy of an older emitter would parse and
	# then disagree about a section that had moved, and the failure would name
	# a field instead of the file.
	if not h.equal("schema", document.get("schema"), SCHEMA):
		return

	# The fixture carries the very document the cache does, so the suite reads
	# the same input the game reads. Building the tables from the case file's
	# own sections instead would test a shape that exists nowhere else.
	var tables: AudioTables = AudioTables.from_document(
		DictRead.as_dict(document["document"]))
	h.check("loaded", tables.is_loaded(), "the sound document opened")
	h.equal("play_slots", tables.play_slots(),
		DictRead.as_int(document["play_slots"]))
	h.equal("volume_ids", tables.volume_ids().size(),
		DictRead.as_dict(document["volume_table"]).size())

	_check_attenuation(h, tables, document)
	_check_scaled(h, tables, document)
	_check_pool(h, tables, document)
	_check_voices(h, tables, document)
	_check_footsteps(h, tables, document)
	_check_walk_period(h, tables, document)
	_check_weapons(h, tables, document)
	_check_catalogue(h, tables, document)
	_check_case_map(h, tables, document)
	_check_playlists(h, document)
	_check_compat(h, tables, document)


func _check_attenuation(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var cases: Array = DictRead.as_array(document["attenuation"])
	var bad: PackedStringArray = PackedStringArray()
	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		var got: int = tables.attenuation(DictRead.as_int(kase["base"]),
			DictRead.as_int(kase["percent"]))
		if got != DictRead.as_int(kase["want"]):
			bad.append("base %d, %d%%: %d != %d" % [
				DictRead.as_int(kase["base"]),
				DictRead.as_int(kase["percent"]), got,
				DictRead.as_int(kase["want"])])
	h.check("attenuation", bad.is_empty() and not cases.is_empty(),
		"%d/%d agree%s" % [cases.size() - bad.size(), cases.size(),
			"" if bad.is_empty() else "; first: " + bad[0]])


func _check_scaled(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var cases: Array = DictRead.as_array(document["scaled"])
	var bad: PackedStringArray = PackedStringArray()
	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		var got: int = tables.scaled_volume(DictRead.as_int(kase["base"]),
			DictRead.as_int(kase["volume_id"]))
		if got != DictRead.as_int(kase["want"]):
			bad.append("id %d at %d: %d != %d" % [
				DictRead.as_int(kase["volume_id"]),
				DictRead.as_int(kase["base"]), got,
				DictRead.as_int(kase["want"])])
	h.check("scaled_volume", bad.is_empty() and not cases.is_empty(),
		"%d/%d ids and base volumes%s" % [cases.size() - bad.size(),
			cases.size(), "" if bad.is_empty() else "; first: " + bad[0]])
	# The two bounds really do differ by one, which is what decides whether a
	# sound is refused at load or accepted by the setter.
	h.check("bound_asymmetry",
		not tables.load_id_valid(120) and tables.set_id_valid(120),
		"120 is refused by the load path and accepted by the setter")
	h.equal("passthrough", tables.scaled_volume(-1234, AudioTables.NO_SCALING),
		-1234, "id -1 passes the base volume through")


func _check_pool(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var pool: AudioPool = AudioPool.with_slots(tables.play_slots())
	var ops: Array = DictRead.as_array(document["pool"])
	var bad: PackedStringArray = PackedStringArray()
	var step: int = 0
	for entry: Variant in ops:
		var op: Dictionary = DictRead.as_dict(entry)
		var name: String = DictRead.as_string(op["op"])
		var got: int = 0
		match name:
			"load":
				got = pool.load_wave("w%d.wav" % step, 0,
					AudioTables.NO_SCALING)
				pool.play(got, DictRead.as_bool(op["loop"]))
			"kill":
				got = 1 if pool.kill(DictRead.as_int(op["slot"])) else 0
			"kill_looping":
				got = pool.kill_looping()
			"live":
				got = pool.live().size()
			_:
				bad.append("unknown op %s" % name)
				continue
		if got != DictRead.as_int(op["want"]):
			bad.append("step %d %s: %d != %d"
				% [step, name, got, DictRead.as_int(op["want"])])
		if pool.drops() != DictRead.as_int(op["drops"]):
			bad.append("step %d %s: %d drops != %d"
				% [step, name, pool.drops(), DictRead.as_int(op["drops"])])
		step += 1
	h.check("pool", bad.is_empty() and not ops.is_empty(),
		"%d operations%s" % [ops.size(),
			"" if bad.is_empty() else "; first: " + bad[0]])
	# The cap is the point of the twenty-slot pool, so it is asserted rather
	# than inferred from the replay agreeing.
	h.equal("pool_size", pool.size(), tables.play_slots())


func _check_voices(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var events: AudioEvents = AudioEvents.open(tables, {})
	var trace: Array = DictRead.as_array(document["voices"])
	var bad: PackedStringArray = PackedStringArray()
	for index: int in range(trace.size()):
		var kase: Dictionary = DictRead.as_dict(trace[index])
		var got: Dictionary = events.second_human() \
			if DictRead.as_string(kase["call"]) == "second_human" \
			else events.pain(DictRead.as_int(kase["species"]))
		var wave: String = "" if got.is_empty() \
			else DictRead.as_string(got["wave"])
		var volume: int = 0 if got.is_empty() \
			else DictRead.as_int(got["volume_id"])
		if wave != DictRead.as_string(kase["wave"]) \
				or volume != DictRead.as_int(kase["volume_id"]):
			bad.append("%d: %s@%d != %s@%d" % [index, wave, volume,
				DictRead.as_string(kase["wave"]),
				DictRead.as_int(kase["volume_id"])])
	h.check("voices", bad.is_empty() and not trace.is_empty(),
		"%d calls, two cursors interleaved%s" % [trace.size(),
			"" if bad.is_empty() else "; first: " + bad[0]])
	# The correction of docs/92 section 7.1, asserted for itself: the alien
	# scream must not be scaled by the human ids, whatever the preset.
	var fresh: AudioEvents = AudioEvents.open(tables, {})
	var alien: Dictionary = fresh.pain(AudioEvents.SPECIES_ALIEN)
	var human_ids: Array = DictRead.as_array(
		DictRead.as_dict(document["catalogue"]).get("_absent", []))
	h.check("alien_volume_fixed",
		not alien.is_empty() and DictRead.as_int(alien["volume_id"])
			== DictRead.as_int(DictRead.as_array(
				DictRead.as_dict(tables.voices())["alien_volume_ids"])[0]),
		"the alien scream carries its own id, not the human one"
			+ ("" if human_ids.is_empty() else " "))
	h.check("silent_species", fresh.pain(2).is_empty(),
		"every species but human and alien is silent")


func _check_footsteps(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var cases: Array = DictRead.as_array(document["footsteps"])
	var bad: PackedStringArray = PackedStringArray()
	var silent: int = 0
	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		var got: Dictionary = tables.footstep(DictRead.as_int(kase["type"]),
			DictRead.as_bool(kase["faithful"]))
		var wave: String = "" if got.is_empty() \
			else DictRead.as_string(got["wave"])
		var volume: int = 0 if got.is_empty() \
			else DictRead.as_int(got["volume_id"])
		var period: int = -1 if got.is_empty() \
			else DictRead.as_int(got["period"])
		if got.is_empty() and DictRead.as_bool(kase["faithful"]):
			silent += 1
		if wave != DictRead.as_string(kase["wave"]) \
				or volume != DictRead.as_int(kase["volume_id"]) \
				or period != DictRead.as_int(kase["period"]):
			bad.append("type %d faithful=%s: %s@%d/%d != %s@%d/%d" % [
				DictRead.as_int(kase["type"]),
				str(DictRead.as_bool(kase["faithful"])), wave, volume, period,
				DictRead.as_string(kase["wave"]),
				DictRead.as_int(kase["volume_id"]),
				DictRead.as_int(kase["period"])])
	h.check("footsteps", bad.is_empty() and not cases.is_empty(),
		"%d (type, preset) pairs, %d silent types%s"
			% [cases.size(), silent,
				"" if bad.is_empty() else "; first: " + bad[0]])
	# Unit type 24's defect, named rather than left inside the sweep: it is
	# reproduced by default and corrected without the preset.
	var fix: Dictionary = DictRead.as_dict(
		DictRead.as_dict(document["document"]).get("footstep_fix", {}))
	if fix.is_empty():
		fix = {"type": 24, "original": 45, "corrected": 91}
	var stray: int = DictRead.as_int(fix["type"])
	h.equal("footstep_24_faithful",
		DictRead.as_int(tables.footstep(stray, true)["volume_id"]),
		DictRead.as_int(fix["original"]))
	h.equal("footstep_24_corrected",
		DictRead.as_int(tables.footstep(stray, false)["volume_id"]),
		DictRead.as_int(fix["corrected"]))


## The step period is one global, and type 54 does not write it.
##
## `aStartWalkAnimationSound` is therefore **not** a pure function of the unit
## type, and this replays the Python model's own ordered trace to prove the
## GDScript twin is not one either: a Squeether walking first has no period at
## all, and a Squeether walking after a marine has the marine's.
func _check_walk_period(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var section: Dictionary = DictRead.as_dict(document["walk_period"])
	var events: AudioEvents = AudioEvents.open(tables, {})
	h.equal("walk_period_initial", events.walk_period(),
		DictRead.as_int(section["initial"]))
	var bad: PackedStringArray = PackedStringArray()
	var trace: Array = DictRead.as_array(section["trace"])
	for entry: Variant in trace:
		var kase: Dictionary = DictRead.as_dict(entry)
		var got: Dictionary = events.footstep(DictRead.as_int(kase["type"]))
		var wave: String = "" if got.is_empty() \
			else DictRead.as_string(got["wave"])
		var period: int = -1 if got.is_empty() \
			else DictRead.as_int(got["period"])
		if wave != DictRead.as_string(kase["wave"]) \
				or period != DictRead.as_int(kase["period"]) \
				or events.walk_period() != DictRead.as_int(kase["global"]):
			bad.append("type %d: %s/%d global %d != %s/%d global %d" % [
				DictRead.as_int(kase["type"]), wave, period,
				events.walk_period(), DictRead.as_string(kase["wave"]),
				DictRead.as_int(kase["period"]),
				DictRead.as_int(kase["global"])])
	h.check("walk_period_trace", bad.is_empty() and not trace.is_empty(),
		"%d walks in order%s" % [trace.size(),
			"" if bad.is_empty() else "; first: " + bad[0]])


func _check_weapons(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var cases: Array = DictRead.as_array(document["weapons"])
	var bad: PackedStringArray = PackedStringArray()
	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		var got: Dictionary = tables.weapon_fire(
			DictRead.as_int(kase["weapon"]), DictRead.as_bool(kase["faithful"]))
		var wave: String = "" if got.is_empty() \
			else DictRead.as_string(got["wave"])
		var volume: int = -1 if got.is_empty() \
			else DictRead.as_int(got["volume_id"])
		if wave != DictRead.as_string(kase["wave"]) \
				or volume != DictRead.as_int(kase["volume_id"]):
			bad.append("weapon %d faithful=%s: %s@%d != %s@%d" % [
				DictRead.as_int(kase["weapon"]),
				str(DictRead.as_bool(kase["faithful"])), wave, volume,
				DictRead.as_string(kase["wave"]),
				DictRead.as_int(kase["volume_id"])])
	h.check("weapon_fire", bad.is_empty() and not cases.is_empty(),
		"%d (weapon, preset) pairs%s" % [cases.size(),
			"" if bad.is_empty() else "; first: " + bad[0]])
	var defective: int = tables.weapon_missing_sound()
	h.check("weapon_35_silent",
		tables.weapon_fire(defective, true).is_empty(),
		"weapon %d loads nothing under Faithful (docs/28 3.1)" % defective)
	h.check("weapon_35_corrected",
		not tables.weapon_fire(defective, false).is_empty(),
		"and does load with the correction")


func _check_catalogue(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var catalogue: Dictionary = DictRead.as_dict(document["catalogue"])
	var events: AudioEvents = AudioEvents.open(tables, {})
	var bad: PackedStringArray = PackedStringArray()
	var cues: int = 0
	var looping: int = 0
	for name: Variant in catalogue:
		var event: String = DictRead.as_string(name)
		var want: Array = DictRead.as_array(catalogue[name])
		var got: Array[Dictionary] = events.for_event_kind(event)
		if got.size() != want.size():
			bad.append("%s: %d cues != %d" % [event, got.size(), want.size()])
			continue
		for index: int in range(want.size()):
			var expect: Dictionary = DictRead.as_dict(want[index])
			cues += 1
			if DictRead.as_bool(expect["loop"]):
				looping += 1
			var same_wave: bool = DictRead.as_string(got[index]["wave"]) \
				== DictRead.as_string(expect["wave"])
			var same_id: bool = DictRead.as_int(got[index]["volume_id"]) \
				== DictRead.as_int(expect["volume_id"])
			var same_loop: bool = DictRead.as_bool(got[index]["loop"]) \
				== DictRead.as_bool(expect["loop"])
			if not (same_wave and same_id and same_loop):
				bad.append("%s[%d]: %s != %s" % [event, index,
					str(got[index]), str(expect)])
	h.check("catalogue", bad.is_empty() and cues > 0,
		"%d events, %d cues, %d looping%s" % [catalogue.size(), cues, looping,
			"" if bad.is_empty() else "; first: " + bad[0]])
	# The aliases exist so `core`'s own event names reach a cue; a rename that
	# stopped resolving would leave a set piece silent and nothing else.
	var unresolved: PackedStringArray = PackedStringArray()
	for kind: String in AudioEvents.EVENT_ALIASES:
		if events.for_event_kind(kind).is_empty():
			unresolved.append(kind)
	h.check("aliases_resolve", unresolved.is_empty(),
		"%d of core's own event names reach a cue: %s"
			% [AudioEvents.EVENT_ALIASES.size(), ", ".join(unresolved)])


func _check_case_map(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var map: Dictionary = DictRead.as_dict(document["case_map"])
	var bad: PackedStringArray = PackedStringArray()
	for lower: Variant in map:
		var name: String = DictRead.as_string(lower)
		if name != name.to_lower():
			bad.append(name)
	h.check("case_resolved", bad.is_empty() and not map.is_empty(),
		"%d waves, every one already lower case%s" % [map.size(),
			"" if bad.is_empty() else "; first: " + bad[0]])
	var renamed: int = 0
	for lower: Variant in map:
		if DictRead.as_string(lower) != DictRead.as_string(map[lower]):
			renamed += 1
	h.check("case_renames", renamed > 0,
		"%d shipped files whose case the code does not match" % renamed)
	h.equal("unresolved", DictRead.as_array(document["unresolved"]).size(), 1,
		"exactly one name in the closure resolves to nothing, and it is "
		+ "weapon 35's")


func _check_playlists(h: TestHarness, document: Dictionary) -> void:
	var cases: Array = DictRead.as_array(document["playlists"])
	var bad: PackedStringArray = PackedStringArray()
	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		var got: PackedInt32Array = AudioTables.parse_playlist(
			DictRead.as_string(kase["program"]))
		var want: PackedInt32Array = DictRead.to_int32(kase["want"])
		if got != want:
			bad.append("%s: %s != %s" % [DictRead.as_string(kase["program"]),
				str(got), str(want)])
	h.check("playlists", bad.is_empty() and not cases.is_empty(),
		"%d CDTrackProgram strings%s" % [cases.size(),
			"" if bad.is_empty() else "; first: " + bad[0]])
	# The list loops: a six-entry programme on a forty-turn mission has to.
	var player: MusicPlayer = MusicPlayer.from_program("3.5.7",
		PackedInt32Array([3, 5, 7]))
	var order: PackedInt32Array = PackedInt32Array([player.current()])
	for _step: int in range(4):
		order.append(player.advance())
	h.equal("playlist_loops", order, PackedInt32Array([3, 5, 7, 3, 5]))
	# A track the cache does not carry is skipped rather than played silently.
	var partial: MusicPlayer = MusicPlayer.from_program("3.5.7",
		PackedInt32Array([7]))
	h.equal("playlist_skips_absent", partial.first_playable(), 7)
	var none: MusicPlayer = MusicPlayer.from_program("3.5.7",
		PackedInt32Array())
	h.equal("playlist_without_music", none.first_playable(), -1,
		"a --no-music cache is quieter, not broken")


func _check_compat(h: TestHarness, tables: AudioTables,
		_document: Dictionary) -> void:
	# The two audible defects are presentation and are held here, **not** in
	# `World.compat_flags` -- that array is hashed with the simulation, and an
	# audio preset that moved the canonical hash would be a worse defect than
	# either of the two it reproduces. This check is what stops that drifting.
	var faithful: AudioEvents = AudioEvents.open(tables, {}, true)
	var corrected: AudioEvents = AudioEvents.open(tables, {}, false)
	h.check("compat_is_presentation",
		faithful.is_faithful() and not corrected.is_faithful(),
		"the preset is a property of the audio layer and of nothing else")
	h.check("compat_changes_footstep",
		DictRead.as_int(faithful.footstep(24)["volume_id"])
			!= DictRead.as_int(corrected.footstep(24)["volume_id"]),
		"and it does change what is heard")

	# **The flags are named, and each moves only its own defect.** An earlier
	# draft carried one boolean, so docs/92 section 7.1's "stable named flag"
	# was true of the Python side and of nothing here.
	var emitted: Array = DictRead.as_array(
		DictRead.as_dict(_document.get("document", {})).get("compat_flags", []))
	h.equal("compat_names", AudioEvents.COMPAT_FLAGS.size(), emitted.size(),
		"the remake spells every flag the converter declared")
	h.equal("compat_unknown", corrected.unknown_compat_flags(),
		PackedStringArray(),
		"every flag the cache declares is one this build carries")

	var one: AudioEvents = AudioEvents.open(tables, {}, true)
	h.check("compat_set_rejects_unknown",
		not one.set_compat("no_such_flag", false),
		"a preset naming a flag this build has not got is refused")
	h.check("compat_set_takes",
		one.set_compat(AudioEvents.COMPAT_FOOTSTEP_24, false)
			and not one.is_faithful()
			and one.compat(AudioEvents.COMPAT_WEAPON_35),
		"turning one off leaves the other on")
	h.equal("compat_one_flag_one_defect",
		DictRead.as_int(one.footstep(24)["volume_id"]),
		DictRead.as_int(corrected.footstep(24)["volume_id"]),
		"and it is the footstep flag that moves the footstep")
