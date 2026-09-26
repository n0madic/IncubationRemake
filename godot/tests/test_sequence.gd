extends TestSuite

## The sequence player -- docs/41, docs/92 section 7.19.
##
## Oracle boundary: **specification-only**, and deliberately so. The manifest,
## the CD programs, the Focus table and the note grammar are pinned to the
## executable by `tools/seq_parse.py --check` (144 checks), and the converter
## copies that reading into the cache verbatim, which `remake_convert.py
## --check` diffs. What this suite owns is the GDScript that consumes it: that
## every directory opens and every model has its `Cam1`, that every `Switch`
## names a bone, that the clock runs at 30 fps and a shot ends at its clip's
## length with the next pair installed in the same update, that a part's
## program is announced once and `Seq_5`'s silence keeps `Seq_4`'s track, and
## that the gate plays the intro once and the two endings by mission id.
##
## **No Python twin** (docs/92 section 5.1): the rule is arithmetic over one
## clock and a table, not over a corpus, so the spec check plus this is the
## whole of it.

## `Focus 43` at 480 rows is the default preset (docs/41 section 4).
const FOCAL_43: int = 765
## The seven ids the manifest carries.
const IDS: Array[int] = [0, 1, 2, 3, 7, 14, 15]
## What fraction of the shots must put the scene's joints in front of the
## camera under [constant SequencePlayer.CAMERA_BASIS_FIX]. The measurement is
## what pins the axis convention: a wrong axis puts roughly half the shots
## behind the lens.
const IN_FRONT_LEAST: float = 0.9
## The roll: how close the lens' own up has to be to the world's, and on what
## share of the poses. 0.7 is 45 degrees -- wide enough for a camera that
## banks and tilts, far too narrow for a frame carrying a quarter turn.
const UPRIGHT_LEAST: float = 0.7
const UPRIGHT_SHOTS: float = 0.9

var _cache_dir: String = ""
var _manifest: Dictionary = {}
## Every measured pose's `up . world up`, filled by [method _facing].
var _rolls: PackedFloat32Array = PackedFloat32Array()
var _programs: PackedStringArray = PackedStringArray()


func run(h: TestHarness) -> void:
	h.begin("sequence", TestHarness.ORACLE_SPEC)
	_cache_dir = CacheFixture.cache_dir()
	_manifest = CacheLoader.read_json(_cache_dir + "/tables/sequences.json")
	if _manifest.is_empty():
		h.check("manifest", false,
			"no tables/sequences.json: " + CacheFixture.missing_hint())
		return
	_manifest_shape(h)
	_directories(h)
	_focus(h)
	_clock(h)
	_programs_and_parts(h)
	_camera_axis(h)
	_gate(h)
	_holds(h)
	_dismissal(h)
	_boot(h)
	_fly_in(h)
	_re_entry(h)
	_shot_holes(h)


func _manifest_shape(h: TestHarness) -> void:
	h.equal("manifest.schema", DictRead.as_string(_manifest["schema"]),
		"incubation.sequences/1")
	h.equal("manifest.frame_rate", DictRead.as_int(_manifest["frame_rate"]), 30)
	h.equal("manifest.cd_family",
		DictRead.as_string(_manifest["cd_family"]).to_lower(),
		AudioTables.FAMILY_TRACK,
		"the family that covers 9..19; missions keep Arack (docs/28 6.1)")
	var ids: Array[int] = []
	var pairs: int = 0
	for entry: Variant in DictRead.as_array(_manifest["sequences"]):
		var sequence: Dictionary = DictRead.as_dict(entry)
		ids.append(DictRead.as_int(sequence["id"]))
		for part: Variant in DictRead.as_array(sequence["parts"]):
			pairs += DictRead.as_array(DictRead.as_dict(part)["animations"]).size()
	h.equal("manifest.ids", ids, IDS)
	h.equal("manifest.pairs", pairs, 130)
	h.equal("manifest.directories",
		DictRead.as_array(_manifest["directories"]).size(), 12)
	var camera: Dictionary = DictRead.as_dict(_manifest["camera"])
	h.equal("manifest.default_camera", DictRead.as_int(camera["default_index"]),
		SequencePlayer.DEFAULT_CAMERA)
	h.equal("manifest.construction_focal",
		[DictRead.as_int(camera["focal_default_full"]),
		DictRead.as_int(camera["focal_default_framed"])],
		[SequencePlayer.construction_focal(640),
		SequencePlayer.construction_focal(518)],
		"`_ftol(width * 10/13)`: 492 and 398, not the 765 preset")
	h.equal("manifest.no_float_ratio", DictRead.to_int32(camera["focal_ratio"]),
		PackedInt32Array([10, 13]), "the cache holds no float")


