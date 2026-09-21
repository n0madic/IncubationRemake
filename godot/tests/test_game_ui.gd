extends TestSuite

## Oracle boundary: **specification** -- docs/22 section 9 for what may be seen,
## docs/92 section 7.6 for where text comes from.
##
## `game/` is not `core/` and most of it is a picture, but three of its files
## make decisions rather than draw them: [Localization] decides what a string
## is, [Fog] decides whether a unit is drawn at all, and [MissionHud] decides what
## the player is told. Those are checkable and are checked here.
##
## The one this suite exists for is the **missing-string** rule. A localization
## seam whose misses render as `""` looks like a layout bug; one whose misses
## render as a marker looks like what it is, and a check can then say there are
## none.

const REPORT_LIMIT: int = 6


func run(h: TestHarness) -> void:
	h.begin("game_ui", TestHarness.ORACLE_SPEC)
	_debug_build_boundary(h)
	_localization(h)
	_fog(h)
	_hud(h)
	_mission_result(h)
	_give_up(h)
	_command_gate(h)
	_game_font(h)
	_shots_and_reactions(h)
	_shot_target_order(h)
	_rebuild(h)
	_replay_positions(h)
	_replay_progress(h)
	_hand_back_selection(h)
	_turn_presentation_regressions(h)
	_unit_animations(h)
	_walk_epilogue(h)
	_push_mine_presentation(h)
	_playback_pacing(h)
	_presenter_arms(h)
	_watching_gate(h)
	_band_filter(h)
	_death_delta(h)
	_quiet_landings(h)
	_setpiece_state(h)
	_ring_rotation(h)
	_silent_opening_mirror(h)
	_campaign_screens(h)
	_pickup_message(h)
	_magnifier(h)
	_briefing_around_a_mission(h)
	_upgrade_marines(h)
	_blip_volume(h)
	_no_campaign_state(h)
	_screens_leave_nothing_behind(h)


