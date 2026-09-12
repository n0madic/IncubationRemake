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

	_check_view_player(h, tables, document)
	_check_mission_interface(h, tables, document)
	_check_load_interface(h, document)
	_check_speech(h, tables, document)
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
	_check_cutscene_volume(h, tables)
	_check_wave_padding(h)
	_check_slot_end_arming(h)
	_check_looping_stream(h)


## Cutscene `Track` files contain dialogue and effects as one mixed soundtrack,
## so silencing background music must not silence them too.
func _check_cutscene_volume(h: TestHarness, tables: AudioTables) -> void:
	var audio: AudioSystem = AudioSystem.new()
	audio.setup(tables, null)
	audio.set_music_volume(-4000)
	audio.set_fx_volume(-900)
	# An absent id exercises the route without opening an audio stream. The
	# family is selected before the playlist answers that it has no file.
	var _cutscene: int = audio.start_program("999", AudioTables.FAMILY_TRACK)
	h.equal("volume.cutscene_uses_fx",
		DictRead.as_int(audio.music_view()["volume"]), -900,
		"Music at its floor does not mute the cutscene soundtrack")
	audio.set_music_volume(-200)
	h.equal("volume.music_change_does_not_touch_cutscene",
		DictRead.as_int(audio.music_view()["volume"]), -900)
	audio.set_fx_volume(-700)
	h.equal("volume.fx_change_reaches_cutscene",
		DictRead.as_int(audio.music_view()["volume"]), -700)

	var _menu: int = audio.start_program("999", AudioTables.FAMILY_ARACK)
	h.equal("volume.frontend_music_uses_music",
		DictRead.as_int(audio.music_view()["volume"]), -200)
	audio.set_fx_volume(-500)
	h.equal("volume.fx_change_does_not_touch_music",
		DictRead.as_int(audio.music_view()["volume"]), -200)
	audio.free()


## ``aLoad.cpp``'s two events, joined all the way from the converted closure
## to the screen that consumes them.
func _check_load_interface(h: TestHarness, document: Dictionary) -> void:
	var sound: Dictionary = DictRead.as_dict(document["document"])
	var cues: Dictionary = DictRead.as_dict(sound["load_interface"])
	var selection: Dictionary = DictRead.as_dict(cues["selection_changed"])
	var activation: Dictionary = DictRead.as_dict(cues["activate"])
	h.equal("load_interface.selection_wave",
		DictRead.as_string(selection["wave"]),
		SaveSlotsScreen.SOUND_SELECTION_CHANGED)
	h.equal("load_interface.activation_wave",
		DictRead.as_string(activation["wave"]), SaveSlotsScreen.SOUND_ACTIVATE)
	h.equal("load_interface.selection_volume",
		DictRead.as_int(selection["volume_id"]), AudioTables.NO_SCALING)
	h.equal("load_interface.activation_volume",
		DictRead.as_int(activation["volume_id"]), AudioTables.NO_SCALING)
	var copied: Dictionary = DictRead.as_dict(sound["waves"])
	h.check("load_interface.selection_copied",
		copied.has(SaveSlotsScreen.SOUND_SELECTION_CHANGED), "click_3.wav")
	h.check("load_interface.activation_copied",
		copied.has(SaveSlotsScreen.SOUND_ACTIVATE), "click_4.wav")