## Every directory opens, every model has `Cam1`, every `Switch` resolves.
func _directories(h: TestHarness) -> void:
	var models: int = 0
	var switches: int = 0
	var unresolved: PackedStringArray = PackedStringArray()
	var no_cam1: PackedStringArray = PackedStringArray()
	var unopened: PackedStringArray = PackedStringArray()
	var meshless: PackedStringArray = PackedStringArray()
	for entry: Variant in DictRead.as_array(_manifest["sequences"]):
		var sequence: Dictionary = DictRead.as_dict(entry)
		for part_entry: Variant in DictRead.as_array(sequence["parts"]):
			var part: Dictionary = DictRead.as_dict(part_entry)
			var directory: String = DictRead.as_string(part["directory"])
			var library: SequenceLibrary = SequenceLibrary.open_directory(
				_cache_dir, directory)
			if library == null:
				unopened.append(directory)
				continue
			var model_names: PackedStringArray = DictRead.to_strings(part["models"])
			var clip_names: PackedStringArray = DictRead.to_strings(
				part["animations"])
			for index: int in range(clip_names.size()):
				var model: CharismaModel = library.model(model_names[index])
				var clip: CharismaClip = library.clip(clip_names[index])
				if model == null or clip == null:
					unopened.append("%s/%s" % [directory, clip_names[index]])
					continue
				models += 1
				if not model.bones.has("Cam1"):
					no_cam1.append(model.name)
				var drawn: bool = false
				for bone: String in model.bones:
					if model.mesh_of(bone) != "" and library.mesh(
							model.mesh_of(bone)) != null:
						drawn = true
						break
				if not drawn:
					meshless.append(model.name)
				for note: Dictionary in clip.notes:
					for line: String in DictRead.as_string(note["text"]) \
							.replace("\r", "\n").split("\n", false):
						var text: String = line.strip_edges()
						if not text.begins_with(SequencePlayer.NOTE_SWITCH + " "):
							continue
						switches += 1
						var bone: String = SequencePlayer.CAMERA_PREFIX + str(
							SequencePlayer.atoi(text.substr(7).strip_edges()))
						if not model.bones.has(bone):
							unresolved.append("%s: %s" % [clip.name, bone])
	h.equal("directories.all_open", unopened, PackedStringArray())
	h.equal("directories.pairs_loaded", models, 130)
	h.equal("directories.cam1_everywhere", no_cam1, PackedStringArray())
	h.equal("directories.switches", switches, 55,
		"the corpus count docs/40 section 9 records")
	h.equal("directories.switches_resolve", unresolved, PackedStringArray())
	h.equal("directories.every_model_draws", meshless, PackedStringArray(),
		"every model's meshes are in its directory's geometry")
	h.check("directories.missing_is_null",
		SequenceLibrary.open_directory(_cache_dir, "No_Such") == null)


func _focus(h: TestHarness) -> void:
	var player: SequencePlayer = SequencePlayer.new()
	var created: bool = player.create(_cache_dir, _manifest, 2,
		Rect2(0.0, 0.0, 640.0, 480.0), Vector2(640.0, 480.0))
	h.check("focus.player_creates", created)
	h.equal("focus.presets_at_480",
		[player.focus_focal(24, 480), player.focus_focal(28, 480),
		player.focus_focal(35, 480), player.focus_focal(43, 480),
		player.focus_focal(50, 480), player.focus_focal(85, 480),
		player.focus_focal(135, 480), player.focus_focal(200, 480)],
		[400, 500, 613, FOCAL_43, 877, 1477, 2350, 3500],
		"the seven `mov eax, imm32` arms and the default, 0x004804FE..2F")
	h.equal("focus.outside_the_table_is_default",
		[player.focus_focal(43, 480), player.focus_focal(0, 480),
		player.focus_focal(300, 480)], [FOCAL_43, FOCAL_43, FOCAL_43])
	h.equal("focus.framed_scales_by_height", player.focus_focal(43, 306),
		int(765.0 * 306.0 / 480.0),
		"`[ebp+0x40] / 480`, truncated; exactly the preset at 480")
	h.equal("focus.construction", player.focal, 492,
		"before any note: `_ftol(640 * 10/13)`")
	h.equal("focus.atof", [SequencePlayer.atof("43..0"),
		SequencePlayer.atof("28.0"), SequencePlayer.atof("x")], [43.0, 28.0, 0.0])
	h.equal("focus.atoi", [SequencePlayer.atoi("2"), SequencePlayer.atoi("12x"),
		SequencePlayer.atoi("")], [2, 12, 0])
	player.destroy()
	player.free()


