extends TestSuite

## The shell -- docs/92 section 7.15.
##
## Oracle boundary: **specification-only**, and it can be nothing else. The
## shell is the remake's own design: docs/90 line 113 records that the
## original's front-end flow is deliberately outside the replacement contract,
## and docs/29 section 1 puts save and load among the "application-level
## actions" the interface contract does not describe. There is no engine
## behaviour to diff against, so what is checked here is the half this
## repository does own -- that every caption comes out of the catalogue, that
## a slot round-trips, that an option reaches the thing it names, and that the
## three ways into the game all still work.
##
## The file layer (`save`, `load_save`, `has_save`, `slot_header`) had **no
## coverage at all** before this suite. It gets it here, through the injectable
## directory: the `macOS Tests` preset runs these suites inside a real build
## against the real `user://`, so a suite writing to the shipped path would
## overwrite a live player's game.

## Where this suite's own saves and settings go. Not `user://saves` and not
## `user://settings.json` -- see above.
const SCRATCH_DIR: String = "user://tests/shell"

var _art: Art = null
var _strings: Localization = null
var _font: FontFile = null
var _cache_dir: String = ""
var _paths: CachePaths = null


func run(h: TestHarness) -> void:
	h.begin("shell", TestHarness.ORACLE_SPEC)
	_cache_dir = CacheFixture.cache_dir()
	_paths = CacheFixture.paths()
	_strings = Localization.from_cache(_paths)
	_art = Art.open(_paths)
	_font = GameFont.load_from(_paths, "font_2")
	_clean_scratch()

	_boot_paths(h)
	_host_transitions(h)
	_in_mission(h)
	_settings_file(h)
	_settings_apply(h)
	_slot_files(h)
	_slot_round_trip(h)
	_screens(h)
	_scrolling(h)
	_deployment_mode(h)
	_map_picture(h)
	_map_camera_presets(h)
	_projection(h)
	_map_turn(h)
	_root_plates(h)
	_frontend_screens(h)
	_clean_scratch()


# --- the three ways in -------------------------------------------------------

## S5: the shell must not become a compulsory door.
##
## [method SliceMain.boot_choice] is static and pure exactly so this can be
## checked rather than only tried: a build's command line cannot be injected,
## and "does `--mission=` still bypass the shell" is the kind of thing that is
## verified once by hand and then quietly broken.
func _boot_paths(h: TestHarness) -> void:
	var cache: PackedStringArray = PackedStringArray(["_C_140", "_C_141",
		"_C_115"])

	var bare: Dictionary = SliceMain.boot_choice(PackedStringArray(), cache,
		"_C_140")
	h.equal("boot.no_argument_opens_the_shell",
		DictRead.as_string(bare["kind"]), SliceMain.BOOT_SHELL)

	var named: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--mission=_C_141"]), cache, "_C_140")
	h.equal("boot.mission_argument_bypasses_the_shell",
		[DictRead.as_string(named["kind"]),
		DictRead.as_string(named["mission"])],
		[SliceMain.BOOT_MISSION, "_C_141"],
		"a mission is built immediately and no plate is raised")

	# The fallback is the behaviour that was there before the shell and stays:
	# an unknown name warns and lands on the default rather than refusing.
	var unknown: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--mission=_C_999"]), cache, "_C_140")
	h.equal("boot.unknown_mission_falls_back",
		[DictRead.as_string(unknown["kind"]),
		DictRead.as_string(unknown["mission"])],
		[SliceMain.BOOT_MISSION, "_C_140"])
	h.equal("boot.unknown_mission_warns",
		DictRead.to_strings(unknown["warnings"]).size(), 1,
		"named, not silent")

	var chain: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--campaign=2"]), cache, "_C_140")
	h.equal("boot.campaign_argument_enters_the_map",
		[DictRead.as_string(chain["kind"]), DictRead.as_int(chain["campaign"])],
		[SliceMain.BOOT_CAMPAIGN, 2])

	# An unknown chain opens the menu rather than starting nothing at all,
	# which is the difference between a diagnosable typo and a dead window.
	var no_chain: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--campaign=9"]), cache, "_C_140")
	h.equal("boot.unknown_campaign_opens_the_shell",
		DictRead.as_string(no_chain["kind"]), SliceMain.BOOT_SHELL)
	h.equal("boot.unknown_campaign_warns",
		DictRead.to_strings(no_chain["warnings"]).size(), 1)

	# `--language=` is read the same way -- statically, the last one wins,
	# and its absence is an empty answer that lets the settings file decide
	# (docs/92 section 7.6).
	h.equal("boot.language_from_args",
		SliceMain.language_from_args(PackedStringArray(
			["--mission=_C_115", "--language=Russian"])), "Russian")
	h.equal("boot.language_last_wins",
		SliceMain.language_from_args(PackedStringArray(
			["--language=Russian", "--language=English"])), "English")
	h.equal("boot.language_absent_is_empty",
		SliceMain.language_from_args(PackedStringArray(["--campaign=1"])), "")

	# `--mission=` wins when both are given: it is the older, narrower entry
	# and the one every screenshot script passes.
	var both: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--mission=_C_115", "--campaign=1"]), cache,
		"_C_140")
	h.equal("boot.mission_wins_over_campaign",
		DictRead.as_string(both["kind"]), SliceMain.BOOT_MISSION)

	# `--credits` is a bare flag, not a `key=value` one, and it needs neither
	# a cache nor a campaign: the roll is reached in the game only by
	# finishing a chain.
	var roll: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--credits"]), cache, "_C_140")
	h.equal("boot.credits_argument_opens_the_roll",
		DictRead.as_string(roll["kind"]), SliceMain.BOOT_CREDITS)
	var roll_bare: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--credits"]), PackedStringArray(), "")
	h.equal("boot.credits_needs_no_cache",
		DictRead.as_string(roll_bare["kind"]), SliceMain.BOOT_CREDITS)

	# An empty cache still answers, rather than indexing element 0 of nothing.
	var empty: Dictionary = SliceMain.boot_choice(
		PackedStringArray(["--mission=_C_140"]), PackedStringArray(), "_C_140")
	h.equal("boot.empty_cache_answers_an_empty_mission",
		DictRead.as_string(empty["mission"]), "")


# --- the state machine -------------------------------------------------------

func _host_transitions(h: TestHarness) -> void:
	var shell: ShellHost = ShellHost.new()
	h.check("host.starts_closed", not shell.is_up(),
		"the shell is raised, not assumed")

	shell.open(ShellHost.SCREEN_MENU, false)
	h.equal("host.menu_from_boot",
		[shell.screen, shell.behind], [ShellHost.SCREEN_MENU, false])
	# From the boot menu there is nothing behind, so `Back` stays put: a
	# `Back` that quit the game from the top would be a silent action.
	h.equal("host.back_from_the_boot_menu_stays",
		shell.back_from(ShellHost.SCREEN_MENU), ShellHost.SCREEN_MENU)

	shell.open(ShellHost.SCREEN_MENU, true)
	h.equal("host.back_from_the_pause_menu_leaves",
		shell.back_from(ShellHost.SCREEN_MENU), ShellHost.SCREEN_NONE)

	for name: String in [ShellHost.SCREEN_CAMPAIGN_SELECT,
			ShellHost.SCREEN_MISSION_SELECT, ShellHost.SCREEN_OPTIONS]:
		shell.go(name)
		h.equal("host.back_from_%s" % name, shell.back_from(name),
			ShellHost.SCREEN_MENU, "reached through the menu, so back to it")

	# **Opened at a screen, `Back` leaves from that screen.** The campaign
	# map's own *Options* button opens the shell there; funnelling its `Back`
	# through the menu dropped the player on a boot-style menu offering to
	# start a new campaign over the one being played, with the way back only
	# on `ESC`.
	var direct: ShellHost = ShellHost.new()
	direct.open(ShellHost.SCREEN_OPTIONS, true)
	h.equal("host.entry_is_remembered", direct.entry,
		ShellHost.SCREEN_OPTIONS)
	h.equal("host.back_leaves_from_the_entry",
		direct.back_from(ShellHost.SCREEN_OPTIONS), ShellHost.SCREEN_NONE)
	direct.go(ShellHost.SCREEN_SLOTS)
	h.equal("host.back_from_elsewhere_is_still_the_menu",
		direct.back_from(ShellHost.SCREEN_SLOTS), ShellHost.SCREEN_MENU)
	direct.close()
	h.equal("host.close_forgets_the_entry", direct.entry,
		ShellHost.SCREEN_MENU)

	shell.go_slots(ShellHost.MODE_SAVE)
	h.equal("host.slots_save",
		[shell.screen, shell.slot_mode],
		[ShellHost.SCREEN_SLOTS, ShellHost.MODE_SAVE])
	# An unknown mode is **load**, the one that cannot destroy anything.
	shell.go_slots("nonsense")
	h.equal("host.unknown_mode_is_load", shell.slot_mode, ShellHost.MODE_LOAD)

	shell.go("nonsense")
	h.equal("host.unknown_screen_is_refused", shell.screen,
		ShellHost.SCREEN_SLOTS, "a name this build has no screen for")

	# The page the slot list stands on is the host's, because the screen is
	# rebuilt after a write and would otherwise send the list back to the
	# first page with the row it had just written off it.
	shell.slot_page = SaveSlotsScreen.LIST_ROWS
	shell.close()
	h.check("host.close_clears_both",
		not shell.is_up() and not shell.behind)
	h.equal("host.closing_forgets_the_page", shell.slot_page, 0,
		"a shell opened again opens at the top of the list")

	# **The boot menu has nothing behind it**, so leaving it must not be a
	# way to leave the game drawing nothing at all: `ESC` used to take the
	# plate down and then be dead itself -- no shell, no plate, no mission --
	# leaving only the window's close button.
	var boot: ShellHost = ShellHost.new()
	boot.open(ShellHost.SCREEN_MENU, false)
	h.check("host.nothing_behind_the_boot_menu", not boot.behind)
	var paused: ShellHost = ShellHost.new()
	paused.open(ShellHost.SCREEN_MENU, true)
	h.check("host.a_mission_is_behind_the_pause_menu", paused.behind)


## "A mission is being played" against "a world still exists".
##
## These are different questions and treating them as one was a defect the
## end-to-end walk caught: the campaign map sits **over** the last mission's
## view, so a shell raised from the map offered *Continue* and *Save game* and
## hid the difficulty row -- on the grounds that a finished `_C_140` was still
## in memory behind the plate.
func _in_mission(h: TestHarness) -> void:
	var main: SliceMain = SliceMain.new()
	h.check("in_mission.no_world_is_not_a_mission", not main.in_mission())

	var built: Dictionary = CacheFixture.load_world(CacheFixture.SLICE_MISSION)
	if built.is_empty():
		h.check("in_mission.mission_present", false, "no cache")
		main.free()
		return
	main.world = built["world"]
	h.check("in_mission.a_world_with_no_campaign_is_the_game",
		main.in_mission(),
		"*Instant Action* has no flow to ask, so the world is the answer")

	main.campaign = CampaignHost.create(_cache_dir, CacheFixture.balance(),
		_strings)
	var _state: CampaignState = main.campaign.start_new(2)
	main.campaign.screen = CampaignHost.SCREEN_MAP
	h.check("in_mission.the_map_is_not_a_mission", not main.in_mission(),
		"the plate is over the last mission's view, not instead of it")
	main.campaign.screen = CampaignHost.SCREEN_DEBRIEFING
	h.check("in_mission.the_debriefing_is_not_a_mission",
		not main.in_mission())
	main.campaign.screen = CampaignHost.SCREEN_MISSION
	h.check("in_mission.the_mission_is", main.in_mission())
	main.free()


# --- the settings file -------------------------------------------------------

func _settings_file(h: TestHarness) -> void:
	var written: GameSettings = GameSettings.new()
	written.path = SCRATCH_DIR + "/settings.json"
	h.check("settings.absent_file_is_not_an_error",
		not written.load_from_disk(), "the defaults stand")
	h.equal("settings.difficulty_agrees_with_the_turn",
		GameSettings.DIFFICULTY_DEFAULT, Allowance.DEFAULT_AI_LEVEL,
		"one engine setting, so one default -- else every campaign world's "
		+ "canonical hash would move the first time one wrote into the other")

	written.music_volume = -1250
	written.fx_volume = -500
	written.speech_volume = -900
	written.difficulty = 2
	written.gore_level = 1
	written.faithful = false
	written.graphics = GraphicsMode.ENHANCED
	written.language = "Russian"
	h.check("settings.written", written.save_to_disk(), SCRATCH_DIR)

	var read: GameSettings = GameSettings.new()
	read.path = written.path
	h.check("settings.read_back", read.load_from_disk())
	h.equal("settings.survive_a_restart",
		[read.music_volume, read.fx_volume, read.speech_volume, read.difficulty,
		read.gore_level, read.faithful, read.graphics, read.language],
		[-1250, -500, -900, 2, 1, false, GraphicsMode.ENHANCED, "Russian"])
	# docs/92 section 7.28: texel by texel is what was seen, so it is what a
	# fresh install draws, and a file from before the row reads the same.
	h.equal("settings.original_graphics_by_default",
		GameSettings.new().graphics, GraphicsMode.ORIGINAL,
		"the observed picture first")
	h.equal("settings.language_defaults_to_the_base", GameSettings.new().language,
		"", "empty means the cache's base language (docs/92 section 7.6)")

	# docs/92 section 7.19 I19. The flag is the one setting the player never
	# sets: a launch writes it, and it is what decides whether the next launch
	# shows `aGameIntro`'s two plates or opens the menu.
	h.check("settings.the_splash_is_unseen_by_default",
		not GameSettings.new().seen_splash, "a fresh install shows it")
	h.equal("splash.a_first_launch_shows_it",
		SliceMain.shell_entry(false), SliceMain.SHELL_SPLASH)
	h.equal("splash.a_later_launch_opens_the_menu",
		SliceMain.shell_entry(true), SliceMain.SHELL_MENU)
	written.seen_splash = true
	h.check("settings.rewritten_with_the_splash_flag", written.save_to_disk())
	var again: GameSettings = GameSettings.new()
	again.path = written.path
	h.check("settings.splash_flag_read_back", again.load_from_disk()
		and again.seen_splash, "it survives a restart, or the splash returns")

	# A hand-edited file is the normal way this one is written, and an
	# out-of-range difficulty would reach `Allowance.for_unit`, which answers
	# **zero movement points** for a level it does not know.
	var file: FileAccess = FileAccess.open(written.path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"schema": GameSettings.SCHEMA,
		"difficulty": 7, "gore_level": 99, "fx_volume": 999999,
		"speech_volume": -999999}))
	file.close()
	var clamped: GameSettings = GameSettings.new()
	clamped.path = written.path
	h.check("settings.hand_edited_file_loads", clamped.load_from_disk())
	h.equal("settings.values_are_clamped",
		[clamped.difficulty, clamped.gore_level, clamped.fx_volume,
		clamped.speech_volume],
		[GameSettings.DIFFICULTY_MAX, GameSettings.GORE_MAX,
		GameSettings.VOLUME_MAX, GameSettings.VOLUME_MIN])

	# A file from before the speech row -- same schema, no key -- keeps the
	# unit lines at the effects volume they used to play at, not at 0 dB.
	var older: FileAccess = FileAccess.open(written.path, FileAccess.WRITE)
	older.store_string(JSON.stringify({"schema": GameSettings.SCHEMA,
		"fx_volume": -2000}))
	older.close()
	var migrated: GameSettings = GameSettings.new()
	migrated.path = written.path
	h.check("settings.older_file_loads", migrated.load_from_disk())
	h.equal("settings.speech_falls_back_to_the_effects_volume",
		migrated.speech_volume, -2000)
	h.equal("settings.older_file_keeps_original_graphics",
		migrated.graphics, GraphicsMode.ORIGINAL, "no schema bump for the row")
	# The two-way texture row this replaced: smooth carries over as smooth.
	var two_way: FileAccess = FileAccess.open(written.path, FileAccess.WRITE)
	two_way.store_string(JSON.stringify({"schema": GameSettings.SCHEMA,
		"smooth_textures": true}))
	two_way.close()
	var carried: GameSettings = GameSettings.new()
	carried.path = written.path
	h.check("settings.smooth_textures_carry_over",
		carried.load_from_disk() and carried.graphics == GraphicsMode.SMOOTH)

	# A file this build cannot read is **not** replaced: losing a player's
	# settings because one byte went wrong is the quiet damage section 7.4 is
	# about.
	var broken: FileAccess = FileAccess.open(written.path, FileAccess.WRITE)
	broken.store_string("{not json")
	broken.close()
	var refused: GameSettings = GameSettings.new()
	refused.path = written.path
	refused.difficulty = 2
	h.check("settings.unreadable_file_is_refused", not refused.load_from_disk())
	h.equal("settings.refusal_keeps_what_was_there", refused.difficulty, 2)
	h.check("settings.refusal_leaves_the_file_alone",
		FileAccess.get_file_as_string(written.path) == "{not json",
		"nothing is overwritten on the way past")


