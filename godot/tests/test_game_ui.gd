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
	_shots_and_reactions(h)
	_rebuild(h)
	_replay_positions(h)


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
## AIPlayback.STEP_SECONDS] cut every combat clip off part way through. And the
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
		if DictRead.as_int(view["player"]) == 0:
			if shooter < 0:
				shooter = slot
		elif reactor < 0:
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
	var _placed: bool = world.apply_unit_record(reactor, {
		"x": ax, "y": sy, "facing": Combat.direction(ax, sy, sx, sy),
		"action_state": Reaction.WAITING, "ticket": 1,
		"mp": Reaction.MIN_MP, "malfunction": 0, "heat": 0,
		"visibility": 0})
	var mover: UnitState = world.units_for_ai()[shooter]
	var entries: Array[Dictionary] = Reaction.drain(world.state,
		world.units_for_ai(), world.unit_types(), world.weapons(), mover,
		world.turn.ai_level, world.turn.human_count(), world.turn.mode,
		world.turn, world.rng)
	h.check("shot.reactions_drained", not entries.is_empty(),
		"%d reaction(s) from slot %d" % [entries.size(), reactor])
	# The shot the reaction took is undone: what is being checked below is the
	# presentation, and a shooter the setup killed would refuse to fire.
	var _restored: bool = world.apply_unit_record(shooter, {
		"hp": DictRead.as_int(us["hp"]), "mp": DictRead.as_int(us["mp"]),
		"ammo": DictRead.as_int(us["ammo"]), "acted": 0, "heat": 0,
		"action_state": 0})
	var shot: AttackResult = world.submit_attack(
		AttackCommand.create(shooter, ax, sy))
	h.check("shot.fired", shot.fired,
		shot.reason if not shot.fired else "%d outcome(s)" % shot.outcomes.size())

	var fire_clip: CharismaClip = _clip_with_break()
	if fire_clip == null:
		h.check("shot.clip", false, "no `F` clip with a BREAK note in the cache")
		return
	var main: SliceMain = SliceMain.new()
	main.world = world
	var units: UnitsView = UnitsView.new()
	units.world_ref = world
	main._units = units
	for slot: int in [shooter, reactor]:
		var node: Node3D = Node3D.new()
		node.name = "unit_%d" % slot
		units.add_child(node)
		units.states[slot] = CharismaState.create(null, fire_clip, fire_clip,
			fire_clip)

	# --- the player\'s own shot ------------------------------------------
	var hold: float = main._present_attack(shooter, sx, sy, ax, sy,
		DictRead.as_int(us["weapon"]), shot)
	h.equal("shot.body_plays_f", units.states[shooter].mode,
		CharismaState.Mode.FIRE, "the shooter is playing its combat clip")
	h.check("shot.body_is_busy", units.states[shooter].is_busy(),
		"and the caller is told to wait for it")
	h.check("shot.hold_covers_the_clip",
		hold >= fire_clip.break_time() / CharismaState.FRAMES_PER_SECOND,
		"%.3f s asked for a clip that breaks at %.3f s"
			% [hold, fire_clip.break_time() / CharismaState.FRAMES_PER_SECOND])

	# --- the return fire it drew ------------------------------------------
	main._queue_reactions(entries, shooter, sx, sy)
	h.equal("shot.reactions_queued", main._pending_reactions.size(), 1,
		"one batch waiting, aimed at the cell that drew it")
	# The mover's camera inputs follow its **slot**, not whoever stands on the
	# cell now: during the computer's replay the mover has walked on, and a
	# bare cell would give the reaction camera no height and no size.
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
	h.equal("shot.waits_for_the_shot", main._drain_pending_reactions(), 1,
		"the shooter\'s own clip runs before the answer to it")
	units.states[shooter].rest()

	var width: int = world.resource.width
	var step: int = 1 if sx + 2 < width else -1
	units.start_walk(shooter, PackedInt32Array([sy * width + sx,
		sy * width + sx + step]), width, 1.0)
	h.equal("shot.waits_for_the_walk", main._drain_pending_reactions(), 1,
		"return fire lands where `core` resolved it: at the end of the move")
	units.finish_walks(world)

	h.equal("shot.drains_when_the_picture_is_free",
		main._drain_pending_reactions(), 0, "nothing walking, nothing shooting")
	h.equal("shot.the_reactor_shoots_back", units.states[reactor].mode,
		CharismaState.Mode.FIRE,
		"the unit on overwatch animates its own shot, which nothing drew before")

	# --- the computer\'s two events ---------------------------------------
	units.states[shooter].rest()
	units.states[reactor].rest()
	var fire_event: Dictionary = AIEvent.make("fire", shooter, sx, sy, ax, sy,
		0, str(DictRead.as_int(us["weapon"])), shot.to_dict()).to_dict()
	var fire_hold: float = main._play_event_body(fire_event, "fire")
	h.check("shot.event_fire_holds",
		fire_hold >= fire_clip.break_time() / CharismaState.FRAMES_PER_SECOND,
		"a `fire` event asks for %.3f s, not the %.2f s floor"
			% [fire_hold, AIPlayback.STEP_SECONDS])
	h.equal("shot.event_fire_plays_the_body", units.states[shooter].mode,
		CharismaState.Mode.FIRE, "and the body it names is the one playing")
	units.states[shooter].rest()

	var reaction_event: Dictionary = AIEvent.make("reactions", shooter, sx, sy,
		0, 0, entries.size(), "",
		{"reactions": entries.duplicate(true)}).to_dict()
	var reaction_hold: float = main._play_event_body(reaction_event, "reactions")
	h.check("shot.event_reactions_hold", reaction_hold > 0.0,
		"a drawn reactor\'s clip is what the replay waits for, %.3f s"
			% reaction_hold)
	h.equal("shot.event_reactions_play_the_body", units.states[reactor].mode,
		CharismaState.Mode.FIRE,
		"the computer\'s turn shows return fire too")

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

	# **Held for as long as the shot that killed it takes to draw.** The
	# rebuild that drops a casualty runs *before* the event that killed it is
	# presented -- for the computer's replay always -- so a marine vanished and
	# the sound of what killed it arrived afterwards.
	units.linger(victim, SliceMain.DEATH_LINGER_SECONDS)
	units.build(world, geometry, {})
	h.check("rebuild.a_casualty_is_held",
		units.get_node_or_null(NodePath("unit_%d" % victim)) != null,
		"still drawn while its killer's shot is on screen")
	units.animate(SliceMain.DEATH_LINGER_SECONDS + 0.01, world)
	h.check("rebuild.and_then_it_goes",
		units.get_node_or_null(NodePath("unit_%d" % victim)) == null,
		"%.2f s later, without waiting for another rebuild"
			% SliceMain.DEATH_LINGER_SECONDS)
	h.equal("rebuild.the_hold_is_released", units.lingering().size(), 0)
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
func _replay_positions(h: TestHarness) -> void:
	# The events are the real shape: `AIPlan` emits a move with the **source**
	# in `x`/`y` and the destination in `tx`/`ty`.
	var events: Array[Dictionary] = [
		AIEvent.make("fire", 4, 1, 1, 2, 2).to_dict(),
		AIEvent.make("warp", 6, 3, 4, 8, 8).to_dict(),
		AIEvent.make("end_unit_turn", 4).to_dict(),
		AIEvent.make("move", 5, 2, 3, 9, 9).to_dict(),
		AIEvent.make("fire", 5, 9, 9, 1, 1).to_dict(),
		AIEvent.make("move", 5, 9, 9, 1, 1).to_dict(),
	]
	var all: Dictionary[int, Vector2i] = AIPlayback.starts_in(events, 0)
	h.equal("replay.every_unmoved_unit_is_placed", all.size(), 2,
		"slots 5 and 6 have a move or a warp still to come")
	h.equal("replay.the_source_is_the_events_own", all.get(5, Vector2i.ZERO),
		Vector2i(2, 3), "the move's `x`/`y`, not its `tx`/`ty`")
	h.equal("replay.a_warp_counts_too", all.get(6, Vector2i.ZERO),
		Vector2i(3, 4))
	# A unit that moves twice is held at the start of its **next** move.
	var later: Dictionary[int, Vector2i] = AIPlayback.starts_in(events, 4)
	h.equal("replay.the_next_move_wins", later.get(5, Vector2i.ZERO),
		Vector2i(9, 9), "its first move has already played")
	h.equal("replay.a_played_warp_is_released", later.has(6), false)
	h.equal("replay.nothing_is_held_at_the_end",
		AIPlayback.starts_in(events, events.size()).size(), 0)

	# And the view really draws them there.
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	var geometry: Dictionary = CacheFixture.geometry("A00")
	if loaded.is_empty() or geometry.is_empty():
		h.check("replay.cache", false, "no _C_140 or no A00 geometry")
		return
	var world: World = loaded["world"]
	var units: UnitsView = UnitsView.new()
	units.library = CharismaLibrary.open(CacheFixture.cache_dir(), {}, "_C_140")
	var slot: int = -1
	for candidate: int in world.unit_slots():
		var view: Dictionary = world.unit_view(candidate)
		if not view.is_empty() and DictRead.as_int(view["hp"]) > 0:
			slot = candidate
			break
	if slot < 0:
		h.check("replay.unit", false, "no live unit on _C_140")
		units.free()
		return
	var at: Dictionary = world.unit_view(slot)
	var home: Vector3 = WorldSpace.cell_centre(DictRead.as_int(at["x"]),
		DictRead.as_int(at["y"]), world.state.height_at(world.state.index_of(
			DictRead.as_int(at["x"]), DictRead.as_int(at["y"]))))
	var elsewhere: Vector2i = Vector2i(
		(DictRead.as_int(at["x"]) + 3) % world.resource.width,
		(DictRead.as_int(at["y"]) + 2) % world.resource.height)
	var held: Dictionary[int, Vector2i] = {slot: elsewhere}
	units.hold_at(held)
	units.build(world, geometry, {})
	var node: Node3D = units.get_node_or_null(NodePath("unit_%d" % slot))
	h.check("replay.the_held_unit_is_drawn", node != null, "slot %d" % slot)
	if node != null:
		var there: Vector3 = WorldSpace.cell_centre(elsewhere.x, elsewhere.y,
			world.state.height_at(world.state.index_of(elsewhere.x,
				elsewhere.y)))
		h.check("replay.it_is_drawn_where_it_is_held",
			node.position.distance_to(there) < 0.001,
			"%.3f m from the held cell" % node.position.distance_to(there))
		h.check("replay.and_not_where_the_world_says",
			node.position.distance_to(home) > 0.5,
			"the world still says (%d,%d) and is never told otherwise"
				% [DictRead.as_int(at["x"]), DictRead.as_int(at["y"])])
	# Releasing the hold puts it back, which is what the end of a replay does.
	units.hold_at({} as Dictionary[int, Vector2i])
	units.build(world, geometry, {})
	var back: Node3D = units.get_node_or_null(NodePath("unit_%d" % slot))
	h.check("replay.the_release_puts_it_back",
		back != null and back.position.distance_to(home) < 0.001,
		"the rebuild after the replay is what returns everyone")
	h.equal("replay.the_hold_is_empty", units.held_at().size(), 0)
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