## The clock is `delta * 30`, a shot ends at its clip's length and the next
## pair is installed in the same update at frame 0.
func _clock(h: TestHarness) -> void:
	var player: SequencePlayer = SequencePlayer.new()
	h.check("clock.refuses_unknown_id",
		not player.create(_cache_dir, _manifest, 4,
			Rect2(0.0, 0.0, 640.0, 480.0), Vector2(640.0, 480.0)),
		"4 is not one of the seven; the compressed switch rejects it")
	# Dialog_03: nine pairs in one part.
	var created: bool = player.create(_cache_dir, _manifest, 3,
		Rect2(0.0, 0.0, 640.0, 480.0), Vector2(640.0, 480.0))
	h.check("clock.creates", created)
	h.check("clock.update_before_start_is_false", not player.update(0.1))
	h.check("clock.starts", player.start())
	h.check("clock.second_start_refused", not player.start(),
		"aStartSeqPlayer refuses a running player")
	h.equal("clock.opens_on_part_0_shot_0", [player.part, player.shot],
		[0, 0])
	var view: Dictionary = player.view()
	h.equal("clock.view", [DictRead.as_int(view["id"]),
		DictRead.as_string(view["directory"]),
		DictRead.as_int(view["camera"]), DictRead.as_bool(view["playing"])],
		[3, "Dialog_03", 1, true])
	for _step: int in range(10):
		var _still: bool = player.update(1.0 / 30.0)
	h.check("clock.ten_thirtieths_are_ten_frames",
		absf(player.frame - 10.0) < 1e-6, "frame %f" % player.frame)
	# Step to just short of the clip's end, then past it.
	var library: SequenceLibrary = SequenceLibrary.open_directory(_cache_dir,
		"Dialog_03")
	var first: CharismaClip = library.clip("Animation_D03_1")
	h.check("clock.clip_has_length", first != null and first.duration > 10.0)
	var remaining: float = first.duration - player.frame
	var _before: bool = player.update((remaining - 0.5) / 30.0)
	h.equal("clock.short_of_the_end_stays", player.shot, 0)
	var still: bool = player.update(1.0 / 30.0)
	h.check("clock.past_the_end_installs_the_next_pair",
		still and player.shot == 1 and player.frame == 0.0
		and player.part == 0,
		"shot %d frame %f" % [player.shot, player.frame])
	h.equal("clock.camera_resets_per_pair", player.camera_index, 1,
		"0x0048023B")
	# The focal is **not** reset by the install: `Animation_D03_1`'s own
	# `Focus 43` notes fired on the way to its end and left 765, and the
	# next pair opens at that value rather than at the construction 492.
	var last_focus: int = -1
	for note: Dictionary in first.notes:
		for line: String in DictRead.as_string(note["text"]) \
				.replace("\r", "\n").split("\n", false):
			var text: String = line.strip_edges()
			if text.begins_with(SequencePlayer.NOTE_FOCUS + " "):
				last_focus = int(SequencePlayer.atof(text.substr(6).strip_edges()))
	h.check("clock.first_clip_has_focus_notes", last_focus > 0)
	h.equal("clock.focal_carries_across_shots", player.focal,
		player.focus_focal(last_focus, 480),
		"no write to [esi+0x58] in the pair installer: the last Focus of the "
		+ "clip before, not the construction 492")
	var second: CharismaClip = library.clip("Animation_D03_2")
	var _to_end: bool = player.update((second.duration + 0.5) / 30.0)
	h.equal("clock.third_pair", player.shot, 2)
	# Run the rest out: the last pair's end returns false.
	var updates: int = 0
	var ended: bool = false
	while updates < 200000:
		updates += 1
		if not player.update(1.0):
			ended = true
			break
	h.check("clock.last_pair_ends_the_sequence", ended
		and player.shot == 8 and player.part == 0, "updates %d" % updates)
	player.destroy()
	h.check("clock.destroy_clears_both_flags",
		not player.active and not player.running)
	player.free()
	_head_notes(h)


## A `Switch` at frame 0 names the shot's camera **before its first frame**:
## the installer fires the head notes, so the update that installs a pair
## already answers with that camera rather than with `Cam1` for one frame.
## UNVERIFIED against the original's order (docs/41 section 7 item 2).
func _head_notes(h: TestHarness) -> void:
	var found_id: int = -1
	var found_part: int = -1
	var found_shot: int = -1
	var found_camera: int = -1
	for entry: Variant in DictRead.as_array(_manifest["sequences"]):
		var sequence: Dictionary = DictRead.as_dict(entry)
		var parts: Array = DictRead.as_array(sequence["parts"])
		for part_index: int in range(parts.size()):
			var part: Dictionary = DictRead.as_dict(parts[part_index])
			var library: SequenceLibrary = SequenceLibrary.open_directory(
				_cache_dir, DictRead.as_string(part["directory"]))
			if library == null:
				continue
			var clips: PackedStringArray = DictRead.to_strings(
				part["animations"])
			for shot_index: int in range(clips.size()):
				var clip: CharismaClip = library.clip(clips[shot_index])
				if clip == null:
					continue
				for note: Dictionary in clip.notes:
					if DictRead.as_float(note["time"]) > 0.0:
						continue
					var text: String = DictRead.as_string(note["text"]) \
						.strip_edges()
					if text.begins_with(SequencePlayer.NOTE_SWITCH + " "):
						found_camera = SequencePlayer.atoi(
							text.substr(SequencePlayer.NOTE_SWITCH.length() + 1)
								.strip_edges())
				if found_camera > 0 and found_camera != SequencePlayer.DEFAULT_CAMERA:
					found_id = DictRead.as_int(sequence["id"])
					found_part = part_index
					found_shot = shot_index
					break
			if found_id >= 0:
				break
		if found_id >= 0:
			break
	h.check("head_notes.a_frame_0_switch_exists", found_id >= 0,
		"26 of the cache's 166 notes sit at the head of their clip")
	if found_id < 0:
		return
	var player: SequencePlayer = SequencePlayer.new()
	var _created: bool = player.create(_cache_dir, _manifest, found_id,
		Rect2(0.0, 0.0, 640.0, 480.0), Vector2(640.0, 480.0))
	var _started: bool = player.start()
	var updates: int = 0
	while (player.part != found_part or player.shot != found_shot) \
			and updates < 200000:
		updates += 1
		if not player.update(1.0):
			break
	h.equal("head_notes.the_pair_is_reached", [player.part, player.shot],
		[found_part, found_shot], "sequence %d, %d updates" % [found_id, updates])
	h.equal("head_notes.the_camera_is_named_before_the_first_frame",
		[player.camera_index, player.frame], [found_camera, 0.0],
		"the switch fired in the install, not one update later")
	player.destroy()
	player.free()