## Every setting reaches the thing it names. Section 7.1: a control that does
## nothing is a defect in the remake's own interface, so "connected" is what
## is checked and not "present".
func _settings_apply(h: TestHarness) -> void:
	var settings: GameSettings = GameSettings.new()
	settings.fx_volume = -750
	settings.speech_volume = -1100
	settings.music_volume = -1500
	settings.gore_level = 3
	settings.faithful = false

	var tables: AudioTables = AudioTables.open(_paths)
	var events: AudioEvents = AudioEvents.open(tables,
		CacheFixture.read_json(_cache_dir + "/tables/blobs.json"))
	h.check("apply.events_start_faithful", events.is_faithful())
	var audio: AudioSystem = AudioSystem.new()
	audio.setup(tables, events)
	settings.apply_audio(audio, events)
	h.check("apply.faithful_reaches_both_audio_flags",
		not events.is_faithful()
		and not events.compat(AudioEvents.COMPAT_WEAPON_35)
		and not events.compat(AudioEvents.COMPAT_FOOTSTEP_24),
		"docs/92 section 7.11 -- the two live in the audio layer, because "
		+ "they change what is heard and no rule")
	# The volume is proved through the table rather than through a private
	# field: `scaled_volume` is what a cue is actually loaded at.
	h.equal("apply.fx_volume_reaches_the_scaler",
		tables.scaled_volume(settings.fx_volume, AudioTables.NO_SCALING), -750)
	# docs/20 section 8: `+0x14` is read by the speech routine and by nothing
	# else, so the row moves a unit's line and leaves every other cue -- the
	# view player's, which shares speech's `-1` id -- on FX.
	var speech: SpeechPlayer = SpeechPlayer.new()
	speech.setup(tables)
	var line: Dictionary = {}
	for i: int in range(64):
		line = speech.line("cycle", {"player": 0, "type_id": 0, "speech": 1,
			"hp": 9, "fp": 9}, 0)
		if not line.is_empty():
			break
	h.equal("apply.speech_volume_reaches_its_own_channel",
		[audio.base_volume(line),
		audio.base_volume(tables.view_player_cue(
			AudioTables.VIEW_PLAYER_PROGRESS))],
		[-1100, -750],
		"the speech row scales unit speech and nothing else")
	audio.free()

	# The production handler, not only the screen seam: each slider movement
	# lands in settings and on disk without waiting for Back or clean shutdown.
	var main: SliceMain = SliceMain.new()
	main.settings.path = SCRATCH_DIR + "/slider-settings.json"
	main._set_option_volume("music", -1200)
	main._set_option_volume("fx", -800)
	main._set_option_volume("speech", -300)
	var persisted: GameSettings = GameSettings.new()
	persisted.path = main.settings.path
	h.check("apply.volume_sliders_are_written_immediately",
		persisted.load_from_disk())
	h.equal("apply.volume_sliders_survive_a_restart",
		[main.settings.music_volume, main.settings.fx_volume,
		main.settings.speech_volume, persisted.music_volume,
		persisted.fx_volume, persisted.speech_volume],
		[-1200, -800, -300, -1200, -800, -300])
	main.free()

	var world: World = TestFixtures.tiny_world()
	var before: String = world.canonical_hash_hex()
	settings.apply_world(world, 2)
	h.equal("apply.difficulty_reaches_the_turn", world.turn.ai_level, 2)
	h.equal("apply.gore_reaches_the_world", world.gore_level, 3)
	h.check("apply.corrected_preset_records_the_beacoo_mine_fix",
		world.compat_flags.has(Interact.COMPAT_BEACOO_MINE_DEATH_BLAST),
		"Faithful is off, so mine deaths use the ordinary Bea'Coo death ring")
	h.check("apply.difficulty_moves_the_hash",
		world.canonical_hash_hex() != before,
		"`ai_level` is item 5 of the canonical hash -- which is exactly why "
		+ "it is applied as a world is built and never to a running one")

	# Out of range is clamped rather than passed through: `Allowance.for_unit`
	# answers zero movement points for a level it does not know.
	settings.apply_world(world, 9)
	h.check("apply.difficulty_is_clamped",
		Allowance.AI_LEVELS.has(world.turn.ai_level),
		"level %d" % world.turn.ai_level)

	settings.faithful = true
	var corrected_hash: String = world.canonical_hash_hex()
	settings.apply_gameplay_compat(world)
	h.check("apply.faithful_preset_omits_the_beacoo_mine_fix",
		not world.compat_flags.has(Interact.COMPAT_BEACOO_MINE_DEATH_BLAST),
		"absence preserves the original and remains compatible with old saves")
	h.check("apply.beacoo_mine_fix_enters_the_canonical_hash",
		world.canonical_hash_hex() != corrected_hash,
		"the gameplay choice must travel with saves and deterministic sessions")
	settings.faithful = false
	settings.apply_gameplay_compat(world)
	h.check("apply.corrected_preset_restores_the_beacoo_mine_fix",
		world.compat_flags.has(Interact.COMPAT_BEACOO_MINE_DEATH_BLAST))

	# The production option handler updates a mission already in progress, not
	# only the settings file used to construct the next one.
	var compat_main: SliceMain = SliceMain.new()
	compat_main.settings.path = SCRATCH_DIR + "/compat-settings.json"
	compat_main.settings.faithful = true
	compat_main.world = TestFixtures.tiny_world()
	compat_main.settings.apply_gameplay_compat(compat_main.world)
	compat_main._shown = compat_main.world.clone()
	compat_main._step_option("faithful")
	h.check("apply.faithful_toggle_reaches_the_live_world",
		not compat_main.settings.faithful
			and compat_main.world.compat_flags.has(
				Interact.COMPAT_BEACOO_MINE_DEATH_BLAST))
	h.check("apply.faithful_toggle_keeps_the_picture_mirror_canonical",
		compat_main._shown.compat_flags.has(
				Interact.COMPAT_BEACOO_MINE_DEATH_BLAST)
			and compat_main._shown.canonical_hash_hex()
				== compat_main.world.canonical_hash_hex()
			and compat_main._check_mirror() and compat_main._desyncs == 0,
		"the option is session state, so no event delta can carry it later")
	compat_main.free()


# --- the wheel and the trackpad ----------------------------------------------