## The slot's "sample ended" connection, and the error it used to raise.
##
## `CONNECT_ONE_SHOT` disconnects when the signal **fires**, and
## `AudioStreamPlayer.stop()` does not fire it -- so every cue a sequence cut
## short left its connection armed, and the next cue on that slot connected the
## same bound callable again, which Godot refuses with an error. [method
## AudioSystem.arm_slot_end] is the one place that is decided now.
func _check_slot_end_arming(h: TestHarness) -> void:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	var on_end: Callable = _slot_ended.bind(7)
	AudioSystem.arm_slot_end(player, on_end, false)
	h.equal("slot_end.armed_once", player.finished.get_connections().size(), 1,
		"a one-shot cue arms the connection")
	AudioSystem.arm_slot_end(player, on_end, false)
	h.equal("slot_end.rearmed_not_doubled",
		player.finished.get_connections().size(), 1,
		"the slot re-used after a stop arms it again, not twice")
	AudioSystem.arm_slot_end(player, on_end, true)
	h.equal("slot_end.loop_disarms", player.finished.get_connections().size(),
		0, "a looping cue on the same slot drops the pending connection")
	AudioSystem.arm_slot_end(player, on_end, true)
	h.equal("slot_end.loop_stays_disarmed",
		player.finished.get_connections().size(), 0,
		"and arming a loop twice is not an error either")
	AudioSystem.arm_slot_end(player, on_end, false)
	h.equal("slot_end.armed_after_loop",
		player.finished.get_connections().size(), 1,
		"a one-shot after a loop arms it once more")
	player.free()


## The callable the arming test binds; it is never called.
func _slot_ended(_slot: int) -> void:
	pass


## A `DSBPLAY_LOOPING` cue needs a stream that loops, and the shipped waves
## carry no loop points at all.
##
## `AudioStreamWAV` repeats only when its own `loop_mode` says so, so every
## one of docs/28's nine looping sites was heard exactly once and then went
## quiet under a sequence that ran on -- `bomber.wav` against a fly-past of
## `0x0042A8E0`'s 150 ticks, and the door, the lift, the platform and the
## drawbridge the same way. The end point is **counted**: `loop_end` is a
## frame number, and a zero one is a loop of no length rather than all of it.
func _check_looping_stream(h: TestHarness) -> void:
	var sample: AudioStreamWAV = AudioStreamWAV.new()
	sample.format = AudioStreamWAV.FORMAT_16_BITS
	sample.stereo = false
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(400)
	sample.data = bytes
	h.equal("loop.frames_16_bit_mono", AudioSystem.frame_count(sample), 200,
		"two bytes a frame")
	sample.stereo = true
	h.equal("loop.frames_16_bit_stereo", AudioSystem.frame_count(sample), 100,
		"two channels of two bytes")
	sample.format = AudioStreamWAV.FORMAT_8_BITS
	h.equal("loop.frames_8_bit_stereo", AudioSystem.frame_count(sample), 200,
		"one byte a channel")
	sample.format = AudioStreamWAV.FORMAT_IMA_ADPCM
	h.equal("loop.frames_compressed_refused",
		AudioSystem.frame_count(sample), 0,
		"a byte count is not a frame count, and a wrong loop point would be "
		+ "worse than no loop")
	sample.format = AudioStreamWAV.FORMAT_16_BITS
	sample.stereo = false
	var looped: AudioStreamWAV = AudioSystem.looping_copy(sample)
	h.check("loop.copy_is_made", looped != null, "a PCM sample loops")
	if looped == null:
		return
	h.equal("loop.copy_repeats", int(looped.loop_mode),
		int(AudioStreamWAV.LOOP_FORWARD))
	h.equal("loop.copy_spans_the_sample",
		[looped.loop_begin, looped.loop_end], [0, 200],
		"the whole of it, counted rather than left at zero")
	h.equal("loop.source_left_alone", int(sample.loop_mode),
		int(AudioStreamWAV.LOOP_DISABLED),
		"a wave asked for both ways keeps its one-shot")
	var empty: AudioStreamWAV = AudioStreamWAV.new()
	h.check("loop.empty_sample_refused",
		AudioSystem.looping_copy(empty) == null and AudioSystem.looping_copy(null) == null,
		"nothing to loop is answered as nothing")