## A part's non-empty program is announced when the part is installed;
## Seq_5's empty string keeps Seq_4's track.
func _programs_and_parts(h: TestHarness) -> void:
	var player: SequencePlayer = SequencePlayer.new()
	_programs = PackedStringArray()
	player.cd_program.connect(func(program: String) -> void:
		_programs.append(program))
	# Logical id 7: Dialog_07 (one pair) then Dialog_09 (eighteen).
	var _created: bool = player.create(_cache_dir, _manifest, 7,
		Rect2(65.0, 57.0, 518.0, 306.0), Vector2(640.0, 480.0))
	h.equal("parts.framed_construction_focal", player.focal, 398,
		"`_ftol(518 * 10/13)`")
	var _started: bool = player.start()
	h.equal("parts.first_program", _programs, PackedStringArray(["14,30"]))
	var library: SequenceLibrary = SequenceLibrary.open_directory(_cache_dir,
		"Dialog_07")
	var clip: CharismaClip = library.clip("Animation_D07")
	var still: bool = player.update((clip.duration + 1.0) / 30.0)
	h.check("parts.list_end_installs_the_next_part",
		still and player.part == 1 and player.shot == 0
		and DictRead.as_string(player.view()["directory"]) == "Dialog_09",
		str(player.view()))
	h.equal("parts.second_program", _programs,
		PackedStringArray(["14,30", "15,30"]))
	h.equal("parts.dialog_09_shares_one_model",
		DictRead.as_string(player.view()["clip"]), "Animation_D09_1")
	player.destroy()
	player.free()

	var seq_5: Dictionary = {}
	for entry: Variant in DictRead.as_array(_manifest["sequences"]):
		var sequence: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_int(sequence["id"]) == 0:
			var parts: Array = DictRead.as_array(sequence["parts"])
			seq_5 = DictRead.as_dict(parts[3])
	h.equal("parts.seq_5_keeps_the_track",
		[DictRead.as_string(seq_5["directory"]),
		DictRead.as_string(seq_5["cd_program"]),
		DictRead.as_int(seq_5["cd_track"])], ["Seq_5", "", -1],
		"the one arm that loads the zero-initialised global 0x004FA524")
	h.equal("parts.playlist_separators",
		AudioTables.parse_playlist("9,30"), PackedInt32Array([9, 30]),
		"the comma is one of strtok's nine separators (0x004C2768)")
	h.equal("parts.playlist_dots_still_parse",
		AudioTables.parse_playlist("5.3.4.2"), PackedInt32Array([5, 3, 4, 2]))
	# The wrap: 30 is no file, so the player loops the one track it has.
	var music: MusicPlayer = MusicPlayer.from_program("9,30",
		PackedInt32Array([9, 10, 11]))
	h.equal("parts.terminator_loops_the_track",
		[music.first_playable(), music.next_playable(), music.next_playable()],
		[9, 9, 9], "0x0042BC10 wraps a -1 entry to index 0")