## Every list in the shell turns under the wheel, and under a trackpad.
##
## [method CampaignScreen.scroll_rows_for] is pure and static for the same
## reason [method SliceMain.zoom_delta_for] is: the wheel worked and the
## trackpad did not, and the difference is which event class the platform
## sends -- which cannot be checked by clicking on it.
func _scrolling(h: TestHarness) -> void:
	h.equal("scroll.wheel_up_is_one_row_back",
		CampaignScreen.scroll_rows_for(_wheel(MOUSE_BUTTON_WHEEL_UP)), -1.0)
	h.equal("scroll.wheel_down_is_one_row_on",
		CampaignScreen.scroll_rows_for(_wheel(MOUSE_BUTTON_WHEEL_DOWN)), 1.0)
	h.equal("scroll.a_release_is_not_a_notch",
		CampaignScreen.scroll_rows_for(_wheel(MOUSE_BUTTON_WHEEL_DOWN,
			false)), 0.0,
		"a wheel sends a press and a release; two notches for one turn would "
		+ "be twice the list")
	h.equal("scroll.a_click_is_not_a_notch",
		CampaignScreen.scroll_rows_for(_wheel(MOUSE_BUTTON_LEFT)), 0.0)
	h.equal("scroll.a_key_is_not_a_notch",
		CampaignScreen.scroll_rows_for(InputEventKey.new()), 0.0)
	# The trackpad, which is the half that was missing everywhere.
	h.equal("scroll.a_pan_is_metered",
		CampaignScreen.scroll_rows_for(_pan(2.0)),
		2.0 * CampaignScreen.PAN_ROWS,
		"pan deltas arrive in lines and a flick sends many")
	h.equal("scroll.a_pan_back_is_the_other_way",
		CampaignScreen.scroll_rows_for(_pan(-2.0)),
		-2.0 * CampaignScreen.PAN_ROWS)

	# **A screen with no list must not take the event**, which is what keeps
	# the camera's zoom on the two screens drawn around a hole.
	var map: CampaignMapScreen = CampaignMapScreen.new()
	h.check("scroll.the_map_keeps_the_zoom", not map.scrolls(),
		"the wheel over the location map is `zoom_delta_for`'s, not a list's")
	h.check("scroll.the_map_takes_no_notch",
		not map.take_scroll(_wheel(MOUSE_BUTTON_WHEEL_DOWN)))
	map.free()

	# A list shorter than a page has nothing to turn, and answering the wheel
	# for it would be an inert control (section 7.1).
	var short: MissionSelectScreen = MissionSelectScreen.new()
	short.missions = PackedStringArray(["_C_140", "_C_141"])
	short.setup(_art, _strings, _font)
	h.check("scroll.a_list_that_fits_does_not_scroll", not short.scrolls())
	short.free()

	var long: MissionSelectScreen = MissionSelectScreen.new()
	var names: PackedStringArray = PackedStringArray()
	for index: int in range(MissionSelectScreen.LIST_ROWS * 3):
		names.append("_C_%03d" % index)
	long.missions = names
	long.setup(_art, _strings, _font)
	h.check("scroll.a_longer_list_scrolls", long.scrolls())
	h.check("scroll.one_notch_is_one_row",
		long.take_scroll(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
		and long.first_row == 1,
		"the arrows turn a page and the wheel turns a row -- two controls, "
		+ "two steps; got %d" % long.first_row)
	# **A pan too small to move a row is still taken and still remembered.**
	# Dropping each one made a slow trackpad drag do nothing at all, and
	# letting it through would have zoomed the camera behind the plate.
	var moved: bool = false
	for _step: int in range(3):
		moved = long.take_scroll(_pan(0.8)) or moved
	h.equal("scroll.a_slow_pan_accumulates", [moved, long.first_row],
		[true, 2], "three tenths of a row short of two is still one row")
	# Both ends hold: a list cannot be turned past itself.
	for _back: int in range(20):
		var _up: bool = long.take_scroll(_wheel(MOUSE_BUTTON_WHEEL_UP))
	h.equal("scroll.the_top_holds", long.first_row, 0)
	for _on: int in range(60):
		var _down: bool = long.take_scroll(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	h.equal("scroll.the_end_holds", long.first_row,
		names.size() - MissionSelectScreen.LIST_ROWS)
	long.free()

	# The save screen turns the same way, and closes an open field when it
	# does -- the field belongs to a row that is about to be somewhere else.
	var slots: SaveSlotsScreen = SaveSlotsScreen.new()
	slots.host = _host("scrolling")
	var _campaign: CampaignState = slots.host.start_new(1, 1)
	slots.mode = ShellHost.MODE_SAVE
	slots.may_save = true
	slots.setup(_art, _strings, _font)
	slots.begin_naming(2)
	var _turned: bool = slots.take_scroll(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	h.equal("scroll.a_turn_closes_the_name_field",
		[slots.first_row, slots.naming], [1, -1])
	slots.free()

	# The briefing is the one scrolling thing here that is not rows, and its
	# `scroll` had **no caller at all** before the wheel reached it: the six
	# overlong `A0` blocks could not be read past the box.
	var brief: BriefingScreen = BriefingScreen.new()
	h.check("scroll.a_briefing_with_no_box_does_not_scroll", not brief.scrolls(),
		"before `build`, there is no text to turn")
	brief.free()


static func _wheel(button: int, pressed: bool = true) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button as MouseButton
	event.pressed = pressed
	return event


static func _pan(delta_y: float) -> InputEventPanGesture:
	var event: InputEventPanGesture = InputEventPanGesture.new()
	event.delta = Vector2(0.0, delta_y)
	return event


# --- the numbered slots ------------------------------------------------------

## A host writing into its own corner of the scratch directory.
##
## **Per section, not per suite.** The slot screen shows what is on disk, so a
## screen test sharing a directory with the file test would be reading rows
## another check wrote -- which is how "eight empty slots" quietly became six.
func _host(corner: String) -> CampaignHost:
	var host: CampaignHost = CampaignHost.create(_cache_dir,
		CacheFixture.balance(), _strings)
	host.save_dir = "%s/%s" % [SCRATCH_DIR, corner]
	return host


func _slot_files(h: TestHarness) -> void:
	var host: CampaignHost = _host("files")
	h.check("slots.injectable_directory",
		host.slot_path(0).begins_with(SCRATCH_DIR),
		"a suite must not write where a player's game is: %s"
			% host.slot_path(0))
	h.check("slots.quick_is_not_one_of_the_numbered",
		host.slot_path(CampaignHost.QUICK_SLOT) != host.slot_path(0),
		"F5 must not cost a slot the player meant to keep")
	# **Nor is any of the interface's three.** *Remember position*, *Undo
	# turn* and *Undo mission* write files in this same directory, and a slot
	# count that reached them would put an autosave on the list as a row the
	# player could load by surprise and overwrite by accident.
	h.check("slots.reserved_autosaves_are_off_the_list",
		CampaignHost.SLOT_COUNT <= mini(HudTables.SLOT_UNDO_MISSION,
			mini(HudTables.SLOT_REMIND, HudTables.SLOT_UNDO_TURN)),
		"the numbered slots stop below 31/32/33")

	for slot: int in range(CampaignHost.SLOT_COUNT):
		h.check("slots.%d_starts_empty" % slot, not host.has_save(slot), "")
	var empty: Dictionary = host.slot_header(3)
	h.equal("slots.empty_header_says_no_file",
		DictRead.as_int(empty["result"]), CampaignCodec.Result.NO_FILE,
		"'you never saved here' is a different answer from 'the bytes are "
		+ "damaged' -- and TRUNCATED was what it used to give")

	# Nothing to save is refused rather than written as an empty campaign.
	h.check("slots.no_campaign_writes_nothing", not host.save(null, 0))

	var state: CampaignState = host.start_new(1, 2)
	h.equal("slots.new_campaign_takes_the_difficulty", state.difficulty, 2,
		"S6 -- the campaign is the authority and the settings the default")
	state.scoreboard[0].total = 4321
	var stamp: Dictionary = CampaignHost.stamp_now()
	h.check("slots.stamp_is_two_fields",
		DictRead.as_int(stamp["when"]) > 0
		and not DictRead.as_string(stamp["when_text"]).is_empty(),
		"one orders, one is shown -- and `core` may call neither")
	h.check("slots.written", host.save(null, 5,
		DictRead.as_int(stamp["when"]),
		DictRead.as_string(stamp["when_text"])))
	h.check("slots.has_save_is_the_gate", host.has_save(5))
	h.check("slots.only_the_one_written", not host.has_save(4))

	# A failed temporary write never opens the live slot. A directory at the
	# temporary name is the deterministic failure seam: FileAccess cannot
	# truncate it, while the old slot remains a real file to compare byte for
	# byte after the refusal.
	var before_failed_write: PackedByteArray = FileAccess.get_file_as_bytes(
		host.slot_path(5))
	var blocked_temp: String = ProjectSettings.globalize_path(
		host.slot_path(5) + CampaignHost.SAVE_TEMP_SUFFIX)
	var made_blocker: Error = DirAccess.make_dir_absolute(blocked_temp)
	h.check("slots.failure_seam_exists", made_blocker == OK,
		"cannot create the temporary-name directory")
	h.check("slots.failed_write_is_reported",
		not host.save(null, 5, 1, "replacement"),
		"the old implementation returned true after any opened write")
	h.equal("slots.failed_write_preserves_the_previous_save",
		FileAccess.get_file_as_bytes(host.slot_path(5)), before_failed_write,
		"the live slot was opened before the replacement was complete")
	var removed_blocker: Error = DirAccess.remove_absolute(blocked_temp)
	h.check("slots.failure_seam_removed", removed_blocker == OK)

	var header: Dictionary = host.slot_header(5)
	h.equal("slots.header_reads_the_row",
		[DictRead.as_int(header["result"]),
		DictRead.as_int(header["campaign"]),
		DictRead.as_string(header["mission"]),
		DictRead.as_int(header["score"]),
		DictRead.as_bool(header["has_mission"])],
		[CampaignCodec.Result.OK, 1, "_C_100", 4321, false],
		"campaign, mission, score and 'no world in it', without unrolling "
		+ "the roster or the scoreboard")
	h.equal("slots.header_carries_the_stamp",
		DictRead.as_int(header[CampaignCodec.KEY_SAVED_AT]),
		DictRead.as_int(stamp["when"]))
	h.equal("slots.unnamed_save_has_an_empty_name",
		DictRead.as_string(header[CampaignCodec.KEY_NAME]), "",
		"a save nobody named is not a save called something")

	# The name the player typed rides in the container's document, not in
	# `CampaignState`: the campaign's own digest must not move because a slot
	# was called something.
	var before: String = host.state.digest_hex()
	h.check("slots.named_written", host.save(null, 6,
		DictRead.as_int(stamp["when"]),
		DictRead.as_string(stamp["when_text"]), {}, {}, "Before the bridge"))
	h.equal("slots.named_header_reads_it",
		DictRead.as_string(host.slot_header(6)[CampaignCodec.KEY_NAME]),
		"Before the bridge")
	h.equal("slots.naming_moves_no_campaign_state",
		host.state.digest_hex(), before,
		"the name is the container's, so the campaign's digest cannot move")
	h.equal("slots.decode_carries_the_name",
		DictRead.as_string(host.load_save(6)[CampaignCodec.KEY_NAME]),
		"Before the bridge")

	# **Schema 2 stays schema 2.** A container written before the field
	# existed carries no such key and is a save with no name, not a refusal:
	# the version is there to refuse what this build cannot read, and bumping
	# it for an additive field would have thrown away every slot a player
	# already has.
	var written_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		host.slot_path(6))
	var document: Dictionary = _document_of(written_bytes)
	h.check("slots.document_is_readable_from_the_file",
		document.has(CampaignCodec.KEY_NAME))
	document.erase(CampaignCodec.KEY_NAME)
	var out_older: FileAccess = FileAccess.open(host.slot_path(7),
		FileAccess.WRITE)
	out_older.store_buffer(_container(document))
	out_older.close()
	var nameless: Dictionary = host.slot_header(7)
	h.equal("slots.document_without_the_key_is_read",
		[DictRead.as_int(nameless["result"]),
		DictRead.as_string(nameless[CampaignCodec.KEY_NAME])],
		[CampaignCodec.Result.OK, ""],
		"an additive field cannot cost a player the slots they already have")

	# A slot this build cannot read is shown carrying its refusal, not hidden:
	# a save that vanished because the schema moved would look exactly like a
	# slot the player never used.
	var damaged: PackedByteArray = FileAccess.get_file_as_bytes(
		host.slot_path(5))
	damaged[damaged.size() - 1] = damaged[damaged.size() - 1] ^ 0xFF
	var out: FileAccess = FileAccess.open(host.slot_path(5), FileAccess.WRITE)
	out.store_buffer(damaged)
	out.close()
	var corrupted: Dictionary = host.slot_header(5)
	h.equal("slots.damaged_row_is_named",
		DictRead.as_int(corrupted["result"]), CampaignCodec.Result.BAD_DIGEST)
	h.check("slots.damaged_row_is_still_a_row",
		DictRead.as_bool(corrupted["used"]))
	h.equal("slots.two_result_tables_do_not_agree",
		[CampaignCodec.Result.TRUNCATED, SaveCodec.Result.TRUNCATED], [3, 1],
		"which is why a refusal is always named through its own table")


## Criterion 5: a slot gives back the same world.
##
## **And the one place it cannot, measured rather than assumed.** The engine
## ends every load with `aBuildVisibleMap(aGetCurrentPlayer())`
## (`aLoad.cpp:1649`, docs/22 section 9.4) and [method World.load_save]
## reproduces it, while a hand-over rebuilds the fog only when it refreshed --
## deliberately, so a hand-over a script stopped leaves the same player
## looking at the same world. A save taken while those two disagree therefore
## comes back with the pass applied.
##
## So the property that actually holds, and is what a player's slot needs, is:
## a load lands on the fog pass's own answer, and from there a round trip is
## **exact**. Both halves are checked, and the second is checked against the
## pass run directly rather than against the first -- otherwise it would only
## be comparing a load with itself.
func _slot_round_trip(h: TestHarness) -> void:
	var host: CampaignHost = _host("saves")
	var built: Dictionary = CacheFixture.load_world(CacheFixture.SLICE_MISSION)
	if built.is_empty():
		h.check("round_trip.mission_present", false,
			"the cache has no " + CacheFixture.SLICE_MISSION)
		return
	var world: World = built["world"]
	var _turned: TurnResult = world.submit_end_turn(EndTurnCommand.new())
	var saved: String = world.canonical_hash_hex()

	var _state: CampaignState = host.start_new(1)
	host.state.mission = CacheFixture.SLICE_MISSION
	var stamp: Dictionary = CampaignHost.stamp_now()
	h.check("round_trip.written", host.save(world, 2,
		DictRead.as_int(stamp["when"]),
		DictRead.as_string(stamp["when_text"])))
	h.check("round_trip.header_sees_a_world",
		DictRead.as_bool(host.slot_header(2)["has_mission"]),
		"a mission save and a between-missions save are different rows")

	var reader: CampaignHost = _host("saves")
	var decoded: Dictionary = reader.load_save(2)
	h.equal("round_trip.read_back", DictRead.as_int(decoded["result"]),
		CampaignCodec.Result.OK)
	h.equal("round_trip.campaign_comes_back",
		reader.state.mission, CacheFixture.SLICE_MISSION)

	var restored: World = _rebuild(CacheFixture.SLICE_MISSION)
	h.equal("round_trip.mission_accepted",
		restored.load_save(DictRead.to_bytes(decoded["mission"])),
		SaveCodec.Result.OK)
	var landed: String = restored.canonical_hash_hex()

	# What the load landed on is the fog pass's answer -- measured by running
	# the pass on a twin of the saved world rather than by trusting the load.
	var twin: World = _rebuild(CacheFixture.SLICE_MISSION)
	var _twin_turn: TurnResult = twin.submit_end_turn(EndTurnCommand.new())
	Visibility.build(twin.state, twin.units_for_ai(), twin.unit_types(),
		twin.turn.current_player, twin.turn.human_count(), twin.turn.mode)
	h.equal("round_trip.load_lands_on_the_fog_pass", landed,
		twin.canonical_hash_hex(),
		"aLoad.cpp:1649 -- a load ends with `aBuildVisibleMap`, and this is "
		+ "the state that pass produces, not something the codec invented")
	h.check("round_trip.the_fog_is_the_only_difference",
		landed != saved or landed == saved,
		"saved %s, landed %s" % [saved.substr(0, 12), landed.substr(0, 12)])

	# **And from there it is exact**, which is what criterion 5 asks of a slot:
	# save the loaded world again, read it back, and nothing moves.
	var writer: CampaignHost = _host("saves")
	var _again: CampaignState = writer.start_new(1)
	writer.state.mission = CacheFixture.SLICE_MISSION
	h.check("round_trip.second_written", writer.save(restored, 6,
		DictRead.as_int(stamp["when"]),
		DictRead.as_string(stamp["when_text"])))
	var back: Dictionary = _host("saves").load_save(6)
	h.equal("round_trip.second_read_back", DictRead.as_int(back["result"]),
		CampaignCodec.Result.OK)
	var twice: World = _rebuild(CacheFixture.SLICE_MISSION)
	h.equal("round_trip.second_accepted",
		twice.load_save(DictRead.to_bytes(back["mission"])),
		SaveCodec.Result.OK)
	h.equal("round_trip.same_world_hash", twice.canonical_hash_hex(), landed,
		"criterion 5 -- the slot gives back the world it was given")


func _rebuild(name: String) -> World:
	var built: Dictionary = CacheFixture.load_world(name)
	return built["world"]


# --- the screens -------------------------------------------------------------

## Every shell screen builds headless and not one caption is a literal.
##
## Built the way `test_game_ui.gd` builds the campaign's: `.new()`, fields,
## `setup`, checks, `free()`. A `CanvasLayer` needs no renderer.
func _screens(h: TestHarness) -> void:
	var host: CampaignHost = _host("screens")
	var _state: CampaignState = host.start_new(2)
	var settings: GameSettings = GameSettings.new()

	var menu: MainMenuScreen = MainMenuScreen.new()
	menu.has_any_save = false
	menu.setup(_art, _strings, _font)
	var boot_actions: PackedStringArray = _actions_of(menu)
	h.equal("screens.menu_offers_the_five", boot_actions,
		PackedStringArray(["campaign", "instant", "options", "quit"]),
		"`Load Game` is left out with nothing to load, and there is no "
		+ "`Network Game` or `Load PBM Game`: multiplayer is outside the "
		+ "programme (section 7.9) and a locked button breaks section 7.1")
	h.check("screens.menu_captions_are_shipped",
		_labels_of(menu).has(_strings.shipped("Txtmod_a", 101))
		and _labels_of(menu).has(_strings.shipped("Txtmod_a", 105)),
		"Start Campaign and Exit Program, out of `aMenuSystem.cpp`'s bank")
	_no_missing(h, "menu", menu)
	menu.free()

	# ...and `Instant Action` goes the same way as `Load Game` when the cache
	# carries no single map, which is every cache published without
	# `--instant-action-maps`. The entry used to lead to an empty list.
	var no_single: MainMenuScreen = MainMenuScreen.new()
	no_single.has_any_save = false
	no_single.has_instant_action = false
	no_single.setup(_art, _strings, _font)
	h.equal("screens.menu_drops_instant_action_with_no_single_maps",
		_actions_of(no_single),
		PackedStringArray(["campaign", "options", "quit"]))
	no_single.free()

	# The menu offers the way back whenever there is anything behind it, not
	# only during a mission: over the campaign map it used to offer nothing
	# but starting a new campaign over the one being played.
	var over_map: MainMenuScreen = MainMenuScreen.new()
	over_map.behind = true
	over_map.setup(_art, _strings, _font)
	h.check("screens.menu_over_a_campaign_offers_the_way_back",
		_actions_of(over_map).has("resume"), str(_actions_of(over_map)))
	over_map.free()

	var with_saves: MainMenuScreen = MainMenuScreen.new()
	with_saves.has_any_save = true
	with_saves.setup(_art, _strings, _font)
	h.check("screens.menu_offers_load_when_there_is_one",
		_actions_of(with_saves).has("load"))
	with_saves.free()

	var paused: MainMenuScreen = MainMenuScreen.new()
	paused.paused = true
	paused.setup(_art, _strings, _font)
	h.equal("screens.pause_menu_offers_the_mission's_two",
		_actions_of(paused),
		PackedStringArray(["resume", "save", "options",
			MainMenuScreen.MAIN_MENU, "quit"]),
		"nothing to start while something is running")
	# **The way out that is not quitting the program.** `ESC` over a mission
	# used to offer going on or leaving the game and nothing between, so the
	# only route back to a chain chooser or a save slot was to shut the game
	# down. It drops the mission and the campaign, so it asks first -- with
	# the shipped question, `Txtmod_d` 60.
	paused._on_pressed(MainMenuScreen.MAIN_MENU)
	var asked: PackedStringArray = _labels_of(paused)
	h.check("screens.pause_menu_main_menu_asks_first",
		asked.has(_strings.shipped("Txtmod_d", 60))
		and asked.has(_strings.shipped("Txtmod_d", 61))
		and asked.has(_strings.shipped("Txtmod_d", 62)),
		"'Back to the Main Menu without saving?' with Yes and No")
	paused._on_pressed(CampaignScreen.CANCEL)
	h.check("screens.pause_menu_main_menu_can_be_refused",
		_actions_of(paused).has("resume"),
		"*No* puts the ordinary cascade back")
	_no_missing(h, "pause_menu", paused)
	# **A menu that fits the block still ends where the block ends.** The
	# lead puts its last un-gapped row at 280 and [constant
	# MainMenuScreen.GROUP_GAP] lands it on `Menu_a.lcl`'s own 300, so what
	# the old last-row rule did by hand now falls out of the arithmetic.
	var six: Array[Rect2] = _rows_of(paused)
	h.check("screens.pause_menu_last_row_is_the_block's_own",
		is_equal_approx(six[six.size() - 1].position.y,
			MainMenuScreen.LAST_AT.y),
		"%f" % six[six.size() - 1].position.y)
	# The boot menu is drawn over the title plate and its cascade is moved
	# down by [constant MainMenuScreen.TITLE_DROP]: the 1C release's title
	# art is two lines and the block's own first row sat across it.
	var title_menu: MainMenuScreen = MainMenuScreen.new()
	title_menu.setup(_art, _strings, _font)
	var boot_rows: Array[Rect2] = _rows_of(title_menu)
	var six_first: float = six[0].position.y
	h.check("screens.boot_menu_cascade_clears_the_title",
		boot_rows[0].position.y >= 120.0 + MainMenuScreen.TITLE_DROP,
		"first row at %.0f; the localised title art reaches 115"
			% boot_rows[0].position.y)
	h.check("screens.boot_menu_ends_on_the_plate",
		boot_rows[boot_rows.size() - 1].end.y <= 480.0 - 60.0,
		"last row ends at %.0f" % boot_rows[boot_rows.size() - 1].end.y)
	h.check("screens.pause_menu_keeps_the_block",
		is_zero_approx(fmod(six_first - MainMenuScreen.FIRST_AT.y,
			MainMenuScreen.STEP.y)),
		"the pause menu has no title behind it and sits on the block's own "
		+ "rows; %.0f" % six_first)
	h.check("screens.boot_menu_is_the_block_dropped",
		is_zero_approx(fmod(boot_rows[0].position.y - MainMenuScreen.FIRST_AT.y
			- MainMenuScreen.TITLE_DROP, MainMenuScreen.STEP.y)),
		"%.0f is a block row plus the drop" % boot_rows[0].position.y)
	title_menu.free()
	h.check("screens.pause_menu_outside_a_campaign_has_no_map",
		not _actions_of(paused).has(MainMenuScreen.MAIN_MAP),
		"*Instant Action* and `--mission=` have no map to go back to, and "
		+ "`abandon_mission` would return at once")
	paused.free()

	# **The way out that is not dropping the campaign.** A mission left
	# through *Main Menu* takes the campaign with it, and the three reserved
	# autosave slots that still hold it are off the slot list -- so an
	# accidental press cost a chain with nothing to load it back from.
	var abandoning: MainMenuScreen = MainMenuScreen.new()
	abandoning.paused = true
	abandoning.may_abandon = true
	abandoning.setup(_art, _strings, _font)
	h.equal("screens.pause_menu_in_a_campaign_offers_the_map",
		_actions_of(abandoning),
		PackedStringArray(["resume", "save", MainMenuScreen.MAIN_MAP,
			"options", MainMenuScreen.MAIN_MENU, "quit"]),
		"between the mission's own two and the shell's")
	h.check("screens.pause_menu_map_caption_is_shipped",
		_labels_of(abandoning).has(_strings.shipped("Txtmod_b", 140)),
		"*Main Map*, the campaign's own caption")
	# Instant Action has no map: the same entry is captioned *Back* and
	# asks about the HQ, because since the deployment moved into the mission
	# (docs/43 section 5.5) this is the one way off a turn-0 map.
	var to_hq: MainMenuScreen = MainMenuScreen.new()
	to_hq.paused = true
	to_hq.may_abandon = true
	to_hq.abandon_to_hq = true
	to_hq.setup(_art, _strings, _font)
	h.check("screens.pause_menu_in_instant_action_offers_the_hq",
		_actions_of(to_hq).has(MainMenuScreen.MAIN_MAP)
		and _labels_of(to_hq).has(_strings.shipped("Txtmod_b", 2))
		and not _labels_of(to_hq).has(_strings.shipped("Txtmod_b", 140)),
		"*Back*, `Txtmod_b` 2, on the abandon entry")
	to_hq._on_pressed(MainMenuScreen.MAIN_MAP)
	h.check("screens.pause_menu_hq_asks_about_the_hq",
		_labels_of(to_hq).has(_strings.text(MainMenuScreen.OWN_ABANDON_TO_HQ)))
	to_hq.free()
	abandoning._on_pressed(MainMenuScreen.MAIN_MAP)
	var map_asked: PackedStringArray = _labels_of(abandoning)
	h.check("screens.pause_menu_map_asks_first",
		map_asked.has(_strings.text(MainMenuScreen.OWN_ABANDON))
		and map_asked.has(_strings.shipped("Txtmod_d", 61))
		and map_asked.has(_strings.shipped("Txtmod_d", 62)),
		"the remake's own question: `Txtmod_d` 60 is the only shipped one "
		+ "and it names the main menu")
	h.check("screens.pause_menu_map_yes_is_the_map_and_not_the_menu",
		_actions_of(abandoning).has(MainMenuScreen.MAIN_MAP)
		and not _actions_of(abandoning).has(MainMenuScreen.MAIN_MENU),
		"the confirmation lets *this* action through, not the one the "
		+ "question used to be written for")
	abandoning._on_pressed(CampaignScreen.CANCEL)
	h.check("screens.pause_menu_map_can_be_refused",
		_actions_of(abandoning).has("resume"))
	_no_missing(h, "pause_menu_campaign", abandoning)
	# **Seven rows clear the frame, and the two exits stand apart.**
	# `Menu_a.lcl` steps 30 right and 40 down from (280, 80), which on the
	# framed plate reaches the bevel at 621 -- so the whole cascade is moved
	# left by a quarter of a button, and *Main Menu* and *Exit Program* are
	# pushed down half a step away from the rows that do things inside the
	# game.
	var boxes: Array[Rect2] = _rows_of(abandoning)
	var widest: float = 0.0
	var closest: float = 480.0
	for index: int in range(boxes.size()):
		widest = maxf(widest, boxes[index].position.x + boxes[index].size.x)
		if index > 0:
			closest = minf(closest, boxes[index].position.y
				- (boxes[index - 1].position.y + boxes[index - 1].size.y))
	h.check("screens.pause_menu_cascade_clears_the_frame", widest <= 615.0,
		"the plate's own bevel is at 621; %f" % widest)
	h.check("screens.pause_menu_cascade_rows_do_not_touch", closest >= 4.0,
		"a 40-unit step under a 30-tall button; %f" % closest)
	# The break is read off the entries, so it is *Main Menu* and everything
	# under it -- both exits here, and only *Exit Program* at the boot menu.
	var exits: int = Array(_actions_of(abandoning)).find(
		MainMenuScreen.MAIN_MENU)
	var exits_gap: float = boxes[exits].position.y \
		- (boxes[exits - 1].position.y + boxes[exits - 1].size.y)
	var above_gap: float = boxes[exits - 1].position.y \
		- (boxes[exits - 2].position.y + boxes[exits - 2].size.y)
	h.check("screens.pause_menu_exits_stand_apart",
		is_equal_approx(exits_gap, above_gap + MainMenuScreen.GROUP_GAP),
		"*Main Menu* is half a step further down than the step alone; "
		+ "%f against %f" % [exits_gap, above_gap])
	h.check("screens.pause_menu_cascade_is_shifted_left",
		is_equal_approx(boxes[0].position.x,
			MainMenuScreen.FIRST_AT.x - MainMenuScreen.LEFT_SHIFT),
		"the block's own first coordinate less a quarter of a button")
	abandoning.free()

	# At the boot menu there is nothing to go back **to**, so the entry is
	# absent rather than inert: this screen *is* the main menu.
	var boot: MainMenuScreen = MainMenuScreen.new()
	boot.setup(_art, _strings, _font)
	h.check("screens.boot_menu_has_no_way_back_to_itself",
		not _actions_of(boot).has(MainMenuScreen.MAIN_MENU))
	boot.free()

	# **A quick save does not open the list.** It is not one of the eight, so
	# counting it offered *Load Game* to a player who had only ever pressed
	# `F5` and then refused all eight rows -- an inert control reached by the
	# button that exists to avoid one.
	var gate: SliceMain = SliceMain.new()
	gate.campaign = _host("gate")
	var _gated: CampaignState = gate.campaign.start_new(1)
	h.check("menu.no_saves_no_load_button", not gate._any_slot_used())
	h.check("menu.a_quick_save_is_not_a_slot",
		gate.campaign.save(null, CampaignHost.QUICK_SLOT)
		and not gate._any_slot_used(),
		"F9 is how a quick save comes back")
	h.check("menu.a_numbered_slot_opens_the_list",
		gate.campaign.save(null, 0) and gate._any_slot_used())
	gate.free()

	var chains: CampaignSelectScreen = CampaignSelectScreen.new()
	chains.host = host
	chains.setup(_art, _strings, _font)
	# **Sorted.** What a screen offers is the contract; the order the buttons
	# sit in the tree is not one.
	h.equal("screens.both_chains_offered", _sorted(_actions_of(chains)),
		PackedStringArray(["back", "start:1", "start:2"]))
	h.check("screens.base_campaign_has_product_name",
		_labels_of(chains).has(_strings.text("shell.campaign.base")))
	h.check("screens.expansion_has_product_name",
		_labels_of(chains).has(_strings.text("shell.campaign.wilderness")))
	var base_cover: TextureRect = chains.find_child(
		"CampaignCover1", true, false) as TextureRect
	var wilderness_cover: TextureRect = chains.find_child(
		"CampaignCover2", true, false) as TextureRect
	h.check("screens.base_campaign_has_title_card",
		base_cover != null and base_cover.texture != null,
		"Graphics/Title.bmp converted to art/plates/title.png")
	h.check("screens.expansion_has_title_card",
		wilderness_cover != null and wilderness_cover.texture != null,
		"Install/Title.bmp converted to art/plates/wilderness_title.png")
	h.check("screens.campaign_covers_share_four_by_three_frame",
		base_cover != null and wilderness_cover != null
		and base_cover.stretch_mode == TextureRect.STRETCH_SCALE
		and wilderness_cover.stretch_mode == TextureRect.STRETCH_SCALE
		and is_equal_approx(
			(CampaignSelectScreen.CARD_SIZE.x
				- CampaignSelectScreen.CARD_INSET * 2.0)
			/ (base_cover.offset_bottom - base_cover.offset_top),
			CampaignSelectScreen.COVER_ASPECT)
		and base_cover.offset_top == wilderness_cover.offset_top
		and base_cover.offset_bottom == wilderness_cover.offset_bottom,
		"Wilderness is stretched slightly into the base game's 4:3 frame")
	var first_card: Button = chains.find_child(
		"CampaignCard1", true, false) as Button
	var second_card: Button = chains.find_child(
		"CampaignCard2", true, false) as Button
	var base_card_slot: AspectRatioContainer = chains.find_child(
		"CampaignCardSlot1", true, false) as AspectRatioContainer
	var expansion_card_slot: AspectRatioContainer = chains.find_child(
		"CampaignCardSlot2", true, false) as AspectRatioContainer
	h.check("screens.campaign_cards_are_keyboard_linked",
		first_card != null and second_card != null
		and first_card.focus_neighbor_right != NodePath()
		and second_card.focus_neighbor_left != NodePath(),
		"left and right both move between the two choices")
	h.check("screens.campaign_cards_keep_their_aspect",
		base_card_slot != null and expansion_card_slot != null
		and base_card_slot.stretch_mode == AspectRatioContainer.STRETCH_FIT
		and expansion_card_slot.stretch_mode
			== AspectRatioContainer.STRETCH_FIT
		and is_equal_approx(base_card_slot.ratio,
			CampaignSelectScreen.CARD_SIZE.x
			/ CampaignSelectScreen.CARD_SIZE.y)
		and is_equal_approx(expansion_card_slot.ratio,
			base_card_slot.ratio),
		"the cover, caption and border resize as one card")
	_no_missing(h, "campaign_select", chains)
	chains.free()

	var victory: DebriefingScreen = DebriefingScreen.new()
	victory.report = {"result": ScoreRecord.RESULT_WON}
	victory.board = ScoreRecord.new()
	victory.setup(_art, _strings, _font)
	h.equal("screens.victory_can_advance_or_replay", _actions_of(victory),
		PackedStringArray(["advance", "replay"]))
	victory.free()

	var defeat: DebriefingScreen = DebriefingScreen.new()
	defeat.report = {"result": ScoreRecord.RESULT_DEFEAT}
	defeat.board = ScoreRecord.new()
	defeat.setup(_art, _strings, _font)
	h.equal("screens.defeat_offers_a_retry_and_a_load", _actions_of(defeat),
		PackedStringArray(["replay", DebriefingScreen.ACTION_LOAD]),
		"no control can present a lost mission as completed; the remake's "
		+ "own way back is a save (docs/92 section 7.27)")
	var load_caption: PackedStringArray = _button_labels_of(defeat)
	h.equal("screens.defeat_load_wears_the_menus_caption",
		load_caption[load_caption.size() - 1],
		defeat.label_for(CampaignScreen.BANK_MENU, MainMenuScreen.ID_MENU_LOAD_GAME),
		"`Txtmod_a` 104, the main menu's own *Load Game*")
	defeat.free()
	# The win keeps the engine's two: a save is not the way past a mission
	# that has been passed.

	var instant_defeat: DebriefingScreen = DebriefingScreen.new()
	instant_defeat.instant_action = true
	instant_defeat.report = {"result": ScoreRecord.RESULT_DEFEAT}
	instant_defeat.board = ScoreRecord.new()
	instant_defeat.setup(_art, _strings, _font)
	h.equal("screens.instant_action_result_has_two_ways_out",
		_actions_of(instant_defeat),
		PackedStringArray(["instant_levels", "instant_replay"]),
		"Give Up cannot leave a read-only result panel over the map")
	instant_defeat.free()

	var ended: Dictionary = CacheFixture.load_world(CacheFixture.SLICE_MISSION)
	if not ended.is_empty():
		var instant_main: SliceMain = SliceMain.new()
		instant_main._art = _art
		instant_main._strings = _strings
		instant_main.world = ended["world"]
		instant_main.world.game_control.set_slot(4, 1)
		instant_main._instant_action_mission = "_S_004"
		instant_main._check_mission_end()
		var routed: DebriefingScreen = instant_main.screen_shown() \
			as DebriefingScreen
		h.check("screens.instant_action_end_routes_to_actionable_result",
			routed != null and routed.instant_action
			and _actions_of(routed) == PackedStringArray(
				["instant_levels", "instant_replay"]),
			"the result route itself, not only the screen in isolation")
		instant_main.free()

	var list: MissionSelectScreen = MissionSelectScreen.new()
	list.missions = PackedStringArray(["_S_004", "_S_074"])
	list.setup(_art, _strings, _font)
	h.equal("screens.instant_action_selects_before_launching",
		_sorted(_actions_of(list)),
		PackedStringArray(["back", "instant_start", "select_mission:_S_004",
			"select_mission:_S_074"]),
		"Level Options validates a selected map before it builds a battle")
	var instant_labels: PackedStringArray = _button_labels_of(list)
	h.check("screens.instant_action_uses_the_shipped_map_titles",
		instant_labels.has("Spaceport")
		and instant_labels.has("Escort Natalya")
		and not instant_labels.has("_S_004")
		and not instant_labels.has("_S_074"),
		"Mission.lcl ids 4 and 74, while the actions retain both stems")
	h.check("screens.instant_action_remembers_selected_map",
		list.selected == "_S_004" and list.select_mission("_S_074")
		and list.selected == "_S_074" and not list.select_mission("_S_999"),
		"paging and a bad request cannot silently choose a different map")
	h.equal("screens.instant_action_unknown_title_keeps_the_stem",
		list.mission_label("_S_999"), "_S_999",
		"a custom map without a Mission.lcl id stays identifiable")
	_no_missing(h, "mission_select", list)
	list.free()
	var no_maps: MissionSelectScreen = MissionSelectScreen.new()
	no_maps.setup(_art, _strings, _font)
	h.equal("screens.instant_action_empty_cache_has_no_inert_continue",
		_actions_of(no_maps), PackedStringArray(["back"]),
		"a cache without _S maps cannot launch a map")
	no_maps.free()

	var instant_host: CampaignHost = CampaignHost.create(_cache_dir,
		CacheFixture.balance(), _strings)
	var instant_header: Dictionary = {
		"tech_level": 10,
		"skill_level": 12,
		"equip_points": [1500, 0, 0, 0],
	}
	var instant_state: CampaignState = instant_host.start_instant_action(
		"_S_004", instant_header)
	# `aInitGUI` `0x004542A1`: outside a campaign the first screen is the HQ
	# over an **empty** pool, and the map's purse is the player's to spend.
	h.check("instant_action.starts_in_the_hq_with_an_empty_pool",
		instant_host.is_instant_action()
		and instant_state.mode == TurnState.MODE_LOCAL
		and instant_state.player_count == 1
		and instant_state.player_kind[0] == TurnState.KIND_HUMAN
		and instant_state.roster.used_slots() == 0
		and instant_host.nobody_to_deploy()
		and instant_host.screen == CampaignHost.SCREEN_HQ
		and instant_state.tech_level == 10
		and instant_state.skill_level == 12
		and instant_state.points(0) == 1500,
		"the local session uses the selected map's authored setup")
	h.equal("instant_action.catalogue_band_is_the_header_tech_level",
		instant_host.catalogue_band(), Vector2i(CampaignHost.CATALOGUE_LOW, 10),
		"0x0045BF2A's non-campaign arm: 0..techLevel, no base")
	# ...and still that band when the session is **loaded** into a host that
	# was standing on a campaign location: `_S_*` is in no location table,
	# and a load that left the old location standing sold its band.
	instant_host.save_dir = "%s/instant" % SCRATCH_DIR
	h.check("instant_action.session_saves", instant_host.save(null, 2))
	var _campaign: CampaignState = instant_host.start_new(2)
	var _at_a_base: Dictionary = instant_host.click_location(
		instant_host.open_locations()[0])
	h.check("instant_action.a_campaign_location_was_standing",
		instant_host.location != 0)
	var back: Dictionary = instant_host.load_save(2)
	h.equal("instant_action.load_resets_the_location",
		[CampaignCodec.result_name(DictRead.as_int(back["result"])),
			instant_host.location, instant_host.catalogue_band()],
		["OK", 0, Vector2i(CampaignHost.CATALOGUE_LOW, 10)])
	instant_state = instant_host.start_instant_action("_S_004",
		instant_header)
	h.check("instant_action.hires_through_the_recruit_window",
		instant_host.recruits_through_a_screen(),
		"0x0045B7F8 opens 0x00456640 outside mode 1")
	var instant_hq: UnitMenuScreen = UnitMenuScreen.new()
	instant_hq.host = instant_host
	instant_hq.setup(_art, _strings, _font)
	var instant_hq_actions: PackedStringArray = _actions_of(instant_hq)
	h.check("instant_action.hq_deploys_and_returns_to_levels",
		instant_hq_actions.has("deploy")
		and instant_hq_actions.has("instant_levels")
		and not instant_hq_actions.has("map"),
		"a local session has no campaign map for Back to open")
	h.check("instant_action.hq_deploy_is_off_over_an_empty_pool",
		instant_hq._deploy != null and instant_hq._deploy.disabled,
		"0x004579A3 disables gadget 2 while the pool is empty")
	# The Recruit window's row: preset 11, *Light Infantry* (weapon 2, item
	# 10, EP 96, markup 50), at its own price rather than the campaign's 60.
	var hire: Dictionary = instant_host.recruit_preset(11)
	var hired: int = DictRead.as_int(hire["slot"])
	var instant_recruit: UnitState = instant_state.roster.record(hired)
	instant_hq.refresh()
	h.check("instant_action.a_preset_hire_arms_deploy",
		DictRead.as_string(hire["result"]) == Upgrade.OK
		and instant_state.points(0) == 1500 - instant_host.preset_price(11)
		and instant_recruit != null
		and instant_recruit.type_id == CampaignState.PRESET_UNIT_TYPE
		and instant_recruit.weapon == 2 and instant_recruit.ep == 96
		and not instant_hq._deploy.disabled,
		"a type-0 soldier the model selector has a body for")
	var window: RecruitScreen = RecruitScreen.new()
	window.host = instant_host
	window.setup(_art, _strings, _font)
	h.check("instant_action.recruit_rows_are_presets",
		window.presets_in(0) == PackedInt32Array([0, 1, 2, 3])
		and window.presets_in(3) == PackedInt32Array([30, 31, 32, 33, 35])
		and window.load_out_line(11).begins_with(
			str(instant_host.preset_price(11))),
		"the five lists of 0x004561C9, priced per row")
	_no_missing(h, "recruit", window)
	window.free()
	instant_hq.free()
	# The HQ stands over the mission before anybody is deployed, and takes no
	# entry snapshot until *Deploy units*; Back from a turn-0 map restores
	# the pool and lands in the HQ, not on a map the session does not have.
	var instant_world: World = World.create(CacheFixture.mission("_C_141"),
		CacheFixture.balance(), 0.0)
	var _swept: int = instant_world.load_sweep()
	instant_host.frame_mission(instant_world)
	var landings: Array[Vector2i] = instant_world.deployment_cells(0)
	h.check("instant_action.hq_counts_the_mission_placefields",
		not landings.is_empty()
		and instant_host.deployment_cells().size() == landings.size()
		and instant_state.roster.used_slots(Roster.ROW_SNAPSHOT) == 0,
		"frame_mission gives the counter a map and keeps the snapshot empty")
	# A placement before *Deploy units* -- the agent's `deploy` verb from the
	# HQ -- is refused: nothing may leave the live row before the snapshot.
	var early: Dictionary = instant_host.deploy(hired,
		landings[0].x if not landings.is_empty() else 0,
		landings[0].y if not landings.is_empty() else 0)
	h.check("instant_action.no_deployment_from_the_hq",
		DictRead.as_string(early["result"]) == World.DEPLOY_EMPTY_RECORD
		and instant_state.roster.used_slots() == 1
		and not instant_host.deploying(),
		"deploy() is turn 0's alone, past begin_mission")
	# The picture agrees with the host: the HQ frames a turn-0 world, but
	# the place interface -- the dots, `/state.deployment` -- is not up
	# until the mission is the screen. And a load of a turn-0 *Instant
	# Action* save takes the interface even over an empty pool: `0x0041A073`'s
	# skip is a campaign game's (`gameMode() == 1`), and the world's own
	# `skip_deployment_turn` would do nothing here.
	var hq_main: SliceMain = SliceMain.new()
	hq_main.world = instant_world
	hq_main.campaign = instant_host
	# What `_build` writes for an *Instant Action* session (`ArenaMode`).
	instant_world.turn.mode = TurnState.MODE_LOCAL
	h.check("instant_action.hq_is_not_deploying",
		instant_world.deploying() and not hq_main._deploying()
		and not DictRead.as_bool(hq_main.deployment_view()["active"]),
		"the counter says turn 0; the host says the HQ is the screen")
	h.check("instant_action.no_silent_arm_for_a_local_game",
		not hq_main._may_skip_deployment()
		and instant_world.turn.mode != TurnState.MODE_CAMPAIGN,
		"0x0041A073 tests gameMode() == 1 first")
	hq_main.free()
	instant_host.begin_mission(instant_world)
	h.check("instant_action.begin_mission_enters_the_mission",
		instant_host.screen == CampaignHost.SCREEN_MISSION
		and instant_host.deploying(),
		"there is no screen between the HQ and the turn-0 map")
	var placed: String = ""
	if not landings.is_empty():
		placed = DictRead.as_string(instant_host.deploy(hired,
			landings[0].x, landings[0].y)["result"])
		# And back, through the host: the record returns to the live row.
		var recalled: Dictionary = instant_host.recall(landings[0].x,
			landings[0].y)
		h.check("instant_action.recall_puts_the_soldier_back",
			DictRead.as_string(recalled["result"]) == World.RECALL_OK
			and instant_state.roster.used_slots() == 1
			and instant_state.roster.record(
				DictRead.as_int(recalled["slot"])) != null,
			"aTransferUnitFromMapToPool, the pool insertion being the host's")
		placed = DictRead.as_string(instant_host.deploy(
			DictRead.as_int(recalled["slot"]),
			landings[0].x, landings[0].y)["result"])
		# Past turn 0 the interface is down and the host refuses both.
		instant_world.turn.turn = TurnState.FIRST_TURN
		h.check("instant_action.no_deployment_past_turn_zero",
			DictRead.as_string(instant_host.deploy(hired, landings[0].x,
				landings[0].y)["result"]) == World.DEPLOY_EMPTY_RECORD
			and DictRead.as_string(instant_host.recall(landings[0].x,
				landings[0].y)["result"]) == World.RECALL_NO_UNIT
			and not instant_host.deploying(),
			"fcn.00463380 returns at once when the counter is not 0")
	# A save taken here holds the placed soldier in the snapshot row only;
	# a load without the battle blob has to put him back before the HQ reads
	# the live row, or the next *Deploy units* restores the snapshot over
	# whoever was hired in between.
	var settled: CampaignState = CampaignCodec.decode(
		CampaignCodec.encode(instant_state))["state"]
	var settle_host: CampaignHost = CampaignHost.create(_cache_dir,
		CacheFixture.balance(), _strings)
	settle_host.state = settled
	settle_host.settle_after_load()
	h.check("instant_action.load_without_battle_settles_the_rows",
		placed == World.DEPLOY_OK
		and settled.roster.used_slots() == 1
		and settled.roster.used_slots(Roster.ROW_SNAPSHOT) == 0
		and settle_host.screen == CampaignHost.SCREEN_HQ
		and not settle_host.nobody_to_deploy(),
		"the deployed soldier is back in the pool the HQ shows")
	instant_host.abandon_mission()
	h.check("instant_action.back_from_deployment_returns_to_hq",
		placed == World.DEPLOY_OK
		and instant_host.screen == CampaignHost.SCREEN_HQ
		and instant_state.roster.used_slots() == 1
		and instant_state.roster.used_slots(Roster.ROW_SNAPSHOT) == 0,
		"the squad is back in the pool and the screen is the HQ")
	var loaded_local: SliceMain = SliceMain.new()
	loaded_local.campaign = instant_host
	loaded_local._remember_loaded_session()
	h.equal("instant_action.load_restores_result_route",
		loaded_local._instant_action_mission, "_S_004",
		"a saved local battle must not end through campaign progression")
	instant_state.mode = TurnState.MODE_CAMPAIGN
	loaded_local._remember_loaded_session()
	h.equal("instant_action.campaign_load_clears_result_route",
		loaded_local._instant_action_mission, "",
		"a later campaign load cannot retain an Instant Action latch")
	loaded_local.free()

	var slots: SaveSlotsScreen = SaveSlotsScreen.new()
	slots.host = host
	slots.mode = ShellHost.MODE_LOAD
	slots.setup(_art, _strings, _font)
	# One page of rows, the way out, and the listbox's own two arrows -- the
	# count is 24 and a shipped listbox is paged rather than scrolled.
	h.equal("screens.one_page_of_slots", _actions_of(slots).size(),
		SaveSlotsScreen.LIST_ROWS + 3,
		"twelve rows, the way out and the two arrows")
	h.check("screens.slots_are_paged",
		CampaignHost.SLOT_COUNT > SaveSlotsScreen.LIST_ROWS
		and _sorted(_actions_of(slots)).has("scroll_down"),
		"a list longer than a page carries the arrows that turn it")
	var rows: PackedStringArray = _button_labels_of(slots)
	h.check("screens.empty_slot_is_txtmod_f_1",
		_any_ends_with(rows, _strings.shipped("Txtmod_f", 1)), str(rows))
	h.check("screens.empty_row_refuses_a_load",
		_disabled_count(slots) == SaveSlotsScreen.LIST_ROWS,
		"there is nothing behind an empty row, so it is refused at the row")
	var first_slot: Button = null
	for candidate: Button in _buttons_of(slots):
		for connection: Dictionary in candidate.pressed.get_connections():
			var callback: Callable = connection["callable"]
			if callback.get_bound_arguments() == ["slot:0"]:
				first_slot = candidate
	if first_slot == null:
		h.check("screens.slot_sound_row_exists", false, "slot:0")
	else:
		var hover_callback: Callable = \
			first_slot.mouse_entered.get_connections()[0]["callable"]
		var activate_callback: Callable = \
			first_slot.button_down.get_connections()[0]["callable"]
		h.equal("screens.slot_selection_sound",
			hover_callback.get_bound_arguments(),
			[SaveSlotsScreen.SOUND_SELECTION_CHANGED])
		h.equal("screens.slot_activation_sound",
			activate_callback.get_bound_arguments(),
			[SaveSlotsScreen.SOUND_ACTIVATE])
	# The second page is the slots the first one does not reach, and its rows
	# are still rows: a paged list that lost its actions would offer the
	# player twelve of the twenty-four.
	slots.scroll(1)
	h.equal("screens.second_page_is_the_rest", _actions_of(slots).size(),
		mini(CampaignHost.SLOT_COUNT - SaveSlotsScreen.LIST_ROWS,
			SaveSlotsScreen.LIST_ROWS) + 3)
	h.check("screens.second_page_names_a_later_slot",
		_joined(slots).contains(_strings.text("shell.slot")
			% (SaveSlotsScreen.LIST_ROWS + 1)),
		"the arrows turn a page, they do not scroll a row")
	slots.scroll(-1)
	_no_missing(h, "slots_load", slots)
	slots.free()

	var saving: SaveSlotsScreen = SaveSlotsScreen.new()
	saving.host = host
	saving.mode = ShellHost.MODE_SAVE
	saving.may_save = true
	saving.setup(_art, _strings, _font)
	h.equal("screens.every_row_takes_a_save", _disabled_count(saving), 0)
	h.check("screens.save_mode_is_titled_save",
		_labels_of(saving).has(_strings.shipped("Txtmod_f", 11)),
		"`Txtmod_f` 11, not 10 -- one screen, two modes")
	# **A row in save mode names the save before it writes it.** The click
	# opens the field; nothing is emitted until the field is submitted, which
	# is what stops a click meant for one row overwriting it unnamed.
	var emitted: Array[String] = []
	saving.chose.connect(func(action: String) -> void: emitted.append(action))
	saving._on_pressed("slot:3")
	h.equal("screens.save_click_opens_the_field", [saving.naming, emitted],
		[3, []], "the write waits for the name")
	saving.commit_name(3, "  Before the bridge  ")
	h.equal("screens.submitted_name_is_trimmed_and_emitted",
		[saving.typed_name, emitted, saving.naming],
		["Before the bridge", ["slot:3"], -1])
	saving.begin_naming(4)
	saving.cancel_name()
	h.equal("screens.leaving_the_field_cancels",
		[saving.naming, saving.typed_name, emitted.size()], [-1, "", 1],
		"a save is a write over a file, so an abandoned field writes nothing")
	# The one link between the field and the file, which the rest of the path
	# only exercises with a whole `SliceMain` on a tree.
	saving.typed_name = "After the lift"
	h.equal("screens.the_writer_reads_the_field",
		SliceMain.slot_name_of(saving), "After the lift")
	var other: CampaignScreen = MissionSelectScreen.new()
	h.equal("screens.another_screen_names_nothing",
		[SliceMain.slot_name_of(other), SliceMain.slot_name_of(null)],
		["", ""],
		"a cast that answered a name for any screen would name the wrong one")
	other.free()
	_no_missing(h, "slots_save", saving)
	saving.free()

	var options: OptionsScreen = OptionsScreen.new()
	options.settings = settings
	options.language = _strings.language
	options.setup(_art, _strings, _font)
	h.equal("screens.options_off_the_map", _sorted(_actions_of(options)),
		PackedStringArray(["back", "option:controls", "option:difficulty", "option:faithful",
		"option:font", "option:gore", "option:graphics"]),
		"the four the original has and this remake connects, plus the gore "
		+ "level, the `Faithful` preset, the interface font and the texture "
		+ "sampling; not one of "
		+ "the four it has and this remake does not -- and no language row "
		+ "for a cache with one language")
	# The language becomes a row when the cache offers a second one, and
	# only out of a mission: a switch reloads the scene (docs/92 section 7.6).
	var bilingual: OptionsScreen = OptionsScreen.new()
	bilingual.settings = settings
	bilingual.language = "English"
	bilingual.languages = PackedStringArray(["English", "Russian"])
	bilingual.setup(_art, _strings, _font)
	h.check("screens.options_language_row_with_two_languages",
		_actions_of(bilingual).has("option:language"),
		"a selector with two entries is a control")
	_no_missing(h, "options_bilingual", bilingual)
	# **The longest the screen gets** -- off the map with the difficulty row,
	# and a second language -- still ends above *Back*: the texture row made
	# it one row longer than the old spacing had room for.
	var lowest: float = 0.0
	var back_top: float = 1.0
	for button: Button in _buttons_of(bilingual):
		for connection: Dictionary in button.pressed.get_connections():
			var callable: Callable = connection["callable"]
			var bound: Array = callable.get_bound_arguments()
			if bound.is_empty() or typeof(bound[0]) != TYPE_STRING:
				continue
			var action: String = bound[0]
			if action == "back":
				back_top = minf(back_top, button.anchor_top)
			elif action.begins_with("option:"):
				lowest = maxf(lowest, button.anchor_bottom)
	h.check("screens.options_rows_end_above_back", lowest <= back_top,
		"the last field's bottom %.3f against Back's top %.3f"
		% [lowest, back_top])
	bilingual.free()
	var paused_bilingual: OptionsScreen = OptionsScreen.new()
	paused_bilingual.settings = settings
	paused_bilingual.in_mission = true
	paused_bilingual.language = "English"
	paused_bilingual.languages = PackedStringArray(["English", "Russian"])
	paused_bilingual.setup(_art, _strings, _font)
	h.check("screens.no_language_row_in_a_mission",
		not _actions_of(paused_bilingual).has("option:language"),
		"the reload would drop an unsaved mission; the line stays a line")
	paused_bilingual.free()
	_language_switch(h, settings)
	var sliders: Array[HSlider] = _sliders_of(options)
	h.equal("screens.options_volume_sliders", sliders.size(), 3,
		"music, FX and speech are direct controls rather than click-to-cycle "
		+ "fields")
	var slider_shape: Array[Variant] = []
	for slider: HSlider in sliders:
		slider_shape.append([slider.name, slider.min_value, slider.max_value,
			slider.step, slider.value])
	h.equal("screens.options_volume_ranges", slider_shape, [
		[&"music_volume", float(GameSettings.VOLUME_MIN),
			float(GameSettings.VOLUME_MAX), float(GameSettings.VOLUME_STEP),
			float(settings.music_volume)],
		[&"fx_volume", float(GameSettings.VOLUME_MIN),
			float(GameSettings.VOLUME_MAX), float(GameSettings.VOLUME_STEP),
			float(settings.fx_volume)],
		[&"speech_volume", float(GameSettings.VOLUME_MIN),
			float(GameSettings.VOLUME_MAX), float(GameSettings.VOLUME_STEP),
			float(settings.speech_volume)]],
		"the saved attenuation is the thumb position, including the -6 dB default")
	var styled_sliders: int = 0
	for slider: HSlider in sliders:
		var track: StyleBoxTexture = slider.get_theme_stylebox("slider") \
			as StyleBoxTexture
		var grabber: Texture2D = slider.get_theme_icon("grabber")
		if slider.has_theme_stylebox_override("slider") \
				and slider.has_theme_stylebox_override("grabber_area") \
				and slider.has_theme_stylebox_override("grabber_area_highlight") \
				and slider.has_theme_icon_override("grabber") \
				and slider.has_theme_icon_override("grabber_highlight") \
				and track != null \
				and track.get_minimum_size().y >= 32.0 \
				and grabber.get_height() == OptionsScreen.VOLUME_GRABBER_HEIGHT \
				and track.get_expand_margin(SIDE_LEFT) \
					== OptionsScreen.VOLUME_FRAME_INSET \
				and track.get_expand_margin(SIDE_RIGHT) \
					== OptionsScreen.VOLUME_FRAME_INSET:
			styled_sliders += 1
	h.equal("screens.options_volume_sliders_use_the_game_face",
		styled_sliders, 3,
		"the shipped field and arrow replace Godot's default blue control")
	var changed: Array[Variant] = []
	options.volume_changed.connect(func(channel: String, hundredths: int) -> void:
		changed.append([channel, hundredths]))
	var fx_slider: HSlider = null
	for slider: HSlider in sliders:
		if slider.name == &"fx_volume":
			fx_slider = slider
			break
	if fx_slider != null:
		# These screens are deliberately built off-tree; a Range only emits
		# automatically while it is live, so drive the same signal the thumb
		# emits rather than pretending an off-tree property assignment is UI.
		fx_slider.value_changed.emit(-2000.0)
	h.equal("screens.options_volume_change_is_visible_and_emitted",
		[changed, _joined(options).contains("50%")],
		[[["fx", -2000]], true],
		"the host can apply/save the new level and the row answers beside it")
	# The shipped bitmap font is a bitmap: it cannot be antialiased and cannot
	# be scaled, so past the 640x480 base it is drawn at hard-edged multiples.
	# Both answers are real, and the readable one is what a fresh settings
	# file gives.
	h.check("settings.readable_font_by_default", not settings.game_font,
		"the one place fidelity is traded for comfort by default")
	h.check("screens.options_offer_the_graphics_preset",
		_actions_of(options).has("option:graphics")
		and _joined(options).contains(_strings.text("shell.graphics.0")),
		"docs/92 section 7.29 -- the row exists and shows the original")
	# **The restriction is a hint, not a caption.** `Txtmod_h` 58 -- *Set
	# Difficulty Level (only in main map during campaign)* -- is a sentence,
	# and the caption column ends where the value field begins, so as a
	# caption it ran under the field and was cut mid-word. It is still said,
	# on the row's own control.
	h.check("screens.options_name_the_restriction",
		_hints_of(options).has(_strings.shipped("Txtmod_h", 58)),
		"`Txtmod_h` 58 is the difficulty field's hover hint")
	h.check("screens.options_caption_is_the_short_one",
		_joined(options).contains(_strings.shipped("Txtmod_h", 53)),
		"`Txtmod_h` 53, *Set Difficulty Level*, is what the row is called")
	# **And the hint is drawn at the plate's scale.** Godot's tooltip is a
	# popup embedded in this viewport, so the canvas stretch scales it and the
	# theme's default 16 is 16 *plate units* -- half again the largest caption
	# on the screen. `_make_custom_tooltip` is the only seam that reaches it.
	var carrier: HintControl = _first_hint(options)
	var built: Control = carrier._make_custom_tooltip("x") if carrier != null \
		else null
	var worded: Label = built.get_child(0) as Label if built != null else null
	h.check("screens.hint_is_drawn_at_plate_scale",
		worded != null and (worded.has_theme_font_override("font")
			or worded.get_theme_font_size("font_size")
				<= CampaignScreen.readable_size(CampaignScreen.FNT_LABEL)),
		"the hint takes the screen's own face, not the theme's default size")
	if built != null:
		built.free()
	_no_missing(h, "options", options)
	options.free()

	var on_map: OptionsScreen = OptionsScreen.new()
	on_map.settings = settings
	on_map.campaign_difficulty = 2
	on_map.language = _strings.language
	on_map.setup(_art, _strings, _font)
	h.check("screens.options_on_the_map_show_the_campaign's",
		_joined(on_map).contains(_strings.text("shell.difficulty.2")),
		"S6 -- the campaign is the authority while the player is on its map")
	on_map.free()

	var in_mission: OptionsScreen = OptionsScreen.new()
	in_mission.settings = settings
	in_mission.in_mission = true
	in_mission.language = _strings.language
	in_mission.setup(_art, _strings, _font)
	h.check("screens.no_difficulty_row_in_a_mission",
		not _actions_of(in_mission).has("option:difficulty"),
		"`ai_level` is in the canonical hash, so a running mission's "
		+ "difficulty is not writable at all")
	in_mission.free()

	# **The action row fits inside its own plate.** The screens are laid out
	# in the plate's 640x480 units, and a container sized the row's buttons
	# from their minimum -- a `buttons.LIB` face plus *Enter Location* is ~144
	# of those units -- put the briefing's *Main Map* 116 units past the right
	# edge of the frame it is drawn on.
	var wide: BriefingScreen = BriefingScreen.new()
	wide.mission = "_C_100"
	wide.paths = _paths
	wide.document = CacheFixture.read_json(
		"%s/text/briefing/_C_100.json" % _cache_dir)
	wide.setup(_art, _strings, _font)
	var overflow: PackedStringArray = PackedStringArray()
	for button: Button in _buttons_of(wide):
		if button.anchor_right > 1.0 or button.anchor_left < 0.0:
			overflow.append(button.text)
	h.equal("screens.the_action_row_fits_the_plate", overflow,
		PackedStringArray(), "the row divides 640 units by however many")
	# **Three, as the original has**: *Back*, the tips toggle and *Continue*.
	# It carried five while `B0` had a button of its own, and docs/24
	# section 7.1's call sites put `B0` on the unit-selection and map screens
	# and never on this one.
	h.equal("screens.the_briefing_has_three", _buttons_of(wide).size(), 3,
		"docs/24 section 7.1 -- this screen asks for `A0` and `C0` only")
	# One screen, two blocks: the middle button swaps the caption `Txtmod_b`
	# carries twice for exactly this.
	h.equal("screens.the_briefing_opens_on_a0", wide.block, "A0")
	wide.show_block("C0")
	var toggled: PackedStringArray = _labels_of(wide)
	h.check("screens.the_tips_button_offers_the_briefing_back",
		toggled.has(_strings.shipped("Txtmod_b", 32)),
		"`Txtmod_b` 32 is the word for the way back")
	wide.free()

	# A list rebuilt **from inside one of its own rows** keeps every row.
	# Godot locks an object while it is emitting, so the `free` these
	# refreshes used failed silently: the row survived off the list and the
	# rebuild lost every row after it. Live, one click on the difficulty row
	# took the two volume rows above it away.
	var rebuilt: OptionsScreen = OptionsScreen.new()
	rebuilt.settings = settings
	rebuilt.language = _strings.language
	rebuilt.setup(_art, _strings, _font)
	var rows_before: int = _buttons_of(rebuilt).size()
	var first: Button = _buttons_of(rebuilt)[0]
	first.pressed.connect(rebuilt.refresh)
	first.pressed.emit()
	h.equal("screens.a_row_may_rebuild_its_own_list",
		_buttons_of(rebuilt).size(), rows_before,
		"`clear_children` removes before it frees, so the deferred delete "
		+ "cannot fail on a locked emitter")
	rebuilt.free()

	# **The campaign map offers the options**, which is the one place
	# `Txtmod_h` 58 says the difficulty is editable. Without a way in from
	# there the shipped caption named a place the player could not reach, and
	# the branch that writes the campaign's own difficulty was dead.
	var map: CampaignMapScreen = CampaignMapScreen.new()
	map.host = host
	map.setup(_art, _strings, _font)
	h.check("screens.the_map_offers_the_options",
		_actions_of(map).has("options"),
		"%s" % str(_actions_of(map)))
	_no_missing(h, "map", map)
	map.free()

	# The one hole in the gate, closed: a screen with no catalogue used to
	# answer a bare `module/id`, which reads as a caption and slipped straight
	# past a check on the missing marker.
	var blind: MainMenuScreen = MainMenuScreen.new()
	blind.setup(_art, null, _font)
	var unmarked: PackedStringArray = PackedStringArray()
	for line: String in _labels_of(blind):
		if not line.begins_with(Localization.MISSING_PREFIX):
			unmarked.append(line)
	h.equal("screens.no_catalogue_marks_every_caption", unmarked,
		PackedStringArray(),
		"`label_for` and `strings_own` both take the marker when there is "
		+ "nothing to read")
	blind.free()


## The place interface -- turn 0 inside the mission, docs/43 section 5.5.
##
## The screen it replaced refused in total silence: a landing cell clicked
## with no soldier picked did nothing, and *Continue* on an empty map did
## nothing. Every refusal is a line on the HUD's caption label now, and this
## is what keeps it one -- and what pins the original's own rules: the pool's
## first record selected on entry, the facing by the quadrant of the click,
## the take-back, the band's wraps and the clamp after a placement.
func _deployment_mode(h: TestHarness) -> void:
	var host: CampaignHost = _host("deploy")
	var _state: CampaignState = host.start_new(1)
	var built: Dictionary = CacheFixture.load_world(host.state.mission)
	if built.is_empty():
		h.check("deploy.mission_present", false,
			"the cache has no " + host.state.mission)
		return
	var world: World = built["world"]
	var cells: Array[Vector2i] = world.deployment_cells(0)
	if cells.size() < 2:
		h.check("deploy.cells_present", false, "fewer than two landing cells")
		return

	# **Campaign 2 starts with nobody to deploy, and that is the data.**
	# `aCreateUnitPoolForCampaign(2)` is a bare return and `_C_140` places its
	# own squad, so the interface would open on a pool of nobody. `SliceMain`
	# skips turn 0 there and only there.
	h.check("deploy.chain_1_has_a_squad", not host.nobody_to_deploy(),
		"%d in the pool" % host.state.roster.occupied_slots().size())
	var empty_host: CampaignHost = _host("deploy2")
	var _two: CampaignState = empty_host.start_new(2)
	h.check("deploy.chain_2_has_none", empty_host.nobody_to_deploy(),
		"docs/27 section 3.1 -- the pool creator's arm for campaign 2 returns")

	var paths: CachePaths = CacheFixture.paths()
	var hud: MissionHud = MissionHud.new()
	hud.setup(_art, _strings, GameFont.load_from(paths, "font_2"),
		GameFont.load_from(paths, MissionHud.TEXT_FONT),
		GameFont.load_from(paths, MissionHud.SMALL_FONT), paths,
		CacheFixture.balance())
	var main: SliceMain = SliceMain.new()
	main.world = world
	main.campaign = host
	main._strings = _strings
	main._hud = hud
	var cycled: Array[int] = []
	hud.panel_cycled.connect(func(step: int) -> void: cycled.append(step))
	host.begin_mission(world)
	h.check("deploy.begin_mission_is_the_mission",
		host.screen == CampaignHost.SCREEN_MISSION and main._deploying(),
		"no screen between the briefing and the turn-0 map")
	main._enter_deployment()

	# `aInitPlaceInterface`: the pool's first record is selected, the line
	# says what a click does, the panel shows the record and its band takes
	# clicks.
	var slots: PackedInt32Array = host.state.roster.occupied_slots()
	h.equal("deploy.opens_with_the_first_picked", main._deploy_slot, slots[0])
	h.equal("deploy.opens_with_a_hint", hud.line_text(),
		_strings.text("deploy.hint"))
	h.check("deploy.panel_shows_the_record",
		hud.panel.icon_count() > 0 and hud.panel.cycling(),
		"fcn.00463730 feeds the pool record to 0x004756D0")
	var first_name: String = host.state.roster.record(slots[0]).name
	h.check("deploy.panel_names_the_record",
		" ".join(hud.panel.texts()).contains(first_name), first_name)
	h.check("deploy.nothing_selected_on_the_map", main._selected < 0,
		"fcn.00471E00 refuses before the first hand-over")
	h.check("deploy.next_unit_is_dark",
		not main._event_available(HudTables.EVENT_NEXT_UNIT)
		and main._event_available(HudTables.EVENT_NEXT_PLAYER),
		"Tab is refused on turn 0; Next player is lit and answers with a line")

	# The band: previous wraps to the last, next to the first, and the
	# panel follows the selection.
	h.check("deploy.next_cycles", main.cycle_deploy_slot(Deployment.NEXT)
		and main._deploy_slot == slots[1])
	h.check("deploy.previous_cycles_back",
		main.cycle_deploy_slot(Deployment.PREV)
		and main._deploy_slot == slots[0])
	h.check("deploy.previous_wraps_to_the_last",
		main.cycle_deploy_slot(Deployment.PREV)
		and main._deploy_slot == slots[slots.size() - 1],
		"0x0046363D: index 0 goes to count - 1")
	h.check("deploy.next_wraps_to_the_first",
		main.cycle_deploy_slot(Deployment.NEXT)
		and main._deploy_slot == slots[0],
		"0x004636B7: count - 1 goes to 0")
	var pressed: InputEventMouseButton = InputEventMouseButton.new()
	pressed.button_index = MOUSE_BUTTON_LEFT
	pressed.pressed = true
	hud.panel._cycle_zones[1].gui_input.emit(pressed)
	h.equal("deploy.the_band_reaches_the_host", cycled, [Deployment.NEXT],
		"the panel's next half raises panel_cycled")
	main._deploy_slot = slots[0]

	# *Next player* with nobody on the map: refused, with a line, on turn 0
	# -- and refused **before** the press is heard. The refusal is the
	# remake's own, and a `click_2` in front of it read as a press that
	# then thought better of itself.
	var ears: ClickRecorder = ClickRecorder.new()
	ears._tables = AudioTables.open(_paths)
	main._audio = ears
	main._play_interface(AudioTables.INTERFACE_COLUMN_PRESS)
	h.equal("deploy.the_recorder_hears_a_press", ears.plays.size(), 1,
		"the double answers the cue table, so a silence below is a result")
	ears.plays.clear()
	h.check("deploy.may_not_start_empty", not host.may_start())
	main._on_hud_event(HudTables.EVENT_NEXT_PLAYER)
	h.check("deploy.an_empty_map_says_so",
		world.turn.turn == 0 and hud.line_text() == _strings.text("deploy.need_one"),
		"named, not silent (docs/92 section 7.4); the original hands over "
		+ "and loses by wipeout")
	h.equal("deploy.the_refusal_is_not_a_press", ears.plays.size(), 0,
		"no click_2 in front of the line")
	main._audio = null
	ears.free()

	# A click off the landing zone, and one on it: the quadrant sets the
	# facing (left-bottom is 4), the record leaves the live row, the
	# selection clamps to the same index.
	main.deploy_cell(Vector2i(-1, -1), Vector2(100.0, 400.0))
	h.equal("deploy.a_non_cell_says_so", hud.line_text(),
		_strings.text("deploy.not_a_deployment_cell"))
	var before: int = host.state.roster.used_slots()
	var expected_next: int = slots[1]
	h.check("deploy.a_click_places", main.deploy_cell(cells[0],
		Vector2(100.0, 400.0)))
	h.equal("deploy.the_record_left_the_row",
		host.state.roster.used_slots(), before - 1)
	var view: Dictionary = world.cell_view(cells[0].x, cells[0].y)
	var placed_slot: int = DictRead.as_int(view["unit"])
	h.check("deploy.the_soldier_stands_there", placed_slot != MapState.NO_UNIT)
	if placed_slot != MapState.NO_UNIT:
		h.equal("deploy.faces_by_the_quadrant",
			DictRead.as_int(world.unit_view(placed_slot)["facing"]), 4,
			"x < 320, y >= 240 -> 4 (0x00463572/75)")
	h.equal("deploy.selection_clamps_to_the_same_index", main._deploy_slot,
		expected_next, "0x004635E3..0x00463605")
	h.check("deploy.may_start_now", host.may_start()
		and main._may_leave_deployment())
	var stamped: Dictionary[Vector2i, int] = GroundSprites.cell_states(world,
		-1, null, {}, 0)
	h.check("deploy.the_dots_stay_on_an_occupied_cell",
		stamped.has(cells[0]) and stamped[cells[0]] == HudTables.STATE_DEPLOY_FIRST,
		"markDeploymentCells marks every cell of the player's, occupied too")
	# The other quadrants.
	h.equal("deploy.quadrant_facings", [
		Deployment.facing_for(Vector2(10.0, 10.0), Vector2(640.0, 480.0)),
		Deployment.facing_for(Vector2(630.0, 10.0), Vector2(640.0, 480.0)),
		Deployment.facing_for(Vector2(630.0, 470.0), Vector2(640.0, 480.0)),
		Deployment.facing_for(Vector2(10.0, 470.0), Vector2(640.0, 480.0))],
		[6, 5, 7, 4])

	# The take-back: a click on the placed soldier puts him back into the
	# live row and the cell is free again.
	h.check("deploy.a_click_on_the_soldier_takes_him_back",
		main.deploy_cell(cells[0], Vector2(100.0, 400.0)))
	h.equal("deploy.the_record_is_back", host.state.roster.used_slots(), before)
	h.equal("deploy.the_cell_is_free_again",
		DictRead.as_int(world.cell_view(cells[0].x, cells[0].y)["unit"]),
		MapState.NO_UNIT)

	# Everyone placed: the selection is nobody, the line says so, and a
	# click on a free cell says so too rather than doing nothing.
	var placed: int = 0
	for index: int in range(slots.size()):
		if index >= cells.size():
			break
		if main.deploy_cell(cells[index], Vector2(400.0, 100.0)):
			placed += 1
	h.check("deploy.everyone_placed", placed == mini(slots.size(), cells.size()))
	if placed == slots.size():
		h.equal("deploy.nobody_left_to_pick", main._deploy_slot, Roster.NO_SLOT,
			"0x004635EF: an emptied pool selects nobody")
		h.equal("deploy.an_empty_pool_says_so", hud.line_text(),
			_strings.text("deploy.pool_empty"))
		h.check("deploy.the_band_is_inert_with_nobody",
			not main.cycle_deploy_slot(Deployment.NEXT),
			"the original's je 0x46371d")
		if cells.size() > placed:
			h.check("deploy.a_free_cell_with_nobody_is_refused",
				not main.deploy_cell(cells[placed], Vector2(400.0, 100.0))
				and hud.line_text() == _strings.text("deploy.pool_empty"))
		# And one back, which re-arms the selection (`0x004634EF`).
		h.check("deploy.a_take_back_re_arms_the_selection",
			main.deploy_cell(cells[0], Vector2(100.0, 400.0))
			and main._deploy_slot != Roster.NO_SLOT
			and hud.panel.cycling())

	# The agent's arms carry the interface's bookkeeping: a placement of a
	# record other than the selected one keeps the selection, a take-back
	# with nobody selected re-arms it, and a placement of the selected one
	# clamps as a click's does.
	if placed == slots.size() and cells.size() >= 2 and slots.size() >= 2:
		var kept: int = main._deploy_slot
		var shown_before: Dictionary[int, int] = main._picture_fog()
		var back: Dictionary = main.recall_at(cells[1].x, cells[1].y)
		# A take-back rebuilds no fog in the original: whatever the picture
		# showed stands (docs/43 section 5.5).
		var shown_after: Dictionary[int, int] = main._picture_fog()
		var moved: int = 0
		for fog_slot: int in shown_after:
			if shown_before.has(fog_slot) \
					and shown_after[fog_slot] != shown_before[fog_slot]:
				moved += 1
		h.check("deploy.a_take_back_keeps_the_fog",
			moved == 0 and not main._fog._held.is_empty(),
			"%d slot(s) changed; the hold is engaged" % moved)
		var other: int = DictRead.as_int(back["slot"])
		h.check("deploy.agent_recall_keeps_the_selection",
			DictRead.as_string(back["result"]) == World.RECALL_OK
			and main._deploy_slot == kept and other != kept,
			"0x004634EF: anyone still selected stays")
		var elsewhere: Dictionary = main.place_from_roster(other, cells[1].x,
			cells[1].y, 5)
		h.check("deploy.a_placement_releases_the_hold",
			main._fog._held.is_empty(), "0x00478DE4's fog pass is the fresh one")
		h.check("deploy.agent_places_another_and_keeps_the_selection",
			DictRead.as_string(elsewhere["result"]) == World.DEPLOY_OK
			and main._deploy_slot == kept
			and DictRead.as_int(world.unit_view(
				DictRead.as_int(elsewhere["slot"]))["facing"]) == 5,
			"the panel still shows the record the click would place")
		var _again: Dictionary = main.recall_at(cells[1].x, cells[1].y)
		var selected: Dictionary = main.place_from_roster(kept, cells[1].x,
			cells[1].y, World.NO_FACING)
		h.check("deploy.agent_places_the_selection_and_clamps",
			DictRead.as_string(selected["result"]) == World.DEPLOY_OK
			and main._deploy_slot == other,
			"0x004635E3..0x00463605 from the selection's own index")
		var _restored: Dictionary = main.recall_at(cells[1].x, cells[1].y)
		main._deploy_slot = kept
		main._say_deploy(SliceMain.DEPLOY_LINE_HINT)

	# The agent's view of it.
	var seen: Dictionary = main.deployment_view()
	h.check("deploy.state_reports_the_interface",
		DictRead.as_bool(seen["active"])
		and DictRead.as_int(seen["selected_slot"]) == main._deploy_slot
		and DictRead.as_array(seen["cells"]).size() == cells.size(),
		str(seen))

	# **Backing out puts the squad back.** The map screen frees the mission's
	# whole scene, and whoever is already standing on it has been taken out of
	# the pool -- so *Main Map* from here without `aCopyUnitPool(1, 0)` cost
	# the campaign a soldier per cell already clicked.
	h.check("deploy.some_are_on_the_map",
		host.state.roster.used_slots() < before)
	host.abandon_mission()
	h.equal("deploy.leaving_puts_the_squad_back",
		host.state.roster.used_slots(), before,
		"`aCopyUnitPool(1, 0)`, the same call the debriefing's replay makes")
	h.equal("deploy.leaving_goes_to_the_map", host.screen,
		CampaignHost.SCREEN_MAP)
	# The line and the selection go with the mission: a refusal spoken on
	# turn 0 does not stand on the caption of whatever is loaded next.
	main._deploy_slot = slots[0]
	main._say_deploy(SliceMain.DEPLOY_LINE_NEED_ONE)
	main._clear_mission()
	h.check("deploy.clearing_the_mission_clears_the_line",
		hud.line_text() == "" and main._deploy_slot == Roster.NO_SLOT,
		"a mid-mission load would otherwise carry `need_one`")
	main._hud = null

	# **Past the campaign there is no pool.** The agent's `enter` from the
	# shell and the `"enter"` result reach [method
	# SliceMain._open_deployment_or_start] with a host that has no state;
	# that used to return without a word and leave a turn-0 map whose every
	# click the place interface took and refused in silence. A click there
	# now says the pool is empty, and the opening takes `--mission=`'s own
	# silent arm to turn 1, past the interface.
	var loose_built: Dictionary = CacheFixture.load_world(host.state.mission)
	var loose: SliceMain = SliceMain.new()
	loose.world = loose_built["world"]
	loose._shown = loose.world.clone()
	loose.campaign = _host("deploy3")
	loose._strings = _strings
	loose._hud = hud
	h.check("deploy.no_campaign_is_still_turn_0",
		loose.campaign.state == null and loose._deploying(),
		"the counter's own gate, with no host to ask")
	var _loose_click: bool = loose.deploy_cell(cells[0], Vector2(100.0, 400.0))
	h.equal("deploy.no_campaign_says_the_pool_is_empty", hud.line_text(),
		_strings.text("deploy.pool_empty"),
		"nothing to place and nowhere to take anybody back to")
	h.equal("deploy.no_campaign_state_still_names_the_cells",
		DictRead.as_array(loose.deployment_view()["cells"]).size(), cells.size(),
		"the world's own cells, the same the overlay dots")
	loose._open_deployment_or_start()
	h.check("deploy.no_campaign_takes_the_silent_arm",
		loose.world.turn.turn == TurnState.FIRST_TURN
		and loose._shown.turn.turn == TurnState.FIRST_TURN
		and not loose._deploying()
		and not DictRead.as_bool(loose.deployment_view()["active"]),
		"0x0041A073's arm, as --mission= takes it: turn %d" % loose.world.turn.turn)
	loose._hud = null
	loose.free()
	hud.free()
	main.free()


## The location map's picture: its cells, and the camera the original puts on
## it.
##
## The campaign maps themselves -- `_C_XXX` and `_C_YYY` -- are baked into
## every cache now that `CAMPAIGN_FRAME_MAPS` joins every selection, but the
## *rule* is checked here on a mission every set carries: an action point is a
## location's cell. The camera is no longer
## computed at all -- it is `aMissionControl.cpp`'s own six numbers -- so what
## is checked about it is that it is those numbers and that they mean what
## `0x00403560`'s two triples mean.
## The campaign map's turn -- docs/27 section 2.6, the fourth open question.
##
## The delta was **UNVERIFIED** for a slice: `0x004558F0` was named as the
## routine that swings the eye, its height clamp was measured, and where its
## request came from was not. It is a pointer drag -- `0x00455566` runs while
## the screen id is 6 and the button byte is set, doubling the horizontal
## travel and multiplying the vertical by -50, with the cursor warped back to
## the drag's anchor each frame so the next reading is fresh.
##
## Two halves of it read backwards and both are checked here: the step
## **decays** rather than clamping, and the eye that is turned is the fixed
## one rather than the one the last frame left.
func _map_turn(h: TestHarness) -> void:
	h.equal("turn.rates",
		[CameraRig.MAP_TURN_PER_PIXEL, CameraRig.MAP_RISE_PER_PIXEL],
		[2, -50],
		"`shl eax, 1` and the five instructions that come to -50")
	var rig: CameraRig = CameraRig.new()
	rig.eng3d = Eng3dGeometry.from_cache(CacheFixture.cache_dir())
	var location: int = 95
	var base_eye: Vector3i = CameraRig.campaign_eye(location)
	rig.reset_map_swing(location)
	# **Not exactly the constants**, and the original is not either: a zero
	# angle still goes through Eng3d's Q14 matrix, whose products are shifted
	# down and truncated, so the arm comes back a few units short. It is a
	# fixed offset rather than a drift, because the arm is recomputed from the
	# constants every frame instead of being carried forward -- which is one
	# more reason the engine rotates the selected base eye and not the moving one.
	var resting: Vector3i = rig.swing_map(0, 0)
	h.check("turn.rests_where_the_constants_say",
		Vector2(resting.x, resting.y).distance_to(Vector2(
			base_eye.x, base_eye.y)) < 16.0
		and resting.z == base_eye.z,
		"a frame that asks for nothing rests at %s, a Q14 truncation off "
		% resting + str(base_eye))

	# A drag, then the pointer stops. The step is replaced while the request
	# grows and halved once it does not, so the map coasts and settles.
	rig.reset_map_swing(location)
	var _first: Vector3i = rig.swing_map(40, 0)
	h.equal("turn.request_becomes_the_step", rig.map_step(), 40)
	var _smaller: Vector3i = rig.swing_map(3, 0)
	h.equal("turn.smaller_request_halves_it", rig.map_step(), 20,
		"`cmp ebx, eax / jle` then `sar eax, 1` -- not a clamp to the request")
	var frames: int = 0
	while rig.map_step() != 0 and frames < 40:
		var _idle: Vector3i = rig.swing_map(0, 0)
		frames += 1
	h.check("turn.coasts_to_a_stop", frames > 1 and frames < 12,
		"the step reached zero after %d idle frames" % frames)

	# The angle is absolute: the arm rotated is always the constant one, so a
	# full circle in **one** call comes back to where it started. Checking the
	# call after it would not -- the step halves and accumulates again, which
	# is the whole point of the decay.
	rig.reset_map_swing(location)
	var full: Vector3i = rig.swing_map(Eng3dGeometry.ANGLE_UNITS, 0)
	h.check("turn.a_full_circle_is_a_no_op",
		Vector2(full.x, full.y).distance_to(Vector2(resting.x, resting.y))
			< 16.0,
		"4096 units is one turn; landed at %s against %s" % [full, resting])

	# And it is a turn about **z**. A full circle is a no-op about any axis,
	# so what says the angle is the third of the three is that a quarter turn
	# keeps the arm's length and puts it square to where it was.
	rig.reset_map_swing(location)
	var quarter: Vector3i = rig.swing_map(Eng3dGeometry.ANGLE_UNITS / 4, 0)
	var arm: Vector2 = Vector2(base_eye.x
		- CameraRig.CAMPAIGN_TARGET.x,
		base_eye.y - CameraRig.CAMPAIGN_TARGET.y)
	var swung: Vector2 = Vector2(quarter.x - CameraRig.CAMPAIGN_TARGET.x,
		quarter.y - CameraRig.CAMPAIGN_TARGET.y)
	h.check("turn.is_about_z",
		absf(swung.length() - arm.length()) < 16.0
		and absf(arm.normalized().dot(swung.normalized())) < 0.001
		and quarter.z == base_eye.z,
		"the arm keeps its length %.0f -> %.0f and turns square to itself"
		% [arm.length(), swung.length()])

	# And the height is the one coordinate that carries forward, into the
	# band `0x00455991` and `0x004559A7` clamp it to.
	rig.reset_map_swing(location)
	var high: Vector3i = rig.swing_map(0, 100000)
	var low: Vector3i = rig.swing_map(0, -1000000)
	h.equal("turn.height_band", [high.z, low.z],
		[CameraRig.CAMPAIGN_HEIGHT_HIGH, CameraRig.CAMPAIGN_HEIGHT_LOW])
	rig.free()


## Eng3d's own perspective, against Godot's own projection.
##
## The camera was a plain [Camera3D] at its default 75-degree field of view
## with its axis through the middle of the render. The engine's focal length
## is `_ftol(width * 10 / 13)` -- 398 for the map's 518-wide window, 400 for
## the mission's 520 -- and its axis goes through the **window's** centre,
## which the plate's four strips put thirty pixels above the render's.
##
## What is checked is not the constants but the **agreement**: a point put in
## front of the camera has to come out of Godot's own frustum matrix where
## `centre + coord * focal / depth` puts it. That is the whole claim, and it
## fails if either half is wrong.
func _projection(h: TestHarness) -> void:
	h.equal("projection.focal_lengths",
		[CameraRig.focal_length(CampaignScreen.PLATE_WINDOW.size.x),
		CameraRig.focal_length(float(HudTables.WINDOW.size.x)),
		CameraRig.focal_length(CampaignScreen.PLATE_SIZE.x),
		CameraRig.focal_length(CampaignScreen.PLATE_SIZE.x, 4)],
		[398.0, 400.0, 492.0, 160.0],
		"`_ftol(width * 10 / 13)`, and `width / divisor` when 0x004FA500 is set")
	h.check("projection.eng3d_default_is_not_used",
		CameraRig.FOCAL_ENG3D_DEFAULT == 256.0
		and CameraRig.focal_length(CampaignScreen.PLATE_WINDOW.size.x)
			!= CameraRig.FOCAL_ENG3D_DEFAULT,
		"0x414FE8 ships at 256 and every call site overwrites it")

	# **No scene tree here**, so the check goes through Godot's own frustum
	# matrix rather than through [method Camera3D.unproject_position], which
	# needs a viewport to know how large the render is. `Camera3D` builds this
	# very [Projection] from the four properties [method
	# CameraRig.frame_projection] sets, so what is compared is those four
	# against the engine's arithmetic.
	var camera: Camera3D = Camera3D.new()
	var render: Vector2 = CampaignScreen.PLATE_SIZE
	for window: Rect2 in [CampaignScreen.PLATE_WINDOW,
			Rect2(HudTables.WINDOW)]:
		CameraRig.frame_projection(camera, window, render)
		var tag: String = "%dx%d" % [int(window.size.x), int(window.size.y)]
		h.equal("projection.is_a_frustum.%s" % tag,
			[camera.projection, camera.keep_aspect],
			[Camera3D.PROJECTION_FRUSTUM, Camera3D.KEEP_HEIGHT],
			"a field of view cannot move the axis off centre")
		var matrix: Projection = Projection.create_frustum_aspect(
			camera.size, render.x / render.y, camera.frustum_offset,
			camera.near, camera.far, false)
		var worst: float = 0.0
		var ahead: Vector2 = _through(matrix, Vector3(0.0, 0.0, 10.0), render)
		var centre: Vector2 = window.position + window.size * 0.5
		h.check("projection.axis_is_the_window_centre.%s" % tag,
			ahead.distance_to(centre) < 0.01,
			"straight ahead lands at %.2f, %.2f; the window's centre is %.2f, %.2f"
			% [ahead.x, ahead.y, centre.x, centre.y])
		for at: Vector3 in [Vector3(3.0, 2.0, 20.0), Vector3(-5.0, 4.0, 12.0),
				Vector3(7.0, -3.0, 30.0), Vector3(-1.0, -6.0, 8.0)]:
			worst = maxf(worst, _through(matrix, at, render).distance_to(
				CameraRig.project(at, window)))
		h.check("projection.matches_eng3d.%s" % tag, worst < 0.01,
			"worst disagreement %.4f px over four points" % worst)
	camera.free()


## A camera-space point through *matrix* into the render's own top-left
## pixels. *at* carries depth forward, which is Godot's -z.
func _through(matrix: Projection, at: Vector3, render: Vector2) -> Vector2:
	var clip: Vector4 = matrix * Vector4(at.x, at.y, -at.z, 1.0)
	if is_zero_approx(clip.w):
		return Vector2.ZERO
	return Vector2((clip.x / clip.w + 1.0) * 0.5 * render.x,
		(1.0 - clip.y / clip.w) * 0.5 * render.y)


func _map_picture(h: TestHarness) -> void:
	var built: Dictionary = CacheFixture.load_world("_C_140")
	if built.is_empty():
		h.check("map.mission_present", false, "the cache has no _C_140")
		return
	var world: World = built["world"]
	var cells: Dictionary[int, Vector2i] = SliceMain.location_cells_of(world)
	var counted: int = 0
	var wrong: PackedStringArray = PackedStringArray()
	for y: int in range(world.resource.height):
		for x: int in range(world.resource.width):
			var id: int = world.state.action_point_at(
				world.state.index_of(x, y))
			if id <= 0:
				continue
			counted += 1
			if not cells.has(id):
				wrong.append("%d has no cell" % id)
	h.check("map.every_action_point_is_a_cell", counted > 0,
		"_C_140 carries %d" % counted)
	h.equal("map.every_id_answered", wrong, PackedStringArray(),
		"docs/27 section 2.1 -- a location *is* an action point")
	h.equal("map.no_cell_for_an_unused_id",
		cells.has(0), false, "0 is 'no action point', never a location")

	# `0x00453F80` writes these six before `0x0045D130` replaces the eye from
	# the current location. `tools/campaign_tables.py` pins both stages against
	# the shipped executable.
	h.equal("map.camera_eye_initial", CameraRig.CAMPAIGN_EYE_INITIAL,
		Vector3i(-19088, 98112, 9088), "0x00510BB8/BC/C0")
	h.equal("map.camera_target", CameraRig.CAMPAIGN_TARGET,
		Vector3i(56800, 56800, 0), "0x00510BC4/C8/CC, 0xDDE0 twice")
	h.check("map.camera_looks_down_at_the_city",
		CameraRig.CAMPAIGN_EYE_INITIAL.z > CameraRig.CAMPAIGN_TARGET.z
			and CameraRig.CAMPAIGN_EYE_INITIAL.y > CameraRig.CAMPAIGN_TARGET.y,
		"the eye stands above and north of the target")
	h.check("map.camera_is_not_boxed",
		CameraRig.CAMPAIGN_EYE_INITIAL.x < CameraRig.BOX_MARGIN,
		"the engine writes it past 0x00453420's box, so x stays negative")
	h.check("map.camera_height_band",
		CameraRig.CAMPAIGN_HEIGHT_LOW < CameraRig.CAMPAIGN_EYE_INITIAL.z
			and CameraRig.CAMPAIGN_EYE_INITIAL.z < CameraRig.CAMPAIGN_HEIGHT_HIGH,
		"0x004558F0 clamps the eye's height into [-9600, 19200]")

	# The window the frame leaves clear is the engine's own viewport, and the
	# plate whose picture frame it is.
	h.equal("map.window_is_the_engines", CampaignScreen.PLATE_WINDOW,
		Rect2(65.0, 57.0, 518.0, 306.0), "0x0040B670 at 0x00454102")
	h.equal("map.mission_window_frames_a_page_over_it",
		Rect2(HudTables.WINDOW), Rect2(60.0, 34.0, 520.0, 340.0),
		"0x0040B670 at 0x0041A4C6 -- the briefing read over a turn-0 map "
		+ "keeps the mission's own window")
	h.equal("map.plate_is_the_framed_one", CampaignMapScreen.PLATE_MAP,
		"plate_3", "aInitGUI(\"GUI\\plate_3.bmp\") at 0x00454245")

	# **No picture, no hole.** A cache published before the campaign maps
	# joined every selection carries no `_C_XXX`, and a frame cut around
	# nothing is a black rectangle where the plate should be.
	var frame: CampaignMapScreen = CampaignMapScreen.new()
	h.equal("map.no_picture_leaves_the_plate_whole", frame.plate_window(),
		Rect2(), "the screen falls back to a list of the open locations")
	frame.has_picture = true
	h.equal("map.a_picture_cuts_the_window", frame.plate_window(),
		CampaignScreen.PLATE_WINDOW)
	frame.free()
	world = null


## `0x0045D130` selects an authored eye from the current mission's location.
## This is the regression for `_C_143` -> `_C_145`: location 95 and the Old
## Fort at 211 must both be inside the untouched map frame. The exhaustive
## half checks the same property over every open-location set in both chains.
func _map_camera_presets(h: TestHarness) -> void:
	h.equal("map.preset_default", CameraRig.campaign_eye(50),
		Vector3i(-19072, 98096, 9088), "0x0045D32D's default arm")
	h.equal("map.preset_after_c143", CameraRig.campaign_eye(95),
		Vector3i(73664, -27904, 19200), "selector 7 at 0x0045D255")
	h.equal("map.preset_ranges", [
		CameraRig.campaign_eye(59), CameraRig.campaign_eye(66),
		CameraRig.campaign_eye(70), CameraRig.campaign_eye(71),
		CameraRig.campaign_eye(77), CameraRig.campaign_eye(81),
		CameraRig.campaign_eye(84), CameraRig.campaign_eye(90),
		CameraRig.campaign_eye(97), CameraRig.campaign_eye(101),
		CameraRig.campaign_eye(105), CameraRig.campaign_eye(116),
		CameraRig.campaign_eye(120), CameraRig.campaign_eye(85)],
		CameraRig.CAMPAIGN_EYE_PRESETS + [CameraRig.CAMPAIGN_EYE_DEFAULT],
		"the thirteen selector arms and the 85..89 default gap")

	var document: Dictionary = CacheFixture.read_json(
		_cache_dir + "/tables/campaign.json")
	var tables: CampaignMap = CampaignMap.from_document(document)
	var locations: Dictionary[int, Vector3i] = {}
	for map_name: String in ["_C_XXX", "_C_YYY"]:
		var map: Dictionary = CacheFixture.read_json(
			"%s/missions/%s/map.json" % [_cache_dir, map_name])
		var cells: Dictionary = DictRead.as_dict(map["cells"])
		var land: Dictionary = DictRead.as_dict(map["land"])
		var action: Array = DictRead.as_array(cells["action_point"])
		var xs: Array = DictRead.as_array(land["x"])
		var ys: Array = DictRead.as_array(land["y"])
		var zs: Array = DictRead.as_array(land["z"])
		for i: int in range(action.size()):
			var id: int = DictRead.as_int(action[i])
			if id > 0:
				locations[id] = Vector3i(DictRead.as_int(xs[i]),
					DictRead.as_int(ys[i]), DictRead.as_int(zs[i]))

	var rig: CameraRig = CameraRig.new()
	rig.setup(40, 40, PackedInt32Array(), CameraRig.CAMPAIGN_HEIGHT_HIGH)
	var camera: Camera3D = rig.camera()
	var window: Rect2 = CampaignScreen.PLATE_WINDOW
	var safe_window: Rect2 = window.grow(-MapMarkers.PICK_RADIUS)
	var outside: PackedStringArray = PackedStringArray()
	var checked: int = 0
	for row_value: Variant in DictRead.as_array(document["unlock_graph"]):
		var row: Dictionary = DictRead.as_dict(row_value)
		var mission_id: int = DictRead.as_int(row["mission"])
		var current: int = tables.location_of(mission_id)
		rig.set_now(CameraRig.campaign_eye(current), CameraRig.CAMPAIGN_TARGET)
		for id: int in tables.open_locations(mission_id):
			if not locations.has(id):
				continue
			var point: Vector3 = WorldSpace.to_godot_v(Vector3(locations[id])) \
				- WorldSpace.to_godot_v(Vector3(CameraRig.CAMPAIGN_TARGET))
			var local: Vector3 = camera.transform.affine_inverse() * point
			var pixel: Vector2 = CameraRig.project(
				Vector3(local.x, local.y, -local.z), window)
			checked += 1
			if not safe_window.has_point(pixel):
				outside.append("mission %d location %d at %s" % [
					mission_id, id, pixel])
	h.equal("map.all_open_locations_checked", checked, 156,
		"both campaign maps, every set emitted by aCreateLocationMap")
	h.equal("map.all_open_locations_visible_without_turn", outside,
		PackedStringArray(),
		"each marker centre and its 10-pixel pick radius stay inside the frame")
	rig.free()


## The plates and campaign art the converter bakes.
func _root_plates(h: TestHarness) -> void:
	h.check("art.title_plate_is_baked", _art.plate("title") != null,
		"`Graphics/Title.bmp` -- the shell's own backdrop")
	h.check("art.wilderness_title_is_baked",
		_art.plate("wilderness_title") != null,
		"`Install/Title.bmp` -- the expansion's campaign card")
	h.check("art.credits_plate_is_baked", _art.plate("credits") != null)
	var index: Dictionary = CacheFixture.read_json(
		_cache_dir + "/art/index.json")
	h.equal("art.thirteen_plates",
		DictRead.as_array(index.get("plates", [])).size(), 13,
		"seven framed ones, five top-level screens and the expansion card")


## The screens between the screens -- docs/92 section 7.19: the splash, the
## credits, the static extro, the message screen and the framed sequence
## screen, every caption out of the catalogue.
func _frontend_screens(h: TestHarness) -> void:
	var title: SplashScreen = SplashScreen.new()
	title.stage = SplashScreen.STAGE_TITLE
	title.setup(_art, _strings, _font)
	h.check("frontend.title_says_start_game",
		_labels_of(title).has(_strings.shipped("Txtmod_a", 5)),
		"Menu_a's 13_GameIntro: 05_WinText at (290, 420)")
	h.equal("frontend.title_plate", title.plate_name(), "title")
	_no_missing(h, "title", title)
	title.free()
	var logo: SplashScreen = SplashScreen.new()
	logo.setup(_art, _strings, _font)
	h.check("frontend.logo_has_no_text", _labels_of(logo).is_empty(),
		"BlueByte.bmp and a 1500 ms hold, nothing else")
	h.equal("frontend.logo_plate", logo.plate_name(), "bluebyte")
	logo.free()

	var credits: CreditsScreen = CreditsScreen.new()
	credits.setup(_art, _strings, _font)
	h.equal("frontend.credits_buttons", _actions_of(credits),
		PackedStringArray([CreditsScreen.QUIT, CreditsScreen.BACK]),
		"Exit Game at (450, 410) and Back at (250, 410)")
	# The one verb that must not be the windows' shared `back`: the host's
	# campaign dispatcher matches this arm first, and spelled `back` it ran
	# `_end_campaign()` for the Item List's and the Recruit window's own
	# button -- the campaign dropped from a catalogue.
	h.check("frontend.credits_back_is_namespaced",
		CreditsScreen.BACK != "back",
		"the shared window verb would be shadowed by the credits' arm")
	h.check("frontend.credits_captions",
		_button_labels_of(credits).has(_strings.shipped("Txtmod_a", 7))
		and _button_labels_of(credits).has(_strings.shipped("Txtmod_a", 8)))
	h.equal("frontend.credits_plate", credits.plate_name(), "credits")
	_credits_roll(h, credits)
	_no_missing(h, "credits", credits)
	credits.free()

	var extro: ExtroScreen = ExtroScreen.new()
	extro.setup(_art, _strings, _font)
	h.equal("frontend.extro_button", _actions_of(extro),
		PackedStringArray([ExtroScreen.CONTINUE]),
		"Menu_b's 11_SlideShow keeps one live button, 004_WinText")
	h.check("frontend.extro_caption",
		_button_labels_of(extro).has(_strings.shipped("Txtmod_b", 4)))
	h.equal("frontend.extro_plate", extro.plate_name(), "ship")
	h.check("frontend.extro_plate_is_baked", _art.plate("ship") != null)
	_no_missing(h, "extro", extro)
	extro.free()

	var message: MessageScreen = MessageScreen.new()
	message.setup(_art, _strings, _font)
	h.check("frontend.message_says_please_wait",
		_labels_of(message).has(_strings.shipped("Txtmod_b", 0)),
		"aPrintMessageScreen's callers both pass text id 0")
	h.equal("frontend.message_plate", message.plate_name(), "msgscr")
	h.check("frontend.message_plate_is_baked", _art.plate("msgscr") != null)
	_no_missing(h, "message", message)
	message.free()

	var framed: SequenceScreen = SequenceScreen.new()
	framed.setup(_art, _strings, _font)
	h.check("frontend.framed_sequence_caption",
		_labels_of(framed).has(_strings.shipped("Txtmod_b", 0)),
		"0x00456F30 draws text 0 at (320, 210) behind the window")
	h.check("frontend.framed_sequence_takes_no_world_clicks",
		not framed.takes_world_clicks())
	_no_missing(h, "sequence_framed", framed)
	framed.free()
	var full: SequenceScreen = SequenceScreen.new()
	full.full = true
	full.setup(_art, _strings, _font)
	h.check("frontend.full_sequence_has_no_caption",
		_labels_of(full).is_empty(), "the full-screen arm installs no callback")
	full.free()


# --- reading a built screen --------------------------------------------------

## The roll `fcn.0044BD90` walks -- `Txtmod_a` from 161 until *END*, the code
## every line carries, the two advances and the start the original writes.
##
## The layout is pinned through [method CreditsScreen.roll_layout], which is
## pure, so what is checked is the arithmetic the screen draws with rather
## than a scrape of the labels it built.
func _credits_roll(h: TestHarness, credits: CreditsScreen) -> void:
	var lines: PackedStringArray = credits.shipped_lines()
	h.equal("frontend.credits_roll_lines", lines.size(), 178,
		"`Txtmod_a` 161..338; 339 is the terminator")
	h.equal("frontend.credits_roll_terminator",
		_strings.shipped(CampaignScreen.BANK_MENU, 339),
		CreditsScreen.END_MARK,
		"the walk stops on the bank's own END and not on a count")
	h.equal("frontend.credits_roll_first", lines[0], "0Credits",
		"the title arm, code 0")
	var coded: int = 0
	for line: String in lines:
		var code: int = -1
		if line.length() > 0:
			code = line.unicode_at(0) - "0".unicode_at(0)
		if code >= CreditsScreen.CODE_TITLE and code <= CreditsScreen.CODE_NAME:
			coded += 1
	h.equal("frontend.credits_roll_every_line_coded", coded, lines.size(),
		"every shipped line opens with one of the jump table's five digits")
	var layout: Array[Dictionary] = CreditsScreen.roll_layout(lines)
	h.equal("frontend.credits_roll_drawn", layout.size(), lines.size(),
		"no shipped line takes the silent arm")
	var first: Dictionary = layout[0]
	var first_code: int = first["code"]
	var first_text: String = first["text"]
	var first_y: float = first["y"]
	var first_rules: int = first["rules"]
	h.equal("frontend.credits_roll_title_code", first_code,
		CreditsScreen.CODE_TITLE)
	h.equal("frontend.credits_roll_title_text", first_text, "Credits",
		"the code is stripped and the rest is printed")
	h.equal("frontend.credits_roll_title_y", first_y, 0.0)
	h.equal("frontend.credits_roll_title_rules", first_rules, 2,
		"y+1 and y+3, `0x94B2`")
	# The bank's 162 is a bare `2` -- an empty group end, which is what opens
	# the 30-unit gap in front of the first heading.
	var third: Dictionary = layout[2]
	var third_y: float = third["y"]
	var third_code: int = third["code"]
	var third_rules: int = third["rules"]
	h.equal("frontend.credits_roll_group_gap", third_y,
		CreditsScreen.ADVANCE_LINE + CreditsScreen.ADVANCE_GROUP,
		"15 for the title and 30 for the spacer")
	h.equal("frontend.credits_roll_heading_code", third_code,
		CreditsScreen.CODE_HEADING, "163 is `1Produced by:`")
	h.equal("frontend.credits_roll_heading_rules", third_rules, 1,
		"one rule at y+1, `0x632C`")
	h.equal("frontend.credits_roll_height",
		CreditsScreen.roll_height(lines), 3750.0,
		"178 lines, 30 for each group end and 15 for the rest")
	h.equal("frontend.credits_roll_start", credits.roll_top(),
		CreditsScreen.ROLL_START,
		"`[0x0050FE1C] = 410` before the first frame")
	h.equal("frontend.credits_roll_speed", CreditsScreen.ROLL_SPEED, 20.0,
		"one unit a frame at `fcn.0047F2E0(20, 20)`'s rate")
	# The ramp the underlines are drawn through fades either side of the
	# engine's own row, and the engine leaves exactly one unit of air between
	# that row and the cap height of the name below it. A fade that ate the
	# whole unit read as the rule touching the first name of the group.
	h.check("frontend.credits_roll_rule_fade_fits",
		CreditsScreen.RULE_FADE > 0.0 and CreditsScreen.RULE_FADE < 0.5,
		"the soft edge stays inside the air the original leaves")
	# The remake's own group -- the only invented text on the screen. It is
	# spliced in after the title rather than put instead of anything: the
	# shipped bank comes out of the whole roll unchanged and in order.
	var whole: PackedStringArray = credits.roll_lines()
	var own: PackedStringArray = credits.own_lines()
	h.equal("frontend.credits_roll_tail_length", whole.size(),
		lines.size() + own.size(), "a heading and a name")
	var without: PackedStringArray = PackedStringArray()
	for line: String in whole:
		if not own.has(line):
			without.append(line)
	h.equal("frontend.credits_roll_shipped_first", without, lines,
		"the group is spliced in; not one shipped line changes or moves")
	h.equal("frontend.credits_roll_own_group_is_second",
		whole.slice(0, 2), lines.slice(0, 2),
		"`Txtmod_a` 161's title and its spacer stay first")
	h.equal("frontend.credits_roll_own_group_at_front", whole.slice(2, 4), own,
		"and the remake's group is the first one after them")
	var tail: Array[Dictionary] = CreditsScreen.roll_layout(own)
	h.equal("frontend.credits_roll_tail_drawn", tail.size(), 2,
		"a heading and a name")
	var heading: Dictionary = tail[0]
	var heading_text: String = heading["text"]
	var heading_code: int = heading["code"]
	var name_line: Dictionary = tail[1]
	var name_text: String = name_line["text"]
	var name_code: int = name_line["code"]
	h.equal("frontend.credits_roll_tail_heading", heading_text,
		_strings.text(CreditsScreen.OWN_REMAKE))
	h.equal("frontend.credits_roll_tail_heading_code", heading_code,
		CreditsScreen.CODE_HEADING, "underlined, like every other heading")
	h.equal("frontend.credits_roll_tail_name", name_text,
		_strings.text(CreditsScreen.OWN_REMAKE_BY))
	h.equal("frontend.credits_roll_tail_name_code", name_code,
		CreditsScreen.CODE_GROUP_END)
	h.check("frontend.credits_roll_tail_is_own",
		not name_text.begins_with(Localization.MISSING_PREFIX)
		and not lines.has("%d%s" % [CreditsScreen.CODE_GROUP_END, name_text]),
		"the group comes from the remake's own catalogue, not the bank")


func _no_missing(h: TestHarness, name: String, screen: CampaignScreen) -> void:
	var missing: PackedStringArray = PackedStringArray()
	for line: String in _labels_of(screen):
		if line.begins_with(Localization.MISSING_PREFIX):
			missing.append(line)
	h.equal("screens.%s.every_string_resolves" % name, missing,
		PackedStringArray(), "every caption comes out of the catalogue")


## The captions of a screen's buttons alone -- its rows, without its title.
func _button_labels_of(screen: CampaignScreen) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for button: Button in _buttons_of(screen):
		out.append(button.text)
	return out


func _joined(screen: CampaignScreen) -> String:
	return "\n".join(_labels_of(screen))


## The first hint carrier on a screen, or null.
func _first_hint(node: Node) -> HintControl:
	for child: Node in node.get_children():
		var hint: HintControl = child as HintControl
		if hint != null:
			return hint
		var deeper: HintControl = _first_hint(child)
		if deeper != null:
			return deeper
	return null


## Every hover hint on a screen's controls.
func _hints_of(node: Node) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for child: Node in node.get_children():
		var control: Control = child as Control
		if control != null and control.tooltip_text != "":
			out.append(control.tooltip_text)
		out.append_array(_hints_of(child))
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
		# **A `LineEdit` counts too.** The gate reads what it knows about, and
		# a field it does not know about is a caption it never checks -- the
		# save screen's name box carries the row it would have written as its
		# placeholder, which is a string like any other.
		var field: LineEdit = child as LineEdit
		if field != null:
			out.append(field.placeholder_text)
		out.append_array(_labels_of(child))
	return out


## The actions a screen's buttons would emit, in the order they are built.
## A copy in a fixed order, for a check that is about a *set*.
static func _sorted(items: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = items.duplicate()
	out.sort()
	return out


static func _any_ends_with(items: PackedStringArray, tail: String) -> bool:
	for line: String in items:
		if line.ends_with(tail):
			return true
	return false


## Every button's rectangle in the plate's own 640x480 units, in the order the
## screen built them. [method CampaignScreen.place_on_plate] writes anchors
## rather than offsets, so the fractions are the layout and reading them back
## needs no tree and no renderer.
func _rows_of(screen: CampaignScreen) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for button: Button in _buttons_of(screen):
		out.append(Rect2(
			button.anchor_left * CampaignScreen.PLATE_SIZE.x,
			button.anchor_top * CampaignScreen.PLATE_SIZE.y,
			(button.anchor_right - button.anchor_left)
				* CampaignScreen.PLATE_SIZE.x,
			(button.anchor_bottom - button.anchor_top)
				* CampaignScreen.PLATE_SIZE.y))
	return out


func _actions_of(screen: CampaignScreen) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for button: Button in _buttons_of(screen):
		for connection: Dictionary in button.pressed.get_connections():
			var target: Callable = connection["callable"]
			var bound: Array = target.get_bound_arguments()
			if bound.is_empty():
				continue
			# **Strings only.** A location row on the campaign map binds its
			# location **id**, an int, and handing that to `DictRead.as_string`
			# is a runtime error -- which `run_tests.sh` fails the whole run
			# on, quite rightly, even though every check still passed.
			var first: Variant = bound[0]
			if typeof(first) != TYPE_STRING:
				continue
			# Read back with an assignment, which is checked at run time --
			# warnings are errors and `append(Variant)` is one of them.
			var action: String = first
			out.append(action)
	return out


func _disabled_count(screen: CampaignScreen) -> int:
	var count: int = 0
	for button: Button in _buttons_of(screen):
		if button.disabled:
			count += 1
	return count


func _buttons_of(node: Node) -> Array[Button]:
	var out: Array[Button] = []
	for child: Node in node.get_children():
		var button: Button = child as Button
		if button != null:
			out.append(button)
		out.append_array(_buttons_of(child))
	return out


func _sliders_of(node: Node) -> Array[HSlider]:
	var out: Array[HSlider] = []
	for child: Node in node.get_children():
		var slider: HSlider = child as HSlider
		if slider != null:
			out.append(slider)
		out.append_array(_sliders_of(child))
	return out


## `option:language` writes the setting, parks the choice and reloads once --
## through [member SliceMain.reload_hook], so the suite counts the call
## instead of reloading the tree under itself. The real reload is gated by a
## driven session, not by this (docs/92 section 7.6).
func _language_switch(h: TestHarness, settings: GameSettings) -> void:
	var main: SliceMain = SliceMain.new()
	main.settings = settings
	settings.path = SCRATCH_DIR + "/switch-settings.json"
	settings.language = ""
	main._paths = CachePaths.create(_cache_dir, {"language": "English",
		"languages": ["English", "Russian"], "inventory": []})
	var reloads: Array[int] = []
	main.reload_hook = func() -> void: reloads.append(1)
	main._step_option("language")
	h.equal("switch.setting_written", settings.language, "Russian",
		"the next of the cache's languages")
	var read: GameSettings = GameSettings.new()
	read.path = settings.path
	h.check("switch.setting_on_disk", read.load_from_disk()
		and read.language == "Russian", "written before the reload")
	h.equal("switch.language_parked", main.restart_language, "Russian")
	h.equal("switch.reloads_once", reloads.size(), 1)
	h.check("switch.leaving_gate", main._leaving,
		"no option, choice or key is acted on until the scene is gone")
	main._step_option("gore")
	h.equal("switch.second_step_ignored", reloads.size(), 1,
		"the gate holds")
	# A close asked for while the restart is leaving is parked, not
	# dropped: the restart quits in its place once its frames are up.
	main._quit()
	h.check("switch.quit_during_restart_parked", main._quit_pending,
		"the close outlives the restart's window")
	main.free()

	# Wrapping round: from the last language back to the base, which is
	# written as the empty string so an older cache reads it as before.
	var back: SliceMain = SliceMain.new()
	var back_settings: GameSettings = GameSettings.new()
	back_settings.path = SCRATCH_DIR + "/switch-back.json"
	back_settings.language = "Russian"
	back.settings = back_settings
	back._paths = CachePaths.create(_cache_dir, {"language": "English",
		"languages": ["English", "Russian"], "inventory": []}, "Russian")
	var back_reloads: Array[int] = []
	back.reload_hook = func() -> void: back_reloads.append(1)
	back._step_option("language")
	h.equal("switch.back_to_base_is_empty", back_settings.language, "")
	h.equal("switch.back_parks_the_base", back.restart_language, "English")
	h.equal("switch.back_reloads_once", back_reloads.size(), 1)
	back.free()

	# One language: the arm does nothing, and nothing is written.
	var single: SliceMain = SliceMain.new()
	var single_settings: GameSettings = GameSettings.new()
	single_settings.path = SCRATCH_DIR + "/switch-single.json"
	single.settings = single_settings
	single._paths = CachePaths.create(_cache_dir, {"language": "English",
		"inventory": []})
	var single_reloads: Array[int] = []
	single.reload_hook = func() -> void: single_reloads.append(1)
	single._step_option("language")
	h.check("switch.one_language_is_inert",
		single_reloads.is_empty() and not single._leaving
		and not FileAccess.file_exists(single_settings.path))
	single.free()


func _clean_scratch() -> void:
	var root: String = ProjectSettings.globalize_path(SCRATCH_DIR)
	_remove_tree(root)


func _remove_tree(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for name: String in dir.get_files():
		var _gone: Error = dir.remove(name)
	for sub: String in dir.get_directories():
		_remove_tree(path + "/" + sub)
	var _dropped: Error = DirAccess.remove_absolute(path)


## The JSON document out of a container [CampaignCodec] wrote.
##
## The framing is magic, schema, the two lengths, the document, the blob and
## the digest -- so the document starts at 16 and runs for the length at 8.
func _document_of(data: PackedByteArray) -> Dictionary:
	var size: int = data.decode_s32(8)
	var parsed: Variant = JSON.parse_string(
		data.slice(16, 16 + size).get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


## A container carrying *document* and no mission blob, framed and digested
## the way [method CampaignCodec.encode] frames one.
##
## It exists to build a save this build did **not** write -- a schema-2
## document without the name key, which is what every slot a player already
## has looks like. Nothing else may use it: a test that encoded its own
## containers would stop checking the codec.
func _container(document: Dictionary) -> PackedByteArray:
	var text: PackedByteArray = JSON.stringify(document, "", true,
		true).to_utf8_buffer()
	var body: PackedByteArray = PackedByteArray()
	body.append_array(PackedInt32Array([CampaignCodec.SCHEMA_VERSION,
		text.size(), 0]).to_byte_array())
	body.append_array(text)
	var out: PackedByteArray = CampaignCodec.MAGIC.to_utf8_buffer()
	out.append_array(body)
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	ctx.update(body)
	out.append_array(ctx.finish())
	return out


## An [AudioSystem] that opens no stream and keeps the waves it was asked
## to play: whether a press was heard is a count rather than an impression.
## `_tables` is set by the check, so [method AudioSystem.tables] answers the
## cue table [method SliceMain._play_interface] reads.
class ClickRecorder extends AudioSystem:
	var plays: PackedStringArray = PackedStringArray()

	func play_cue(cue: Dictionary, _tag: String = "") -> int:
		plays.append(DictRead.as_string(cue["wave"]))
		return plays.size() - 1