## The RIFF pad byte, and the one place the remake corrects a shipped header.
##
## 125 of the 407 shipped `.wav` files end one byte past what their `RIFF` size
## claims -- an odd `data` chunk and the pad byte RIFF requires after it, which
## the writer did not count. [method AudioSystem.with_pad_counted] fixes the
## header in memory so Godot's loader stops warning per file, and it must fix
## **only** that case: a truncated file or a file with trailing rubbish is a
## real defect and has to reach the loader as it is.
func _check_wave_padding(h: TestHarness) -> void:
	var padded: PackedByteArray = _riff(40, 31)
	var counted: PackedByteArray = AudioSystem.with_pad_counted(padded)
	h.equal("wave_pad.size_kept", counted.size(), padded.size(),
		"the sample is not touched, only the header")
	h.equal("wave_pad.header_corrected", counted.decode_u32(4),
		padded.size() - 8, "the header now counts the pad byte")
	h.equal("wave_pad.body_kept", counted.slice(8), padded.slice(8),
		"every byte past the size field is the shipped one")
	h.equal("wave_pad.source_untouched", padded.decode_u32(4), 31,
		"the buffer handed in is not written through")
	h.equal("wave_pad.exact_left_alone",
		AudioSystem.with_pad_counted(_riff(40, 32)).decode_u32(4), 32,
		"a file whose header already agrees is passed on unchanged")
	h.equal("wave_pad.short_left_alone",
		AudioSystem.with_pad_counted(_riff(40, 33)).decode_u32(4), 33,
		"a file shorter than its header claims still reports itself")
	h.equal("wave_pad.two_over_left_alone",
		AudioSystem.with_pad_counted(_riff(40, 30)).decode_u32(4), 30,
		"two bytes over is not a pad byte and is left to the loader")
	var alien: PackedByteArray = _riff(40, 31)
	alien.encode_u8(0, 0x52 + 1)
	h.equal("wave_pad.not_riff_left_alone",
		AudioSystem.with_pad_counted(alien).decode_u32(4), 31,
		"a buffer that does not open with RIFF is not rewritten")
	h.equal("wave_pad.too_short_left_alone",
		AudioSystem.with_pad_counted(PackedByteArray([0x52, 0x49])).size(), 2,
		"a buffer too short to hold a header is passed straight through")


