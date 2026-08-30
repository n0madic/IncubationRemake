extends TestSuite

## Oracle boundary: **specification** -- docs/22 section 9 for what may be seen,
## docs/92 section 7.6 for where text comes from.
##
## `game/` is not `core/` and most of it is a picture, but three of its files
## make decisions rather than draw them: [Localization] decides what a string
## is, [Fog] decides whether a unit is drawn at all, and [Hud] decides what the
## player is told. Those are checkable and are checked here.
##
## The one this suite exists for is the **missing-string** rule. A localization
## seam whose misses render as `""` looks like a layout bug; one whose misses
## render as a marker looks like what it is, and a check can then say there are
## none.

const REPORT_LIMIT: int = 6


func run(h: TestHarness) -> void:
	h.begin("game_ui", TestHarness.ORACLE_SPEC)
	_localization(h)
	_fog(h)
	_hud(h)
	_command_gate(h)
	_game_font(h)


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
	var strings: Localization = Localization.from_cache(
		CacheFixture.cache_dir(), manifest)
	h.check("text.cache_carries_the_catalogue", strings.has_shipped_text(),
		"text/%s.json" % strings.language)
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
		foreign.text("hud.end_turn"),
		DictRead.as_string(DictRead.as_dict(
			Localization.OWN["hud.end_turn"])[Localization.FALLBACK_LANGUAGE]))


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
	var marker: MeshInstance3D = Fog.contact_marker()
	h.check("fog.the_blip_has_a_mesh", marker.mesh != null, marker.name)
	marker.free()
	# The states are [Visibility]'s, not a second set: a renderer that invented
	# its own numbering would drift the first time the fog pass changed.
	h.equal("fog.states_match_the_simulation",
		[Fog.FULL, Fog.CONTACT, Fog.HIDDEN],
		[Visibility.FULL, Visibility.CONTACT, Visibility.HIDDEN])


func _hud(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("hud.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var strings: Localization = Localization.from_cache(
		CacheFixture.cache_dir(), CacheFixture.manifest())
	var hud: Hud = Hud.new(strings)
	hud.refresh(world, -1, "")
	var idle: String = _hud_text(hud)
	h.check("hud.says_the_mission_and_the_turn",
		idle.contains(world.resource.mission) and idle.contains(
			strings.shipped(Localization.MODULE_MISSION,
				Localization.ID_TURN)),
		idle.split("\n")[0])
	h.check("hud.says_nothing_is_selected",
		idle.contains(strings.text("hud.no_selection")), idle)
	h.check("hud.renders_no_missing_string",
		not idle.contains(Localization.MISSING_PREFIX), idle)

	var squad: PackedInt32Array = PackedInt32Array()
	for slot: int in world.unit_slots():
		if DictRead.as_int(world.unit_view(slot)["player"]) == 0:
			squad.append(slot)
	h.check("hud.the_mission_has_a_squad", not squad.is_empty(),
		"%d unit(s) of player 0" % squad.size())
	if squad.is_empty():
		hud.free()
		return
	hud.refresh(world, squad[0], "")
	var selected: String = _hud_text(hud)
	h.check("hud.names_the_selected_unit",
		selected.contains(DictRead.as_string(
			world.unit_view(squad[0])["name"])), selected)
	h.check("hud.renders_no_missing_string_when_selected",
		not selected.contains(Localization.MISSING_PREFIX), selected)

	# The report appears only once the game-control slots say the mission is
	# over (docs/20 section 7), and it is the debriefing rather than a word.
	h.check("hud.no_report_before_the_end", not _report_visible(hud),
		"slots 0..4 are clear")
	world.game_control.set_slot(0, 1)
	hud.refresh(world, squad[0], "")
	h.check("hud.the_report_appears_on_a_win", _report_visible(hud),
		"slot 0 is set")
	var won: String = _report_text(hud)
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

	# The three grades are three different lines, in docs/27 section 6.3's
	# order. A report that printed one word for every win would pass every
	# check above.
	var grades: Array[String] = []
	for value: int in [1, 2, 3]:
		world.game_control.set_slot(0, value)
		hud.refresh(world, squad[0], "")
		grades.append(_report_text(hud))
	h.check("hud.the_three_win_grades_differ",
		grades[0] != grades[1] and grades[1] != grades[2]
		and grades[0] != grades[2], " | ".join(grades).replace("\n", " / "))
	h.check("hud.the_best_grade_is_the_glorious_one",
		grades[2].contains(strings.shipped(Localization.MODULE_REPORT,
			Localization.ID_REPORT_GLORIOUS)), grades[2].replace("\n", " | "))

	# The payout lines are shown only when the slot carries something and only
	# when the result is not 5 -- both of docs/27 section 6.2's own tests.
	var equipment: String = strings.shipped(Localization.MODULE_REPORT,
		Localization.ID_REPORT_EQUIPMENT)
	h.check("hud.an_unset_payout_is_not_printed",
		not grades[0].contains(equipment), grades[0].replace("\n", " | "))
	world.game_control.set_slot(0, 1)
	world.game_control.set_slot(GameControl.SLOT_EQUIPMENT_POINTS, 50)
	hud.refresh(world, squad[0], "")
	h.check("hud.a_set_payout_is_printed",
		_report_text(hud).contains(equipment),
		_report_text(hud).replace("\n", " | "))

	world.game_control.set_slot(0, 0)
	world.game_control.set_slot(4, 1)
	hud.refresh(world, squad[0], "")
	var lost: String = _report_text(hud)
	h.check("hud.a_loss_says_so",
		lost.contains(strings.shipped(Localization.MODULE_MISSION,
			Localization.ID_FAILED))
		and lost.contains(strings.shipped(Localization.MODULE_REPORT,
			Localization.ID_REPORT_DEFEATED)), lost.replace("\n", " | "))
	h.check("hud.a_loss_forfeits_the_payout",
		not lost.contains(equipment), lost.replace("\n", " | "))
	hud.free()

	_mission_result(h)


## docs/27 section 6.3 -- `0x0047D600`'s classification, which is one order of
## operations and not a lookup.
##
## The vector that matters is the third: **another player's slot ends the
## mission and this player is defeated by it.** The OR chain stamps 5 on
## everybody first and only then does each player's own slot put a grade back,
## so an implementation that reads its own slot and slot 4 answers every other
## case correctly and this one wrongly.
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


## The HUD's two labels, read back out of the node it built.
##
## Reaching into the children rather than exposing the text: the HUD's job is
## to *put* it on screen, and an accessor for the benefit of a test would be a
## second definition of what it says.
static func _hud_text(hud: Hud) -> String:
	var label: Label = hud.get_child(0)
	return label.text


## The report panel is the HUD's second child, and the words are the Label
## inside it -- the first child of the panel is what dims the map.
static func _report_visible(hud: Hud) -> bool:
	var panel: Control = hud.get_child(1)
	return panel.visible


static func _report_text(hud: Hud) -> String:
	var panel: Control = hud.get_child(1)
	var label: Label = panel.get_child(1)
	return label.text


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
	var opened: Dictionary = CacheLoader.open_active()
	if not DictRead.as_bool(opened["ok"]):
		h.check("font.cache", false, DictRead.as_string(opened["reason"]))
		return
	var dir: String = DictRead.as_string(opened["cache_dir"])
	var font: FontFile = GameFont.load_from(dir, "font_2")
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
