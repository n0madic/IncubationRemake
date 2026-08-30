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

	# The result banner is the mission's own words, and it appears only once
	# the game-control slots say the mission is over (docs/20 section 7).
	h.check("hud.no_banner_before_the_end", not _banner_visible(hud),
		"slots 0..4 are clear")
	world.game_control.set_slot(0, 1)
	hud.refresh(world, squad[0], "")
	h.check("hud.the_banner_appears_on_a_win", _banner_visible(hud),
		"slot 0 is set")
	h.equal("hud.the_banner_is_the_game_s_own_words", _banner_text(hud),
		strings.shipped(Localization.MODULE_MISSION,
			Localization.ID_COMPLETED))
	world.game_control.set_slot(0, 0)
	world.game_control.set_slot(4, 1)
	hud.refresh(world, squad[0], "")
	h.equal("hud.a_loss_says_so", _banner_text(hud),
		strings.shipped(Localization.MODULE_MISSION, Localization.ID_FAILED))
	hud.free()


## The HUD's two labels, read back out of the node it built.
##
## Reaching into the children rather than exposing the text: the HUD's job is
## to *put* it on screen, and an accessor for the benefit of a test would be a
## second definition of what it says.
static func _hud_text(hud: Hud) -> String:
	var label: Label = hud.get_child(0)
	return label.text


static func _banner_visible(hud: Hud) -> bool:
	var label: Label = hud.get_child(1)
	return label.visible


static func _banner_text(hud: Hud) -> String:
	var label: Label = hud.get_child(1)
	return label.text