## A buffer of `total` bytes whose `RIFF` size field says `claimed`.
static func _riff(total: int, claimed: int) -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	out.resize(total)
	out.encode_u32(0, 0x46464952)
	out.encode_u32(4, claimed)
	for i: int in range(8, total):
		out.encode_u8(i, i & 0xFF)
	return out


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
		var call: String = DictRead.as_string(kase["call"])
		var type_id: int = DictRead.as_int(kase["type_id"]) \
			if kase.has("type_id") else -1
		var got: Dictionary = {}
		if call == "second_human":
			got = events.second_human()
		elif call == "death":
			got = events.death_voice(DictRead.as_int(kase["species"]), type_id)
		else:
			got = events.pain(DictRead.as_int(kase["species"]), type_id)
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
	# docs/42 section 4.5 -- three unit types are silent whatever their
	# species, and the cursor still moves past them.
	var loud: AudioEvents = AudioEvents.open(fresh.tables(), {})
	var mute: AudioEvents = AudioEvents.open(fresh.tables(), {})
	h.check("mute_type.22_and_26_say_nothing",
		mute.pain(AudioEvents.SPECIES_HUMAN, 0x16).is_empty()
		and mute.death_voice(AudioEvents.SPECIES_HUMAN, 0x1A).is_empty(),
		"0x0040CBE2 clears the play flag for 22, 25 and 26")
	# Two calls were spent on each; the loud one spends the same two and both
	# must land on the same wave next, which is what "the cursor still moved"
	# means with a modulus of three.
	var _a: Dictionary = loud.pain(AudioEvents.SPECIES_HUMAN)
	var _b: Dictionary = loud.death_voice(AudioEvents.SPECIES_HUMAN)
	h.equal("mute_type.the_cursor_still_moved",
		DictRead.as_string(mute.pain(AudioEvents.SPECIES_HUMAN)["wave"]),
		DictRead.as_string(loud.pain(AudioEvents.SPECIES_HUMAN)["wave"]),
		"the gate is at 0x0040CBF2, past the round robin")
	h.check("silent_species", fresh.pain(2).is_empty(),
		"every species but human and alien is silent")
	# docs/42 section 4.5 -- the death scream: an alien off its own cursor at
	# the ids docs/28 once called unnamed, a machine's explosion, an object's
	# silence.
	var dying: AudioEvents = AudioEvents.open(tables, {})
	var alien_death: Dictionary = dying.death_voice(AudioEvents.SPECIES_ALIEN)
	h.check("death_alien_ids",
		not alien_death.is_empty() and DictRead.as_int(alien_death["volume_id"])
			== DictRead.as_int(DictRead.as_array(DictRead.as_dict(
				tables.voices())["death_alien_volume_ids"])[0]),
		"the alien death scream carries 53..55, %s" % str(alien_death))
	var blast: Dictionary = dying.death_voice(AudioEvents.SPECIES_MACHINE)
	h.check("death_machine_explodes",
		DictRead.as_string(blast.get("wave", "")) == "explosion.wav",
		str(blast))
	h.check("death_object_silent", dying.death_voice(2).is_empty(),
		"species 2 dies without a sound")
	# And the mute covers the explosion: the machine's arm jumps into the same
	# `0x0040CBD6` the screams do, and `0x0040CBDB` is the next thing after it.
	h.check("death_machine_is_muted",
		dying.death_voice(AudioEvents.SPECIES_MACHINE, 0x1A).is_empty(),
		"type 26 explodes silently")


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
	# One command, **two routines**: `ParaBombs` `0x00470790` runs the
	# fly-past and then the bomb run, so an alias could name only the first
	# and `crush.wav` @89 was never played. Every phase must reach a cue of
	# its own, or one of the two is silent again and nothing says so.
	var phase_bad: PackedStringArray = PackedStringArray()
	for kind: String in AudioEvents.EVENT_PHASES:
		var names: PackedStringArray = AudioEvents.phases_of(kind)
		if names.size() < 2:
			phase_bad.append("%s: %d phase(s)" % [kind, names.size()])
		for index: int in range(names.size()):
			if events.for_event_phase(kind, index).is_empty():
				phase_bad.append("%s[%d] %s" % [kind, index, names[index]])
	h.check("phases_resolve",
		phase_bad.is_empty() and not AudioEvents.EVENT_PHASES.is_empty(),
		"%d commands run two routines each, and both make a sound%s"
			% [AudioEvents.EVENT_PHASES.size(),
				"" if phase_bad.is_empty() else "; first: " + phase_bad[0]])
	# The two waves themselves, in the order `0x00470790` runs them:
	# `bomber.wav` @87 looping for `0x00415E90`, `crush.wav` @89 for
	# `0x004160F0` (docs/28 section 2).
	h.equal("para_bombs_phase_waves",
		[_waves_of(events.for_event_phase("para_bombs", 0)),
		_waves_of(events.for_event_phase("para_bombs", 1))],
		[PackedStringArray(["bomber.wav"]), PackedStringArray(["crush.wav"])],
		"the fly-past's wave, then the bomb run's")
	# A caller that cannot stage the phases gets both, in the same order --
	# which is what the computer's sound-only replay asks for.
	h.equal("para_bombs_whole_event",
		_waves_of(events.for_event_kind("para_bombs")),
		PackedStringArray(["bomber.wav", "crush.wav"]))
	h.equal("para_bombs_no_third_phase",
		events.for_event_phase("para_bombs", 2).size(), 0,
		"a phase the event does not have is empty, not an error")