## The camera bone's forward axis, measured over every shot: under
## [constant SequencePlayer.CAMERA_BASIS_FIX] the scene's joints stand in
## front of the lens in 514 of 520 poses (the probe of 2026-09-08 over all
## six axes: -Z 0.99, every other one 0.46..0.54). The roll is not measured
## here and is **UNVERIFIED** against the original (docs/41 section 4).
func _camera_axis(h: TestHarness) -> void:
	_rolls = PackedFloat32Array()
	var shots: int = 0
	var in_front: int = 0
	var behind: PackedStringArray = PackedStringArray()
	for entry: Variant in DictRead.as_array(_manifest["sequences"]):
		var sequence: Dictionary = DictRead.as_dict(entry)
		for part_entry: Variant in DictRead.as_array(sequence["parts"]):
			var part: Dictionary = DictRead.as_dict(part_entry)
			var library: SequenceLibrary = SequenceLibrary.open_directory(
				_cache_dir, DictRead.as_string(part["directory"]))
			if library == null:
				continue
			var model_names: PackedStringArray = DictRead.to_strings(part["models"])
			var clip_names: PackedStringArray = DictRead.to_strings(
				part["animations"])
			for index: int in range(clip_names.size()):
				var model: CharismaModel = library.model(model_names[index])
				var clip: CharismaClip = library.clip(clip_names[index])
				if model == null or clip == null:
					continue
				for at: float in [0.0, clip.duration * 0.5]:
					var verdict: int = _facing(model, clip, at)
					if verdict == 0:
						continue
					shots += 1
					if verdict > 0:
						in_front += 1
					else:
						behind.append("%s@%d" % [clip.name, int(at)])
	h.check("camera.shots_measured", shots >= 200, "%d shots" % shots)
	var fraction: float = float(in_front) / float(maxi(shots, 1))
	h.check("camera.joints_in_front_of_the_lens", fraction >= IN_FRONT_LEAST,
		"%d of %d shots (%.2f) under CAMERA_BASIS_FIX; behind: %s"
		% [in_front, shots, fraction, ", ".join(behind.slice(0, 8))])
	# The roll, the other half of the convention. There is no second reading
	# of it in the data, so what is measured is the scenes themselves: every
	# shipped cutscene is a built world with a sky above it, and a camera
	# whose bone frame carried a quarter or a half turn would hold that world
	# on its side or upside down. The up axis of the same 520 poses agrees
	# with the world's up.
	var upright: int = 0
	for cosine: float in _rolls:
		if cosine >= UPRIGHT_LEAST:
			upright += 1
	var level: float = float(upright) / float(maxi(_rolls.size(), 1))
	h.check("camera.up_is_the_world_s_up", level >= UPRIGHT_SHOTS,
		"%d of %d poses have the lens' own up within %.0f degrees of the "
		% [upright, _rolls.size(), rad_to_deg(acos(UPRIGHT_LEAST))]
		+ "scene's (%.2f); a quarter or half turn in the bone frame would "
		% level
		+ "put this near zero")


## +1 when the mean joint of the drawn parts is in front of `Cam1`, -1 when
## behind, 0 when the model has no drawn part to measure.
func _facing(model: CharismaModel, clip: CharismaClip, at: float) -> int:
	var posed: CharismaSkeleton = CharismaSkeleton.pose(model, clip, at)
	var sum: Vector3 = Vector3.ZERO
	var count: int = 0
	for bone: String in model.bones:
		if model.mesh_of(bone) == "" or bone.begins_with(
				SequencePlayer.CAMERA_PREFIX):
			continue
		var world: PackedFloat64Array = posed.world_matrix(bone)
		sum += WorldSpace.to_godot_v(Vector3(world[3], world[7], world[11])
			* SequencePlayer.SKELETON_TO_WORLD)
		count += 1
	if count == 0 or not model.bones.has("Cam1"):
		return 0
	var cam: PackedFloat64Array = posed.world_matrix("Cam1")
	cam[3] *= SequencePlayer.SKELETON_TO_WORLD
	cam[7] *= SequencePlayer.SKELETON_TO_WORLD
	cam[11] *= SequencePlayer.SKELETON_TO_WORLD
	var placed: Transform3D = SequencePlayer.camera_transform(cam)
	var forward: Vector3 = -placed.basis.z
	_rolls.append(placed.basis.y.normalized().dot(Vector3.UP))
	var to_scene: Vector3 = sum / float(count) - placed.origin
	if to_scene.length() < 1e-3:
		return 0
	return 1 if forward.dot(to_scene) > 0.0 else -1