## A secondary ring discovered on a repeat pass can append a lower-index cell
## after a higher one. aPlayFightAnimation rebuilds its presentation array by
## scanning the final CtrlMap, so consumers must not inherit outcomes order.
func _shot_target_order(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._shown = world.clone()
	var result: AttackResult = AttackResult.new()
	result.outcomes = [
		{"slot": 1, "x": 4, "y": 2, "marker": Combat.MARKER_HIT,
			"dealt": 1},
		{"slot": 0, "x": 2, "y": 2, "marker": Combat.MARKER_HIT,
			"dealt": 1},
	]
	var targets: Array[Dictionary] = main._shot_targets(result)
	var slots: Array[int] = []
	for target: Dictionary in targets:
		slots.append(DictRead.as_int(target["slot"]))
	h.equal("shot.targets_rebuild_final_ctrlmap_order", slots, [0, 1],
		"outcomes arrived as [1, 0]")
	main.free()


## Developer overlays and hidden keys are useful in an editor run, but none of
## them may become an undocumented control or caption in a release export.
func _debug_build_boundary(h: TestHarness) -> void:
	var detected: SliceMain = SliceMain.new()
	detected._install_debug_status()
	h.equal("debug_build.engine_kind_controls_status_overlay",
		detected._status != null, OS.is_debug_build(),
		"the live Godot build kind, not a project setting or launch flag")
	detected.world = TestFixtures.tiny_world()
	detected._unhandled_input(_pressed_key(CheatEntry.OPEN_KEY, 0x60))
	h.equal("debug_build.engine_kind_controls_cheat_entry",
		detected._cheat_entry.is_open(), OS.is_debug_build())
	detected.free()

	var actions: Dictionary[int, int] = {
		KEY_F5: SliceMain.DebugKeyAction.QUICK_SAVE,
		KEY_F9: SliceMain.DebugKeyAction.QUICK_LOAD,
		KEY_Y: SliceMain.DebugKeyAction.FIELD_TYPES,
		KEY_F8: SliceMain.DebugKeyAction.LATTICE,
		KEY_BRACKETRIGHT: SliceMain.DebugKeyAction.NEXT_MISSION,
		KEY_BRACKETLEFT: SliceMain.DebugKeyAction.PREVIOUS_MISSION,
	}
	var wrong: PackedStringArray = PackedStringArray()
	for keycode: int in actions:
		if SliceMain.debug_key_action(keycode, true) != actions[keycode]:
			wrong.append("debug %s" % OS.get_keycode_string(keycode))
		if SliceMain.debug_key_action(keycode, false) \
				!= SliceMain.DebugKeyAction.NONE:
			wrong.append("release %s" % OS.get_keycode_string(keycode))
	h.equal("debug_build.hidden_keys_are_build_gated", Array(wrong), [],
		"F5/F8/F9, Y and both mission-step brackets")
	h.equal("debug_build.a_player_key_is_never_a_debug_key",
		[SliceMain.debug_key_action(KEY_G, true),
			SliceMain.debug_key_action(KEY_G, false)],
		[SliceMain.DebugKeyAction.NONE, SliceMain.DebugKeyAction.NONE])

	var release: SliceMain = SliceMain.new()
	release._debug_build = false
	release._install_debug_status()
	h.check("debug_build.release_has_no_status_overlay",
		release._status == null
			and release.get_node_or_null("DebugOverlay/DebugStatus") == null)
	release._show_fatal_error("cache is out of date")
	h.check("debug_build.release_still_shows_fatal_startup_error",
		release._fatal_status != null
			and release.get_node_or_null("FatalErrorOverlay/FatalError")
				== release._fatal_status
			and release._fatal_status.text.contains("cache is out of date"))
	release.world = TestFixtures.tiny_world()
	release._unhandled_input(_pressed_key(CheatEntry.OPEN_KEY, 0x60))
	h.check("debug_build.release_cannot_open_cheat_entry",
		not release._cheat_entry.is_open())
	release.free()

	var debug: SliceMain = SliceMain.new()
	debug._debug_build = true
	debug._install_debug_status()
	h.check("debug_build.debug_has_status_overlay",
		debug._status != null
			and debug.get_node_or_null("DebugOverlay/DebugStatus") == debug._status)
	debug.world = TestFixtures.tiny_world()
	debug._unhandled_input(_pressed_key(CheatEntry.OPEN_KEY, 0x60))
	h.check("debug_build.debug_keeps_cheat_entry",
		debug._cheat_entry.is_open())
	debug.free()


static func _pressed_key(keycode: int, unicode: int = 0) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = keycode as Key
	event.unicode = unicode
	event.pressed = true
	return event


func _turn_presentation_regressions(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("turn_picture.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._shown = world.clone()
	var heights: PackedInt32Array = PackedInt32Array()
	heights.resize(world.resource.width * world.resource.height)
	heights.fill(0)
	var rig: CameraRig = CameraRig.new()
	rig.setup(world.resource.width, world.resource.height, heights, 32000)
	main._rig = rig
	main._director = CameraDirector.create(rig)
	var units: UnitsView = UnitsView.new()
	main._units = units
	var slot: int = SliceMain.first_friendly_slot(world)
	var _frames: int = rig.view_overview()
	rig.settle()
	var overview: Dictionary = rig.state()
	main._camera_offset_before_turn = rig.eye_goal() - rig.target_goal()
	main._camera_mode_before_turn = rig.view_mode()
	main._restore_camera_on(slot)
	h.equal("turn_picture.overview_stays_centred", rig.state(), overview)
	_frames = rig.view_map(Vector3i(3200, 3200, 0))
	main._restore_camera_on(slot)
	h.equal("turn_picture.overview_survives_replay_camera", rig.state(), overview)
	var alien: int = -1
	for candidate: int in world.unit_slots():
		if DictRead.as_int(world.unit_view(candidate)["player"]) == 255:
			alien = candidate
			break
	h.check("turn_picture.alien", alien >= 0)
	if alien >= 0:
		var view: Dictionary = world.unit_view(alien)
		var x: int = DictRead.as_int(view["x"])
		var y: int = DictRead.as_int(view["y"])
		var index: int = world.state.index_of(x, y)
		var event: Dictionary = {"kind": "move", "slot": alien,
			"x": x, "y": y, "tx": x + 2, "ty": y,
			"payload": {"path": PackedInt32Array([index, index + 1, index + 2]),
				"steps": 2, "seen_source": false, "seen_destination": false}}
		rig.settle()
		var hold: float = main._play_event_body(event, "move")
		h.equal("turn_picture.hidden_walk_no_hold", hold, 0.0)
		h.check("turn_picture.hidden_walk_not_started", not units.is_walking())
		h.equal("turn_picture.hidden_walk_no_camera", rig.state(), overview)
		# The same route must still animate when it is seen.
		var payload: Dictionary = event["payload"]
		payload["seen_source"] = true
		h.check("turn_picture.seen_walk_holds", main._play_event_body(event, "move") > 0.0)
		h.check("turn_picture.seen_walk_started", units.is_walking())
		var attack: AttackResult = AttackResult.new()
		var shooter: UnitState = world.units_for_ai()[alien]
		var old_facing: int = shooter.facing
		var old_height: int = world.state.height_at(index)
		# Only the future changes: replay inputs and the presentation RNG
		# stay identical, including for the reaction camera's floor query.
		for reaction: bool in [false, true]:
			for distance: int in [1, 5]:
				rig.apply_state(overview)
				main._director.rng.seed = 1.0
				var _flight: float = main._camera_for_shot(alien, x, y,
					x + distance, y, attack, reaction, slot)
				var expected: Dictionary = rig.state()
				world.state.set_height(index, old_height + 16000)
				shooter.facing = 1 if old_facing != 1 else 2
				rig.apply_state(overview)
				main._director.rng.seed = 1.0
				_flight = main._camera_for_shot(alien, x, y,
					x + distance, y, attack, reaction, slot)
				h.equal("turn_picture.shot_ignores_future_%s_%d" % [str(reaction), distance],
					rig.state(), expected)
				world.state.set_height(index, old_height)
				shooter.facing = old_facing
	units.free()
	rig.free()
	main.free()


## The ring's facing rides **inside** the walk's playback (docs/43 section
## 4.3): [method SliceMain.move_selected] submits the rotation before the
## playback takes the events. Submitting it after -- which is what the ring
## once did -- moved the truth under a running picture, and the mirror fell
## behind it on every walk.
func _ring_rotation(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("ring.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var slot: int = -1
	var target: Vector2i = Vector2i(-1, -1)
	var step_taken: Vector2i = Vector2i.ZERO
	for candidate: int in world.unit_slots():
		var view: Dictionary = world.unit_view(candidate)
		if DictRead.as_int(view["player"]) != world.turn.current_player \
				or DictRead.as_int(view["hp"]) == 0 \
				or DictRead.as_int(view["mp"]) == 0:
			continue
		var start: Vector2i = Vector2i(DictRead.as_int(view["x"]),
			DictRead.as_int(view["y"]))
		var fill: MoveMapResult = world.submit_move_query(
			MoveQueryCommand.create(candidate))
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 1), Vector2i(0, -1)]:
			var at: Vector2i = start + step
			if world.state.in_bounds(at.x, at.y) and fill.is_reachable(at.x, at.y) \
					and world.state.unit_at(world.state.index_of(at.x, at.y)) \
						== MapState.NO_UNIT:
				target = at
				step_taken = step
				break
		if target.x >= 0:
			slot = candidate
			break
	h.check("ring.a_unit_can_walk_one_field", slot >= 0, "on _C_140")
	if slot < 0:
		return
	world.enable_journal()
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._shown = world.clone()
	main._strings = Localization.new()
	main._geometry = {"prototypes": {}}
	var units: UnitsView = UnitsView.new()
	units.shown_ref = main._shown
	main._units = units
	var node: Node3D = Node3D.new()
	node.name = "unit_%d" % slot
	units.add_child(node)
	main._sequences = SequenceQueue.create(null)
	main._selected = slot
	# A facing the walk itself would not leave the body in: the way back.
	# (The unit's own facing plus four is not it -- a unit that happens to
	# stand with its back to the target walks into exactly that facing.)
	var facing: int = -1
	for candidate: int in range(Interact.FACING_DX.size()):
		if Interact.FACING_DX[candidate] == -step_taken.x \
				and Interact.FACING_DY[candidate] == -step_taken.y:
			facing = candidate
	h.check("ring.the_way_back_is_a_facing", facing >= 0, str(step_taken))
	if facing < 0:
		units.free()
		main.free()
		return
	var moved: MoveResult = main.move_selected(target.x, target.y, facing)
	h.check("ring.the_walk_went", moved.ok, moved.reason)
	h.check("ring.the_turn_is_inside_the_playback",
		main._playback.is_running() and world.take_events().is_empty()
			and DictRead.as_int(world.unit_view(slot)["facing"]) == facing,
		"the rotation was submitted before the playback took the events, "
		+ "so nothing is left over for the next command to carry")
	main._playback.skip()
	h.check("ring.the_mirror_turns_with_the_truth",
		main._desyncs == 0
			and DictRead.as_int(main._shown.unit_view(slot)["facing"]) == facing,
		"a rotation submitted under a running playback is what the resync "
		+ "warning used to report after every walk")
	units.free()
	main.free()


## The silent arm of the opening moves the mirror with the truth.
##
## Oracle boundary: **the remake's own** (docs/100). A bare `--mission=`, the
## campaign's entry into a mission with nobody to place and the debugging
## step between missions all skip the deployment turn after [method
## SliceMain._build] has taken the picture's mirror, and the skip leaves no
## delta -- so the plate read `0` while the truth stood on 1 and the first
## command counted a desync. The host's own arm resyncs.
func _silent_opening_mirror(h: TestHarness) -> void:
	var main: SliceMain = SliceMain.new()
	main.world = TestFixtures.tiny_world()
	main._shown = main.world.clone()
	h.check("opening.starts_on_the_deployment_turn",
		main.world.turn.turn == 0 and main._shown.turn.turn == 0)
	main._skip_deployment_turn()
	h.check("opening.silent_arm_moves_the_truth",
		main.world.turn.turn == TurnState.FIRST_TURN)
	h.check("opening.silent_arm_moves_the_mirror",
		main._shown.turn.turn == TurnState.FIRST_TURN
			and main._shown.canonical_hash_hex()
				== main.world.canonical_hash_hex()
			and main._check_mirror() and main._desyncs == 0,
		"the skip is a write to the truth with no replayable delta, so "
		+ "the picture has to be told by a fresh mirror")
	main.free()


## The crate's message -- docs/26 section 3 and docs/24 section 7.2.
##
## Oracle boundary: **specification**. The action-point-to-label map is the
## switch's own, decoded by `interaction_tables.InteractionTables.cases()` and
## baked into `text/info/events.json`; `remake_convert --check` compares that
## baking with docs/26 section 3's table pair by pair. **There is no copy of
## it on this side**, so what is checked here is that the reader is faithful
## to the document and that the document is whole.
func _pickup_message(h: TestHarness) -> void:
	var info: InfoText = InfoText.load_from(CacheFixture.paths())
	var points: PackedInt32Array = info.action_points()
	h.equal("info.table_size", points.size(), 13,
		"the thirteen arms of aExecuteUse that show something")
	h.equal("info.first_label", info.label_for(11), "E0",
		"action point 11 is `Found nothing`")
	h.equal("info.last_label", info.label_for(42), "EC",
		"action point 42 is the explosion pack")
	h.equal("info.batteries_has_one", info.label_for(41), "EB",
		"docs/26 section 3.2: 41 is absent from the picker legend and the "
		+ "switch still shows a message for it")
	h.equal("info.a_door_says_nothing", info.label_for(30), "",
		"only the pickup arms hand a label to 0x00410780")
	h.equal("info.an_unknown_action_point_says_nothing",
		info.label_for(0), "")
	# **The whole map, without a table to compare it against.** The thirteen
	# arms take the thirteen labels in id order -- `E0`..`E9`, then `EA`,
	# `EB`, `EC` -- so a pair swapped anywhere in the chain from the switch to
	# this reader breaks the run, which a check on the label *set* alone
	# cannot see.
	h.equal("info.labels_run_in_id_order", info.labels_out_of_order(),
		PackedStringArray())
	# And the rule can fail, which is the point of it: the same reader over a
	# document with two of the pairs exchanged says so.
	var swapped: InfoText = InfoText.new()
	var rows: Array = []
	for ap: int in points:
		# The pair the shipped table gives 14 and 15, exchanged; every other
		# row is left as the cache has it.
		var takes: int = ap
		if ap == 14:
			takes = 15
		elif ap == 15:
			takes = 14
		rows.append({"action_point": ap, "label": info.label_for(takes),
			"speech": 9})
	swapped.read({"schema": InfoText.SCHEMA, "blocks": {}, "pickups": rows})
	h.equal("info.a_swapped_pair_is_caught",
		swapped.labels_out_of_order().size(), 2,
		"14 and 15 exchanged: a check on the label set alone sees nothing")
	# Twelve of the thirteen also speak; `Found nothing` does not. Read out of
	# the arms, not written down: the quiet one is whichever pushes no
	# argument to `0x0047B660`.
	var quiet: PackedInt32Array = PackedInt32Array()
	var arguments: PackedInt32Array = PackedInt32Array()
	for ap: int in points:
		if info.speaks(ap):
			if not arguments.has(info.speech_argument(ap)):
				arguments.append(info.speech_argument(ap))
		else:
			quiet.append(ap)
	h.equal("info.one_arm_is_quiet", quiet, PackedInt32Array([11]),
		"`Found nothing` gets no voice line (docs/26 section 3)")
	h.equal("info.every_voice_line_is_event_9", arguments,
		PackedInt32Array([9]), "docs/28 section 4.3")
	h.check("info.a_door_never_speaks", not info.speaks(30),
		"every one of the twelve 0x0047B660 sites is inside the equipment "
		+ "switch, so a door, a lever and a push are silent")

	var missing: PackedStringArray = PackedStringArray()
	var empty: PackedStringArray = PackedStringArray()
	var seen: PackedStringArray = PackedStringArray()
	var repeated: PackedStringArray = PackedStringArray()
	for ap: int in points:
		var label: String = info.label_for(ap)
		if seen.has(label):
			repeated.append(label)
		seen.append(label)
		var spans: Array = info.spans_for(ap)
		if spans.is_empty():
			missing.append("%d/%s" % [ap, label])
			continue
		var body: String = BriefingText.to_bbcode(spans)
		if body.strip_edges() == "" \
				or body.contains(Localization.MISSING_PREFIX):
			empty.append("%d/%s" % [ap, label])
	h.equal("info.every_arm_resolves", missing, PackedStringArray(),
		"text/info/events.json carries a block for each")
	h.equal("info.every_arm_has_words", empty, PackedStringArray())
	h.equal("info.no_two_arms_share_a_label", repeated, PackedStringArray())
	h.check("info.is_structured",
		not info.spans_for(11).is_empty()
			and DictRead.as_dict(info.spans_for(11)[0]).has("font"),
		"docs/92 3.2: spans, not a marked-up string")

	# **The reader carries pairs, not an order.** A document whose ids and
	# labels are deliberately not in the shipped arrangement has to come back
	# exactly as written; a reader that assumed either would pass every check
	# above and answer the wrong text for a crate.
	var made_up: InfoText = InfoText.new()
	made_up.read({"schema": InfoText.SCHEMA,
		"blocks": {"ZZ": [{"text": "second", "font": 0, "colour": 0,
			"breaks": 0}],
			"AA": [{"text": "first", "font": 1, "colour": 1,
				"breaks": 0}]},
		"pickups": [{"action_point": 42, "label": "ZZ", "speech": 9},
			{"action_point": 11, "label": "AA", "speech": -1}]})
	h.equal("info.the_reader_keeps_the_pairing",
		[made_up.label_for(11), made_up.label_for(42)], ["AA", "ZZ"])
	h.equal("info.the_reader_orders_by_id", made_up.action_points(),
		PackedInt32Array([11, 42]))
	h.equal("info.the_reader_carries_the_speech",
		[made_up.speaks(11), made_up.speaks(42)], [false, true])
	h.equal("info.the_reader_finds_the_block",
		BriefingText.to_bbcode(made_up.spans_for(11)).contains("first"), true)
	# A cache that predates the document, and one whose schema is not this
	# one, both answer nothing rather than half of something.
	var absent: InfoText = InfoText.new()
	absent.read({})
	h.equal("info.no_document_is_no_message", absent.action_points().size(), 0)
	var wrong: InfoText = InfoText.new()
	wrong.read({"schema": "incubation.info/99",
		"pickups": [{"action_point": 11, "label": "E0", "speech": -1}]})
	h.equal("info.a_foreign_schema_is_refused", wrong.label_for(11), "")

	# The box's own rectangle. At 640x480 it is the shipped literal; on a
	# larger canvas it keeps its offset from the 3D window's centre, because
	# that is where every extra pixel goes ([method HudTables.window_for]).
	var shipped: Rect2 = MissionHud.info_box_rect(
		Vector2(HudTables.PLATE_SIZE))
	h.equal("info.box_at", shipped.position, InfoText.BOX_AT,
		"0x004107A2/0x0041079D push 230, 200")
	h.equal("info.box_width", shipped.size.x, InfoText.BOX_SIZE.x,
		"0x00410798 pushes 180")
	h.check("info.box_height_is_bounded_by_the_screen",
		shipped.size.y < InfoText.BOX_SIZE.y and shipped.size.y > 0.0,
		"400 tall on a 480 screen that starts it at 200: the height is a "
		+ "layout bound, as docs/24 7.1's 500-tall B0 box is")
	var wide: Rect2 = MissionHud.info_box_rect(Vector2(1280.0, 800.0))
	h.equal("info.box_follows_the_window",
		wide.position - shipped.position,
		Vector2(320.0, 160.0),
		"half of each extra dimension, the window's centre having moved by "
		+ "that much")
	h.equal("info.box_stays_the_width_it_was", wide.size.x,
		InfoText.BOX_SIZE.x, "the plate's units are the plate's units")

	# The sound: all thirteen reach `0x00410780`, whose own cue is `box.wav`.
	var events: AudioEvents = AudioEvents.open(
		AudioTables.open(CacheFixture.paths()),
		CacheFixture.read_json(CacheFixture.cache_dir() + "/tables/blobs.json"))
	var opened: UseResult = UseResult.new()
	opened.ok = true
	opened.kind = "message_only"
	h.equal("info.a_silent_pickup_still_clicks",
		events.for_use(opened).is_empty(), false,
		"action points 11 and 41 hand their label to the same routine the "
		+ "other eleven do")


## One shot and one burst of return fire, at the level `main.gd` shows them.
##
## Oracle boundary: **specification**. `core` decides what a shot does and
## `test_combat` checks that; what is checked here is the half `game` owns and
## had no coverage of at all -- that a shot animates its shooter, that the
## computer\'s events report how long they need, and that return fire is shown
## rather than only counted in the HUD.
##
## **Three defects this pins.** Reaction fire had no presentation whatever at
## any of the three sites that drain it, so the HUD counted shots nothing drew.
## The computer\'s `"fire"` event returned `0.0`, so [constant
## EventPlayback.STEP_SECONDS] cut every combat clip off part way through. And the
## return fire a move drew was shown -- once it was shown at all -- only when
## the picture had caught up with the walk, which is where `core` resolved it.
##
## `_after_command`\'s own clearing of the queue is **not** checked here: it
## rebuilds the units, redraws the terrain and refreshes the status line, so it
## needs a HUD, an overlay and the mission geometry that a headless suite has
## none of. What is checked is the queue it clears.
func _shots_and_reactions(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("shot.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	world.turn.current_player = 0
	var shooter: int = -1
	var reactor: int = -1
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			continue
		var player: int = DictRead.as_int(view["player"])
		if player == 0:
			if shooter < 0:
				shooter = slot
		elif player == UnitState.PLAYER_ALIEN and reactor < 0:
			reactor = slot
	if shooter < 0 or reactor < 0:
		h.check("shot.units", false, "_C_140 has no live pair to shoot with")
		return

	# The alien is **moved** next to the squad member and put on overwatch. No
	# shipped `.lev` places a unit on overwatch (docs/25 section 6, and
	# `test_combat` says the same), and none starts an alien within a field of
	# the first marine either, so a suite about presenting return fire has to
	# arrange for some. Everything after this point is `core`\'s own answer.
	var us: Dictionary = world.unit_view(shooter)
	var sx: int = DictRead.as_int(us["x"])
	var sy: int = DictRead.as_int(us["y"])
	var ax: int = sx + 1 if sx + 1 < world.resource.width else sx - 1
	# Enough hit points to survive the player's shot below: a killed alien
	# is hidden by the shot's own death stage, and the checks after it read
	# its body.
	var _placed: bool = world.apply_unit_record(reactor, {
		"x": ax, "y": sy, "facing": Combat.direction(ax, sy, sx, sy),
		"action_state": Reaction.WAITING, "ticket": 1,
		"mp": Reaction.MIN_MP, "malfunction": 0, "heat": 0,
		"visibility": 0, "hp": 200})
	var mover: UnitState = world.units_for_ai()[shooter]
	var entries: Array[Dictionary] = Reaction.drain(world.state,
		world.units_for_ai(), world.unit_types(), world.weapons(), mover,
		world.turn.ai_level, world.turn.human_count(), world.turn.mode,
		world.turn, world.rng)
	h.check("shot.reactions_drained", not entries.is_empty(),
		"%d reaction(s) from slot %d" % [entries.size(), reactor])
	# The shot the reaction took is undone: what is being checked below is the
	# presentation, and both bodies must survive long enough to draw it. The
	# reactor goes back on overwatch too, so the player's shot below draws
	# the same return fire through `World.submit_attack`'s own drain.
	var _restored: bool = world.apply_unit_record(shooter, {
		"hp": 200, "mp": DictRead.as_int(us["mp"]),
		"ammo": DictRead.as_int(us["ammo"]), "acted": 0, "heat": 0,
		"action_state": 0})
	var _rearmed: bool = world.apply_unit_record(reactor, {
		"action_state": Reaction.WAITING, "ticket": 1,
		"mp": Reaction.MIN_MP, "malfunction": 0, "heat": 0, "hp": 200})
	# The journal is what the picture reads (docs/100): the shot below is the
	# `fire` event and one `reaction` per shot of the drain, in that order.
	world.enable_journal()
	var shot: AttackResult = world.submit_attack(
		AttackCommand.create(shooter, ax, sy))
	h.check("shot.fired", shot.fired,
		shot.reason if not shot.fired else "%d outcome(s)" % shot.outcomes.size())
	var shot_events: Array[Dictionary] = world.take_events()
	var shot_kinds: Array[String] = []
	for event: Dictionary in shot_events:
		shot_kinds.append(DictRead.as_string(event["kind"]))
	var expected_kinds: Array[String] = ["fire"]
	for _entry: Dictionary in shot.reactions:
		expected_kinds.append("reaction")
	h.equal("commands.a_shot_is_fire_then_one_reaction_per_shot", shot_kinds,
		expected_kinds, "the drain marks one boundary per shot, after the shot")
	h.check("shot.drew_a_reaction", shot.reactions.size() >= 1,
		"%d reaction(s): the overwatcher answered" % shot.reactions.size())

	var fire_clip: CharismaClip = _clip_with_break()
	if fire_clip == null:
		h.check("shot.clip", false, "no `F` clip with a BREAK note in the cache")
		return
	var main: SliceMain = SliceMain.new()
	main.world = world
	var units: UnitsView = UnitsView.new()
	units.shown_ref = world
	main._units = units
	for slot: int in [shooter, reactor]:
		var node: Node3D = Node3D.new()
		node.name = "unit_%d" % slot
		units.add_child(node)
		units.states[slot] = CharismaState.create(null, fire_clip, fire_clip,
			fire_clip)

	# --- the player\'s own shot ------------------------------------------
	# The shot is a sequence on the queue (docs/42 section 4): nothing has
	# moved until the queue is advanced, and the first frame starts the clip.
	main._sequences = SequenceQueue.create(null)
	main._strings = Localization.new()
	var hold: float = main._present_attack(shooter, sx, sy, ax, sy,
		DictRead.as_int(us["weapon"]), shot)
	h.check("shot.is_queued", main._sequences.is_running(),
		"the nine stages are on the queue")
	h.equal("shot.first_stage_is_the_clip", main._sequences.current(),
		ShotSequence.STAGE_CLIP)
	var _went: bool = main._sequences.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("shot.body_plays_f", units.states[shooter].mode,
		CharismaState.Mode.FIRE, "the shooter is playing its combat clip")
	h.check("shot.body_is_busy", units.states[shooter].is_busy(),
		"and the caller is told to wait for it")
	h.check("shot.hold_covers_the_clip",
		hold >= float(units.states[shooter].frames_to_break())
			/ CharismaState.FRAMES_PER_SECOND,
		"%.3f s asked for a clip that breaks after %d frame(s) at speed 6"
			% [hold, units.states[shooter].frames_to_break()])
	# Whatever is left of the sequence is let go, so the reactions below can
	# be queued and drained on their own terms.
	main._sequences.skip()
	units.states[shooter].rest()

	# --- the return fire it drew ------------------------------------------
	# **One `reaction` event per shot of the drain**, each with an arm of its
	# own in [method SliceMain._play_event_body] (docs/100 section 3): the
	# reactor shoots from the event's own cell at the mover's, and the mover's
	# slot rides in the payload so the reaction camera has a height to work
	# from even when the mover has walked on.
	var empty_x: int = sx
	var empty_y: int = sy
	for y: int in range(world.resource.height):
		for x: int in range(world.resource.width):
			if world.state.unit_at(world.state.index_of(x, y)) < 0:
				empty_x = x
				empty_y = y
	var mover_inputs: Dictionary = main._inputs_of(shooter, empty_x, empty_y)
	h.check("shot.mover_inputs_follow_the_slot",
		DictRead.as_int(mover_inputs.get("height", 0)) > 0
			and DictRead.as_int(mover_inputs.get("x", -1)) == empty_x,
		"the mover's own height on the event's cell, %s" % str(mover_inputs))

	# The presenter, recorded: which events reached the picture and in what
	# order, and what each asked to be held for. The busy probe is the one the
	# game hands the playback -- the queue, a body still shooting, a walk.
	var presented: Array[String] = []
	var holds: Array[float] = []
	var present: Callable = func(event: Dictionary) -> float:
		if event.is_empty():
			return 0.0
		var kind: String = DictRead.as_string(event["kind"])
		presented.append(kind)
		var asked: float = main._play_event_body(event, kind)
		holds.append(asked)
		return asked
	var busy: Callable = func() -> bool:
		return main._sequences.is_running() or units.any_busy() \
			or units.is_walking()

	# --- the player\'s own shot, through the playback ----------------------
	# **The shot starts in the frame the button was pressed**: the first shown
	# event is presented inside `play()`, and the return fire waits for it
	# behind the picture\'s own `busy`, not behind a stage or a number.
	units.states[shooter].rest()
	units.states[reactor].rest()
	main._sequences = SequenceQueue.create(null)
	main._playback.play(shot_events, present, Callable(), 0.0, busy)
	h.equal("commands.the_shot_starts_inside_play", presented,
		["fire"] as Array[String], "presented before `play()` returned")
	h.check("shot.event_fire_holds",
		not holds.is_empty() and holds[0] >= float(
			units.states[shooter].frames_to_break())
			/ CharismaState.FRAMES_PER_SECOND,
		"a `fire` event asks for %.3f s, its clip to the break"
			% (holds[0] if not holds.is_empty() else -1.0))
	# The hold is the engine\'s deterministic frames only: the open-ended
	# waits are the picture\'s business (`EventPlayback.advance`\'s `busy`), and
	# a hold that summed their bounds stalled every computer shot for half
	# a minute.
	h.check("shot.event_fire_hold_is_bounded",
		not holds.is_empty() and holds[0] < 3.0,
		"clip, spin, muzzle, impact and resume, no safety bounds")
	var _went_fire: bool = main._sequences.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("shot.event_fire_plays_the_body", units.states[shooter].mode,
		CharismaState.Mode.FIRE, "and the body it names is the one playing")
	var _held: bool = main._playback.advance(5.0, DictRead.as_bool(busy.call()))
	h.equal("commands.the_reaction_waits_for_the_shot", presented,
		["fire"] as Array[String],
		"the shooter\'s own clip runs before the answer to it")
	main._sequences.skip()
	units.states[shooter].rest()
	var _freed: bool = main._playback.advance(0.0, DictRead.as_bool(busy.call()))
	h.equal("commands.the_reaction_follows_the_frame_the_shot_is_over",
		presented, ["fire", "reaction"] as Array[String],
		"no gap of the remake\'s own between a player\'s shot and its answer")
	h.check("shot.the_reaction_is_queued", main._sequences.is_running(),
		"the return fire is a shot sequence of its own")
	var _fired: bool = main._sequences.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("shot.the_reactor_shoots_back", units.states[reactor].mode,
		CharismaState.Mode.FIRE,
		"the unit on overwatch animates its own shot, which nothing drew before")
	main._sequences.skip()
	units.states[shooter].rest()
	units.states[reactor].rest()
	main._playback.skip()

	# --- return fire after a walk ------------------------------------------
	# `core` resolves a move\'s reactions at the end of the move and the walk
	# that follows is only the picture, so the `reaction` event waits for the
	# body to arrive: the busy probe says a walk is on, and nothing else does.
	var width: int = world.resource.width
	var step: int = 1 if sx + 2 < width else -1
	var route: PackedInt32Array = PackedInt32Array([sy * width + sx,
		sy * width + sx + step])
	var walk_event: Dictionary = AIEvent.make("move", shooter, sx, sy,
		sx + step, sy, 1, "", {"path": route, "steps": 1, "facing": 0,
			"cost": 1, "seen_source": false, "seen_destination": false}).to_dict()
	var reaction_event: Dictionary = {}
	for event: Dictionary in shot_events:
		if DictRead.as_string(event["kind"]) == "reaction":
			reaction_event = event
			break
	presented.clear()
	main._playback.play([walk_event, reaction_event], present, Callable(),
		0.0, busy)
	h.check("commands.the_walk_starts_inside_play",
		units.is_walking() and presented == (["move"] as Array[String]),
		"the body is on its way, and the reaction has not been drawn")
	var _walking: bool = main._playback.advance(5.0, DictRead.as_bool(busy.call()))
	h.equal("commands.the_reaction_waits_for_the_walk", presented,
		["move"] as Array[String],
		"return fire lands where `core` resolved it: at the end of the move")
	units.finish_walks(world)
	var _arrived: bool = main._playback.advance(0.0, DictRead.as_bool(busy.call()))
	h.equal("commands.the_reaction_follows_the_walk", presented,
		["move", "reaction"] as Array[String], "nothing walking, so it fires")
	main._sequences.skip()
	units.states[reactor].rest()
	main._playback.skip()

	# --- the order, and the cell ------------------------------------------
	# Two reactions present in the order the drain resolved them -- the
	# journal\'s order is the list\'s -- and each reactor shoots from the cell
	# **its event** names, not from wherever the mirror has it now: during a
	# replay the reactor may have walked on by the time the event is drawn.
	var second: Dictionary = reaction_event.duplicate(true)
	second["detail"] = DictRead.as_int(reaction_event["detail"]) + 1
	var tickets: Array[int] = []
	var by_ticket: Callable = func(event: Dictionary) -> float:
		if event.is_empty():
			return 0.0
		tickets.append(DictRead.as_int(event["detail"]))
		return 1.0
	main._playback.play([reaction_event, second], by_ticket, Callable(),
		0.0, Callable())
	var _next: bool = main._playback.advance(1.0, false)
	h.equal("commands.reactions_present_in_ticket_order", tickets,
		[DictRead.as_int(reaction_event["detail"]),
			DictRead.as_int(reaction_event["detail"]) + 1] as Array[int],
		"one at a time, as the drain fired them")
	main._playback.skip()
	var recorder: MuzzleRecorder = MuzzleRecorder.new(main)
	main._shot_host = recorder
	main._sequences = SequenceQueue.create(null)
	# The reactor is moved in the mirror; the event still names (ax, sy).
	var _moved_reactor: bool = world.apply_unit_record(reactor,
		{"x": empty_x, "y": empty_y})
	var _shown_hold: float = main._play_event_body(reaction_event, "reaction")
	var muzzle_frames: int = 0
	while main._sequences.is_running() and recorder.shots.is_empty() \
			and muzzle_frames < 400:
		var _stage: bool = main._sequences.advance(
			1.0 / SequenceQueue.FRAMES_PER_SECOND)
		muzzle_frames += 1
	h.equal("commands.the_reactor_shoots_from_the_events_cell",
		recorder.shots[0] if not recorder.shots.is_empty() else Vector2i(-1, -1),
		Vector2i(ax, sy), "the muzzle is at the event\'s cell after %d frame(s)"
			% muzzle_frames)
	main._sequences.skip()
	units.states[reactor].rest()
	var _back: bool = world.apply_unit_record(reactor, {"x": ax, "y": sy})
	main._shot_host = null

	# --- a kill, through the real pool ------------------------------------
	# The death stage runs the creators of docs/42 section 4.8 into the live
	# pool: the casualty's record has left its cell in `core`, so the
	# creator's inputs must find it by its coordinates, and blood must
	# actually appear. A recording host cannot show that; this does.
	_check_kill_spawns(h, main, units, world, shooter, ax, sy)

	# --- the ammunition gate ----------------------------------------------
	# `aAttackUnit`'s spend is an 8-bit `sub` with no check (`0x0046C308`), so
	# the refusal is the **caller's**: the computer goes through `0x0042FF30`
	# and the player's call site had nothing at all, which let a marine fire
	# for ever and drove its count negative.
	var armed: Dictionary = world.unit_view(shooter)
	var per_shot: int = world.weapons().mun_per_fight(
		DictRead.as_int(armed["weapon"]))
	var magazine: int = world.weapons().magazine(
		DictRead.as_int(armed["weapon"]))
	if magazine != Combat.MUN_NONE and per_shot > 0:
		var _empty: bool = world.apply_unit_record(shooter,
			{"ammo": 0, "acted": 0, "mp": 40})
		var dry: AttackResult = world.submit_attack(
			AttackCommand.create(shooter, ax, sy))
		h.check("ammo.an_empty_weapon_does_not_fire", not dry.fired, dry.reason)
		h.equal("ammo.and_the_count_stays_at_zero",
			DictRead.as_int(world.unit_view(shooter)["ammo"]), 0,
			"the engine's own spend is a byte and wraps; nothing may reach it")
		# One round short of a shot is refused too, which `ammo == 0` alone
		# would let through for a weapon that spends more than one.
		if per_shot > 1:
			var _short: bool = world.apply_unit_record(shooter,
				{"ammo": per_shot - 1, "acted": 0, "mp": 40})
			var partial: AttackResult = world.submit_attack(
				AttackCommand.create(shooter, ax, sy))
			h.check("ammo.a_partial_magazine_does_not_fire", not partial.fired,
				"%d round(s) for a shot that costs %d"
					% [per_shot - 1, per_shot])
		var _full: bool = world.apply_unit_record(shooter,
			{"ammo": per_shot, "acted": 0, "mp": 40})
		var last: AttackResult = world.submit_attack(
			AttackCommand.create(shooter, ax, sy))
		h.check("ammo.exactly_enough_still_fires", last.fired, last.reason)
		h.equal("ammo.and_spends_it_all",
			DictRead.as_int(world.unit_view(shooter)["ammo"]), 0)
	else:
		h.check("ammo.an_empty_weapon_does_not_fire", true,
			"weapon %d spends no ammunition"
				% DictRead.as_int(armed["weapon"]))

	units.free()
	main.free()


## One kill of the alien at `(ax, ay)` with a real [BlobPool] behind the
## host: the victim is hidden at the impact stage and the pool holds the
## death creator's records afterwards.
func _check_kill_spawns(h: TestHarness, main: SliceMain, units: UnitsView,
		world: World, shooter: int, ax: int, ay: int) -> void:
	# The victim is an alien whose type awards experience (docs/22 section
	# 7.5): a neutral prop or a species-2 object would kill silently.
	var victim: int = -1
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			continue
		if DictRead.as_int(view["player"]) == UnitState.PLAYER_ALIEN \
				and world.unit_types().exp(DictRead.as_int(view["type_id"])) > 0:
			victim = slot
			break
	h.check("kill.an_alien_worth_experience", victim >= 0, "none on the map")
	if victim < 0:
		return
	# Whoever stood on the target cell moves aside; the victim takes it.
	var standing: int = world.state.unit_at(world.state.index_of(ax, ay))
	if standing >= 0 and standing != victim:
		var free: Vector2i = Vector2i(-1, -1)
		for y: int in range(world.resource.height):
			for x: int in range(world.resource.width):
				if world.state.unit_at(world.state.index_of(x, y)) < 0 \
						and free.x < 0:
					free = Vector2i(x, y)
		var _aside: bool = world.apply_unit_record(standing, {"x": free.x,
			"y": free.y})
	var geometry: Dictionary = CacheFixture.geometry("A00")
	main._fx = BlobPool.create(1.0)
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in DictRead.as_dict(geometry.get("prototypes", {})):
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	main._fx.hooks().model_index = index
	var killer: Dictionary = world.unit_view(shooter)
	var sx: int = DictRead.as_int(killer["x"])
	var sy: int = DictRead.as_int(killer["y"])
	var killed: AttackResult = null
	var last: String = ""
	for seed_value: int in range(1, 300):
		# One hit point and no armour, so any hit that connects kills.
		var _alive: bool = world.apply_unit_record(victim, {"hp": 1, "x": ax,
			"y": ay, "armour_front": 0, "armour_rear": 0, "absorber": 0})
		var _ready: bool = world.apply_unit_record(shooter,
			{"hp": DictRead.as_int(killer["hp"]), "mp": 40, "acted": 0,
			"ammo": 30, "heat": 0, "action_state": 0, "malfunction": 0})
		world.rng.randomize_seed(float(seed_value))
		var attempt: AttackResult = world.submit_attack(
			AttackCommand.create(shooter, ax, ay))
		if attempt.fired and DictRead.as_int(world.unit_view(victim)["hp"]) == 0:
			killed = attempt
			break
		last = "fired %s (%s), %d outcome(s), victim hp %d at (%d,%d) vs (%d,%d)" % [
			str(attempt.fired), attempt.reason, attempt.outcomes.size(),
			DictRead.as_int(world.unit_view(victim)["hp"]),
			DictRead.as_int(world.unit_view(victim)["x"]),
			DictRead.as_int(world.unit_view(victim)["y"]), ax, ay]
	h.check("kill.found_a_killing_seed", killed != null,
		"no seed below 300 kills a one-point target; last: " + last)
	if killed == null:
		return
	h.check("kill.awards_experience", killed.xp > 0,
		"%d point(s) for the alien" % killed.xp)
	if units.get_node_or_null(NodePath("unit_%d" % victim)) == null:
		var node: Node3D = Node3D.new()
		node.name = "unit_%d" % victim
		units.add_child(node)
	main._sequences = SequenceQueue.create(null)
	var _hold: float = main._present_attack(shooter, sx, sy, ax, ay,
		DictRead.as_int(killer["weapon"]), killed)
	var frames: int = 0
	var reached_impact: bool = false
	while main._sequences.is_running() and frames < 400:
		var _going: bool = main._sequences.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
		if main._sequences.current() == ShotSequence.STAGE_POOL \
				or main._sequences.current() == ShotSequence.STAGE_RESUME:
			reached_impact = true
			break
	h.check("kill.reached_the_impact", reached_impact,
		"%d frame(s), on %s" % [frames, main._sequences.current()])
	h.check("kill.victim_hidden_at_the_impact",
		units.get_node_or_null(NodePath("unit_%d" % victim)) == null,
		"0x00405320(obj, 5) in the death stage")
	h.check("kill.death_creator_filled_the_pool", main._fx.in_use() > 0,
		"%d record(s) in use -- the dead record was found by its cell"
			% main._fx.in_use())
	main._sequences.skip()

	# **The same kill, drawn as a stab.** A bayonet leaves death style 3
	# (docs/42 section 4.8), a different creator from the gun's, and the whole
	# path from the shot's weapon to the pool has to reach it: an empty pool
	# here is the "the enemy just disappears" a player reports.
	if units.get_node_or_null(NodePath("unit_%d" % victim)) == null:
		var again: Node3D = Node3D.new()
		again.name = "unit_%d" % victim
		units.add_child(again)
	main._fx = BlobPool.create(1.0)
	main._fx.hooks().model_index = index
	main._sequences = SequenceQueue.create(null)
	var _stab_hold: float = main._present_attack(shooter, sx, sy, ax, ay,
		Combat.CLOSE_COMBAT_WEAPONS[0], killed)
	var stab_frames: int = 0
	while main._sequences.is_running() and stab_frames < 400:
		var _step: bool = main._sequences.advance(
			1.0 / SequenceQueue.FRAMES_PER_SECOND)
		stab_frames += 1
		if main._fx.in_use() > 0:
			break
	h.check("kill.a_stab_fills_the_pool_too", main._fx.in_use() > 0,
		"%d record(s) after %d frame(s) with weapon %d"
			% [main._fx.in_use(), stab_frames, Combat.CLOSE_COMBAT_WEAPONS[0]])
	main._sequences.skip()

	# The computer's para bomb, through its event. The payload **is** the
	# blast (`AISpecialPlayer` writes `AttackResult.to_dict()` into it), and
	# until [method SliceMain._play_event_body] staged it the arm was sound
	# only: the casualties the replay holds from its first frame had nothing
	# to take them away and stood until the end of the turn.
	var bomb_body: Node3D = Node3D.new()
	bomb_body.name = "unit_%d" % victim
	units.add_child(bomb_body)
	main._sequences = SequenceQueue.create(null)
	var bomb: Dictionary = AIEvent.make("parabomb", shooter, ax, ay, 0, 0, 0,
		"", killed.to_dict()).to_dict()
	var bomb_hold: float = main._play_event_body(bomb, "parabomb")
	h.check("kill.parabomb_event_is_shown",
		bomb_hold > 0.0 and main._sequences.is_running(),
		"the fuse's blast is a shot sequence of its own, %.3f s" % bomb_hold)
	var bomb_frames: int = 0
	while main._sequences.is_running() and bomb_frames < 400:
		var _stepped: bool = main._sequences.advance(
			1.0 / SequenceQueue.FRAMES_PER_SECOND)
		bomb_frames += 1
		if units.get_node_or_null(NodePath("unit_%d" % victim)) == null:
			break
	h.check("kill.parabomb_releases_its_dead",
		units.get_node_or_null(NodePath("unit_%d" % victim)) == null,
		"%d frame(s): the death stage is the only caller of `hide_now`"
			% bomb_frames)
	main._sequences.skip()
	main._fx = null


## The first `F` clip in the cache that carries a `BREAK` note, by name.
##
## Read out of the published cache rather than constructed: the hold is about
## what the shipped clips do, and 29 of the 33 shipped `F` clips have the note.
func _clip_with_break() -> CharismaClip:
	var directory: String = CacheFixture.cache_dir() + "/animations"
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		return null
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for name: String in names:
		if not name.ends_with(".json") or name == "index.json":
			continue
		var document: Dictionary = CacheFixture.read_json(
			"%s/%s" % [directory, name])
		if document.is_empty():
			continue
		var clip: CharismaClip = CharismaClip.from_document(document)
		if clip != null and clip.break_time() >= 0.0:
			return clip
	return null


## What the picture drops, and what it carries, when it is rebuilt.
##
## Oracle boundary: **specification** -- docs/22 section 9.5 for the first and
## docs/40 section 7.2 for the second.
##
## Two defects, both reported from play and both in [method UnitsView.build]:
##
## * a **killed** unit stayed on screen. `aKillUnit` is the death sequence and
##   `aRemoveUnitElement`, so the engine deletes the object at once; `core`
##   keeps the record (the hero counter reads it) and the picture was drawing
##   every record it found, so a dead alien stood there until the next
##   hand-over happened to drop it;
## * every rebuild **restarted every animation**. A rebuild happens on every
##   command and on every fog change, so ten bodies snapped to idle frame 0
##   each time the player did anything, and a shot in flight was thrown away.
func _rebuild(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	var geometry: Dictionary = CacheFixture.geometry("A00")
	if loaded.is_empty() or geometry.is_empty():
		h.check("rebuild.cache", false, "no _C_140 or no A00 geometry")
		return
	var world: World = loaded["world"]
	var units: UnitsView = UnitsView.new()
	units.library = CharismaLibrary.open(CacheFixture.cache_dir(), {}, "_C_140")
	h.check("rebuild.library", units.library.is_ready(),
		"the cache carries the bodies, so there are states to carry over")
	units.build(world, geometry, {})
	var drawn: int = units.get_child_count()
	h.check("rebuild.something_is_drawn", drawn > 0, "%d unit node(s)" % drawn)

	# The dead are not drawn. The record stays -- `core` owns that -- and the
	# picture is what has to lose it.
	var victim: int = -1
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if not view.is_empty() and DictRead.as_int(view["hp"]) > 0 \
				and units.get_node_or_null(NodePath("unit_%d" % slot)) != null:
			victim = slot
			break
	h.check("rebuild.a_live_unit_is_drawn", victim >= 0,
		"slot %d has a node" % victim)
	if victim < 0:
		units.free()
		return
	var _killed: bool = world.apply_unit_record(victim, {"hp": 0})
	h.check("rebuild.the_record_survives_the_death", world.has_unit(victim),
		"`core` keeps it: the hero counter and the win conditions read it")

	# **The mirror is what keeps it.** The rebuild that drops a casualty used
	# to run *before* the event that killed it was presented, so a marine
	# vanished and the sound of what killed it arrived afterwards; now the
	# picture reads a world that has not been told, and the delta lands in
	# the death stage of the shot that is drawing it (docs/42 section 4.8).
	var mirror: World = world.clone()
	var _alive: bool = mirror.apply_unit_record(victim, {"hp": 10})
	units.build(mirror, geometry, {})
	h.check("rebuild.the_mirror_keeps_a_body_until_its_delta",
		units.get_node_or_null(NodePath("unit_%d" % victim)) != null,
		"still drawn while its killer's shot is on screen")
	units.animate(5.0, mirror)
	h.check("rebuild.no_timer_drops_it",
		units.get_node_or_null(NodePath("unit_%d" % victim)) != null,
		"five seconds later it is still there: only the delta hides it")
	h.check("rebuild.hidden_by_the_death_stage", units.hide_now(victim),
		"0x00405320(obj, 5) -- gone in this frame")
	h.check("rebuild.and_then_it_goes",
		units.get_node_or_null(NodePath("unit_%d" % victim)) == null,
		"without waiting for another rebuild")
	units.build(world, geometry, {})
	h.check("rebuild.the_dead_are_not_drawn",
		units.get_node_or_null(NodePath("unit_%d" % victim)) == null,
		"slot %d died and left the picture at once" % victim)
	h.equal("rebuild.only_that_one_left", units.get_child_count(), drawn - 1,
		"and nothing else went with it")

	# The animation clock survives a rebuild.
	var mover: int = -1
	for slot: int in units.states:
		mover = slot
		break
	h.check("rebuild.a_body_has_a_state", mover >= 0,
		"slot %d is a Charisma body rather than a capsule" % mover)
	if mover < 0:
		units.free()
		return
	# docs/42 section 6: a body idles only when a scheduler slot starts its
	# clip, so one is started here the way the slot would start it.
	var moving: Dictionary = world.unit_view(mover)
	var roll: IncRandom = IncRandom.new()
	roll.randomize_seed(1.0)
	var idle_clip: CharismaClip = units.library.idle_clip_for(
		DictRead.as_int(moving["type_id"]), DictRead.as_int(moving["weapon"]),
		DictRead.as_int(moving["player"]), roll)
	if idle_clip == null:
		idle_clip = _clip_with_break()
	var _idle_length: float = units.states[mover].start_idle(idle_clip)
	units.animate(0.5, world)
	var before: Dictionary = units.states[mover].playback()
	h.check("rebuild.the_idle_has_run",
		DictRead.as_float(before["time"]) > 0.0,
		"%.2f frames into %s" % [DictRead.as_float(before["time"]),
			DictRead.as_string(before["clip"])])
	units.build(world, geometry, {})
	var after: Dictionary = units.states[mover].playback()
	h.equal("rebuild.the_clock_is_carried",
		DictRead.as_float(after["time"]), DictRead.as_float(before["time"]),
		"a command must not snap every idle on the map back to frame 0")
	h.equal("rebuild.the_clip_is_carried",
		DictRead.as_string(after["clip"]), DictRead.as_string(before["clip"]))

	# A shot in flight survives one too, which is what a fog change landing in
	# the middle of a reaction used to destroy.
	var length: float = units.fire(mover, 0, 0)
	if length > 0.0:
		units.animate(0.2, world)
		var shooting: Dictionary = units.states[mover].playback()
		units.build(world, geometry, {})
		h.equal("rebuild.a_shot_survives", units.states[mover].mode,
			CharismaState.Mode.FIRE, "the body is still firing after a rebuild")
		h.equal("rebuild.the_shots_clock_is_carried",
			DictRead.as_float(units.states[mover].playback()["time"]),
			DictRead.as_float(shooting["time"]))
	else:
		h.check("rebuild.a_shot_survives", true,
			"slot %d has no `F` clip; the carry is checked on its idle" % mover)
	# **The 60 m freeze stops the clip, not the walk.** docs/42 section 1.3
	# freezes Charisma above `FREEZE_HEIGHT`; `aExecuteMove` still steps the
	# unit field to field. `_picture_busy()` and the pending-reaction drain
	# both gate on `is_walking()`, so a frozen `animate` that returned before
	# the walk loop left `_walks` full for ever and stalled the replay.
	var walker: int = -1
	for slot: int in units.states.keys():
		walker = slot
		break
	if walker >= 0:
		var cells: PackedInt32Array = PackedInt32Array([
			world.state.index_of(2, 2), world.state.index_of(3, 2)])
		units.start_walk(walker, cells, world.state.width, 0.2)
		h.check("freeze.the_walk_started", units.is_walking())
		for _step: int in range(8):
			units.animate(0.1, world, true)
		h.check("freeze.a_frozen_body_still_finishes_its_walk",
			not units.is_walking(),
			"the freeze is the clip's, and `_walks` must still drain")
	units.free()


## Where the computer's replay draws a unit that has not moved yet.
##
## Oracle boundary: **specification** -- docs/94 for the resolve-then-replay
## split this exists because of.
##
## `core` decides the whole turn in one call, so the world holds every unit at
## the position it *ends* the turn on from the first rebuild onwards. A unit
## whose move event has not come round yet was therefore standing at the place
## it was about to walk to -- for as long as every event before its own took --
## and then jumped back to its source and set off. Placing the body on its
## first cell in `start_walk` fixed the one-frame flash of that and not the
## rest, which is why this exists as well.
## docs/42 section 7 at the level `main.gd` queues it (docs/97 section 31):
## the orbits ahead of a shot, the jam after a reaction, the jump, and the
## marker on a real pool.
func _unit_animations(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("anim.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	world.turn.current_player = 0
	var shooter: int = -1
	var alien: int = -1
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			continue
		if DictRead.as_int(view["player"]) == 0 and shooter < 0:
			shooter = slot
		elif DictRead.as_int(view["player"]) != 0 and alien < 0:
			alien = slot
	if shooter < 0 or alien < 0:
		h.check("anim.units", false, "_C_140 has no live pair")
		return
	var main: SliceMain = SliceMain.new()
	main.world = world
	var units: UnitsView = UnitsView.new()
	units.shown_ref = world
	main._units = units
	main._sequences = SequenceQueue.create(null)
	main._strings = Localization.new()
	var us: Dictionary = world.unit_view(shooter)
	var sx: int = DictRead.as_int(us["x"])
	var sy: int = DictRead.as_int(us["y"])

	# A shot that raised a skill level: the orbit is queued **after** the nine
	# stages. `0x00410190` plays once `aPlayFightAnimation` has returned and
	# the shooter's pool level has risen over the value saved at entry
	# (docs/22 section 7.5); queued ahead of the shot, as it was until
	# 2026-09-07, it showed the player a promotion before the shot that
	# earned it.
	main.world.turn.mode = TurnState.MODE_CAMPAIGN
	var attack: AttackResult = AttackResult.new()
	attack.fired = true
	attack.skill_raised = 1
	var _hold: float = main._present_attack(shooter, sx, sy, sx + 1, sy,
		DictRead.as_int(us["weapon"]), attack)
	h.equal("anim.the_shot_comes_first", main._sequences.current(),
		ShotSequence.STAGE_CLIP,
		"the fight animation, and the promotion after it")
	var seen: Array[String] = []
	var frames: int = 0
	while main._sequences.is_running() and frames < 400:
		var stage: String = main._sequences.current()
		if seen.is_empty() or seen[seen.size() - 1] != stage:
			seen.append(stage)
		var _went: bool = main._sequences.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.check("anim.the_skill_orbit_follows_the_shot",
		seen.find(OrbitSequence.STAGE_RAISE) >= 0
			and seen.find(OrbitSequence.STAGE_RAISE)
				> seen.find(ShotSequence.STAGE_CLIP),
		str(seen))
	# An overheat that destroyed the carrier: kind 1, no wave of its own.
	main._sequences = SequenceQueue.create(null)
	var hot: AttackResult = AttackResult.new()
	hot.fired = true
	hot.overheat = Combat.OVERHEAT_DESTROYED
	main._present_overheat_orbit(shooter, us, hot)
	h.equal("anim.overheat_orbit_queued", main._sequences.current(),
		OrbitSequence.STAGE_RAISE)
	# **And the skill orbit is not queued with it.** `0x00410190` plays after
	# `aPlayFightAnimation` returns (docs/22 section 7.5), so a promotion
	# reached the player before the shot that earned it while the two were
	# one call.
	main._sequences = SequenceQueue.create(null)
	var raised: AttackResult = AttackResult.new()
	raised.fired = true
	raised.skill_raised = 1
	main._present_overheat_orbit(shooter, us, raised)
	h.check("anim.the_skill_orbit_is_not_the_overheats",
		not main._sequences.is_running(),
		"a shot that raised a level and did not overheat queues nothing here")
	# It is the campaign's alone, and never a body's.
	main.world.turn.mode = TurnState.MODE_CAMPAIGN
	var dead: AttackResult = AttackResult.new()
	dead.fired = true
	dead.skill_raised = 1
	dead.overheat = Combat.OVERHEAT_DESTROYED
	h.equal("anim.a_destroyed_shooter_earns_no_orbit",
		main._present_skill_orbit(shooter, us, dead), 0,
		"the reactor that blew took the shooter with it")
	h.check("anim.the_skill_orbit_follows_the_shot",
		main._present_skill_orbit(shooter, us, raised) > 0,
		"queued after the shot's own stages")
	h.equal("anim.overheat_kinds", [
		DictRead.as_int(SliceMain.OVERHEAT_KINDS[Combat.OVERHEAT_DESTROYED]),
		DictRead.as_int(SliceMain.OVERHEAT_KINDS[Combat.OVERHEAT_JAM]),
		DictRead.as_int(SliceMain.OVERHEAT_KINDS[Combat.OVERHEAT_DAMAGE])],
		[1, 2, 3], "docs/22 section 8: explosion, jam, damage")
	# The jam after a reaction, and the jump.
	main._sequences = SequenceQueue.create(null)
	main._present_jam(alien)
	h.equal("anim.jam_orbit_queued", main._sequences.current(),
		OrbitSequence.STAGE_RAISE)
	main._sequences = SequenceQueue.create(null)
	var jump_frames: int = main._present_jump(shooter, Vector2i(sx, sy),
		Vector2i(sx + 1, sy), true)
	h.equal("anim.jump_frames", jump_frames, 1 + 6 + 1)
	h.equal("anim.jump_queued", main._sequences.current(),
		JumpSequence.STAGE_LEAVE)
	# The marker on a real pool: four arrows for the selected unit, none
	# without a selection.
	main._selected = shooter
	main._fx = BlobPool.create(1.0, 64)
	main._fx.hooks().model_index["A_ARROW.3DI"] = 1
	main._eng3d = Eng3dGeometry.from_cache(CacheFixture.cache_dir())
	main._raise_marker()
	h.equal("anim.marker_four_arrows", main._fx.live(), 4,
		"`0x00473920` raises `0x00422D40` once for the selected unit")
	main._selected = -1
	main._raise_marker()
	h.equal("anim.marker_needs_a_selection", main._fx.live(), 4)
	main._selected = shooter
	units.scheduler.enabled = false
	main._raise_marker()
	h.equal("anim.marker_off_at_animation_level_1", main._fx.live(), 4,
		"`0x004604D0() == 1` returns before the creator")
	units.free()
	main.free()


## docs/43 section 4.5 -- the selection the hand-over gives back.
##
## Reported as "in the original one of my soldiers is selected when the
## computer's turn ends; in the remake nobody is". The engine's selection is a
## global no hand-over routine writes, and `0x004721F0` refills an empty one
## from `fcn.00477CE0`; this is that search, over a real mission.
func _hand_back_selection(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("handback.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var slot: int = SliceMain.first_friendly_slot(world)
	h.check("handback.somebody_is_selectable", slot >= 0,
		"the side the turn belongs to has a unit to select")
	h.equal("handback.the_first_is_the_players",
		DictRead.as_int(world.unit_view(slot)["player"]),
		world.turn.current_player)
	# **The lowest-numbered one**, not the first the iteration happens to hit:
	# `fcn.00477CE0` walks the unit array from slot 0.
	var mine: PackedInt32Array = PackedInt32Array()
	for other: int in world.unit_slots():
		if world.may_command(other):
			mine.append(other)
	h.check("handback.the_side_is_not_empty", mine.size() >= 2,
		"_C_140 places a squad: %s" % str(mine))
	h.equal("handback.takes_the_lowest_slot", slot, mine[0])

	# The carry-over: the engine's selection is a global no hand-over writes,
	# so the marine the player last had comes back.
	var other_slot: int = mine[mine.size() - 1]
	h.check("handback.the_squad_has_a_second", other_slot != slot, "")
	h.equal("handback.keeps_the_previous",
		SliceMain.resumed_slot(world, other_slot), other_slot,
		"a marine the computer left alive and able to move stays selected")
	h.equal("handback.nothing_selected_takes_the_first",
		SliceMain.resumed_slot(world, -1), slot)
	# And the branch a drive cannot stage: the computer killed them.
	var was_hp: int = world._units[other_slot].hp
	world._units[other_slot].hp = 0
	h.equal("handback.a_dead_previous_falls_back",
		SliceMain.resumed_slot(world, other_slot), slot)
	world._units[other_slot].hp = was_hp
	# So does one it left with nothing to spend.
	var was_mp: int = world._units[other_slot].mp
	world._units[other_slot].mp = 0
	h.equal("handback.a_spent_previous_falls_back",
		SliceMain.resumed_slot(world, other_slot), slot)
	world._units[other_slot].mp = was_mp

	# The second pass: with nobody left able to move, the search still answers
	# -- and it answers with a unit that has no movement at all.
	var kept: Dictionary[int, int] = {}
	for other: int in mine:
		kept[other] = world._units[other].mp
		world._units[other].mp = 0
	h.equal("handback.second_pass_ignores_movement",
		SliceMain.first_friendly_slot(world), mine[0],
		"a side that has moved everything still has somebody selected")
	h.equal("handback.and_it_cannot_be_selected_by_a_click",
		world.may_select(mine[0]), false,
		"which is the one thing the two passes disagree about")
	h.equal("handback.a_spent_side_still_hands_one_back",
		SliceMain.resumed_slot(world, -1), mine[0])
	for other: int in mine:
		world._units[other].mp = kept[other]

	# **The quiet computer turn hands back twice.** `EventPlayback.play` finishes
	# inside its own call when no event survives its filter, so `_on_ai_step`
	# runs the hand-back before `end_turn` reaches its own; the second must be
	# a no-op or the camera moves to a second unit and a second voice cuts the
	# first one off.
	h.equal("handback.first_hand_back_selects",
		SliceMain.hand_back_slot(world, -1, other_slot), other_slot)
	h.equal("handback.second_hand_back_is_a_no_op",
		SliceMain.hand_back_slot(world, other_slot, -1), -1,
		"a selection that already stands is the engine's own state")
	h.equal("handback.a_standing_selection_is_never_replaced",
		SliceMain.hand_back_slot(world, other_slot, slot), -1)

	# And a side with nothing alive answers "none" -- 0x00477CE0's 0xFFFF.
	var was: int = world.turn.current_player
	world.turn.current_player = 7
	h.equal("handback.no_units_no_selection",
		SliceMain.first_friendly_slot(world), -1)
	h.equal("handback.no_units_no_hand_back",
		SliceMain.resumed_slot(world, -1), -1)
	world.turn.current_player = was


## The bar's two counts on a real world -- docs/43 section 7.
##
## The world holds the end of the computer's turn from its first frame, so the
## tally is masked by what the replay has played; a spent unit nobody has seen
## move must not be on the bar yet.
func _replay_progress(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("progress.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var player: int = UnitState.PLAYER_ALIEN
	var slots: PackedInt32Array = PackedInt32Array()
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["player"]) == player \
				and DictRead.as_int(view["hp"]) > 0:
			slots.append(slot)
	h.check("progress.the_side_has_units", slots.size() > 0,
		"_C_140 places aliens")
	# **The tally reads the world it is given, and that world is the
	# picture's.** The mirror is a command behind the truth, so a unit it
	# shows as spent is one whose action has already been drawn and a unit it
	# shows as alive is one still standing on screen -- which is why the two
	# compensating lists this used to take are gone (docs/100 section 1).
	var opening: Vector2i = TurnProgress.tally(world, player)
	h.equal("progress.the_turn_opens_at_zero", opening.x, 0,
		"nobody has spent a point yet")
	h.equal("progress.live_is_the_whole_side", opening.y, slots.size())
	h.equal("progress.one_capsule_at_the_opening",
		TurnProgress.fill_for(opening.x, opening.y) + 1, 1)
	# Spend one unit's movement, the way an event's delta does.
	var mover: int = slots[0]
	var units: Dictionary = world.units_for_ai()
	var unit: UnitState = units[mover]
	unit.mp = maxi(world.movement_allowance(mover, world.turn.ai_level) - 1, 0)
	h.equal("progress.a_spent_unit_is_counted",
		TurnProgress.tally(world, player).x, 1,
		"the delta that spent it has landed, so the bar may show it")
	h.equal("progress.the_others_are_not",
		TurnProgress.tally(world, player).x, 1,
		"only the one whose points moved")
	# A casualty leaves the divisor when its own delta lands, and not before:
	# until then the mirror still has it alive.
	var doomed: int = slots[1]
	units[doomed].hp = 0
	h.equal("progress.the_dead_leave_the_divisor",
		TurnProgress.tally(world, player).y, slots.size() - 1)
	# And the side is the replay's own. The computer's turn hands over again
	# inside `submit_end_turn`, so the world's seat is the marines' before the
	# first alien is drawn moving -- a bar read off `world.turn` would count
	# the player's own squad.
	# The seat is the **mirror's**: the computer's turn hands over again
	# inside `submit_end_turn`, so a bar read off the truth's `turn` would
	# count the player's own squad. The mirror still stands where the turn
	# began, and its `previous_player` is who is being watched.
	h.equal("progress.the_world_seat_is_not_it",
		world.turn.current_player == player, false,
		"_C_140 opens on the marines")
	var events: Array[Dictionary] = [
		AIEvent.make("move", mover, 1, 1, 2, 2).to_dict()]
	for event: Dictionary in events:
		event["delta"] = {}
	var playback: EventPlayback = EventPlayback.new()
	playback.play(events, func(_event: Dictionary) -> float: return 1.0)
	h.check("progress.the_playback_runs", playback.is_running(),
		"one shown event, held for the second its presenter asked")
	playback.skip()
	h.check("progress.and_stops", not playback.is_running(), "skipped")


func _replay_positions(h: TestHarness) -> void:
	# **The reveals the engine itself writes**, read off an event rather than
	# off the byte, because the byte is rebuilt at the hand-over and not in
	# between (docs/22 section 9.4). Three writes qualify: `aExecuteMove`'s
	# mode 3 (`0x0046E4BB`) when the mover could be seen where it set off,
	# `aAttackUnit`'s shooter reveal (`0x0046B643`) the moment the weapon is
	# cleared to fire, and the same reveal for a reactor, which reaches it
	# through `Reaction.drain`.
	h.equal("fog.a_move_reveals_on_seen_source",
		PictureFog.reveals_of("move", 7, {"seen_source": true}),
		PackedInt32Array([7]), "aExecuteMove mode 3")
	h.equal("fog.a_still_move_reveals_nobody",
		PictureFog.reveals_of("move", 7, {"seen_source": false}),
		PackedInt32Array())
	h.equal("fog.the_opening_passes_reveal_too",
		PictureFog.reveals_of("move_begin", 7, {"seen_source": true}),
		PackedInt32Array([7]),
		"the write is before the first step, so the picture may show it there")
	h.equal("fog.a_shot_reveals_its_shooter",
		PictureFog.reveals_of("fire", 7, {"fired": true}),
		PackedInt32Array([7]),
		"aAttackUnit marks the shooter visible before it turns to aim")
	h.equal("fog.a_jammed_shot_reveals_nobody",
		PictureFog.reveals_of("fire", 7, {"fired": false}),
		PackedInt32Array(), "the reveal is past the weapon-damage gate")
	h.equal("fog.a_door_reveals_nobody",
		PictureFog.reveals_of("door", 7, {"fired": true}),
		PackedInt32Array(), "only the writes core actually makes")
	# One event per shot since the journal, so the reactor is the event's own
	# slot rather than an entry in a list.
	h.equal("fog.a_reaction_reveals_its_reactor",
		PictureFog.reveals_of("reaction", 11, {"attack": {"fired": true}}),
		PackedInt32Array([11]), "`0x0046B643`, reached through the drain")
	h.equal("fog.a_jammed_reaction_reveals_nobody",
		PictureFog.reveals_of("reaction", 11, {"attack": {"fired": false}}),
		PackedInt32Array(), "a jam is not a shot")

	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	var geometry: Dictionary = CacheFixture.geometry("A00")
	if loaded.is_empty() or geometry.is_empty():
		h.check("mirror.cache", false, "no _C_140 or no A00 geometry")
		return
	var world: World = loaded["world"]
	world.enable_journal()
	var mirror: World = world.clone()
	var slot: int = -1
	for candidate: int in world.unit_slots():
		var view: Dictionary = world.unit_view(candidate)
		if DictRead.as_int(view["player"]) != UnitState.PLAYER_ALIEN \
				and DictRead.as_int(view["hp"]) > 0 \
				and DictRead.as_int(view["mp"]) > 0:
			slot = candidate
			break
	if slot < 0:
		h.check("mirror.unit", false, "no live unit on _C_140")
		return
	var view: Dictionary = world.unit_view(slot)
	var start: Vector2i = Vector2i(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))
	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(slot))
	var target: Vector2i = start
	for radius: int in range(1, 4):
		if target != start:
			break
		for dy: int in range(-radius, radius + 1):
			for dx: int in range(-radius, radius + 1):
				var at: Vector2i = start + Vector2i(dx, dy)
				if at == start or not world.state.in_bounds(at.x, at.y):
					continue
				if not fill.is_reachable(at.x, at.y):
					continue
				if world.state.unit_at(
						world.state.index_of(at.x, at.y)) != MapState.NO_UNIT:
					continue
				target = at
				break
			if target != start:
				break
	h.check("mirror.a_cell_is_reachable", target != start, str(target))
	if target == start:
		return
	var _moved: MoveResult = world.submit_move(
		MoveCommand.create(slot, target.x, target.y))
	var events: Array[Dictionary] = world.take_events()

	var units: UnitsView = UnitsView.new()
	units.library = CharismaLibrary.open(CacheFixture.cache_dir(), {}, "_C_140")
	units.build(mirror, geometry, {})
	var node: Node3D = units.get_node_or_null(NodePath("unit_%d" % slot))
	h.check("mirror.the_unit_is_drawn", node != null, "slot %d" % slot)
	if node != null:
		var here: Vector3 = WorldSpace.cell_centre(start.x, start.y,
			mirror.state.height_at(mirror.state.index_of(start.x, start.y)))
		h.check("mirror.the_walker_stands_on_its_source_before_its_delta",
			node.position.distance_to(here) < 0.001,
			"the truth put it on its destination the instant the command ran")
		var there: Vector3 = WorldSpace.cell_centre(target.x, target.y,
			mirror.state.height_at(mirror.state.index_of(target.x, target.y)))
		h.check("mirror.and_not_where_the_world_says",
			node.position.distance_to(there) > 0.5,
			"which is what every hold in the old picture was compensating")
	mirror.apply_events(events)
	units.build(mirror, geometry, {})
	var moved_node: Node3D = units.get_node_or_null(NodePath("unit_%d" % slot))
	if moved_node != null:
		var there: Vector3 = WorldSpace.cell_centre(target.x, target.y,
			mirror.state.height_at(mirror.state.index_of(target.x, target.y)))
		h.check("mirror.and_on_the_destination_after",
			moved_node.position.distance_to(there) < 0.001,
			"the delta landed and the picture followed")
	h.equal("mirror.the_deltas_put_it_on_the_truth",
		mirror.canonical_hash_hex(), world.canonical_hash_hex(),
		"the standing check that replaces the per-mechanic holds")

	# The fog is answered for the **watching** seat and at the cell each body
	# is drawn on. A pass for player 255 is the aliens' own view of the map.
	var fog: PictureFog = PictureFog.new()
	fog.viewer = 0
	var seen: Dictionary[int, int] = fog.states(mirror)
	h.check("fog.the_viewer_is_the_watching_seat", not seen.is_empty(),
		"%d slot(s) answered" % seen.size())
	var alien: int = -1
	for candidate: int in mirror.unit_slots():
		var record: Dictionary = mirror.unit_view(candidate)
		if DictRead.as_int(record["player"]) == UnitState.PLAYER_ALIEN \
				and DictRead.as_int(record["hp"]) > 0:
			alien = candidate
			break
	if alien >= 0:
		# **The seat decides the answer**, which is why it is taken before the
		# rotation moves on: a pass for player 255 is the aliens' own view of
		# the map, with every alien a body and every marine a contact.
		var own: Dictionary[int, int] = mirror.display_visibility(0)
		var theirs: Dictionary[int, int] = mirror.display_visibility(
			UnitState.PLAYER_ALIEN)
		var differs: int = 0
		for at: int in own:
			if theirs.has(at) and DictRead.as_int(own[at]) \
					!= DictRead.as_int(theirs[at]):
				differs += 1
		h.check("fog.the_seat_decides_the_answer", differs > 0,
			"%d slot(s) answered differently" % differs)
		# And the picture never takes the alien seat, whatever it is handed:
		# during the computer's turn `turn.current_player` is 255, and a fog
		# pass for 255 would show the player the whole map.
		fog.viewer = UnitState.PLAYER_ALIEN
		var refused: Dictionary[int, int] = fog.states(mirror)
		var same: bool = true
		for at: int in own:
			if DictRead.as_int(refused.get(at, -1)) != DictRead.as_int(own[at]):
				same = false
		h.check("fog.the_alien_seat_is_refused", same,
			"it falls back to the seat the world says holds the turn")
		fog.viewer = 0
		fog.viewer = 0
		# A shooter that fired is forced visible for the rest of the replay,
		# because the engine's write is permanent until the hand-over.
		fog.note_event("fire", alien, {"fired": true})
		h.equal("fog.a_shooter_that_fired_is_full",
			fog.states(mirror).get(alien, -1), Visibility.FULL,
			"an alien that attacks is a body and not a beam")
		fog.note_event("hand_over", -1, {})
		h.check("fog.reveals_clear_on_the_hand_over",
			not fog.revealed().has(alien),
			"the hand-over rebuilds the fog outright")
		# And the compatibility flag puts the original's timing back.
		fog.beams_until_hand_over = true
		var stored: Dictionary[int, int] = fog.states(mirror)
		h.equal("fog.beams_until_hand_over_reads_the_stored_byte",
			stored.get(alien, -1),
			DictRead.as_int(mirror.unit_view(alien)["visibility"]),
			"the byte the last hand-over left, which is the engine's own")

	# **The fix the beam needed**, on a world built to need it: a wall between
	# the squad and one alien, so the plain pass calls it a contact and the
	# same pass asked at the cell its body is drawn on calls it a body. This
	# is the situation a player reported -- an alien that steps into view and
	# stays a green beam, attacking as a beam.
	_fog_override(h)

	var replayed: EventPlayback = EventPlayback.new()
	var landed: Array[int] = [0]
	replayed.play(events, func(_event: Dictionary) -> float: return 0.0,
		func(_event: Dictionary) -> void: landed[0] += 1)
	replayed.skip()
	h.equal("mirror.skip_lands_every_delta", landed[0], events.size(),
		"skipping stops the drawing, never the state")

	# **The muzzle part is really there, and it is not the body's axis.**
	# `aBlob_CreateTracerBullet` puts the round at the shooter's `"M"` part
	# (`0x0042C660` over the three source coordinates), and the whole of that
	# hangs on the part name being the key the body draws under.
	# The shooter is a marine, not the first live record: slot 0 on `_C_140`
	# is a Barrel, and a barrel has no muzzle -- which [method
	# UnitsView.has_muzzle] answering false for it is the other half of this.
	var shooter: int = -1
	for candidate: int in world.unit_slots():
		var record: Dictionary = world.unit_view(candidate)
		if DictRead.as_int(record["player"]) == 0 \
				and DictRead.as_int(record["hp"]) > 0:
			shooter = candidate
			break
	h.check("muzzle.part_is_found", shooter >= 0 and units.has_muzzle(shooter),
		"slot %d's model carries the part the creator names" % shooter)
	# The scenery's own record: player 252 owns the barrels and cases, and a
	# barrel has no muzzle. Found here rather than assumed, because the slot
	# the mirror checks above uses is a marine.
	var scenery: int = -1
	for candidate: int in world.unit_slots():
		var record: Dictionary = world.unit_view(candidate)
		var owner: int = DictRead.as_int(record["player"])
		if owner != 0 and owner != UnitState.PLAYER_ALIEN:
			scenery = candidate
			break
	h.check("muzzle.scenery_is_found", scenery >= 0, "slot %d" % scenery)
	h.check("muzzle.scenery_has_none", not units.has_muzzle(scenery),
		"and slot %d, a Barrel, does not" % scenery)
	if shooter >= 0 and units.has_muzzle(shooter):
		var stand: Dictionary = world.unit_view(shooter)
		var barrel: Vector3i = units.muzzle_point(shooter)
		var axis: Vector3i = BlobTriggers.muzzle_point(
			DictRead.as_int(stand["x"]), DictRead.as_int(stand["y"]),
			world.state.height_at(world.state.index_of(
				DictRead.as_int(stand["x"]), DictRead.as_int(stand["y"]))),
			HitChance.eye_height(world.unit_types(),
				DictRead.as_int(stand["type_id"])))
		var apart: int = absi(barrel.x - axis.x) + absi(barrel.y - axis.y)
		h.check("muzzle.is_off_the_axis", apart > 200,
			"%d units from the body's own axis" % apart)
		h.check("muzzle.is_on_the_unit",
			absi(barrel.x - axis.x) < MapResource.WORLD_UNITS_PER_FIELD
				and absi(barrel.y - axis.y)
					< MapResource.WORLD_UNITS_PER_FIELD,
			"and still inside the shooter's own field")
		# **The part name is a parameter, not a constant.** Weapon 12's
		# second call site names `"MM"`, and only `P0_020.cho` carries a
		# part by that name -- so `has_muzzle` must answer for the name it
		# is given rather than for `"M"` whatever is asked.
		h.check("muzzle.second_barrel_is_asked_for_by_name",
			units.has_muzzle(shooter, UnitsView.MUZZLE_PART)
				and not units.has_muzzle(shooter, "no-such-part"),
			"a name the model does not carry is not the default's answer")
		h.check("muzzle.no_part_is_no_muzzle", not units.has_muzzle(shooter, ""),
			"a creator that names no part gets no joint")

	units.free()


## `0x00477DF0` -- who the player may give an order to.
##
## The rule the second slice did not have: a click selected whatever was under
## the cursor, and with docs/23's planner in place that meant the aliens could
## be commanded by hand. Checked here rather than in `game` because
## [method World.may_command] is where the rule lives.
func _command_gate(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("command.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	world.turn.current_player = 0
	var ours: Array[int] = []
	var theirs: Array[int] = []
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["hp"]) == 0:
			continue
		if DictRead.as_int(view["player"]) == 0:
			ours.append(slot)
		else:
			theirs.append(slot)
	h.check("command.the_map_has_both", not ours.is_empty()
		and not theirs.is_empty(),
		"%d of the player's and %d of everyone else's" % [ours.size(),
			theirs.size()])

	var refused: Array[int] = []
	for slot: int in theirs:
		if world.may_command(slot):
			refused.append(slot)
	h.equal("command.not_the_other_players", refused, [] as Array[int],
		"the aliens and the props are not the player's to move")
	var allowed: int = 0
	for slot: int in ours:
		if world.may_command(slot):
			allowed += 1
	h.equal("command.the_players_own", allowed, ours.size(),
		"every live squad member can be given an order")

	# And the gate follows the turn rather than the unit: hand the turn to the
	# computer and the same four slots stop being commandable.
	world.turn.current_player = UnitState.PLAYER_ALIEN
	var still: Array[int] = []
	for slot: int in ours:
		if world.may_command(slot):
			still.append(slot)
	h.equal("command.follows_the_turn", still, [] as Array[int],
		"nobody commands the squad while it is not the squad's turn")

	# And a finished mission is not playable. The engine never shows the map in
	# that state -- the debriefing screen replaces it (docs/27 section 6.1) --
	# so the rule is the remake's, and it lives beside the other three rather
	# than in the input handler.
	world.turn.current_player = 0
	world.game_control.set_slot(4, 1)
	var after: Array[int] = []
	for slot: int in ours:
		if world.may_command(slot):
			after.append(slot)
	h.equal("command.not_after_the_mission_ends", after, [] as Array[int],
		"nobody gives an order once the game-control slots are set")
	world.game_control.set_slot(4, 0)
	h.equal("command.and_the_squad_is_commandable_again",
		world.may_command(ours[0]), true,
		"the gate is the slots, not a latch")

	# **A refusal is not a target.** `may_command` says no to three different
	# things -- somebody else's unit, a hidden one, and the player's **own
	# dead** one -- and only the first is something to shoot at. A dead squad
	# member stays in `unit_slots()` and stays drawn (the fog pass leaves an
	# own corpse fully visible), so routing every refusal into the attack
	# branch let a player spend a soldier's action points, and drain the
	# reaction queue, firing at the body of the soldier who had just died.
	var corpse: int = ours[0]
	var body: Dictionary = world.unit_view(corpse).duplicate()
	body["hp"] = 0
	h.equal("command.a_dead_friend_is_not_commandable",
		[DictRead.as_int(body["hp"]) != 0,
			DictRead.as_int(body["player"]) == 0], [false, true],
		"the view the picker hands the click")
	h.equal("command.a_dead_friend_is_not_a_target",
		SliceMain.is_a_target(body, 0), false,
		"clicking your own casualty is not an order to shoot it")
	var enemy: Dictionary = world.unit_view(theirs[0])
	h.equal("command.a_live_enemy_is_a_target",
		SliceMain.is_a_target(enemy, 0), true,
		"which is the case the branch exists for")
	var dead_enemy: Dictionary = enemy.duplicate()
	dead_enemy["hp"] = 0
	h.equal("command.a_dead_enemy_is_not_a_target",
		SliceMain.is_a_target(dead_enemy, 0), false,
		"a corpse is a corpse whoever owned it")

	# `0x00477DF0`'s third test, `+0x4F != 3`, is not exercised here: making a
	# unit hidden means running the fog pass from the *other* side, which
	# `_fog` above already does, and `World` grows no test-only mutator to
	# fake it. Named rather than silently absent.
	world.turn.current_player = 0
	h.equal("command.visibility_is_the_third_test",
		UnitState.VISIBILITY_HIDDEN, 3,
		"exercised by the fog checks above, not by a hand-set byte")


func _localization(h: TestHarness) -> void:
	var manifest: Dictionary = CacheFixture.manifest()
	var strings: Localization = Localization.from_cache(CacheFixture.paths())
	h.check("text.cache_carries_the_catalogue", strings.has_shipped_text(),
		"%s for %s" % [Localization.GUI_DOCUMENT, strings.language])
	# The manifest's base language unless one was chosen -- and the fixture
	# is converted without a pack, so nothing can be.
	h.equal("text.language_comes_from_the_manifest", strings.language,
		DictRead.as_string(manifest.get("language",
			Localization.FALLBACK_LANGUAGE)))

	# The five shipped words this stage puts on screen, by the ids docs/24
	# section 7's module uses. Compared against the module's own content rather
	# than against a literal: the point is that the id resolves, and the English
	# text is Blue Byte's.
	var ids: Array[int] = [Localization.ID_MISSION, Localization.ID_TURN,
		Localization.ID_PLAYER, Localization.ID_COMPLETED,
		Localization.ID_FAILED]
	var unresolved: Array[String] = []
	for id: int in ids:
		var value: String = strings.shipped(Localization.MODULE_MISSION, id)
		if value.begins_with(Localization.MISSING_PREFIX) or value == "":
			unresolved.append("%s/%d" % [Localization.MODULE_MISSION, id])
	h.check("text.every_shipped_id_resolves", unresolved.is_empty(),
		", ".join(unresolved))
	h.check("text.the_shipped_words_are_not_the_remake_s",
		strings.shipped(Localization.MODULE_MISSION,
			Localization.ID_COMPLETED) != "",
		"'%s'" % strings.shipped(Localization.MODULE_MISSION,
			Localization.ID_COMPLETED))

	# Every one of the remake's own keys resolves in every language it claims.
	var own_bad: Array[String] = []
	for key: Variant in Localization.OWN:
		var name: String = DictRead.as_string(key)
		if strings.text(name).begins_with(Localization.MISSING_PREFIX):
			own_bad.append(name)
	h.check("text.every_own_key_resolves", own_bad.is_empty(),
		", ".join(own_bad.slice(0, REPORT_LIMIT)))

	# A miss is **visible**. This is the whole reason the fallback is a marker
	# and not an empty string.
	h.check("text.a_missing_own_key_is_visible",
		strings.text("no.such.key").begins_with(Localization.MISSING_PREFIX),
		strings.text("no.such.key"))
	h.check("text.a_missing_shipped_id_is_visible",
		strings.shipped(Localization.MODULE_MISSION, 9999).begins_with(
			Localization.MISSING_PREFIX),
		strings.shipped(Localization.MODULE_MISSION, 9999))
	h.check("text.a_missing_module_is_visible",
		strings.shipped("NoSuchModule", 0).begins_with(
			Localization.MISSING_PREFIX),
		strings.shipped("NoSuchModule", 0))

	# An unknown language falls back to English rather than to nothing.
	var foreign: Localization = Localization.new()
	foreign.language = "Klingon"
	h.equal("text.an_unknown_language_falls_back",
		foreign.text("hud.no_selection"),
		DictRead.as_string(DictRead.as_dict(
			Localization.OWN["hud.no_selection"])[Localization.FALLBACK_LANGUAGE]))

	# **Every own key has every column [constant Localization.LANGUAGES]
	# claims, and none is empty** -- so a pack cannot ship with a marker or
	# a blank in the middle of its options screen (docs/92 section 7.6).
	var holes: Array[String] = []
	for key: Variant in Localization.OWN:
		var by_language: Dictionary = DictRead.as_dict(Localization.OWN[key])
		for column: String in Localization.LANGUAGES:
			if not by_language.has(column) \
					or DictRead.as_string(by_language[column]).is_empty():
				holes.append("%s/%s" % [DictRead.as_string(key), column])
	h.check("text.every_own_key_in_every_language", holes.is_empty(),
		", ".join(holes.slice(0, REPORT_LIMIT)))
	var russian: Localization = Localization.new()
	russian.language = "Russian"
	var marked: Array[String] = []
	for key: Variant in Localization.OWN:
		var name: String = DictRead.as_string(key)
		if russian.text(name).begins_with(Localization.MISSING_PREFIX):
			marked.append(name)
	h.check("text.russian_resolves_without_markers", marked.is_empty(),
		", ".join(marked.slice(0, REPORT_LIMIT)))
	h.equal("text.russian_recruit_name",
		russian.text(CampaignHost.RECRUIT_NAME_KEY) % 1, "Солдат 1",
		"the literal the 1C release's Incubation.dll carries")

	# **The shipped fallback is per id.** A pack bank shorter than the
	# neutral one -- the 1C `Txtmod_a` ends at 298 where GOG's runs to 339 --
	# answers the neutral entry for an id it lacks and the marker only for an
	# id neither has; an id both have is the pack's.
	var neutral: Dictionary = {"gui": {"Txtmod_a": {"1": "one", "2": "two"},
		"Txtmod_g": {"11": "Mission"}}}
	var chosen: Dictionary = {"gui": {"Txtmod_a": {"1": "один"}}}
	var mixed: Localization = Localization.from_documents(chosen, neutral,
		"Russian")
	h.equal("text.fallback.pack_wins", mixed.shipped("Txtmod_a", 1), "один")
	h.equal("text.fallback.neutral_per_id", mixed.shipped("Txtmod_a", 2), "two")
	h.equal("text.fallback.neutral_per_bank", mixed.shipped("Txtmod_g", 11),
		"Mission", "a whole bank the pack lacks")
	h.check("text.fallback.neither_is_a_marker",
		mixed.shipped("Txtmod_a", 3).begins_with(Localization.MISSING_PREFIX))
	h.equal("text.fallback.language_is_the_chosen", mixed.language, "Russian")


## docs/22 section 9.1 -- three states, and the middle one is the interesting
## one: a contact is drawn as a blip with no body and no facing.
func _fog(h: TestHarness) -> void:
	h.equal("fog.full_is_drawn",
		[Fog.is_drawn({"visibility": Fog.FULL}),
			Fog.is_contact({"visibility": Fog.FULL})], [true, false])
	h.equal("fog.contact_is_a_blip",
		[Fog.is_drawn({"visibility": Fog.CONTACT}),
			Fog.is_contact({"visibility": Fog.CONTACT})], [true, true])
	h.equal("fog.hidden_is_not_drawn",
		Fog.is_drawn({"visibility": Fog.HIDDEN}), false)
	_the_blip(h)
	# The states are [Visibility]'s, not a second set: a renderer that invented
	# its own numbering would drift the first time the fog pass changed.
	h.equal("fog.states_match_the_simulation",
		[Fog.FULL, Fog.CONTACT, Fog.HIDDEN],
		[Visibility.FULL, Visibility.CONTACT, Visibility.HIDDEN])


## The blip is the engine's own geometry, not a shape this remake invented.
##
## `A_BLIB.3DI` -- `a3DObjects.cpp` line 3838, resolved through
## `aGetNumberOfPrototype` at `0x00407056` -- is a **beam**: 28 vertices
## spanning z 730..6337, about 3.5 m tall. The disc drawn before this was a
## guess, and a flat disc at a cell reads as a decal rather than as something
## standing on the map. The height is what separates the two, so it is what is
## checked; the fallback is checked as well, because a cache built by an older
## converter still has to draw something.
func _the_blip(h: TestHarness) -> void:
	var geometry: Dictionary = CacheFixture.geometry("A00")
	var prototypes: Dictionary = DictRead.as_dict(
		geometry.get("prototypes", {}))
	h.check("fog.the_cache_carries_the_engines_blip",
		prototypes.has(Fog.CONTACT_MODEL),
		"%s is emitted for every world set, named by no placement"
			% Fog.CONTACT_MODEL)
	var beam: MeshInstance3D = Fog.contact_marker(prototypes, {})
	h.check("fog.the_blip_has_a_mesh", beam.mesh != null, beam.name)
	var tall: float = beam.mesh.get_aabb().size.y if beam.mesh != null else 0.0
	h.check("fog.the_blip_is_the_beam", tall > 2.0,
		"%.2f m tall -- the disc it replaced was 0.08" % tall)
	beam.free()
	var disc: MeshInstance3D = Fog.contact_marker({}, {})
	h.check("fog.an_older_cache_still_draws_something",
		disc.mesh != null and disc.mesh.get_aabb().size.y < 0.5,
		"the fallback disc, for a cache built before the beam was emitted")
	disc.free()


func _hud(h: TestHarness) -> void:
	# The text HUD became the battle interface of docs/43 on 2026-09-05; its
	# own suite is `test_hud.gd`. What stays here is the seam this suite
	# guards everywhere: the words are the game's and none is the marker.
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("hud.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var strings: Localization = Localization.from_cache(CacheFixture.paths())
	var hud: MissionHud = MissionHud.new()
	hud.setup(null, strings, null, null, null)
	var yes: Callable = func(_number: int) -> bool: return true
	hud.refresh(world, -1, yes, yes, Vector2(0, -1), Vector2(1, 0), {}, false)
	h.equal("hud.says_the_turn", hud.turn_text(), str(world.turn.turn))
	h.check("hud.no_report_before_the_end", not hud.report_visible(),
		"slots 0..4 are clear")
	var squad: PackedInt32Array = PackedInt32Array()
	for slot: int in world.unit_slots():
		if DictRead.as_int(world.unit_view(slot)["player"]) == 0:
			squad.append(slot)
	h.check("hud.the_mission_has_a_squad", not squad.is_empty(),
		"%d unit(s) of player 0" % squad.size())
	if squad.is_empty():
		hud.free()
		return
	hud.refresh(world, squad[0], yes, yes, Vector2(0, -1), Vector2(1, 0), {}, false)
	var texts: PackedStringArray = hud.panel.texts()
	var named: bool = false
	var missing: bool = false
	for text: String in texts:
		if text.begins_with(DictRead.as_string(world.unit_view(squad[0])["name"])):
			named = true
		if text.contains(Localization.MISSING_PREFIX):
			missing = true
	h.check("hud.names_the_selected_unit", named, ", ".join(texts))
	h.check("hud.renders_no_missing_string_when_selected", not missing, ", ".join(texts))
	world.game_control.set_slot(0, 1)
	hud.refresh(world, squad[0], yes, yes, Vector2(0, -1), Vector2(1, 0), {}, false)
	h.check("hud.the_report_appears_on_a_win", hud.report_visible(), "slot 0 is set")
	var won: String = hud.report_text()
	h.check("hud.the_report_is_the_game_s_own_words",
		won.contains(strings.shipped(Localization.MODULE_MISSION,
			Localization.ID_COMPLETED))
		and won.contains(strings.shipped(Localization.MODULE_REPORT,
			Localization.ID_REPORT_TITLE)), won.replace("\n", " | "))
	h.check("hud.the_report_grades_the_win",
		won.contains(strings.shipped(Localization.MODULE_REPORT,
			Localization.ID_REPORT_SUCCESS)), won.replace("\n", " | "))
	h.check("hud.the_report_renders_no_missing_string",
		not won.contains(Localization.MISSING_PREFIX), won)
	var grades: Array[String] = []
	for value: int in [1, 2, 3]:
		world.game_control.set_slot(0, value)
		hud.refresh(world, squad[0], yes, yes, Vector2(0, -1), Vector2(1, 0), {}, false)
		grades.append(hud.report_text())
	h.check("hud.the_three_win_grades_differ",
		grades[0] != grades[1] and grades[1] != grades[2]
		and grades[0] != grades[2], " | ".join(grades).replace("\n", " / "))
	h.check("hud.the_best_grade_is_the_glorious_one",
		grades[2].contains(strings.shipped(Localization.MODULE_REPORT,
			Localization.ID_REPORT_GLORIOUS)), grades[2].replace("\n", " | "))
	hud.free()


func _mission_result(h: TestHarness) -> void:
	var control: GameControl = GameControl.create()
	h.equal("result.nothing_happened_while_it_runs", control.mission_result(0),
		GameControl.RESULT_NOTHING)
	h.check("result.a_running_mission_pays_nothing_out", control.pays_out(0),
		"the payout gate is the result test, not the end test")
	var grades: Array[int] = []
	for value: int in [1, 2, 3]:
		control.set_slot(0, value)
		grades.append(control.mission_result(0))
	h.equal("result.the_three_grades", grades, [GameControl.RESULT_WON,
		GameControl.RESULT_WON_OUTSTANDING, GameControl.RESULT_WON_GLORIOUS])

	control = GameControl.create()
	control.set_slot(4, 1)
	h.equal("result.the_computer_s_slot_is_a_defeat", control.mission_result(0),
		GameControl.RESULT_DEFEAT)
	h.check("result.a_defeat_forfeits_the_payout", not control.pays_out(0),
		"docs/27 section 6.2 gates on result != 5")

	control = GameControl.create()
	control.set_slot(1, 1)
	h.equal("result.another_player_s_win_defeats_this_one",
		[control.mission_result(0), control.mission_result(1)],
		[GameControl.RESULT_DEFEAT, GameControl.RESULT_WON])

	control = GameControl.create()
	control.set_slot(0, 9)
	h.equal("result.an_unaccounted_value_leaves_the_five_standing",
		control.mission_result(0), GameControl.RESULT_DEFEAT)


## The remake's Give Up is a forfeit, not a second way to kill the squad.
## Drive the same dispatcher the column button uses and require its only
## simulation change to be the game-control defeat stamp.
func _give_up(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("give_up.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	world.turn.current_player = 0
	var before: World = world.clone()
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._shown = before.clone()

	main._on_hud_event(HudTables.EVENT_GIVE_UP)

	h.equal("give_up.marks_the_mission_defeated",
		world.game_control.mission_result(0), GameControl.RESULT_DEFEAT)
	h.equal("give_up.only_changes_the_mission_result",
		world.mirror_diff(before), PackedStringArray(["game_control"]),
		"the squad, loss counters, turn, map and random streams stay untouched")
	main.free()


## The game's own bitmap font, built from the cache (docs/60 section 5).
##
## The check that matters is **coverage**, not metrics. A glyph's pixels are
## palette *indices*, not intensities: `font_2` uses only 0, 1 and 2, so the
## obvious `alpha = value / 255` renders the whole font at 1 % opacity. It
## builds, it reports sane metrics, `has_char` is true for everything -- and
## nothing appears on screen. That is exactly how it first came out, and only
## looking at a screenshot found it.
##
## So this asserts that the atlas has ink: some pixel of the built font is
## fully opaque. Metrics are checked too, because a font that measured zero
## would lay every glyph on top of the last.
func _game_font(h: TestHarness) -> void:
	var font: FontFile = GameFont.load_from(CacheFixture.paths(), "font_2")
	if font == null:
		h.check("font.built", false,
			"no fonts/index.json -- republish the cache")
		return
	h.check("font.built", true, "font_2 at %d px" % font.fixed_size)
	h.equal("font.glyphs",
		font.get_glyph_list(0, Vector2i(font.fixed_size, 0)).size(), 224,
		"one per cp1252 code point from 32 to 255")
	h.check("font.has_letters", font.has_char(65) and font.has_char(122),
		"A and z")
	var measured: Vector2 = font.get_string_size("Incubation", 0, -1,
		font.fixed_size)
	h.check("font.measures", measured.x > 20.0 and measured.y > 4.0,
		"\"Incubation\" is %.0f x %.0f px" % [measured.x, measured.y])

	# The ink. A texture whose most opaque pixel is nearly transparent is the
	# palette-index trap, and every other check above passes through it.
	var image: Image = font.get_texture_image(0,
		Vector2i(font.fixed_size, 0), 0)
	var opaque: int = 0
	for y: int in range(image.get_height()):
		for x: int in range(image.get_width()):
			if image.get_pixel(x, y).a > 0.99:
				opaque += 1
	h.check("font.has_ink", opaque > 100,
		"%d fully opaque texels of %d" % [opaque,
			image.get_width() * image.get_height()])


## The walk and the walk's own epilogue, in the engine's order.
##
## `aExecuteMove`'s step loop blocks, so the mine's blast (`0x0046EDAF`) and
## the teleporter's stream (`0x0046EE03`) are drawn after the last step. The
## body walks on [UnitsView]'s clock and the set pieces on [SequenceQueue]'s;
## since docs/100 the mine is an **event of its own** behind the `move`, and
## the playback's `busy` gate -- the body still walking -- is what keeps it
## there. No stage of the remake's own joins the two clocks any more, and a
## plain walk queues nothing behind the body.
func _walk_epilogue(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("walk.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var slot: int = -1
	for candidate: int in world.unit_slots():
		var view: Dictionary = world.unit_view(candidate)
		if not view.is_empty() and DictRead.as_int(view["hp"]) > 0:
			slot = candidate
			break
	if slot < 0:
		h.check("walk.units", false, "_C_140 has no live unit")
		return
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._strings = Localization.new()
	var units: UnitsView = UnitsView.new()
	units.shown_ref = world
	main._units = units
	main._sequences = SequenceQueue.create(null)
	var node: Node3D = Node3D.new()
	node.name = "unit_%d" % slot
	units.add_child(node)

	var view: Dictionary = world.unit_view(slot)
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	var width: int = world.resource.width
	var step: int = 1 if x + 1 < width else -1
	var route: PackedInt32Array = PackedInt32Array([
		world.state.index_of(x, y), world.state.index_of(x + step, y)])
	var walk_event: Dictionary = AIEvent.make("move", slot, x, y, x + step, y,
		1, "", {"path": route, "steps": 1, "facing": 0, "cost": 1,
			"seen_source": false, "seen_destination": false}).to_dict()
	var blast: AttackResult = AttackResult.new()
	blast.fired = true
	var mine_event: Dictionary = AIEvent.make("mine", slot, x + step, y,
		x + step, y, 0, "", {"blast": blast.to_dict(), "events": []}).to_dict()
	var presented: Array[String] = []
	var present: Callable = func(event: Dictionary) -> float:
		if event.is_empty():
			return 0.0
		var kind: String = DictRead.as_string(event["kind"])
		presented.append(kind)
		return main._play_event_body(event, kind)
	var busy: Callable = func() -> bool:
		return main._sequences.is_running() or units.is_walking()

	# A plain walk: the body, and nothing queued behind it.
	main._playback.play([walk_event], present, Callable(), 0.0, busy)
	h.check("walk.the_walk_is_the_first_event",
		units.is_walking() and presented == (["move"] as Array[String]),
		"the body is on its way from inside `play()`")
	h.check("walk.a_plain_walk_holds_nothing_after_it",
		not main._sequences.is_running(),
		"no stage waits on the queue for a walk with no epilogue")
	units.finish_walks(world)
	var _over: bool = main._playback.advance(1.0, DictRead.as_bool(busy.call()))
	h.check("walk.and_is_over_when_the_body_arrives",
		not main._playback.is_running() and not main._sequences.is_running(),
		"`UnitsView.is_walking` is the predicate, not a frame count")

	# The walk onto a mine: the blast is its own event, and it waits.
	presented.clear()
	main._playback.play([walk_event, mine_event], present, Callable(), 0.0,
		busy)
	h.equal("walk.the_mine_waits_for_the_walk", presented,
		["move"] as Array[String], "the body has not arrived")
	var _still: bool = main._playback.advance(5.0, DictRead.as_bool(busy.call()))
	h.check("walk.the_blast_is_not_queued_under_the_body",
		presented == (["move"] as Array[String]) and not main._sequences.is_running(),
		"five seconds of a walking body: the mine has not gone off")
	units.finish_walks(world)
	var _landed: bool = main._playback.advance(0.0, DictRead.as_bool(busy.call()))
	h.equal("walk.the_mine_is_its_own_event_after_the_walk", presented,
		["move", "mine"] as Array[String],
		"`aExecuteBomb` runs after the last step has been drawn")
	h.check("walk.the_blast_is_a_shot_sequence", main._sequences.is_running(),
		"weapon 36/37 on the bomb\'s own cell, as `aPlayFightAnimation` draws it")
	main._sequences.skip()
	main._playback.skip()
	units.free()
	main.free()


## A mine reached through Use is still an aExecuteBomb fight animation. The
## push and the blast share one journal delta, but remain two ordered pictures:
## first the object slides onto the cell, then weapon 36 impacts there.
func _push_mine_presentation(h: TestHarness) -> void:
	var world: World = World.create(TestFixtures.map_document(7, 5, [
		TestFixtures.unit(0, 1, 2, 0, 0, 6, 0, [], 3, 15, 3, 200),
		TestFixtures.unit(1, 2, 2, 30, TurnState.PLAYER_PROPS, 0, 0, [],
			0, 0, 0, 200),
	]), TestFixtures.balance([TestFixtures.unit_type(30)]), 1.0)
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._shown = world.clone()
	main._strings = Localization.new()
	main._sequences = SequenceQueue.create(null)
	var blast: AttackResult = AttackResult.new()
	blast.fired = true
	var outcome: Dictionary = {
		"ok": true, "kind": "push_onto_mine", "reason": "",
		"cell": [2, 2], "action_point": 0,
		"fires_script_event": false, "pushed": [[3, 2]],
		"blast": blast.to_dict(),
	}
	var _hold: float = main._present_use(0, outcome, Vector2i(2, 2))
	var stages: Array[String] = []
	var guard: int = 0
	while main._sequences.is_running() and guard < 500:
		var stage: String = main._sequences.current()
		if stages.is_empty() or stages[stages.size() - 1] != stage:
			stages.append(stage)
		var _advanced: bool = main._sequences.advance(
			1.0 / SequenceQueue.FRAMES_PER_SECOND)
		guard += 1
	h.check("push_mine.the_blast_follows_the_slide",
		stages.has(PushSequence.STAGE_CELL)
			and stages.has(ShotSequence.STAGE_IMPACT)
			and stages.find(PushSequence.STAGE_CELL)
				< stages.find(ShotSequence.STAGE_IMPACT),
		"stages: %s" % [stages])
	main.free()


func _campaign_screens(h: TestHarness) -> void:
	var cache_dir: String = CacheFixture.cache_dir()
	var paths: CachePaths = CacheFixture.paths()
	var strings: Localization = Localization.from_cache(paths)
	var art: Art = Art.open(paths)
	var font: FontFile = GameFont.load_from(paths, "font_2")
	h.check("screens.art_present", art.has_art(),
		"art/index.json is in the cache")

	var host: CampaignHost = CampaignHost.create(cache_dir,
		CacheFixture.balance(), strings)
	var state: CampaignState = host.start_new(1)
	h.equal("screens.host_started", [state.campaign, state.mission],
		[1, "_C_100"])

	# Every screen builds headless: a `CanvasLayer` needs no renderer.
	var map: CampaignMapScreen = CampaignMapScreen.new()
	map.host = host
	# **The map is a picture now, not a list.** Every open location is a dot
	# standing on the cell whose action point is its id, so what is checked is
	# the set of dots and what a click on one of them means -- the screen no
	# longer has a row per location to count.
	var open: PackedInt32Array = host.open_locations()
	var cells: Dictionary[int, Vector2i] = {}
	for index: int in range(open.size()):
		cells[open[index]] = Vector2i(index, 1)
	map.location_cells = cells
	map.setup(art, strings, font)
	var marks: Dictionary[Vector2i, int] = CampaignMapScreen.marks_for(host,
		cells)
	h.equal("screens.map_marks_every_open_location", marks.size(), open.size(),
		"one ring per open location")
	# docs/27 section 2.6.3: every open location wears the same 17x17 white
	# ring; the kind is told by the badge the hover raises, chosen by the id
	# band `fcn.00418F40` tests -- which is the kind table's own partition.
	var all_rings: bool = true
	for cell: Vector2i in marks:
		if marks[cell] != MapMarkers.RING_OPEN:
			all_rings = false
	h.check("screens.map_marks_are_the_open_ring", all_rings, str(marks))
	h.equal("screens.map_badge_bands",
		[CampaignMapScreen.badge_for(1, false), CampaignMapScreen.badge_for(210, false),
		CampaignMapScreen.badge_for(10, false), CampaignMapScreen.badge_for(51, false),
		CampaignMapScreen.badge_for(9, false), CampaignMapScreen.badge_for(25, false),
		CampaignMapScreen.badge_for(1, true), CampaignMapScreen.badge_for(10, true),
		CampaignMapScreen.badge_for(51, true)],
		[15, 15, 12, 9, MapMarkers.BADGE_NONE, MapMarkers.BADGE_NONE, 14, 11, 8])
	var band_is_kind: bool = true
	for id: int in host.open_locations():
		var want: int = -1
		match host.tables.kind_of(id):
			CampaignMap.KIND_UPGRADE:
				want = CampaignMapScreen.BADGE_BAND_BASE
			CampaignMap.KIND_DIALOGUE:
				want = CampaignMapScreen.BADGE_BAND_DIALOGUE
			CampaignMap.KIND_BATTLE:
				want = CampaignMapScreen.BADGE_BAND_BATTLE
		if CampaignMapScreen.badge_band(id) != want:
			band_is_kind = false
	h.check("screens.map_badge_band_is_the_kind", band_is_kind,
		"the three id bands are the three kinds of location")
	h.equal("screens.map_click_names_the_location",
		map.location_at(Vector2i(0, 1)), open[0],
		"a click on a cell is `aLocationHandling` on the location standing there")
	h.equal("screens.map_click_off_the_locations",
		map.location_at(Vector2i(-1, -1)), -1)
	# docs/27 section 2.5: campaign 1 opens two locations `_C_XXX` has no cell
	# for. A location with nowhere to stand is skipped, not drawn at the origin.
	var homeless: Dictionary[int, Vector2i] = {}
	h.equal("screens.map_skips_a_location_with_no_cell",
		CampaignMapScreen.marks_for(host, homeless).size(), 0,
		"docs/27 section 2.5's two cells that are not on the map")
	# **The one irreversible button on this plate asks first.** *End game*
	# drops a campaign that may never have been saved, and `Txtmod_d` 60/61/62
	# is the question and its two answers -- the bank carries them for this
	# button. A click that cannot be undone and says nothing is what
	# docs/92 section 7.4 forbids.
	map._on_pressed("end_game")
	var asked: PackedStringArray = _labels_of(map)
	h.check("screens.map_end_game_asks_first",
		asked.has(strings.shipped("Txtmod_d", 60))
		and asked.has(strings.shipped("Txtmod_d", 61))
		and asked.has(strings.shipped("Txtmod_d", 62)),
		"'Back to the Main Menu without saving?' with Yes and No")
	map._on_pressed(CampaignScreen.CANCEL)
	h.check("screens.map_end_game_can_be_refused",
		_labels_of(map).has(strings.shipped("Txtmod_b", 18)),
		"*No* puts the ordinary row back")
	# The pointer over a location names it, and leaving the picture clears
	# the name: one left standing reads as a selection nobody made.
	map.world_hover(Vector2i(0, 1))
	h.check("screens.map_names_what_is_under_the_pointer",
		_labels_of(map).has("%s  --  %s" % [
			strings.shipped("Campaign", open[0]),
			strings.shipped("Txtmod_b", 141)]),
		"`Campaign.lcl` names every location")
	h.equal("screens.map_hover_is_the_location", map.hovered, open[0])
	map.world_hover(Vector2i(-1, -1))
	h.equal("screens.map_hover_clears", map.hovered, -1)
	_no_missing_strings(h, "map", map)
	map.free()

	# --- the Unit Menu, docs/27 section 3 -------------------------------------
	var roster: UnitMenuScreen = UnitMenuScreen.new()
	roster.host = host
	roster.setup(art, strings, font)
	h.check("screens.unit_menu_rows", roster.root().get_child_count() > 0,
		"%d in the squad" % state.roster.used_slots())
	_no_missing_strings(h, "unit_menu", roster)
	# A row addresses the record, not the position: after a sort the slot the
	# screen remembers still names the same soldier (docs/29 section 1.4).
	roster.selected = 2
	var before: String = state.roster.record(2).name
	state.roster.sort_by_ep()
	roster.refresh()
	h.equal("screens.unit_menu_addresses_a_record",
		state.roster.record(roster.selected).name, before,
		"the seed's three are all rank 1, so the sort leaves them alone")
	# `plate_3` with the frame's window left clear -- the plate Mission Control
	# loads once and this window does not replace.
	h.equal("screens.unit_menu_plate",
		[roster.plate_name(), roster.plate_window()],
		[CampaignScreen.PLATE_MISSION_CONTROL, CampaignScreen.PLATE_WINDOW])
	# **The remake's own reading aids** -- `CampaignScreen.SHADE_BACKING`
	# and `ROW_HOVER`.
	# The original writes these rows straight onto a base's 3D scene and gets
	# away with it because that scene is a dark still; the remake draws the
	# same one and cannot promise a row will never fall over a lit ramp.
	h.check("screens.unit_menu_shades_the_window",
		_shade_of(roster) != null,
		"a backing under the roster and the three counters")
	h.check("screens.unit_menu_rows_light_under_the_pointer",
		_row_lights(roster),
		"every roster row carries a `hover` box of its own")
	roster.free()

	# --- the Item List, docs/27 section 5.2 -----------------------------------
	var items: ItemListScreen = ItemListScreen.new()
	items.host = host
	items.slot = 0
	items.setup(art, strings, font)
	h.equal("screens.item_list_starts_on_weapons", items.kind,
		CampaignHost.KIND_WEAPONS)
	items.toggle()
	h.equal("screens.item_list_toggles", items.kind,
		CampaignHost.KIND_EQUIPMENT, "`Toggle List` is the one button that "
		+ "changes what the window is a list of")
	items.toggle()
	# **Across, then down.** `0x0045A13B` steps the painter's `x` by 250 per
	# row and drops `y` only when it passes 500, so row 1 of the catalogue is
	# the *right* column of line 0 -- not the second entry of a left-hand
	# column. Filling by column ran a twelve-item catalogue eleven deep.
	items.kind = CampaignHost.KIND_WEAPONS
	items.refresh()
	h.equal("screens.item_grid_fills_across",
		[ItemListScreen.grid_cell(0), ItemListScreen.grid_cell(1),
		ItemListScreen.grid_cell(2)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
		"the second row sits right of the first, not under it")
	h.check("screens.item_list_shades_the_window",
		_shade_of(items) != null)
	h.check("screens.item_list_rows_light_under_the_pointer",
		_row_lights(items))
	_no_missing_strings(h, "item_list", items)
	items.free()

	# --- the Recruit window, docs/27 section 3.2 ------------------------------
	var hiring: RecruitScreen = RecruitScreen.new()
	hiring.host = host
	hiring.setup(art, strings, font)
	# The rows are `0x00476260`'s presets, every one of which the cache
	# carries -- so *Light Units* offers four and *Commanders* five, where a
	# reading of the ids as unit types offered four soldiers and nothing.
	h.equal("screens.recruit_light_units", hiring.presets_in(0).size(), 4,
		"presets 0..3: Squad Leader, Platoon Leader, Commander, Guardian")
	h.equal("screens.recruit_commanders",
		hiring.presets_in(4).size(), 5,
		"presets 40..44: the two recons, the two medics and the Jump Trooper")
	# **The five categories are lists, not bases.** `0x004561C9`'s arms fill
	# the five slots of `0x00510A14` one immediate at a time, and reading
	# every write finds twenty-three, not twenty-five: two categories fill
	# four slots and category 3's fifth is 35, not 34.
	h.equal("screens.recruit_categories_are_written_out",
		[RecruitScreen.category_types(0), RecruitScreen.category_types(2),
		RecruitScreen.category_types(3)],
		[PackedInt32Array([0, 1, 2, 3]), PackedInt32Array([20, 21, 22, 23]),
		PackedInt32Array([30, 31, 32, 33, 35])])
	h.equal("screens.recruit_heavy_units", hiring.presets_in(2).size(), 4,
		"20..23 -- 24 is never listed and has no arm")
	h.check("screens.recruit_is_not_the_campaign_path",
		not host.recruits_through_a_screen(),
		"`0x0045B7F8` hires on the spot in game mode 1")
	_no_missing_strings(h, "recruit", hiring)
	hiring.free()

	# --- the Upgrade Menu, docs/27 section 5 ----------------------------------
	var upgrade: UpgradeScreen = UpgradeScreen.new()
	upgrade.host = host
	upgrade.setup(art, strings, font)
	upgrade.select(0)
	# `0x00475240`: the ceiling the panel prints is the type's plus EP / 12,
	# capped at 15 -- the column alone read `15/5` for a rank-10 recruit.
	var ranked: UnitState = UnitState.new()
	ranked.type_id = 0
	ranked.ep = 120
	ranked.hp = 15
	var base_hp: int = DictRead.as_int(host.row_for("units", 0).get("hp_max", 0))
	h.equal("screens.upgrade_hit_point_ceiling_counts_rank",
		upgrade._hit_point_ceiling(ranked),
		mini(Interact.MAX_HIT_POINTS_CAP, base_hp + 10))
	var weapons: Dictionary = host.catalogue("weapons")
	var equipment: Dictionary = host.catalogue("equipment")
	# The measured split at tech 1, which is the tech level a campaign has from
	# beginning to end. A screen that hid the locked rows would make a frozen
	# level look like a working one.
	h.equal("screens.catalogue_weapons",
		[DictRead.as_array(weapons["available"]).size(),
		DictRead.as_array(weapons["locked"]).size()], [5, 13])
	h.equal("screens.catalogue_equipment",
		[DictRead.as_array(equipment["available"]).size(),
		DictRead.as_array(equipment["locked"]).size()], [7, 12])
	# **In a campaign the band is the base's, not the tech level's.**
	# `0x0045BF2A` has two arms and a campaign takes the one that copies
	# `0x00510C5C`/`0x00510C5D`, which the entered location's own arm of
	# `0x0045C7D0` wrote. Location 1 sells tech 0 alone and location 5 sells 9
	# alone, so the same roster sees a different shop at each base.
	#
	# **Location 1's arm has no body of its own.** It and 210 both enter
	# `0x0045CB26`, which the compiler tail-merged, so both sell 0..0; the
	# same holds for 7 and 216 at `0x0045CDAB`, which sell 0..9. Reading an
	# arm's bytes forward from its entry walked into the next location's body
	# and gave this row (0, 3) -- base 7's copy of that error is what made it
	# sell seven weapons instead of sixteen.
	var stood_at: int = host.location
	host.location = 1
	h.equal("screens.catalogue_band_of_location_1",
		[host.catalogue_band(),
		DictRead.as_array(host.catalogue("weapons")["available"]).size()],
		[Vector2i(0, 0), 3])
	host.location = 7
	h.equal("screens.catalogue_band_of_location_7",
		[host.catalogue_band(),
		DictRead.as_array(host.catalogue("weapons")["available"]).size()],
		[Vector2i(0, 9), 16])
	host.location = 5
	h.equal("screens.catalogue_band_of_location_5",
		[host.catalogue_band(),
		DictRead.as_array(host.catalogue("weapons")["available"]).size()],
		[Vector2i(9, 9), 1],
		"`mov al, 9` writes both ends, so that base stocks the one tech-9 "
			+ "weapon and nothing under it")
	host.location = 214
	h.equal("screens.catalogue_band_does_not_start_at_zero",
		host.catalogue_band(), Vector2i(3, 3))
	host.location = stood_at
	h.equal("screens.catalogue_band_without_a_base",
		host.catalogue_band(), Vector2i(0, host.state.tech_level),
		"a location that names no upgrade arm falls back to the tech level")
	# **Neither half carries a nameless record.** Both builders compare the
	# record's name against the empty string before they look at the range
	# (`0x0047A1DD`, `0x0047A0BD`), and weapon 35 -- a `SetWeaponInfo2` line
	# with no `SetWeaponInfo` beside it -- is the one row in the shipped table
	# that trips it. It used to be listed as available, at cost 0 with every
	# stat zero -- and it is inside the id bound, so the name compare is the
	# only thing that keeps it out of the 18 the two halves above add up to.
	var nameless: PackedStringArray = PackedStringArray()
	for kind: String in [CampaignHost.KIND_WEAPONS,
			CampaignHost.KIND_EQUIPMENT]:
		var halves: Dictionary = host.catalogue(kind)
		for half: String in ["available", "locked"]:
			for entry: Variant in DictRead.as_array(halves[half]):
				var row: Dictionary = entry
				if DictRead.as_string(row.get("name", "")) == "":
					nameless.append("%s/%s/%d"
						% [kind, half, DictRead.as_int(row["id"])])
	h.equal("screens.catalogue_skips_the_nameless", nameless,
		PackedStringArray(), "the empty-string compare at `0x004FA524`")
	# **Nothing past the id bound, in either half.** `0x0047A18B` is the test
	# that keeps the ten alien weapons, the eight `B`-variant duplicates and
	# the `"-"` placeholder out of the shop; without it they listed as
	# available at cost 0, drawn with the Light Combat Gun's own picture
	# because every one of them carries icon 0.
	var past: PackedStringArray = PackedStringArray()
	for kind: String in [CampaignHost.KIND_WEAPONS,
			CampaignHost.KIND_EQUIPMENT]:
		var bound: int = CampaignHost.CATALOGUE_ID_MAX[kind]
		var halves: Dictionary = host.catalogue(kind)
		for half: String in ["available", "locked"]:
			for entry: Variant in DictRead.as_array(halves[half]):
				var row: Dictionary = entry
				if DictRead.as_int(row["id"]) >= bound:
					past.append("%s/%d" % [kind, DictRead.as_int(row["id"])])
	h.equal("screens.catalogue_stops_at_the_bound", past,
		PackedStringArray(), "weapons below 20, equipment below 21")
	# The composed faces, which is `aPrintGadget`'s own arithmetic
	# (`0x0043a4ab` normal, `0x0043a2ab` lit) rather than a measurement off a
	# screenshot: left, then `Width - 2` fills, then right, edge to edge.
	var action_face: Texture2D = art.button_face(Art.BUTTON_BASE_ACTION,
		CampaignScreen.GUI_BUTTON_WIDTH, false)
	h.equal("screens.button_face_width",
		int(action_face.get_size().x) if action_face != null else 0, 169,
		"27 + 4*31 + 18, the width `0x0043a9d0` measures")
	var field_face: Texture2D = art.button_face(Art.BUTTON_BASE_FIELD,
		UpgradeScreen.NAME_FIELD_WIDTH, false)
	h.equal("screens.name_field_width",
		int(field_face.get_size().x) if field_face != null else 0, 160,
		"32 + 3*32 + 32 -- the name box is gadget type 3 too")
	var lit_face: Texture2D = art.button_face(Art.BUTTON_BASE_ACTION,
		CampaignScreen.GUI_BUTTON_WIDTH, true)
	h.check("screens.button_lit_is_a_different_face",
		lit_face != null and action_face != null
			and lit_face.get_image().get_data()
				!= action_face.get_image().get_data(),
		"`buttons.LIB` 3/5/4 are the pointer's, not a press")
	# And the face actually reaches the widget: a `Button` takes its picture
	# from a style box, and the pointer's box has to be a different one.
	_button_probe(h, art, strings, font)
	h.equal("screens.button_lit_same_width",
		int(lit_face.get_size().x) if lit_face != null else 0,
		int(action_face.get_size().x) if action_face != null else 0)

	# `plate_6` is the one campaign window that loads a plate of its own
	# (`0x0045BFBB`), and it is painted rather than framed -- no window.
	h.equal("screens.upgrade_plate",
		[upgrade.plate_name(), upgrade.plate_window()],
		[CampaignScreen.PLATE_UPGRADE, Rect2()])
	h.check("screens.upgrade_offers_buy_before_anything_changed",
		not upgrade.undo_offered(),
		"gadget 0 and gadget 18 share (405, 384); `0x0045C075` clears 18")
	# *Undo* is the whole visit, not the last purchase: `0x0045B507` copies the
	# record back and `0x0043BD40` the economy block.
	var purse_before: int = state.points(0)
	var weapon_before: int = state.roster.record(0).weapon
	# `Standard Assault Rifle` wants LW 3 and the seeded squad's best has LW 1
	# with no skill points at all, so the purchase is refused **on the skills**
	# and the purse is untouched -- the check the engine makes at
	# `rec[+0x18] < cost * 12`.
	upgrade.show_item(CampaignHost.KIND_WEAPONS, 2)
	upgrade.buy()
	h.equal("screens.upgrade_refuses_without_skill_points",
		[state.points(0), upgrade.is_dirty()], [purse_before, false],
		"LW 3 against LW 1 is two skill points and the squad has none")
	# `Advanced Combat Gun` wants LW 1, which Bratt already has, so it costs
	# only the difference in points: 20 for the new one less 10 refunded.
	upgrade.show_item(CampaignHost.KIND_WEAPONS, 1)
	upgrade.buy()
	h.equal("screens.upgrade_buy_costs_the_difference",
		[state.points(0), state.roster.record(0).weapon],
		[purse_before - 10, 1])
	h.check("screens.upgrade_buy_changed_something", upgrade.is_dirty(),
		"which is what *Undo* would put back")
	# The model window shows the soldier **with** the weapon: the selector
	# names a body per weapon, so the purchase rebuilds it on the spot rather
	# than on the next visit.
	h.equal("screens.upgrade_buy_rebuilds_the_body_for_the_weapon",
		upgrade._figure_weapon, 1,
		"the body in the window is the one the new weapon selects")
	# **The two share a position per catalogue row, not per visit.** The item
	# window's refresh re-gates gadget 0 on the row that is up: the weapon
	# just bought is carried now (`0x00458037`), so the position keeps the
	# *Undo* the purchase armed at `0x0045A970` -- and stepping onto one the
	# soldier can still afford disables gadget 18 again (`0x004580E3`).
	h.check("screens.upgrade_undo_is_offered_on_the_bought_row",
		upgrade.undo_offered() and not upgrade.buy_offered(),
		"carried, so gadget 0 is greyed and 18 is still armed")
	upgrade.show_item(CampaignHost.KIND_WEAPONS, 0)
	h.check("screens.upgrade_buy_returns_on_another_row",
		upgrade.buy_offered() and not upgrade.undo_offered(),
		"`Light Combat Gun` is affordable and is not what he carries")
	upgrade.show_item(CampaignHost.KIND_WEAPONS, 1)
	upgrade.undo()
	h.equal("screens.upgrade_undo_restores_the_visit",
		[state.points(0), state.roster.record(0).weapon, upgrade.is_dirty()],
		[purse_before, weapon_before, false])
	# A fresh visit with the carried weapon up leaves **both** gadgets
	# disabled, which the engine does too: the failing gate greys gadget 0
	# and the build has already cleared 18.
	upgrade.select(0)
	upgrade.show_item(CampaignHost.KIND_WEAPONS,
		state.roster.record(0).weapon)
	h.check("screens.upgrade_carried_row_offers_neither",
		not upgrade.buy_offered() and not upgrade.undo_offered(),
		"`0x00458037` refuses the row the soldier already carries")

	# Gadget 3 is a `GUI_SetTextButton` and not a caption: it renames the
	# soldier, and `0x00458449` greys it for a hero (docs/10 section 5.11).
	var hero_slot: int = Roster.NO_SLOT
	var named_slot: int = Roster.NO_SLOT
	for slot: int in state.roster.occupied_slots():
		if Upgrade.may_rename(state.roster.record(slot)):
			named_slot = slot
		else:
			hero_slot = slot
	h.check("screens.upgrade_roster_has_a_hero", hero_slot != Roster.NO_SLOT,
		"the campaign's one `pool_flag == 2` record")
	h.check("screens.upgrade_roster_has_a_recruit",
		named_slot != Roster.NO_SLOT, "and somebody who may be renamed")
	upgrade.select(hero_slot)
	upgrade.begin_rename()
	h.check("screens.upgrade_hero_keeps_his_name", not upgrade.is_renaming(),
		"the box does not open on a hero")
	upgrade.select(named_slot)
	var was_called: String = state.roster.record(named_slot).name
	upgrade.begin_rename()
	h.check("screens.upgrade_name_box_opens", upgrade.is_renaming())
	upgrade.commit_rename("Rook")
	h.equal("screens.upgrade_renamed",
		[state.roster.record(named_slot).name, upgrade.is_renaming()],
		["Rook", false])
	h.check("screens.upgrade_rename_is_part_of_the_visit", upgrade.is_dirty(),
		"a name is one of the fields *Undo* puts back")
	upgrade.undo()
	h.equal("screens.upgrade_rename_undone",
		state.roster.record(named_slot).name, was_called)
	# An empty name is refused rather than written -- `+0x00` is the record's
	# only identity, and the original's field cannot be cleared either.
	upgrade.begin_rename()
	upgrade.commit_rename("   ")
	h.equal("screens.upgrade_empty_name_refused",
		state.roster.record(named_slot).name, was_called)
	# **Leaving the box keeps what was typed**, which means the `focus_exited`
	# connection has to read the field when it fires. A `Callable.bind` freezes
	# its argument where the connection is made -- one line under
	# `field.text = unit.name` -- so a bound `field.text` hands the commit the
	# *old* name and everything typed is dropped.
	upgrade.begin_rename()
	var box: LineEdit = _first_field(upgrade)
	h.check("screens.upgrade_name_box_is_a_field", box != null,
		"gadget 3 opens a `LineEdit` over the composed panel")
	if box != null:
		box.text = "Vulture"
		box.focus_exited.emit()
	h.equal("screens.upgrade_focus_leaving_keeps_the_typed_name",
		[state.roster.record(named_slot).name, upgrade.is_renaming()],
		["Vulture", false])
	upgrade.begin_rename()
	upgrade.commit_rename(was_called)


	# The eight region hints are hover text now, not captions laid over the
	# plate: `Txtmod_b` 166..173 on the regions and 160..165 on the six skill
	# boxes.
	upgrade.select(named_slot)
	var tips: PackedStringArray = _tooltips_of(upgrade)
	for id: int in UpgradeScreen.HINT_IDS:
		var line: String = strings.shipped(CampaignScreen.BANK_MISSION, id)
		h.check("screens.upgrade_hint_%d" % id, tips.has(line),
			"%s is on a region" % line)
	for index: int in range(6):
		var skill_line: String = strings.shipped(CampaignScreen.BANK_MISSION,
			UpgradeScreen.ID_HINT_FITNESS + index)
		h.check("screens.upgrade_skill_hint_%d" % index,
			tips.has(skill_line), "%s is on its box" % skill_line)
	h.check("screens.upgrade_name_hint",
		tips.has(strings.shipped(CampaignScreen.BANK_MISSION,
			UpgradeScreen.ID_HINT_UNIT)),
		"and *Unit to upgrade* is on the name field itself")


	# The *i*: `0x0045B4BC` toggles it, the picture goes (`0x00458BFE`) and the
	# item's own `Data.txt` page takes its place -- the letter out of the
	# record (`key`) plus the family's digit, so `Scan Module`'s `A` is `A1`.
	upgrade.descriptions = InfoText.new()
	upgrade.descriptions.read({
		"schema": InfoText.SCHEMA,
		"families": {"units": "0", "equipment": "1", "weapons": "2"},
		"no_page": "#",
		"blocks": {"A1": [{"text": "a scanner", "colour": 1, "font": 0,
			"breaks": 0}]},
	})
	upgrade.show_item(CampaignHost.KIND_EQUIPMENT, 0)
	upgrade.hints = false
	upgrade.refresh()
	h.check("screens.upgrade_no_description_while_the_i_is_up",
		not _rich_text_of(upgrade).contains("a scanner"),
		"with the *i* up the window is the picture")
	upgrade.hints = true
	upgrade.refresh()
	h.check("screens.upgrade_i_shows_the_description",
		_rich_text_of(upgrade).contains("a scanner"),
		"`Data.txt`'s A1, which is what `key` \"A\" plus family 1 names")
	upgrade.hints = false
	upgrade.refresh()

	_no_missing_strings(h, "upgrade", upgrade)
	upgrade.free()

	# The place interface has no screen of its own; its lines go to the
	# HUD's caption label, and every one `SliceMain` can say has to resolve.
	var deploy_lines: PackedStringArray = PackedStringArray([
		SliceMain.DEPLOY_LINE_HINT, SliceMain.DEPLOY_LINE_NEED_ONE,
		SliceMain.DEPLOY_LINE_POOL_EMPTY, World.DEPLOY_NOT_A_CELL,
		World.DEPLOY_CELL_TAKEN, World.DEPLOY_NO_SLOT,
		World.DEPLOY_EMPTY_RECORD, World.RECALL_NO_UNIT,
		World.RECALL_NOT_YOURS, World.RECALL_NOT_A_CANDIDATE,
		CampaignHost.RECALL_POOL_FULL])
	var unresolved: PackedStringArray = PackedStringArray()
	for name: String in deploy_lines:
		if strings.text(SliceMain.DEPLOY_LINE_PREFIX % name).begins_with(
				Localization.MISSING_PREFIX):
			unresolved.append(name)
	h.check("screens.every_deploy_line_resolves", unresolved.is_empty(),
		"missing: " + ", ".join(unresolved))

	var briefing: BriefingScreen = BriefingScreen.new()
	briefing.mission = "_C_100"
	briefing.paths = paths
	briefing.document = CacheFixture.read_json(
		"%s/text/briefing/_C_100.json" % cache_dir)
	briefing.setup(art, strings, font)
	var blocks: Dictionary = DictRead.as_dict(
		briefing.document.get("blocks", {}))
	h.check("screens.briefing_has_blocks", blocks.has("A0"),
		"the cache carries %s" % str(blocks.keys()))
	h.check("screens.briefing_is_spans",
		DictRead.as_array(blocks.get("A0", [])).size() > 1,
		"structure, not a marked-up string")
	_no_missing_strings(h, "briefing", briefing)
	briefing.free()

	# **The heading face is the game's too.** `{§1}` is written `[b]`
	# ([method BriefingText.to_bbcode]) and a [RichTextLabel] with only
	# `normal_font` overridden draws bold in the *theme's* face -- so a
	# briefing asked for in the shipped font came out with `font_0` body text
	# under headings in Godot's vector default, which is what the two faces
	# looked like side by side.
	var body_text: BriefingText = BriefingText.create(paths, true)
	var body_face: Font = body_text.get_theme_font("normal_font")
	var head_face: Font = body_text.get_theme_font("bold_font")
	var head_height: int = _fixed_size(head_face)
	var body_height: int = _fixed_size(body_face)
	h.check("screens.briefing_bold_is_the_shipped_face",
		head_face != body_face and head_height > 0
			and head_height == body_height,
		"`font_1`, a %d-unit bitmap beside `font_0`'s %d, and not the theme's "
		% [head_height, body_height] + "vector bold")
	# **Four faces, not two.** The second ink level of a glyph is drawn in the
	# ramp's second colour, and the three ramps do not agree on the fraction,
	# so the pair carrying the body ramp's own goes in the italic slots.
	var slanted: Font = body_text.get_theme_font("italics_font")
	var slanted_heavy: Font = body_text.get_theme_font("bold_italics_font")
	h.check("screens.briefing_has_the_body_ramp_faces",
		_fixed_size(slanted) == body_height
			and _fixed_size(slanted_heavy) == head_height
			and slanted != body_face and slanted_heavy != head_face,
		"`font_0` and `font_1` again, at the body ramp's shade")
	# The blank line under a heading: `breaks` is a count and two `@` in the
	# shipped source start two lines, not one.
	var two: String = BriefingText.to_bbcode([{"text": "a", "font": 0,
		"colour": 0, "breaks": 0}, {"text": "b", "font": 0, "colour": 0,
		"breaks": 2}])
	h.check("screens.briefing_breaks_are_counted", two.contains("\n\n"),
		"a span with `breaks` 2 opens a blank line before it")
	body_text.free()

	# The debriefing names both silent refusals.
	var report: Dictionary = {
		"result": ScoreRecord.RESULT_WON, "score": 140, "total": 140,
		"kills": 6, "losses": 1, "equipment_points": 250, "commendations": 1,
		"recovered": [{"name": "Bratt", "slot": 0}],
		"lost": [{"name": "West", "reason": MissionEnd.DROP_NOT_CANDIDATE},
			{"name": "Maxon", "reason": MissionEnd.DROP_POOL_FULL}],
		"next_map": "_C_101"}
	var board: ScoreRecord = ScoreRecord.new()
	board.kills = 6
	board.campaign_kills = 6
	board.losses = 1
	board.campaign_losses = 1
	board.score = 140
	board.total = 140
	board.result = ScoreRecord.RESULT_WON
	var debriefing: DebriefingScreen = DebriefingScreen.new()
	debriefing.report = report
	debriefing.board = board
	debriefing.setup(art, strings, font)
	var named: PackedStringArray = _labels_of(debriefing)
	var lost_named: int = 0
	for line: String in named:
		if line.contains("West") or line.contains("Maxon"):
			lost_named += 1
	h.equal("screens.debriefing_names_the_lost", lost_named, 2,
		"docs/92 section 7.4: the rule stays, the silence does not")
	h.check("screens.debriefing_shows_both_halves",
		named.has(strings.shipped("Txtmod_d", 30))
		and named.has(strings.shipped("Txtmod_d", 31)),
		"'In Mission' beside 'In Campaign' -- the record's four pairs")
	_no_missing_strings(h, "debriefing", debriefing)
	debriefing.free()
	host = null


## A bitmap face's own height, or 0 for anything that is not one -- which is
## what a theme fallback answers.
static func _fixed_size(chosen: Font) -> int:
	if not chosen is FontFile:
		return 0
	var file: FontFile = chosen
	return file.fixed_size


## Not one caption may come back as `Localization`'s missing marker.
func _no_missing_strings(h: TestHarness, name: String,
		screen: CampaignScreen) -> void:
	var missing: PackedStringArray = PackedStringArray()
	for line: String in _labels_of(screen):
		if line.begins_with(Localization.MISSING_PREFIX):
			missing.append(line)
	h.equal("screens.%s.every_string_resolves" % name, missing,
		PackedStringArray(),
		"every caption comes from the shipped banks")


## What a dressed button carries: the two faces, the two sounds, the slicing.
##
## The screen is kept alive for the length of it -- the sounds are bound to
## **its** method, and freeing it first drops the very connections being
## counted.
func _button_probe(h: TestHarness, art: Art, strings: Localization,
		font: FontFile) -> void:
	var screen: CampaignScreen = CampaignScreen.new()
	screen.setup(art, strings, font)
	var probe: Button = screen.gui_text_button("probe", "probe", Vector2.ZERO)
	h.check("screens.button_hover_box_differs",
		probe.get_theme_stylebox("hover") != probe.get_theme_stylebox("normal"),
		"the hover state is dressed in `buttons.LIB` 3/5/4")
	h.check("screens.button_focus_box_is_empty",
		probe.get_theme_stylebox("focus") is StyleBoxEmpty,
		"focus draws over whatever is showing, so it must draw nothing")
	h.check("screens.button_sounds_armed",
		probe.mouse_entered.get_connections().size() > 0
			and probe.button_down.get_connections().size() > 0,
		"the pointer's sound and the press's, `0x0043C500` and `0x0043E5E0`")
	var box: StyleBoxTexture = probe.get_theme_stylebox("normal") \
		as StyleBoxTexture
	h.check("screens.button_face_is_nine_sliced",
		box != null and box.texture_margin_left > 0.0
			and box.texture_margin_right > 0.0
			and box.axis_stretch_horizontal
				== StyleBoxTexture.AXIS_STRETCH_MODE_TILE,
		"the caps keep their width and the fill tiles, whatever the rectangle")
	screen.free()


## Everything a screen's rich-text boxes are showing.
func _rich_text_of(node: Node) -> String:
	var out: PackedStringArray = PackedStringArray()
	for child: Node in node.get_children():
		var page: RichTextLabel = child as RichTextLabel
		if page != null:
			out.append(page.get_parsed_text())
		out.append(_rich_text_of(child))
	return " ".join(out)


## Every hover hint on a screen, wherever it is hung.
## The backing [method Screen.shade] draws, or null.
func _shade_of(node: Node) -> ColorRect:
	for child: Node in node.get_children():
		var rect: ColorRect = child as ColorRect
		var wanted: float = CampaignScreen.SHADE_BACKING.a
		if rect != null and is_equal_approx(rect.color.a, wanted):
			return rect
		var deeper: ColorRect = _shade_of(child)
		if deeper != null:
			return deeper
	return null


## Whether every flat row button on a screen drives a light of its own.
func _row_lights(node: Node) -> bool:
	var rows: int = 0
	for button: Button in _flat_buttons(node):
		rows += 1
		if button.mouse_entered.get_connections().is_empty() \
				or button.mouse_exited.get_connections().is_empty():
			return false
	return rows > 0


func _flat_buttons(node: Node) -> Array[Button]:
	var out: Array[Button] = []
	for child: Node in node.get_children():
		var button: Button = child as Button
		if button != null and button.flat:
			out.append(button)
		out.append_array(_flat_buttons(child))
	return out


## The first text field on a screen, or null.
func _first_field(node: Node) -> LineEdit:
	for child: Node in node.get_children():
		var field: LineEdit = child as LineEdit
		if field != null:
			return field
		var deeper: LineEdit = _first_field(child)
		if deeper != null:
			return deeper
	return null


func _tooltips_of(node: Node) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for child: Node in node.get_children():
		var control: Control = child as Control
		if control != null and control.tooltip_text != "":
			out.append(control.tooltip_text)
		out.append_array(_tooltips_of(child))
	return out


func _labels_of(node: Node) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for child: Node in node.get_children():
		var label: Label = child as Label
		if label != null:
			out.append(label.text)
		var button: Button = child as Button
		if button != null:
			out.append(button.text)
		out.append_array(_labels_of(child))
	return out


## The drawn-cell override, on a world where it decides the answer.
##
## A 7x7 map with a wall of tall cells down the middle, a marine on one side
## and an alien on the other: the plain pass cannot see the alien, and the
## same pass asked at a cell on the marine's own side can. Without a fixture
## like this the check is vacuous -- on `_C_140`'s opening turn every alien is
## already fully visible, so an override changes nothing and a broken
## override passes.
func _fog_override(h: TestHarness) -> void:
	# 40 levels of `MissionScript.HEIGHT_LEVEL_UNITS`, well over any body.
	var wall: int = 40 * MissionScript.HEIGHT_LEVEL_UNITS
	var heights: Array = []
	for i: int in range(49):
		heights.append(wall if i % 7 == 3 else 0)
	var units: Array = [
		TestFixtures.unit(0, 1, 3, 0, 0),
		TestFixtures.unit(1, 5, 3, 0, UnitState.PLAYER_ALIEN),
	]
	var world: World = World.create(
		TestFixtures.map_document(7, 7, units, [], heights),
		TestFixtures.balance(), 1.0)
	var fog: PictureFog = PictureFog.new()
	fog.viewer = 0
	var plain: Dictionary[int, int] = fog.states(world)
	h.check("fog.the_wall_hides_the_alien",
		DictRead.as_int(plain.get(1, -1)) != Visibility.FULL,
		"a wall of %d levels between them, answered %d"
			% [40, DictRead.as_int(plain.get(1, -1))])
	var at: Dictionary[int, Vector2i] = {1: Vector2i(2, 3)}
	var drawn: Dictionary[int, int] = fog.states(world, at)
	h.equal("fog.the_walkers_body_cell_is_what_is_asked",
		DictRead.as_int(drawn.get(1, -1)), Visibility.FULL,
		"the body is drawn on the marine's side of the wall, so it is a body")
	h.equal("fog.the_override_is_put_back",
		Vector2i(DictRead.as_int(world.unit_view(1)["x"]),
			DictRead.as_int(world.unit_view(1)["y"])), Vector2i(5, 3),
		"the pass is a query and moves nothing for good")


## A shot host that records where each muzzle burst is placed: the cell the
## sequence was given, before any trigger table looks at it.
class MuzzleRecorder extends SliceMain.MainShotHost:
	var shots: Array[Vector2i] = []

	func muzzle(_weapon: int, sx: int, sy: int, _tx: int, _ty: int,
			_shooter: int = MapState.NO_UNIT,
			_pattern: Array[Dictionary] = []) -> void:
		shots.append(Vector2i(sx, sy))


## The playback's pacing -- docs/100 section 3, revised.
##
## Oracle boundary: **specification**. The original's `aPlay*` routines block
## for as long as they draw and return; the remake's playback reproduces that
## for a player's command and adds a gap of its own, [constant
## EventPlayback.STEP_SECONDS], to the computer's turn only. Five facts: the
## first event shows in the frame the command was given, a player's command
## has no gap and no floor, the computer's turn keeps its gap, a shown event
## whose presenter queued nothing costs nothing, and the hold a presenter
## asks for runs *under* the animation rather than after it.
func _playback_pacing(h: TestHarness) -> void:
	var events: Array[Dictionary] = []
	for slot: int in range(2):
		var event: Dictionary = AIEvent.make("fire", slot, 0, 0, 1, 1).to_dict()
		event["delta"] = {}
		events.append(event)
	var seen: Array[int] = [0]
	var busy: Array[bool] = [true]
	var probe: Callable = func() -> bool: return busy[0]
	var count: Callable = func(event: Dictionary) -> float:
		if not event.is_empty():
			seen[0] += 1
		return 0.0

	var playback: EventPlayback = EventPlayback.new()
	playback.play(events, count, Callable(), 0.0, probe)
	h.equal("playback.the_first_event_shows_inside_play", seen[0], 1,
		"no empty frame between the button and the shot")

	# A second command over one still being drawn ends the first: its deltas
	# land and its finish runs before the new list is taken.
	var landed: Array[int] = [0]
	var finished: Array[int] = [0]
	var land: Callable = func(_event: Dictionary) -> void:
		landed[0] += 1
	var finish_count: Callable = func(event: Dictionary) -> float:
		if event.is_empty():
			finished[0] += 1
		return 0.0
	var second: EventPlayback = EventPlayback.new()
	second.play(events, finish_count, land, 0.0, probe)
	var before: int = finished[0]
	second.play(events, finish_count, land, 0.0, probe)
	h.check("playback.a_second_play_lands_the_first",
		landed[0] >= events.size() and finished[0] == before + 1,
		"landed %d of %d, finished %d time(s)"
			% [landed[0], events.size(), finished[0] - before])
	second.skip()
	busy[0] = false
	var _next: bool = playback.advance(0.01, false)
	h.equal("playback.a_player_command_has_no_gap", seen[0], 2,
		"the second follows in the frame the picture stands free")

	seen[0] = 0
	busy[0] = true
	playback.play(events, count, Callable(), EventPlayback.STEP_SECONDS, probe)
	busy[0] = false
	var _soon: bool = playback.advance(0.01, false)
	h.equal("playback.the_computers_turn_keeps_the_gap", seen[0], 1,
		"%.2f s of free picture before the next alien moves"
			% EventPlayback.STEP_SECONDS)
	var _later: bool = playback.advance(EventPlayback.STEP_SECONDS, false)
	h.equal("playback.and_steps_once_the_gap_has_passed", seen[0], 2)

	seen[0] = 0
	busy[0] = false
	var quiet: Array[Dictionary] = []
	for _i: int in range(2):
		var script: Dictionary = AIEvent.make("script", -1, 0, 0, 0, 0, 0, "",
			{"ran": true, "events": []}).to_dict()
		script["delta"] = {}
		quiet.append(script)
	playback.play(quiet, count, Callable(), EventPlayback.STEP_SECONDS, probe)
	h.check("playback.a_quiet_shown_event_holds_nothing",
		seen[0] == 2 and not playback.is_running(),
		"a presenter that asked for nothing and queued nothing waits no gap "
		+ "and no floor: %d seen, running %s" % [seen[0], str(playback.is_running())])

	seen[0] = 0
	busy[0] = true
	var ask: Callable = func(event: Dictionary) -> float:
		if event.is_empty():
			return 0.0
		seen[0] += 1
		return 1.0 if seen[0] == 1 else 0.0
	playback.play(events, ask, Callable(), 0.0, probe)
	var _held: bool = playback.advance(1.0, true)
	h.equal("playback.the_picture_holds_the_event", seen[0], 1,
		"busy: the event on screen does not end")
	busy[0] = false
	var _freed: bool = playback.advance(0.0, false)
	h.equal("playback.the_hold_runs_while_the_picture_is_busy", seen[0], 2,
		"the second it asked for ran under the animation and is not waited "
		+ "out again after it")


## Every kind the journal marks with a picture has an arm that draws it
## (docs/100 section 3): the walk's mine, the teleporter, the return fire,
## the script's set pieces and the computer's door all queue something or
## answer a hold, and a hook that drew nothing answers zero so the playback
## goes straight on.
func _presenter_arms(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("presenters.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var slot: int = -1
	for candidate: int in world.unit_slots():
		var view: Dictionary = world.unit_view(candidate)
		if not view.is_empty() and DictRead.as_int(view["hp"]) > 0:
			slot = candidate
			break
	if slot < 0:
		h.check("presenters.units", false, "_C_140 has no live unit")
		return
	var view: Dictionary = world.unit_view(slot)
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	var x2: int = x + 1 if x + 1 < world.resource.width else x - 1
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._strings = Localization.new()
	var units: UnitsView = UnitsView.new()
	units.shown_ref = world
	main._units = units
	var node: Node3D = Node3D.new()
	node.name = "unit_%d" % slot
	units.add_child(node)
	var blast: AttackResult = AttackResult.new()
	blast.fired = true
	var arms: Dictionary[String, Dictionary] = {
		"mine": AIEvent.make("mine", slot, x, y, x, y, 0, "",
			{"blast": blast.to_dict(), "events": []}).to_dict(),
		"teleport": AIEvent.make("teleport", slot, x, y, x2, y, 0, "",
			{"events": [{"kind": "teleporter", "x": x, "y": y},
				{"kind": "teleported", "x": x2, "y": y}]}).to_dict(),
		"reaction": AIEvent.make("reaction", slot, x, y, x2, y, 1,
			str(DictRead.as_int(view["weapon"])),
			{"reactor": slot, "ticket": 1, "attack": blast.to_dict(),
				"jammed": false, "mover": slot}).to_dict(),
		"script": AIEvent.make("script", -1, 0, 0, 0, 0, 0, "",
			{"ran": true, "events": [{"name": "open_door",
				"values": [x2, y]}]}).to_dict(),
		"door": AIEvent.make("door", slot, x, y, x2, y).to_dict(),
		"warp": AIEvent.make("warp", slot, x, y, x2, y).to_dict(),
	}
	for kind: String in arms:
		main._sequences = SequenceQueue.create(null)
		var hold: float = main._play_event_body(arms[kind], kind)
		h.check("presenters.%s_has_an_arm" % kind,
			hold > 0.0 or main._sequences.is_running(),
			"%.3f s asked, queue running %s" % [hold,
				str(main._sequences.is_running())])
		main._sequences.skip()
	main._sequences = SequenceQueue.create(null)
	var nothing: Dictionary = AIEvent.make("script", -1, 0, 0, 0, 0, 0, "",
		{"ran": true, "events": []}).to_dict()
	var none: float = main._play_event_body(nothing, "script")
	h.check("presenters.a_hook_that_drew_nothing_holds_nothing",
		is_zero_approx(none) and not main._sequences.is_running(),
		"%.3f s: the playback goes straight on" % none)
	units.free()
	main.free()


## Whose turn the picture is watching is the **mirror's** seat, not whether a
## playback is running: a player's own command runs through the same
## playback, and the progress bar, the *press key to skip* note and the
## agent's `replay` must not take it for the computer's turn.
func _watching_gate(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("hud.watching_cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var main: SliceMain = SliceMain.new()
	main.world = world
	var event: Dictionary = AIEvent.make("move", 0, 0, 0, 1, 1).to_dict()
	event["delta"] = {}
	main._playback.play([event], func(_event: Dictionary) -> float: return 1.0)
	h.check("hud.the_players_playback_runs", main._playback.is_running(),
		"a command is being drawn")
	h.check("hud.a_players_own_command_is_not_watched",
		main._watching(main.shown()).is_empty()
			and not main._watching_the_computer(),
		"the seat is the player's, so no bar and no skip")
	var was: int = world.turn.current_player
	world.turn.previous_player = was
	world.turn.current_player = TurnState.PLAYER_COMPUTER
	var watched: Dictionary = main._watching(main.shown())
	h.check("hud.the_computers_seat_is_watched",
		not watched.is_empty() and DictRead.as_int(watched.get("player", -1)) == was
			and main._watching_the_computer(),
		"the mirror holds 255 from one hand-over to the next: %s" % str(watched))
	world.turn.current_player = was
	main._playback.skip()
	# **The hand-over reads the mirror's seat.** The truth's rotation has run
	# past the computer's turn to the next human seat by the time the replay
	# is drawn; with two humans the fog would otherwise be the wrong seat's.
	main._shown = world.clone()
	world.turn.current_player = 1
	main._shown.turn.current_player = TurnState.PLAYER_COMPUTER
	main._shown.turn.previous_player = 0
	main._fog.viewer = -1
	var hand_over: Dictionary = AIEvent.make("hand_over", -1, 0, 0, 0, 0).to_dict()
	hand_over["delta"] = {"cells": {}, "units": {},
		"turn": main._shown.turn.view(),
		"game_control": main._shown.game_control.values(),
		"rng": main._shown.rng.state(), "crand": main._shown.crand.state()}
	main._apply_event(hand_over)
	h.equal("fog.the_hand_over_reads_the_mirrors_seat", main._fog.viewer, 0,
		"the seat that handed over, off the mirror; the truth already sits "
		+ "at player 1")
	world.turn.current_player = was
	main.free()


## A target band over an empty cell is not drawn: the bands are computed on
## the truth at selection and the mirror lags it, so the aim over a victim
## the shot has killed goes the moment its delta lands rather than when the
## next command recomputes the bands.
func _band_filter(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("overlay.band_cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var alien: int = -1
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["player"]) == UnitState.PLAYER_ALIEN \
				and DictRead.as_int(view["hp"]) > 0:
			alien = slot
			break
	if alien < 0:
		h.check("overlay.band_units", false, "_C_140 places no alien")
		return
	var _seen: bool = world.apply_unit_record(alien,
		{"visibility": Visibility.FULL})
	var view: Dictionary = world.unit_view(alien)
	var cell: Vector2i = Vector2i(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))
	var empty: Vector2i = Vector2i(-1, -1)
	for y: int in range(world.resource.height):
		for x: int in range(world.resource.width):
			if empty.x < 0 and world.state.unit_at(world.state.index_of(x, y)) < 0:
				empty = Vector2i(x, y)
	var bands: Dictionary[Vector2i, int] = {cell: HudTables.STATE_BAND_FIRST,
		empty: HudTables.STATE_BAND_FIRST + 1}
	var drawn: Dictionary[Vector2i, int] = GroundSprites.cell_states(world, -1,
		null, bands)
	h.check("overlay.a_band_on_a_live_body_is_drawn", drawn.has(cell),
		str(drawn.keys()))
	h.check("overlay.a_band_on_an_empty_cell_is_not", not drawn.has(empty),
		str(drawn.keys()))
	var _killed: bool = world.apply_unit_record(alien, {"hp": 0})
	drawn = GroundSprites.cell_states(world, -1, null, bands)
	h.check("overlay.a_band_on_a_dead_body_is_not_drawn", not drawn.has(cell),
		"the aim goes with the body: %s" % str(drawn.keys()))


## The `fire` delta lands at the impact, from inside the shot's own death
## stage, and not when the playback moves on: the mirror loses the victim in
## the frame the blood appears, the band over its cell goes with it, and the
## playback is still holding the event.
func _death_delta(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("death.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	world.turn.current_player = 0
	var shooter: int = -1
	var victim: int = -1
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			continue
		if DictRead.as_int(view["player"]) == 0:
			if shooter < 0:
				shooter = slot
		elif victim < 0 and world.unit_types().exp(
				DictRead.as_int(view["type_id"])) > 0:
			victim = slot
	if shooter < 0 or victim < 0:
		h.check("death.units", false, "_C_140 has no pair to shoot with")
		return
	var killer: Dictionary = world.unit_view(shooter)
	var sx: int = DictRead.as_int(killer["x"])
	var sy: int = DictRead.as_int(killer["y"])
	var ax: int = sx + 1 if sx + 1 < world.resource.width else sx - 1
	var standing: int = world.state.unit_at(world.state.index_of(ax, sy))
	if standing >= 0 and standing != victim:
		var free: Vector2i = Vector2i(-1, -1)
		for y: int in range(world.resource.height):
			for x: int in range(world.resource.width):
				if free.x < 0 and world.state.unit_at(world.state.index_of(x, y)) < 0:
					free = Vector2i(x, y)
		var _aside: bool = world.apply_unit_record(standing, {"x": free.x,
			"y": free.y})
	var fire_clip: CharismaClip = _clip_with_break()
	world.enable_journal()
	var events: Array[Dictionary] = []
	var last: String = ""
	var mirror: World = null
	for seed_value: int in range(1, 300):
		var _alive: bool = world.apply_unit_record(victim, {"hp": 1, "x": ax,
			"y": sy, "armour_front": 0, "armour_rear": 0, "absorber": 0,
			"visibility": Visibility.FULL})
		var _ready: bool = world.apply_unit_record(shooter,
			{"hp": DictRead.as_int(killer["hp"]), "mp": 40, "acted": 0,
			"ammo": 30, "heat": 0, "action_state": 0, "malfunction": 0})
		world.rng.randomize_seed(float(seed_value))
		var _residue: Array[Dictionary] = world.take_events()
		# The mirror stands where the shot was ordered: the victim alive.
		mirror = world.clone()
		var attempt: AttackResult = world.submit_attack(
			AttackCommand.create(shooter, ax, sy))
		events = world.take_events()
		if attempt.fired and DictRead.as_int(world.unit_view(victim)["hp"]) == 0:
			break
		events = []
		last = "fired %s (%s), victim hp %d" % [str(attempt.fired),
			attempt.reason, DictRead.as_int(world.unit_view(victim)["hp"])]
	h.check("death.found_a_killing_seed", not events.is_empty(),
		"no seed below 300 kills a one-point target; last: " + last)
	if events.is_empty():
		return
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._shown = mirror
	main._strings = Localization.new()
	main._geometry = {"prototypes": {}}
	var units: UnitsView = UnitsView.new()
	units.shown_ref = mirror
	main._units = units
	for slot: int in [shooter, victim]:
		var node: Node3D = Node3D.new()
		node.name = "unit_%d" % slot
		units.add_child(node)
		if fire_clip != null:
			units.states[slot] = CharismaState.create(null, fire_clip,
				fire_clip, fire_clip)
	main._sequences = SequenceQueue.create(null)
	var present: Callable = func(event: Dictionary) -> float:
		if event.is_empty():
			return 0.0
		var kind: String = DictRead.as_string(event["kind"])
		return main._play_event_body(event, kind)
	var busy: Callable = func() -> bool:
		return main._sequences.is_running() or units.any_busy()
	var cell: Vector2i = Vector2i(ax, sy)
	var bands: Dictionary[Vector2i, int] = {cell: HudTables.STATE_BAND_FIRST}
	main._playback.play(events, present, Callable(main, "_apply_event"), 0.0,
		busy)
	h.check("death.the_victim_stands_until_the_impact",
		DictRead.as_int(mirror.unit_view(victim).get("hp", 0)) > 0
			and GroundSprites.cell_states(mirror, shooter, null, bands).has(cell)
			and main._sequences.is_running(),
		"the shot is on the queue and the mirror still has the victim")
	var frames: int = 0
	while main._sequences.is_running() and frames < 400 \
			and DictRead.as_int(mirror.unit_view(victim).get("hp", 0)) > 0:
		var _going: bool = main._sequences.advance(
			1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.check("death.the_fire_delta_lands_at_the_impact",
		DictRead.as_int(mirror.unit_view(victim).get("hp", -1)) == 0
			and main._playback.is_running() and main._sequences.is_running(),
		"after %d frame(s) on %s: the death stage landed the delta itself, "
		% [frames, main._sequences.current()]
		+ "with the playback still holding the event")
	h.check("death.the_body_is_gone_with_the_record",
		units.get_node_or_null(NodePath("unit_%d" % victim)) == null,
		"the rebuild from the mirror dropped it")
	h.check("death.the_band_goes_with_the_body",
		not GroundSprites.cell_states(mirror, shooter, null, bands).has(cell),
		"no aim over an empty cell")
	# **The terrain half of that forced flush is owed, not lost.** The
	# presenter cleared `_picture_stale` from inside its own sequence, so the
	# once-a-frame flush will not come back for the cells: only the flag of
	# its own does. What this regressed to was the mine a walker stepped on
	# -- `core` cleared the cell, the mirror agreed, and the model stayed on
	# screen with its tint until an unrelated delta asked for a repaint.
	h.check("death.the_repaint_is_owed",
		main._terrain_stale and not main._picture_stale,
		"the flush inside the sequence deferred the terrain and remembered")
	main._sequences.skip()
	main._drain_deferred_repaints()
	h.check("death.the_drain_pays_it", not main._terrain_stale,
		"the frame the queue empties repaints the cells the event changed")
	main._playback.skip()
	units.free()
	main.free()


## Several deltas landing in one frame cost one rebuild: [method
## SliceMain._apply_event] marks the picture stale and [method
## SliceMain._flush_picture] pays once.
func _quiet_landings(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("picture.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._shown = world.clone()
	main._geometry = {"prototypes": {}}
	var units: UnitsView = UnitsView.new()
	units.shown_ref = main._shown
	main._units = units
	for _i: int in range(3):
		var quiet: Dictionary = AIEvent.make("rotate", 0, 0, 0, 0, 0).to_dict()
		quiet["delta"] = {}
		main._apply_event(quiet)
	h.equal("picture.a_landing_rebuilds_nothing", units.builds, 0,
		"three deltas landed and the bodies were not touched")
	main._flush_picture()
	h.equal("picture.quiet_landings_rebuild_once", units.builds, 1,
		"one rebuild for the frame, however many deltas")
	main._flush_picture()
	h.equal("picture.a_flush_with_nothing_landed_is_free", units.builds, 1)
	units.free()
	main.free()


## A set piece is queued against the state **after** its event, and the
## picture waits for the queue before it follows.
##
## The door is the case that found it: `_paint_setpiece` turns the leaves
## by the sign of `to - from`, and a door queued against the mirror's closed
## cell had `to == from`, turned its leaves the closing way and snapped open
## when the delta landed at the end. So [method SliceMain._queue_setpiece]
## lands the event's delta first, and [method SliceMain._flush_picture]
## holds the bodies and the terrain where the drawn snapshot has them for
## as long as the queue runs, so a footbridge's riders can still fall and a
## platform's passengers still ride from where they were.
func _setpiece_state(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var unit: UnitState = world.units_for_ai()[0]
	unit.facing = 0
	var front: PackedInt32Array = Interact.cell_in_front(world.state, unit)
	var index: int = world.state.index_of(front[0], front[1])
	# A closed door in front of unit 0: odd id, one tile up, a wall.
	world.state.set_action_point(index, Interact.DOOR_JAMMED_CLOSED - 2)
	world.state.set_field_type(index, Interact.FIELD_TYPE_WALL)
	world.state.set_height(index, Interact.DOOR_HEIGHT_STEP)
	if not world.may_use(0):
		h.check("use.a_door_is_in_front", false,
			"action point %d is not a door the fixture's unit can use"
				% world.state.action_point_at(index))
		return
	world.enable_journal()
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._shown = world.clone()
	main._geometry = {"prototypes": {}}
	main._drawn_terrain = main._shown.terrain_snapshot()
	var units: UnitsView = UnitsView.new()
	units.shown_ref = main._shown
	main._units = units
	main._sequences = SequenceQueue.create(null)
	var used: UseResult = world.submit_use(UseCommand.create(0))
	h.equal("use.the_door_toggles", used.kind, World.DOOR_USE_KIND, used.reason)
	var events: Array[Dictionary] = world.take_events()
	# The `use` event on screen with its delta not landed: the mirror still
	# has the door closed.
	main._playback.play(events, func(event: Dictionary) -> float:
		return 0.0 if event.is_empty() else 1.0,
		Callable(main, "_apply_event"), 0.0, Callable(main, "_picture_busy"))
	h.check("use.the_mirror_is_behind_until_the_set_piece",
		main._shown.state.action_point_at(index) % 2 == 1,
		"the door is still closed in the mirror")
	var drawn: PackedInt32Array = main._drawn_terrain["height_map"]
	main._queue_setpiece({"name": "open_door", "values": [front[0], front[1]]},
		SetpieceDriver.DOOR_FRAMES, [], 0)
	h.check("use.a_set_piece_reads_the_state_after_its_event",
		main._shown.state.action_point_at(index) % 2 == 0
			and main._shown.state.height_at(index) < drawn[index],
		"the delta landed before the target was read: `to < from`, so the "
		+ "leaves turn the opening way")
	h.check("use.the_queue_is_running", main._sequences.is_running(),
		"the door's frames are on the queue")
	main._flush_picture()
	h.equal("picture.the_flush_waits_for_the_queue", units.builds, 0,
		"the bodies stand where the drawn snapshot has them while the set "
		+ "piece carries the change")
	main._sequences.skip()
	main._flush_picture()
	h.equal("picture.and_follows_when_it_drains", units.builds, 1)
	main._playback.skip()
	units.free()
	main.free()


## The magnifying glass -- docs/43 section 5.2, decision D4 closed.
##
## Oracle boundary: **specification**. The letter comes out of the cache's own
## `SetUnitInfo` column and the page out of `text/info/data.json`; what is
## checked here is the pair of byte tests `0x00432AB0` makes, the label
## `0x00432B20` composes, and `0x0043E850`'s retry with `{:**}`.
func _magnifier(h: TestHarness) -> void:
	var texts: InfoText = InfoText.load_from(CacheFixture.paths(),
		InfoText.DATA_DOCUMENT)
	h.equal("magnifier.family_digit", texts.family_digit("units"), "0",
		"0x00432B27 pushes '0' for a unit")
	h.check("magnifier.a_letter_has_a_page",
		BriefingText.to_bbcode(texts.unit_page("A")).strip_edges() != "",
		"{:A0} is Ray'Ther's page")
	var fallback: String = BriefingText.to_bbcode(
		texts.spans(InfoText.FALLBACK_LABEL))
	h.check("magnifier.the_fallback_exists", fallback.strip_edges() != "",
		"Data.txt carries {:**}")
	# **The unit path makes no `#` test**, unlike the two item paths at
	# `0x00432B86` and `0x00432BE4`: a letter with no block and the no-page
	# marker itself both come back as the retry's own text.
	h.equal("magnifier.a_letter_with_no_block_falls_back",
		BriefingText.to_bbcode(texts.unit_page("X")), fallback,
		"the ComBot's X has no {:X0}")
	h.equal("magnifier.the_no_page_marker_falls_back_too",
		BriefingText.to_bbcode(texts.unit_page(InfoText.NO_PAGE)), fallback)
	var absent: InfoText = InfoText.new()
	absent.read({})
	h.equal("magnifier.no_document_is_no_page", absent.unit_page("A").size(), 0,
		"a cache made before the converter grew Data.txt")

	# The box: the pickup's rectangle with a shorter height bound
	# (`0x00432B3D` pushes 300 where `0x0041079D` pushes 400). At 640x480 the
	# screen cuts both to the same thing; a taller canvas is where they part.
	# The rectangle, which is what the specs quote and the agent reads -- the
	# drawn box is as tall as its content either way ([code]_layout_info[/code]).
	var tall: Vector2 = Vector2(640.0, 900.0)
	h.equal("magnifier.box_rect_height_is_its_own",
		MissionHud.info_box_rect(tall, InfoText.DATA_BOX_SIZE.y).size.y,
		InfoText.DATA_BOX_SIZE.y)
	h.equal("magnifier.the_pickup_rect_keeps_its_own",
		MissionHud.info_box_rect(tall).size.y, InfoText.BOX_SIZE.y)
	h.equal("magnifier.box_shares_the_pickup_rectangle",
		MissionHud.info_box_rect(tall, InfoText.DATA_BOX_SIZE.y).position,
		MissionHud.info_box_rect(tall).position,
		"0x00432B47/0x00432B4C push the same 230, 200, 180")

	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("magnifier.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	h.equal("magnifier.the_letter_is_the_units_own",
		world.unit_types().info_key(50), "A",
		"SetUnitInfo 50 is Ray'Ther; 0x0051C09D is this column")
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._shown = world.clone()
	main._cache_dir = CacheFixture.cache_dir()
	main._paths = CacheFixture.paths()
	h.check("magnifier.the_button_is_offered",
		main._event_available(HudTables.EVENT_MAGNIFIER),
		"D4 had it dark because the cache carried no Data bank")
	# And it goes dark again where there is nothing to open: a cache made
	# before the converter grew the document, or one whose `Data.txt` decoded
	# with no label in it, would otherwise light a button that answers
	# nothing when it is pressed.
	var pageless: SliceMain = SliceMain.new()
	pageless.world = world
	pageless._shown = main._shown
	h.check("magnifier.no_pages_no_button",
		not pageless._event_available(HudTables.EVENT_MAGNIFIER),
		"no cache directory, so no Data bank")
	var empty_bank: InfoText = InfoText.new()
	empty_bank.read({"schema": InfoText.SCHEMA,
		"families": {"units": "0"}, "blocks": {}})
	h.check("magnifier.an_empty_bank_is_no_bank",
		not empty_bank.has_unit_pages()
			and texts.has_unit_pages(),
		"convert_info_data warns and writes an empty block map")
	pageless.free()
	# The face: the remake lights the button while the mode is on, which the
	# original does not -- its sprite chooser `0x00451A70` never reads the
	# mode. The lit face is the shipped **hover** one, `element + 1`.
	var mi: int = DictRead.as_int(
		HudTables.COLUMN_SPRITES[HudTables.EVENT_MAGNIFIER])
	h.equal("magnifier.dark_face_is_its_own",
		ButtonColumns.lit_element(HudTables.EVENT_MAGNIFIER, mi, true, false),
		mi)
	h.equal("magnifier.lit_face_is_the_hover_one",
		ButtonColumns.lit_element(HudTables.EVENT_MAGNIFIER, mi, true, true),
		mi + 1)
	h.equal("magnifier.an_unavailable_button_is_never_lit",
		ButtonColumns.lit_element(HudTables.EVENT_MAGNIFIER,
			HudTables.COLUMN_EMPTY, false, true), HudTables.COLUMN_EMPTY)
	var other: int = DictRead.as_int(
		HudTables.COLUMN_SPRITES[HudTables.EVENT_NEXT_PLAYER])
	h.equal("magnifier.no_other_button_moves",
		ButtonColumns.lit_element(HudTables.EVENT_NEXT_PLAYER, other, true,
			true), other)
	h.check("magnifier.starts_off", not main.magnifier_on())
	main._on_hud_event(HudTables.EVENT_MAGNIFIER)
	h.check("magnifier.the_button_toggles_it", main.magnifier_on())
	main._on_hud_event(HudTables.EVENT_MAGNIFIER)
	h.check("magnifier.and_toggles_it_back", not main.magnifier_on())

	# The two byte tests, over every record the mission has: `+0x45` is the
	# computer's seat and `+0x4F` is 0. The fog answer is the picture's own,
	# so what is asserted is the equivalence and not a fog state.
	var seen: Dictionary[int, int] = main.shown().display_visibility()
	var wrong_owner: PackedInt32Array = PackedInt32Array()
	var wrong_state: PackedInt32Array = PackedInt32Array()
	var aliens: PackedInt32Array = PackedInt32Array()
	for slot: int in main.shown().unit_slots():
		var view: Dictionary = main.shown().unit_view(slot)
		var alien: bool = DictRead.as_int(view["player"]) 			== TurnState.PLAYER_COMPUTER
		if alien:
			aliens.append(slot)
		var state: int = DictRead.as_int(view["visibility"])
		if seen.has(slot):
			state = seen[slot]
		var wanted: bool = alien and state == Fog.FULL
		if main.magnifier_answers(slot) != wanted:
			if alien:
				wrong_state.append(slot)
			else:
				wrong_owner.append(slot)
	h.equal("magnifier.a_marine_is_never_magnified", wrong_owner,
		PackedInt32Array(), "0x00432AFA: `cmp byte [eax + 0x45], 0xff`")
	h.equal("magnifier.an_alien_answers_when_it_is_drawn", wrong_state,
		PackedInt32Array(), "0x00432B00: `+0x4F` must be 0")
	h.check("magnifier.there_are_aliens_to_look_at", aliens.size() > 0,
		"_C_140")
	# The heading is the unit's own name, `0x0043E850`'s eighth argument.
	var hud: MissionHud = MissionHud.new()
	hud.setup(null, null, null, null, null, CacheFixture.paths())
	var named: String = DictRead.as_string(
		main.shown().unit_view(aliens[0])["name"])
	h.check("magnifier.a_unit_is_named", named != "",
		"+0x00 is a char[20] defaulting to the type's description")
	hud.show_info([{"text": "body", "font": 0, "colour": 0, "breaks": 0}],
		InfoText.DATA_BOX_SIZE.y, false, named)
	h.equal("magnifier.the_box_carries_the_heading", hud.info_title(), named)
	hud.show_info([{"text": "body", "font": 0, "colour": 0, "breaks": 0}])
	h.equal("magnifier.a_pickup_has_no_heading", hud.info_title(), "",
		"0x0043ED4C: the title is compared with the empty string")
	hud.free()
	h.check("magnifier.no_such_slot_is_refused",
		not main.magnifier_answers(-1) and not main.magnifier_answers(9999))

	# **A beacon reaches the visible arm**, and by a rule rather than by a
	# contrivance: docs/22 section 9.2's three types come out of the pass as
	# `FULL` whatever the seat is (`Visibility._pass`), so one alien given
	# that type is one the magnifier must answer for. The seat itself stays
	# the watching human's -- writing 255 into the mirror's turn would test a
	# fog pass the picture never asks for.
	var beacon: int = aliens[0]
	main._shown._units[beacon].type_id = Visibility.ALWAYS_VISIBLE_TYPES[0]
	h.check("magnifier.a_beacon_is_answered", main.magnifier_answers(beacon),
		"+0x45 is 255 and the pass leaves +0x4F at 0")
	h.check("magnifier.the_page_is_prose",
		BriefingText.to_bbcode(
			main.magnifier_page(beacon)).strip_edges() != "",
		"Data.txt, or the {:**} retry")
	main.free()


## docs/24 sections 5 and 7.1 in the remake (docs/92 section 7.19): the
## typewriter reveals a glyph a frame and blips on a word's end, the deployment
## screen types `B0`, the mission-start `A0` box is whole and sits where
## `0x0041B629` puts it, and an upgrade base's waypoints are read in order.
func _briefing_around_a_mission(h: TestHarness) -> void:
	var cache_dir: String = CacheFixture.cache_dir()
	var paths: CachePaths = CacheFixture.paths()
	var label: BriefingText = BriefingText.create(paths, false)
	var blips: Array[int] = []
	label.blip.connect(func() -> void: blips.append(1))
	label.start_typewriter()
	label.show_block([{"text": "ab cd", "font": 0, "colour": 0, "breaks": 0}])
	h.check("typewriter.starts_hidden", label.typing()
		and label.visible_characters == 0)
	var owed: int = label.tick_typewriter(1.0 / BriefingText.TYPEWRITER_FPS)
	h.equal("typewriter.one_glyph_a_frame",
		[label.visible_characters, owed], [1, 0],
		"fcn.0043ECF0 adds one to each limit per printed frame")
	var _half: int = label.tick_typewriter(0.5 / BriefingText.TYPEWRITER_FPS)
	h.equal("typewriter.half_a_frame_shows_nothing_more",
		label.visible_characters, 1)
	var _two: int = label.tick_typewriter(1.5 / BriefingText.TYPEWRITER_FPS)
	h.equal("typewriter.carry_lands_the_space",
		[label.visible_characters, blips.size()], [3, 1],
		"the space after `ab` is a word's end: one textbeep")
	var _rest: int = label.tick_typewriter(10.0 / BriefingText.TYPEWRITER_FPS)
	h.check("typewriter.finishes_and_stops",
		not label.typing() and label.visible_characters == -1
		and blips.size() == 1)
	h.equal("typewriter.blip_wave", BriefingText.BLIP_WAVE, "textbeep.wav",
		"0x0043E3C1 -> 0x00436EF0, the third buffer aInitGUI loads")
	label.free()

	var strings: Localization = Localization.from_cache(paths)
	var art: Art = Art.open(paths)
	var host: CampaignHost = CampaignHost.create(cache_dir,
		CacheFixture.balance(), strings)
	var _state: CampaignState = host.start_new(1)
	var document: Dictionary = CacheLoader.read_json(
		"%s/text/briefing/%s.json" % [cache_dir, host.state.mission])
	h.check("briefing.document_present", not document.is_empty())
	var page: BriefingScreen = BriefingScreen.new()
	page.mission = host.state.mission
	page.paths = paths
	page.document = document
	page.setup(art, strings, null)
	h.check("briefing.screen_types", page.typing(),
		"0x00456DCB passes animate = 0")
	page.free()
	var recall: BriefingScreen = BriefingScreen.new()
	recall.mission = host.state.mission
	recall.paths = paths
	recall.document = document
	recall.over_mission = true
	recall.setup(art, strings, null)
	h.check("briefing.recall_does_not_type", not recall.typing(),
		"the page raised by B over a mission shows what was already read")
	recall.free()

	# The pictures give way to the text, by programme row. `_C_151` puts
	# `br_151_0` (133x180) at (150, 170) and `Ruther` (135x180) at (410, 170)
	# under an `A0` whose readable face runs to about 257: the reached one
	# drops beneath the block, its row-mate goes with it, and both shrink
	# about their centres to clear the action row. `Bratt` on a row of its
	# own, clear of the text, stays put.
	var floor_y: float = CampaignScreen.BUTTON_ROW_TOP \
		- CampaignScreen.BUTTON_ROW_GAP - BriefingScreen.CAPTION_HEIGHT \
		- BriefingScreen.CAPTION_GAP
	var reached: Rect2 = Rect2(84.0, 77.0, 272.0, 180.0)
	var settled: Array[Rect2] = BriefingScreen.settle_pictures([
		Rect2(150.0, 170.0, 133.0, 180.0), Rect2(410.0, 170.0, 135.0, 180.0),
		Rect2(415.0, 300.0, 50.0, 79.0)], reached, floor_y)
	var top: float = reached.end.y + BriefingScreen.PICTURE_GAP
	var room: float = floor_y - top
	h.equal("briefing.reached_row_drops_beneath_the_text",
		[settled[0].position.y, settled[1].position.y, settled[2]],
		[top, top, Rect2(415.0, 300.0, 50.0, 79.0)],
		"the row-mate at the same y goes too; another row stays")
	h.check("briefing.dropped_picture_shrinks_to_the_action_row",
		is_equal_approx(settled[0].size.y, room)
		and is_equal_approx(settled[0].size.x, 133.0 * room / 180.0)
		and is_equal_approx(settled[0].get_center().x, 150.0 + 133.0 * 0.5),
		"uniformly, about its own centre")
	# `_C_102` hand-wraps its lines at forty characters to keep clear of the
	# 260-wide picture at `x` 310 -- inside the 280-wide box. The block's own
	# width is what is tested, so the authors' layout stands; the same picture
	# under lines that run the box's width moves.
	var wide: Rect2 = Rect2(310.0, 70.0, 260.0, 170.0)
	h.equal("briefing.hand_wrapped_lines_leave_the_picture",
		BriefingScreen.settle_pictures([wide],
			Rect2(84.0, 77.0, 220.0, 216.0), floor_y)[0], wide)
	h.check("briefing.full_width_lines_move_the_picture",
		BriefingScreen.settle_pictures([wide],
			Rect2(84.0, 77.0, 272.0, 216.0), floor_y)[0].position.y > wide.position.y)
	# `_C_119`'s `A0` fills the box in the readable face and leaves its
	# picture thirty units: rather than a smudge on the action row, the
	# picture stays where the programme put it, under the text, as the
	# original draws it.
	var full: Rect2 = Rect2(84.0, 77.0, 272.0, 276.0)
	h.equal("briefing.a_picture_with_no_room_stays_under_the_text",
		BriefingScreen.settle_pictures([wide], full, floor_y)[0], wide,
		"shrunk past PICTURE_MIN_SCALE it would be a smudge on the buttons")

	# docs/92 section 7.19 I21: a click or a key finishes the reveal. The check
	# calls the seam rather than pushing an event, because a screen built off
	# the tree is routed no input at all -- which is also why the input
	# handler is two lines over this method and not the method itself.
	var skipped: BriefingScreen = BriefingScreen.new()
	skipped.mission = host.state.mission
	skipped.paths = paths
	skipped.document = document
	skipped.setup(art, strings, null)
	skipped.tick(2.0 / BriefingText.TYPEWRITER_FPS)
	h.check("briefing.skip_needs_something_to_skip", skipped.typing(),
		"two glyphs in, the reveal is still running")
	h.check("briefing.a_click_finishes_the_reveal", skipped.skip_typing()
		and not skipped.typing(), "docs/92 section 7.19 I21")
	h.check("briefing.skipping_twice_is_not_a_second_skip",
		not skipped.skip_typing(),
		"nothing to finish, so the click is not the screen's to take")
	# docs/92 section 7.19 I20: the tips are a reference page and never type,
	# and coming back to the briefing after them does not start it again.
	skipped.free()
	var tips: BriefingScreen = BriefingScreen.new()
	tips.mission = host.state.mission
	tips.paths = paths
	tips.document = document
	tips.setup(art, strings, null)
	var has_tips: bool = not DictRead.as_array(DictRead.as_dict(
		document.get("blocks", {})).get("C0", [])).is_empty()
	h.check("briefing.the_fixture_mission_carries_tips", has_tips,
		"%s: 25 of the 116 briefings carry no C0" % host.state.mission)
	tips.show_block("C0")
	h.check("briefing.tips_are_shown_whole", not tips.typing(),
		"docs/92 section 7.19 I20")
	tips.show_block("A0")
	h.check("briefing.the_briefing_does_not_retype_after_the_tips",
		not tips.typing(), "one visit to C0 settles the page")
	tips.free()

	# **No box opens over a campaign mission.** `0x0041B629`'s `A0` popup is
	# the arm `0x0041a980` takes when `0x0043b1f0()` is non-zero, and that
	# predicate is `[0x00509f08] and (gameMode() in {2, 4} or (3 with more
	# than one human))` -- false in every campaign, whose mode is 1. The whole
	# block is behind `0x005106d4` besides, whose only setter is the arm the
	# map's `B` takes when *its* gate fails. So a campaign mission opens on
	# its interface and nothing else, and the briefing is the screen the
	# player came through.
	var opener: MissionHud = MissionHud.new()
	opener.setup(art, strings, null, null, null, paths)
	h.check("start_briefing.a_campaign_mission_opens_on_no_box",
		not opener.info_visible(),
		"0x0041B629 is the multiplayer arm; docs/24 section 7.1")
	opener.free()

	# The location map's own `B0` -- mission control's action `0xb`, reached
	# by the key `0x00451240` maps to it. Its gate is one human player and not
	# the network predicate `0x0043b1f0`, both of which hold here, so the box
	# is drawn rather than being behind a switch the remake lacks.
	var frontend: Dictionary = CacheLoader.read_json(
		cache_dir + "/tables/frontend.json")
	var briefing_table: Dictionary = DictRead.as_dict(
		frontend.get("briefing", {}))
	h.equal("map_short.key_is_the_measured_one",
		DictRead.as_string(briefing_table.get("map_short_key", "")),
		char(CampaignMapScreen.SHORT_KEY),
		"0x00451240 maps it to mission control's 0xb")
	h.check("map_short.gate_holds_in_a_campaign",
		DictRead.as_bool(briefing_table.get(
			"map_short_always_in_single_player", false)),
		"0x0043b700() == 1 and not 0x0043b1f0()")
	var box: Dictionary = DictRead.as_dict(DictRead.as_dict(
		briefing_table.get("boxes", {})).get("map_short", {}))
	h.equal("map_short.box_is_docs_24_s",
		[DictRead.as_string(box.get("label", "")),
		DictRead.to_int32(box.get("box", []))],
		["B0", PackedInt32Array([int(CampaignMapScreen.SHORT_AT.x),
			int(CampaignMapScreen.SHORT_AT.y),
			int(CampaignMapScreen.SHORT_SIZE.x),
			int(CampaignMapScreen.SHORT_SIZE.y)])])
	var chart: CampaignMapScreen = CampaignMapScreen.new()
	chart.host = host
	chart.paths = paths
	chart.document = document
	chart.setup(art, strings, null)
	h.check("map_short.starts_down", not chart.typing(),
		"the box is what the key asks for, not what the screen opens with")
	chart.toggle_short_briefing()
	h.check("map_short.types_on_the_key", chart.typing(),
		"animate = 0 on the arm")
	chart.tick(100.0)
	h.check("map_short.finishes", not chart.typing())
	chart.toggle_short_briefing()
	h.check("map_short.the_key_takes_it_down_again", not chart.typing())
	chart.free()

	var main: SliceMain = SliceMain.new()
	var opening: Dictionary = {"events": [
		{"name": SliceMain.CREATE_CAMERA_PATH, "values": [0, 0, 10, 20, 30]},
		{"name": SliceMain.CREATE_CAMERA_PATH, "values": [1, 1, 1, 2, 3]},
		{"name": SliceMain.CREATE_CAMERA_PATH, "values": [2, 1, 4, 5, 6]},
	]}
	var waypoints: Array[Vector3i] = main._read_camera_waypoints(opening)
	h.equal("fly_in.waypoints_in_script_order", waypoints,
		[Vector3i(1, 2, 3) * SliceMain.CAMERA_PATH_SCALE,
		Vector3i(4, 5, 6) * SliceMain.CAMERA_PATH_SCALE],
		"the mode 1 entries, the mode 0 target left out")
	h.equal("fly_in.the_last_waypoint_is_the_fallback_rest",
		main._read_camera_path(opening)[0],
		Vector3i(4, 5, 6) * SliceMain.CAMERA_PATH_SCALE,
		"where a base has no flight to run; a flown one rests where it "
		+ "stopped, which 0x00403780 is what reads back")
	h.equal("fly_in.constants", [SliceMain.FLY_SPEED,
		SliceMain.FLY_SMOOTH_START, SliceMain.FLY_SMOOTH_FLOOR,
		SliceMain.FLY_ARRIVAL, SliceMain.FLY_LANDED_SHARE,
		int(SliceMain.FLY_FPS)],
		[800, 40, 5, 3200, 80, 20],
		"0x004171DE, 0x004171C9, 0x00417316, 0x004171FF, 0x0041729E, "
		+ "0x0040B82D")
	main.free()


## An upgrade base is not an empty landing pad (docs/27 section 2.7.1).
##
## `0x00417510` walks player 0's living units and starts `P0_M2_000` on each,
## and every `upgrade_N.lev` places two or three of them -- so the marines are
## what the fly-in crosses. The remake used to build the backdrop without any
## bodies at all, on a comment that was true of the two chain maps and of
## nothing else.
func _upgrade_marines(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world("upgrade_1")
	if loaded.is_empty():
		# A cache published without `--campaign-maps` carries no upgrade
		# scene. That is a thinner cache and not a failure -- but say which,
		# so a run that quietly checked nothing cannot read as a pass.
		h.check("marines.cache", false,
			"no upgrade_1 in the cache; publish with --campaign-maps")
		return
	var world: World = loaded["world"]
	# The corpus half, which needs no library: three living player-0 records.
	var live: int = 0
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["player"]) == BackdropBodies.PLAYER \
				and DictRead.as_int(view["hp"]) > 0:
			live += 1
	h.equal("marines.upgrade_1_places_three", live, 3)
	# The constants, at the addresses `campaign_tables.py` reads them from.
	h.equal("marines.playback",
		[BackdropBodies.CLIP, BackdropBodies.SPEED, BackdropBodies.LOOPS,
		BackdropBodies.START_MAX, BackdropBodies.FPS],
		["P0_M2_000", 1.0, 100000, 10.0, 20.0])
	var library: CharismaLibrary = CharismaLibrary.open(
		CacheFixture.cache_dir(), {}, "upgrade_1")
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 1
	var marines: BackdropBodies = BackdropBodies.new()
	var built: int = marines.build(world, library, rng)
	h.equal("marines.bodies", built, live)
	# The clip is in the cache from 0.31.0 on: no selector's closure names it,
	# so a cache built before the bump stands the bodies up in their bind pose
	# and nothing walks.
	h.check("marines.clip_is_in_the_cache",
		library.clip(BackdropBodies.CLIP) != null,
		"P0_M2_000 -- docs/40 section 7.2's kind-4 literal")
	# The starting times are drawn, not shared: the original's `aRandom2(0,10)`
	# is what keeps three marines out of step.
	var spread: bool = false
	for i: int in range(1, marines.times.size()):
		if not is_equal_approx(marines.times[i], marines.times[0]):
			spread = true
	h.check("marines.start_times_differ", spread or built < 2,
		"%s" % [marines.times])
	var in_range: bool = marines.times.size() == built
	for t: float in marines.times:
		if t < 0.0 or t >= BackdropBodies.START_MAX:
			in_range = false
	h.check("marines.start_times_in_range", in_range, "%s" % [marines.times])
	# The clock is the front end's 20 a second and the step is one clip unit
	# a frame, so a second of drawn time is twenty of them.
	var before: PackedFloat32Array = marines.times.duplicate()
	marines.tick(1.0)
	var moved: bool = marines.times.size() == before.size()
	for i: int in range(marines.times.size()):
		if not is_equal_approx(marines.times[i] - before[i],
				BackdropBodies.SPEED * BackdropBodies.FPS):
			moved = false
	h.check("marines.tick_is_twenty_a_second", moved,
		"%s -> %s" % [before, marines.times])
	# **The march is the clip's own.** Nothing moves these records -- no
	# `upgrade_N.lcl` carries a movement command -- so if the body did not
	# travel under its own root track, the marines would walk on the spot.
	# One second of drawn time is twenty frames of a clip that carries
	# `Bip000` 3017.7 skeleton units over 452: 133.5 of them, times the 16 of
	# docs/40 section 5.3 and over [constant WorldSpace.WORLD_UNITS_PER_METRE]
	# is **1.33 m**, two thirds of a map field and an ordinary walking pace.
	#
	# The part measured is a *drawn* one: `Bip000` carries the travel and has
	# no mesh of its own, and [method CharismaBody.part_position] answers for
	# the parts a body actually builds.
	var model: CharismaModel = library.model(library.name_for(
		CharismaLibrary.SELECTOR_MODEL, 0, 0, BackdropBodies.PLAYER))
	var bone: String = ""
	if model != null and built > 0:
		for candidate: String in model.bones:
			if marines.bodies[0].has_part(candidate):
				bone = candidate
				break
	var walked: float = -1.0
	var lately: Vector3 = Vector3.ZERO
	if built > 0 and bone != "" and library.clip(BackdropBodies.CLIP) != null:
		var was: Vector3 = marines.bodies[0].part_position(bone)
		marines.tick(1.0)
		var now: Vector3 = marines.bodies[0].part_position(bone)
		walked = Vector2(now.x - was.x, now.z - was.z).length()
		lately = was
	h.check("marines.the_clip_walks_them",
		walked > 1.0 and walked < 1.7,
		"%.2f m in a second of drawn time, against the clip's own 1.33" % walked)
	# **And forwards.** The magnitude alone would pass with the sign the wrong
	# way round, and a squad marching backwards off the pad is exactly the
	# defect a screenshot cannot see -- a metre at forty thousand units of
	# depth is a pixel.
	#
	# The heading is **both** bases: [method UnitsView.face] puts the engine's
	# yaw on the node and the difference between that and the Charisma one on
	# the body, and `node.basis * body.basis` is the composition
	# `test_charisma.gd` compares a walk's own step against. Taking the node's
	# alone gives exactly -1 here, because a Charisma body is authored facing
	# engine -Y.
	var ahead: float = -2.0
	if built > 0 and bone != "":
		var node: Node3D = marines.bodies[0].get_parent() as Node3D
		if node != null:
			var heading: Vector3 = node.basis * marines.bodies[0].basis \
				* CharismaBody.AUTHORED_FORWARD
			var step: Vector3 = marines.bodies[0].part_position(bone) - lately
			ahead = Vector2(step.x, step.z).normalized().dot(
				Vector2(heading.x, heading.z).normalized())
	h.check("marines.they_walk_the_way_they_face", ahead > 0.9,
		"cosine %.2f between the step and the facing" % ahead)
	# The clip is 452 frames and loops: half a minute of drawn time wraps it.
	marines.tick(30.0)
	h.check("marines.clip_loops", marines.loops() >= built,
		"%d wrap(s) after 31 s of a 452-frame clip" % marines.loops())
	marines.free()


## The word blip is the GUI's own volume, and there is one of it.
##
## The briefing page, the deployment screen and the map's `B0` play the same
## `textbeep.wav`. The volume was written out three times and one of them was
## `0` -- a real table id -- so the map's blip alone would fall silent on a
## cache whose table has no entry 0. There is one seam now, and this is the
## check on it; that the three screens use it is the reason there is nothing
## left to get wrong.
func _blip_volume(h: TestHarness) -> void:
	var plain: Dictionary = BriefingText.blip_cue()
	var sited: Dictionary = BriefingText.blip_cue(CampaignMapScreen.SHORT_BLOCK)
	h.equal("blip.volume_is_the_gui_s_own",
		[DictRead.as_int(plain["volume_id"]),
		DictRead.as_int(sited["volume_id"])],
		[AudioTables.NO_SCALING, AudioTables.NO_SCALING])
	h.equal("blip.wave", DictRead.as_string(plain["wave"]), "textbeep.wav")
	h.check("blip.the_site_is_the_block_it_typed",
		not plain.has("site")
		and DictRead.as_string(sited["site"]) == CampaignMapScreen.SHORT_BLOCK,
		"%s" % [sited])
	# The table the cue is measured against: `NO_SCALING` is refused by
	# nothing, which is the property the literal `0` did not have.
	var tables: AudioTables = AudioTables.open(CacheFixture.paths())
	h.check("blip.no_scaling_is_never_refused",
		tables.scaled_volume(0, AudioTables.NO_SCALING) != AudioTables.REFUSED,
		"the GUI volume passes the scaler at every setting")


## A campaign screen raised with no campaign running does not crash.
##
## The agent's `ui NAME` is a debugging entry past the location map and raises
## a screen from the shell (docs/92 section 7.16). Three of those screens read
## the mission's own briefing document, and reading `campaign.state.mission`
## at the call site made that a null dereference -- the gate above them is
## guarded and simply does not run, so the arm below it was reached with no
## state at all. [method CampaignHost.current_mission] is the guarded read.
func _no_campaign_state(h: TestHarness) -> void:
	var main: SliceMain = SliceMain.new()
	main.campaign = CampaignHost.create(CacheFixture.cache_dir(),
		CacheFixture.balance())
	h.check("no_state.host_has_none", main.campaign.state == null)
	h.equal("no_state.mission_reads_empty", main.campaign.current_mission(), "")
	# Each of these would have thrown on `campaign.state.mission`. Reaching the
	# next line at all is the check.
	for name: String in [CampaignHost.SCREEN_MAP, CampaignHost.SCREEN_BRIEFING]:
		var _raised: CampaignScreen = main.show_campaign_screen(name)
	h.check("no_state.every_screen_survives_it", true,
		"map and briefing raised with no campaign state")
	main.free()


## Raising a screen and freeing it leaves **nothing** alive.
##
## Godot reports what it still holds only at process exit, as a warning, and a
## warning fails no check -- so a node that is built and never parented sits
## outside every suite's reach and the run stays green. `run_tests.sh` gates on
## that text now, but the gate names the process and not the screen; this one
## names the screen, and it runs inside the exported build as well.
##
## The one it was written for: [method CampaignScreen._draw_plate] built its
## missing-art backing *before* asking whether the screen wants a window, and
## parented it only in the other arm, so every windowed screen on a cache with
## no plate -- the location map is one -- left a `ColorRect` and its
## theme owner behind.
##
## [constant Performance.OBJECT_ORPHAN_NODE_COUNT] is the count of live nodes
## outside a [SceneTree], which is every node these suites make; the screens
## are freed with [method Object.free], which is immediate, so the count is
## back where it started unless something is genuinely unowned.
##
## **That immediacy is the check's contract.** A suite runs inside
## `_initialize` with no frames, so a deferred deletion never happens: the day
## [method SliceMain.show_campaign_screen] closes a previous screen with
## `queue_free` instead, or a screen queues one of its own children, this will
## fail on a node that is owned perfectly well. The answer then is to make the
## teardown immediate, not to widen the tolerance -- a tolerance here reads as
## "some leaking is allowed".
func _screens_leave_nothing_behind(h: TestHarness) -> void:
	var names: Array[String] = [
		CampaignHost.SCREEN_MAP, CampaignHost.SCREEN_BRIEFING,
		CampaignHost.SCREEN_DEBRIEFING,
		CampaignHost.SCREEN_HQ, CampaignHost.SCREEN_RECRUIT,
		CampaignHost.SCREEN_UPGRADE, CampaignHost.SCREEN_ITEMS,
	]
	var left: PackedStringArray = PackedStringArray()
	for name: String in names:
		var before: int = int(Performance.get_monitor(
			Performance.OBJECT_ORPHAN_NODE_COUNT))
		var main: SliceMain = SliceMain.new()
		main.campaign = CampaignHost.create(CacheFixture.cache_dir(),
			CacheFixture.balance())
		var _raised: CampaignScreen = main.show_campaign_screen(name)
		main.free()
		var after: int = int(Performance.get_monitor(
			Performance.OBJECT_ORPHAN_NODE_COUNT))
		if after != before:
			left.append("%s left %d" % [name, after - before])
	h.check("no_state.a_screen_owns_everything_it_builds", left.is_empty(),
		", ".join(left) if not left.is_empty()
		else "%d screens built and freed, no node left over" % names.size())