## docs/28 section 2.5 -- the ten interface sites and the four waves they
## reach through the two modules' globals.
func _check_mission_interface(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var copied: Dictionary = DictRead.as_dict(
		DictRead.as_dict(document["document"])["waves"])
	var interface: Dictionary = DictRead.as_dict(
		DictRead.as_dict(document["document"])["interface"])
	var seen: Dictionary[String, bool] = {}
	for action: String in [AudioTables.INTERFACE_ORDER_MOVE,
			AudioTables.INTERFACE_ORDER_WARP, AudioTables.INTERFACE_RESELECT,
			AudioTables.INTERFACE_PAD_PRESS, AudioTables.INTERFACE_HOVER_CELL,
			AudioTables.INTERFACE_PAD_HOVER, AudioTables.INTERFACE_COLUMN_PRESS,
			AudioTables.INTERFACE_COLUMN_HOVER, AudioTables.INTERFACE_VIEW_MAP,
			AudioTables.INTERFACE_VIEW_UNIT]:
		var cue: Dictionary = tables.interface_cue(action)
		h.check("interface_%s" % action, not cue.is_empty(),
			"the sound document names the cue")
		if cue.is_empty():
			continue
		var wave: String = DictRead.as_string(cue["wave"])
		seen[wave] = true
		h.check("interface_%s_copied" % action, copied.has(wave),
			"%s is in the conversion's closure" % wave)
		# Every one of them is the id the authors labelled *gui-sounds*.
		h.equal("interface_%s_volume" % action,
			DictRead.as_int(cue["volume_id"]),
			DictRead.as_int(interface["volume_id"]))
	# The three ring arms really do reach three different actions, and the
	# selection's is `select.wav` rather than a click.
	h.equal("interface_ring_arms",
		[DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_ORDER_MOVE)["wave"]),
		DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_ORDER_WARP)["wave"]),
		DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_RESELECT)["wave"])],
		["click_5.wav", "click_5.wav", "click_5.wav"])
	h.equal("interface_selection_is_select_wav",
		DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_VIEW_UNIT)["wave"]), "select.wav")
	h.equal("interface_map_view_is_select_wav",
		DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_VIEW_MAP)["wave"]), "select.wav")
	# The two widgets' presses are `click_2` and their hover ticks `click_1`,
	# pad and columns alike (docs/28 section 2.5, corrected 2026-09-12).
	h.equal("interface_widget_presses",
		[DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_PAD_PRESS)["wave"]),
		DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_COLUMN_PRESS)["wave"])],
		["click_2.wav", "click_2.wav"])
	h.equal("interface_widget_hovers",
		[DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_PAD_HOVER)["wave"]),
		DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_COLUMN_HOVER)["wave"]),
		DictRead.as_string(tables.interface_cue(
			AudioTables.INTERFACE_HOVER_CELL)["wave"])],
		["click_1.wav", "click_1.wav", "click_1.wav"])
	# Four waves reached, and `textbeep` -- the shell's -- reached by none.
	h.equal("interface_waves_reached", seen.keys().size(), 4)
	h.check("interface_textbeep_is_the_shells",
		not seen.has("textbeep.wav"),
		"no mission action reaches the aGUI.cpp beep")
	h.check("interface_unknown_is_empty",
		tables.interface_cue("no-such-action").is_empty(),
		"an unnamed action is an empty cue, not a made-up one")