## The upgrade base's arrival flight, `0x00417000` (docs/27 section 2.7).
##
## The law is arithmetic, so it is checked as arithmetic: the direction helper
## `0x0046d400` against its horizontal shapes and its vertical one -- the run
## is in eighths as well as the rise, which is what `upgrade_8`'s own first
## leg is here to pin -- the first frame's step against the 20 units the old
## constant used to be, and a whole flight down a synthetic path against the
## arrival, the landing countdown and the frame count. The eye must **reach**
## its path -- a step law that does not converge would run for ever behind a
## plate with no way out but a key.
func _fly_in(h: TestHarness) -> void:
	# The two horizontal components over the larger of them: the dominant
	# axis is exactly one, whichever it is, and a flat leg has no vertical.
	var east: Vector3 = SliceMain.fly_direction(Vector3i.ZERO,
		Vector3i(1000, 500, 0))
	h.check("fly.dominant_axis_is_one",
		is_equal_approx(east.x, 1.0) and is_equal_approx(east.y, 0.5)
		and is_zero_approx(east.z),
		"a 2:1 leg east: %v" % east)
	var north: Vector3 = SliceMain.fly_direction(Vector3i.ZERO,
		Vector3i(-500, -1000, 0))
	h.check("fly.the_larger_component_wins",
		is_equal_approx(north.y, -1.0) and is_equal_approx(north.x, -0.5),
		"a 1:2 leg south-west: %v" % north)
	var straight: Vector3 = SliceMain.fly_direction(Vector3i.ZERO,
		Vector3i(0, 900, 0))
	h.check("fly.a_leg_with_no_run", is_equal_approx(straight.y, 1.0)
		and is_zero_approx(straight.x), "%v" % straight)
	# The height is the difference over the horizontal distance with **all
	# six** coordinates in eighths: `(goal.z >> 3) - (eye.z >> 3)` over
	# `0x0044ae10(eye.x >> 3, eye.y >> 3, goal.x >> 3, goal.y >> 3)`. The two
	# eighths cancel, so a leg that rises as far as it runs rises at one.
	var climb: Vector3 = SliceMain.fly_direction(Vector3i.ZERO,
		Vector3i(8000, 0, 8000))
	h.check("fly.the_run_is_in_eighths_too", is_equal_approx(climb.z, 1.0),
		"%v -- 8000 up over 8000 across is one, not an eighth" % climb)
	# `upgrade_8`'s own first leg, which is what this cost: the base opens
	# 12000 under the ground and the flight has to lift the eye out of it.
	# Dividing the rise in eighths by the **unshifted** run gives 0.1485 and
	# the eye crawls along the street for the whole eleven seconds; the two
	# candidates are required to differ before either is compared, so a
	# `flat` computed the other way cannot pass this by arithmetic accident.
	# Both divisors are literals worked out from the listing rather than from
	# the shipped expression, so this is a measurement and not a restatement:
	# the rise is `(4000 >> 3) - (-12000 >> 3)` = 2000, the run in eighths is
	# `_ftol(hypot(4084 - 4314, -1254 - 414))` = 1683, and the whole run is
	# `_ftol(hypot(-1840, -13344))` = 13470.
	var eye: Vector3i = Vector3i(32672, -10032, -12000)
	var goal: Vector3i = Vector3i(34512, 3312, 4000)
	var shifted: float = 2000.0 / 1683.0
	var whole: float = 2000.0 / 13470.0
	h.check("fly.the_two_runs_disagree", absf(shifted - whole) > 0.5,
		"%.4f in eighths against %.4f whole" % [shifted, whole])
	h.check("fly.upgrade_8_lifts_the_eye_out",
		is_equal_approx(SliceMain.fly_direction(eye, goal).z, shifted),
		"%v -- 2000/1683, eight times the climb 2000/13470 would give"
		% SliceMain.fly_direction(eye, goal))
	# Each coordinate is shifted on its own. `sar` floors, so this leg's run
	# is 1000 eighths one way and 999 the other. The case is put on a
	# negative coordinate because that is also where GDScript's `>>` has to
	# floor as `sar` does, and nine of the fifteen bases carry one in their
	# first waypoint.
	var straddle: Vector3 = SliceMain.fly_direction(Vector3i(1, 0, 0),
		Vector3i(-7998, 0, 8000))
	h.check("fly.each_coordinate_is_shifted_on_its_own",
		is_equal_approx(straddle.z, 1000.0 / 1000.0)
		and not is_equal_approx(1000.0 / 1000.0, 1000.0 / 999.0),
		"%v -- 1000 apart in eighths, not (1 - -7998) >> 3 = 999" % straddle)
	# The first frame steps 800/40 = 20 on the dominant axis, which is the
	# whole of what the constant used to say; by the floor it is 800/5.
	h.equal("fly.first_frame_is_twenty",
		int(east.x * float(SliceMain.FLY_SPEED)) / SliceMain.FLY_SMOOTH_START,
		20)
	h.equal("fly.the_floor_is_the_top_speed",
		SliceMain.FLY_SPEED / SliceMain.FLY_SMOOTH_FLOOR, 160)
	# A whole flight down `upgrade_1`'s own shape: three waypoints, the last
	# leg counting itself down. It has to land, and in a cinematic number of
	# frames rather than in three or in three thousand.
	var path: Array[Vector3i] = [
		Vector3i(60000, 40000, 12000),
		Vector3i(69520, 86192, 20000),
		Vector3i(111328, 107552, 36000)]
	var flown: Dictionary = _fly(path)
	h.check("fly.lands", DictRead.as_bool(flown["landed"]),
		"%d frames, %d legs left" % [DictRead.as_int(flown["frames"]),
		DictRead.as_int(flown["leg"])])
	var frames: int = DictRead.as_int(flown["frames"])
	h.check("fly.takes_a_few_seconds", frames >= 40 and frames <= 400,
		"%d frames at %d a second is %.1f s"
		% [frames, int(SliceMain.FLY_FPS), float(frames) / SliceMain.FLY_FPS])


## Fly a whole path by calling [method SliceMain.fly_advance] itself.
##
## **The production copy, not a second transcription.** This loop used to
## restate the step law, which proved the law and left a drift inside the
## shipped arithmetic invisible; the only thing left here is the waypoint
## bookkeeping [method SliceMain._fly_step] does around it, which needs a rig
## and a screen this suite has neither of.
func _fly(path: Array[Vector3i]) -> Dictionary:
	var state: Dictionary = {
		"eye": path[0],
		"velocity": Vector3i.ZERO,
		"smooth": SliceMain.FLY_SMOOTH_START,
		"leg_from": path[0],
		"first": true,
		"landed": false,
	}
	var frames: int = 0
	var leg: int = 1
	while leg < path.size():
		var step: Dictionary = SliceMain.fly_advance(
			state, path[leg], leg == path.size() - 1)
		state["velocity"] = step["velocity"]
		state["smooth"] = step["smooth"]
		state["leg_from"] = step["leg_from"]
		state["first"] = step["first"]
		state["landed"] = step["landed"]
		if DictRead.as_bool(step["stop"]):
			return {"landed": true, "frames": frames, "leg": leg}
		if DictRead.as_bool(step["arrived"]):
			leg += 1
			continue
		state["eye"] = step["eye"]
		frames += 1
		if frames > 5000:
			return {"landed": false, "frames": frames, "leg": leg}
	return {"landed": true, "frames": frames, "leg": path.size()}