## docs/28 section 4.3 -- the speech switch, replayed through [SpeechPlayer].
func _check_speech(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var speech: Dictionary = DictRead.as_dict(
		DictRead.as_dict(document["document"])["speech"])
	h.equal("speech_volume_id", tables.speech_volume_id(),
		AudioTables.NO_SCALING)
	h.equal("speech_sets", DictRead.as_dict(speech["sets"]).keys().size(), 10)
	var speech_files: Dictionary = DictRead.as_dict(speech["files"])
	h.equal("speech_files", speech_files.keys().size(), 172)
	var carries_dead_category: bool = false
	for path: String in speech_files:
		var filename: String = path.get_file()
		var category: String = filename.substr(filename.length() - 8, 2)
		if category == "06" or category == "07":
			carries_dead_category = true
	h.check("speech_excludes_unreachable_categories",
		not carries_dead_category, "categories 06 and 07 have no caller")
	# The switch's own default, and the id an ordinary spawn leaves behind.
	h.equal("speech_unset_id_is_silent", tables.speech_wave(0, 1, 1), "")
	h.equal("speech_name", tables.speech_wave(11, 3, 2), "speech/5/rrd0302.wav")
	# `Mrd` ships no `0104`, so a name the arithmetic can produce resolves to
	# nothing -- which is silence and not an error.
	h.equal("speech_missing_file_is_silence", tables.speech_wave(6, 1, 4), "")

	var player: SpeechPlayer = SpeechPlayer.new()
	player.setup(tables)
	var healthy: Dictionary = {"player": 0, "type_id": 0, "hp": 10, "fp": 10,
		"speech": 1}
	var hurt: Dictionary = {"player": 0, "type_id": 0, "hp": 1, "fp": 10,
		"speech": 1}
	# The two selection arguments print two different categories -- 01 for a
	# marine that is fit and 02 for one that is not -- and both draw, so this
	# asks which category and not which index.
	var categories: Dictionary[int, bool] = {}
	for i: int in range(64):
		for unit: Dictionary in [healthy, hurt]:
			var cue: Dictionary = player.line("select", unit, 0)
			if cue.is_empty():
				continue
			categories[int(DictRead.as_string(cue["wave"]).substr(
				"speech/1/mano".length(), 2))] = true
	h.equal("speech_select_categories", categories.keys().size(), 2)
	h.check("speech_select_healthy_is_01", categories.has(1), "category 01")
	h.check("speech_select_hurt_is_02", categories.has(2), "category 02")
	# The cycle walks a cursor rather than drawing: `1, 2, 3, 4, 5, 0`, and the
	# two of those that name no shipped file are silence.
	var cycled: PackedStringArray = PackedStringArray()
	for i: int in range(6):
		var cue: Dictionary = player.line("cycle", healthy, 0)
		cycled.append("" if cue.is_empty() else DictRead.as_string(cue["wave"]))
	h.equal("speech_cycle_cursor", cycled, PackedStringArray([
		"speech/1/mano0301.wav", "speech/1/mano0302.wav",
		"speech/1/mano0303.wav", "speech/1/mano0304.wav", "", ""]))
	# The three gates in front of the whole routine.
	h.check("speech_other_seat_is_silent",
		player.line("select", healthy, 1).is_empty(),
		"a unit the current player does not own says nothing")
	var muted: Dictionary = healthy.duplicate()
	muted["type_id"] = tables.speech_mute_type()
	h.check("speech_mute_type_is_silent",
		player.line("select", muted, 0).is_empty(),
		"unit type 0x14 says nothing")
	h.check("speech_unknown_event_is_silent",
		player.line("no-such-event", healthy, 0).is_empty(),
		"an event no site asks for says nothing")


## docs/43 section 7 -- `aViewPlayer.cpp`'s own two buffers.
##
## The point of this one is the **closure**: the screen is the single place
## outside `aAnimations.cpp` and the id-96 set that names a wave, so a cue that
## resolved to a name the conversion does not copy would leave the whole
## computer turn silent with nothing failing.
func _check_view_player(h: TestHarness, tables: AudioTables,
		document: Dictionary) -> void:
	var copied: Dictionary = DictRead.as_dict(
		DictRead.as_dict(document["document"])["waves"])
	for name: String in [AudioTables.VIEW_PLAYER_PROGRESS,
			AudioTables.VIEW_PLAYER_ALARM]:
		var cue: Dictionary = tables.view_player_cue(name)
		h.check("view_player_%s" % name, not cue.is_empty(),
			"the sound document names the cue")
		if cue.is_empty():
			continue
		var wave: String = DictRead.as_string(cue["wave"])
		h.check("view_player_%s_copied" % name, copied.has(wave),
			"%s is in the conversion's closure" % wave)
		# Neither goes through the volume table: `aDirectSoundPlay(handle, 0)`
		# takes the buffer and nothing else.
		h.equal("view_player_%s_volume" % name,
			DictRead.as_int(cue["volume_id"]), AudioTables.NO_SCALING)
	h.check("view_player_unknown_is_empty",
		tables.view_player_cue("no-such-buffer").is_empty(),
		"an unnamed buffer is an empty cue, not a made-up one")


## The waves of a cue list, for a check that is about which sound and not
## about how loud.
static func _waves_of(cues: Array[Dictionary]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for cue: Dictionary in cues:
		out.append(DictRead.as_string(cue["wave"]))
	return out


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