## `0x00456FC0(-1)`: the intro once on mission id 1, the two endings by id.
func _gate(h: TestHarness) -> void:
	var host: CampaignHost = CampaignHost.create(_cache_dir,
		CacheFixture.balance())
	h.equal("gate.no_state_is_none",
		DictRead.as_string(host.opening_sequence()["kind"]),
		CampaignHost.OPENING_NONE)
	var state: CampaignState = host.start_new(1)
	h.check("gate.campaign_1_arms_the_intro", state.intro_pending,
		"0x00450997: push 1 on the campaign-1 arm")
	var first: Dictionary = host.opening_sequence()
	h.equal("gate.intro_once", [DictRead.as_string(first["kind"]),
		DictRead.as_int(first["sequence"]), DictRead.as_bool(first["full_screen"])],
		[CampaignHost.OPENING_INTRO, 0, true])
	h.check("gate.intro_consumes_the_flag", not state.intro_pending
		and DictRead.as_string(host.opening_sequence()["kind"])
		== CampaignHost.OPENING_NONE, "0x004570B6 clears it")
	var second: CampaignState = host.start_new(2)
	h.check("gate.campaign_2_never_arms_it", not second.intro_pending,
		"0x00450A11: push 0 on the other arm")
	second.mission = "_C_180"
	h.equal("gate.mission_180_is_the_static_extro",
		DictRead.as_string(host.opening_sequence()["kind"]),
		CampaignHost.OPENING_STATIC_EXTRO)
	h.check("gate.180_is_an_ending", host.at_an_ending())
	second.mission = "_C_YYY"
	h.check("gate.yyy_is_a_mission_row", host.tables.has_mission("_C_YYY")
		and host.tables.mission_id("_C_YYY") == 255,
		"docs/27 6.6 corrected: _C_133 hands over to mission id 255")
	var extro: Dictionary = host.opening_sequence()
	h.equal("gate.mission_255_is_the_animated_extro",
		[DictRead.as_string(extro["kind"]), DictRead.as_int(extro["sequence"]),
		DictRead.as_bool(extro["full_screen"])],
		[CampaignHost.OPENING_EXTRO, 1, true])
	second.mission = "_C_141"
	h.equal("gate.an_ordinary_mission_is_none",
		DictRead.as_string(host.opening_sequence()["kind"]),
		CampaignHost.OPENING_NONE)
	h.check("gate.141_is_no_ending", not host.at_an_ending())
	# The flag rides in the save.
	second.intro_pending = true
	var back: CampaignState = CampaignState.from_view(second.view())
	h.check("gate.flag_survives_the_codec", back.intro_pending
		and back.digest_hex() == second.digest_hex())
	var old: Dictionary = second.view()
	var _erased: bool = old.erase("intro_pending")
	h.check("gate.older_save_is_not_re_armed",
		not CampaignState.from_view(old).intro_pending,
		"a loaded game never re-arms the intro")


## The three holds count down in drawn time.
func _holds(h: TestHarness) -> void:
	var main: SliceMain = SliceMain.new()
	h.equal("holds.fallbacks", [main.hold_ms("logo", 1500),
		main.hold_ms("after_sequence", 1000), main.hold_ms("after_extro", 4000)],
		[1500, 1000, 4000], "the cache's document or aGameIntro's own numbers")
	var fired: Array[int] = []
	main.hold(100, func() -> void: fired.append(1))
	h.check("holds.counting", main.holding())
	main._tick_hold(0.05)
	h.check("holds.not_yet", fired.is_empty() and main.holding())
	main._tick_hold(0.06)
	h.check("holds.fires_once_at_zero", fired.size() == 1 and not main.holding())
	main._tick_hold(1.0)
	h.equal("holds.does_not_fire_again", fired.size(), 1)
	main.hold(0, func() -> void: fired.append(2))
	h.equal("holds.zero_fires_at_once", fired, [1, 2])
	# **A hold that has been overtaken does not raise anything.** The original
	# `Sleep`s block, so nothing can get in front of one; here a screen raised
	# while one is counting would be replaced a moment later by the hold's own
	# callback. Found through the control server, whose `wait` counts frames
	# while a hold counts seconds. `campaign` is null on a bare instance, so
	# the screen is not built -- the cancel happens before that and is what is
	# being read.
	main.hold(100, func() -> void: fired.append(3))
	var _raised: CampaignScreen = main.show_campaign_screen(
		CampaignHost.SCREEN_MAP)
	h.check("holds.a_raised_screen_cancels_one", not main.holding(),
		"show_campaign_screen dropped the countdown")
	main._tick_hold(1.0)
	h.equal("holds.the_cancelled_one_never_fires", fired, [1, 2])
	main.free()


## Any key or click ends the sequence and the title.
func _dismissal(h: TestHarness) -> void:
	var screen: SequenceScreen = SequenceScreen.new()
	screen.full = true
	var heard: PackedStringArray = PackedStringArray()
	screen.chose.connect(func(action: String) -> void: heard.append(action))
	var key: InputEventKey = InputEventKey.new()
	key.keycode = KEY_SPACE
	key.pressed = true
	screen._unhandled_input(key)
	var release: InputEventKey = InputEventKey.new()
	release.keycode = KEY_SPACE
	release.pressed = false
	screen._unhandled_input(release)
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	screen._unhandled_input(click)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	screen._unhandled_input(motion)
	h.equal("dismissal.key_and_click_end_it", heard,
		PackedStringArray([SequenceScreen.DONE, SequenceScreen.DONE]),
		"a release and a motion do not")
	h.equal("dismissal.full_screen_has_no_plate",
		[screen.plate_name(), screen.plate_window()],
		[CampaignScreen.PLATE_NONE, Rect2()])
	screen.free()
	var framed: SequenceScreen = SequenceScreen.new()
	h.equal("dismissal.framed_is_plate_7_around_the_window",
		[framed.plate_name(), framed.plate_window()],
		["plate_7", CampaignScreen.PLATE_WINDOW])
	framed.free()

	var logo: SplashScreen = SplashScreen.new()
	var logo_heard: PackedStringArray = PackedStringArray()
	logo.chose.connect(func(action: String) -> void: logo_heard.append(action))
	logo._unhandled_input(key)
	h.check("dismissal.logo_takes_no_input", logo_heard.is_empty(),
		"aGameIntro's Sleep reads no key")
	var logo_plate: String = logo.plate_name()
	logo.free()
	var title: SplashScreen = SplashScreen.new()
	title.stage = SplashScreen.STAGE_TITLE
	title.chose.connect(func(action: String) -> void: logo_heard.append(action))
	title._unhandled_input(key)
	h.equal("dismissal.title_ends_on_a_key", logo_heard,
		PackedStringArray([SplashScreen.DONE]))
	h.equal("dismissal.splash_plates", [logo_plate, title.plate_name()],
		["bluebyte", "title"])
	title.free()


## `--sequence=N` is the fourth way in, and an unknown id opens the shell.
func _boot(h: TestHarness) -> void:
	var cache: PackedStringArray = PackedStringArray(["_C_140"])
	var chosen: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--sequence=7"]), cache, "_C_140")
	h.equal("boot.sequence_argument", [DictRead.as_string(chosen["kind"]),
		DictRead.as_int(chosen["sequence"])], [SliceMain.BOOT_SEQUENCE, 7])
	var unknown: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--sequence=4"]), cache, "_C_140")
	h.equal("boot.unknown_sequence_opens_the_shell",
		DictRead.as_string(unknown["kind"]), SliceMain.BOOT_SHELL)
	h.check("boot.unknown_sequence_warns",
		not DictRead.to_strings(unknown["warnings"]).is_empty())


## A second dismissal during the hold does nothing.
##
## The screen stays up over the hold -- black, as the original's `Sleep` leaves
## it -- with its `_unhandled_input` still live, so `DONE` can arrive twice.
## The animated extro is where that mattered: `opening_sequence()` arms itself
## from the mission id every time, unlike the intro's once-only flag, so the
## second `DONE` replayed the whole extro and the credits could not be reached.
func _re_entry(h: TestHarness) -> void:
	var main: SliceMain = SliceMain.new()
	# Nothing is playing, which is the state the hold leaves behind.
	main._finish_sequence()
	h.check("re_entry.a_second_dismissal_is_ignored", not main.holding(),
		"_finish_sequence with no player armed a hold")
	# **A sequence that cannot play answers null**, and that is the state
	# `--sequence=N` used to boot into with no screen at all -- a black window
	# with no way out. `boot_choice` cannot catch it: whether a logical id
	# *plays* is the cache's answer, not the command line's, so the boot arm
	# falls back to the menu the way the `--campaign=` arm does.
	h.check("re_entry.a_sequence_with_no_manifest_is_null",
		main.play_sequence(0, true, SliceMain.SEQUENCE_DEBUG) == null,
		"a bare instance carries no manifest")
	main.free()


## A pair the cache cannot supply is a hole, not the end of the part.
##
## `_install_shot` answers false only when the part has run out; a missing
## model or clip is noted and skipped, so the shots after it still play. It
## also bounds itself on **both** lists, because it indexes both -- the
## converter requires them to be the same length (`sequences.parts_are_pairs`)
## and this is what happens if that ever stops being true.
func _shot_holes(h: TestHarness) -> void:
	var player: SequencePlayer = SequencePlayer.new()
	var ragged: Array = [{
		"directory": "Seq_1",
		"models": PackedStringArray(["Model_1_1"]),
		"animations": PackedStringArray(["Anima_1_1", "Anima_1_2"]),
	}]
	player._parts = ragged
	player.part = 0
	h.check("shots.bounded_by_the_shorter_list",
		not player._install_shot(1),
		"a part with one model and two clips must end at the first pair")
	player.free()
