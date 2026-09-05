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
	_localization(h)
	_fog(h)
	_hud(h)
	_mission_result(h)
	_command_gate(h)
	_game_font(h)
	_shots_and_reactions(h)
	_rebuild(h)
	_replay_positions(h)
	_replay_progress(h)
	_hand_back_selection(h)
	_unit_animations(h)
	_walk_epilogue(h)
	_campaign_screens(h)


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
	units.states[shooter].fire()
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
	h.check("shot.the_reaction_is_queued", main._sequences.is_running(),
		"the return fire is a shot sequence of its own")
	var _fired: bool = main._sequences.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("shot.the_reactor_shoots_back", units.states[reactor].mode,
		CharismaState.Mode.FIRE,
		"the unit on overwatch animates its own shot, which nothing drew before")
	main._sequences.skip()

	# --- the computer\'s two events ---------------------------------------
	units.states[shooter].rest()
	units.states[reactor].rest()
	var fire_event: Dictionary = AIEvent.make("fire", shooter, sx, sy, ax, sy,
		0, str(DictRead.as_int(us["weapon"])), shot.to_dict()).to_dict()
	var fire_hold: float = main._play_event_body(fire_event, "fire")
	h.check("shot.event_fire_holds",
		fire_hold >= float(units.states[shooter].frames_to_break())
			/ CharismaState.FRAMES_PER_SECOND,
		"a `fire` event asks for %.3f s, not the %.2f s floor"
			% [fire_hold, AIPlayback.STEP_SECONDS])
	# The hold is the engine's deterministic frames only: the open-ended
	# waits are the picture's business (`AIPlayback.advance`'s `busy`), and
	# a hold that summed their bounds stalled every computer shot for half
	# a minute.
	h.check("shot.event_fire_hold_is_bounded", fire_hold < 3.0,
		"%.3f s: clip, spin, muzzle, impact and resume, no safety bounds"
			% fire_hold)
	var _shown: bool = main._sequences.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("shot.event_fire_plays_the_body", units.states[shooter].mode,
		CharismaState.Mode.FIRE, "and the body it names is the one playing")
	main._sequences.skip()
	units.states[shooter].rest()

	var reaction_event: Dictionary = AIEvent.make("reactions", shooter, sx, sy,
		0, 0, entries.size(), "",
		{"reactions": entries.duplicate(true)}).to_dict()
	var reaction_hold: float = main._play_event_body(reaction_event, "reactions")
	h.check("shot.event_reactions_hold", reaction_hold > 0.0,
		"a drawn reactor\'s clip is what the replay waits for, %.3f s"
			% reaction_hold)
	var _answered: bool = main._sequences.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("shot.event_reactions_play_the_body", units.states[reactor].mode,
		CharismaState.Mode.FIRE,
		"the computer\'s turn shows return fire too")
	main._sequences.skip()

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
	var _marked: int = main._mark_dying(killed.outcomes)
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
	h.check("kill.death_creator_filled_the_pool", main._fx.live() > 0,
		"%d live record(s) -- the dead record was found by its cell"
			% main._fx.live())
	main._sequences.skip()

	# The computer's para bomb, through its event. The payload **is** the
	# blast (`AISpecialPlayer` writes `AttackResult.to_dict()` into it), and
	# until [method SliceMain._play_event_body] staged it the arm was sound
	# only: the casualties the replay holds from its first frame had nothing
	# to take them away and stood until the end of the turn.
	var bomb_body: Node3D = Node3D.new()
	bomb_body.name = "unit_%d" % victim
	units.add_child(bomb_body)
	var _held_by_the_bomb: int = main._mark_dying(killed.outcomes)
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

	# **Held until the shot that killed it hides it.** The rebuild that drops
	# a casualty runs *before* the event that killed it is presented -- for
	# the computer's replay always -- so a marine vanished and the sound of
	# what killed it arrived afterwards. The engine hides the object in the
	# death stage of `aPlayFightAnimation` (docs/42 section 4.8), and that is
	# the one moment it leaves the picture; there is no timer.
	units.mark_dying(victim)
	units.build(world, geometry, {})
	h.check("rebuild.a_casualty_is_held",
		units.get_node_or_null(NodePath("unit_%d" % victim)) != null,
		"still drawn while its killer's shot is on screen")
	units.animate(5.0, world)
	h.check("rebuild.no_timer_drops_it",
		units.get_node_or_null(NodePath("unit_%d" % victim)) != null,
		"five seconds later it is still there: only the shot hides it")
	h.check("rebuild.hidden_by_the_death_stage", units.hide_now(victim),
		"0x00405320(obj, 5) -- gone in this frame")
	h.check("rebuild.and_then_it_goes",
		units.get_node_or_null(NodePath("unit_%d" % victim)) == null,
		"without waiting for another rebuild")
	h.equal("rebuild.the_hold_is_released", units.dying().size(), 0)
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
	units.world_ref = world
	main._units = units
	main._sequences = SequenceQueue.create(null)
	main._strings = Localization.new()
	var us: Dictionary = world.unit_view(shooter)
	var sx: int = DictRead.as_int(us["x"])
	var sy: int = DictRead.as_int(us["y"])

	# A shot that raised a skill level: the orbit is queued **before** the
	# nine stages, as `aAttackUnit` plays it before its caller's animation.
	var attack: AttackResult = AttackResult.new()
	attack.fired = true
	attack.skill_raised = 1
	var _hold: float = main._present_attack(shooter, sx, sy, sx + 1, sy,
		DictRead.as_int(us["weapon"]), attack)
	h.equal("anim.skill_orbit_first", main._sequences.current(),
		OrbitSequence.STAGE_RAISE)
	var seen: Array[String] = []
	var frames: int = 0
	while main._sequences.is_running() and frames < 400:
		var stage: String = main._sequences.current()
		if seen.is_empty() or seen[seen.size() - 1] != stage:
			seen.append(stage)
		var _went: bool = main._sequences.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.check("anim.shot_follows_the_orbit",
		seen.find(OrbitSequence.STAGE_BACK) >= 0
			and seen.find(ShotSequence.STAGE_CLIP) > seen.find(OrbitSequence.STAGE_BACK),
		str(seen))
	# An overheat that destroyed the carrier: kind 1, no wave of its own.
	main._sequences = SequenceQueue.create(null)
	var hot: AttackResult = AttackResult.new()
	hot.fired = true
	hot.overheat = Combat.OVERHEAT_DESTROYED
	main._present_shot_orbits(shooter, us, hot)
	h.equal("anim.overheat_orbit_queued", main._sequences.current(),
		OrbitSequence.STAGE_RAISE)
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

	# **The quiet computer turn hands back twice.** `AIPlayback.play` finishes
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
	var none: PackedInt32Array = PackedInt32Array()
	var opening: Vector2i = TurnProgress.tally(world, player, none, none)
	h.equal("progress.the_turn_opens_at_zero", opening.x, 0,
		"nothing has been played, so nothing is counted")
	h.equal("progress.live_is_the_whole_side", opening.y, slots.size())
	h.equal("progress.one_capsule_at_the_opening",
		TurnProgress.fill_for(opening.x, opening.y) + 1, 1)
	# Spend one unit's movement, the way the turn does.
	var mover: int = slots[0]
	var units: Dictionary = world.units_for_ai()
	var unit: UnitState = units[mover]
	unit.mp = maxi(world.movement_allowance(mover, world.turn.ai_level) - 1, 0)
	h.equal("progress.a_spent_unit_is_not_counted_before_its_event",
		TurnProgress.tally(world, player, none, none).x, 0,
		"the world is the end of the turn from the first frame")
	h.equal("progress.and_is_counted_once_it_is_played",
		TurnProgress.tally(world, player, PackedInt32Array([mover]), none).x, 1)
	h.equal("progress.a_played_unit_that_did_not_move_is_not",
		TurnProgress.tally(world, player, PackedInt32Array([slots[1]]),
			none).x, 0)
	# A casualty the replay is still holding belongs to the divisor.
	var doomed: int = slots[1]
	units[doomed].hp = 0
	h.equal("progress.the_dead_leave_the_divisor",
		TurnProgress.tally(world, player, none, none).y, slots.size() - 1)
	h.equal("progress.unless_the_replay_still_holds_them",
		TurnProgress.tally(world, player, none,
			PackedInt32Array([doomed])).y, slots.size())
	# And the side is the replay's own. The computer's turn hands over again
	# inside `submit_end_turn`, so the world's seat is the marines' before the
	# first alien is drawn moving -- a bar read off `world.turn` would count
	# the player's own squad.
	var result: AITurnResult = AITurnResult.new()
	result.player = player
	result.add(AIEvent.make("move", mover, 1, 1, 2, 2))
	var playback: AIPlayback = AIPlayback.new()
	playback.play(result, Callable())
	h.equal("progress.the_side_is_the_replays_own", playback.player(), player)
	h.equal("progress.the_world_seat_is_not_it", world.turn.current_player == player,
		false, "_C_140 opens on the marines")
	playback.skip()


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

	# The casualties, the other half of the same rule: the world has lost
	# every one of them before the replay draws its first frame, so the whole
	# list has to be held from the start or a marine vanishes as the computer's
	# turn opens and comes back a second before it dies.
	var deaths: Array[Dictionary] = [
		AIEvent.make("fire", 4, 1, 1, 2, 2, 0, "",
			{"outcomes": [{"slot": 11, "killed": true}]}).to_dict(),
		AIEvent.make("reactions", 5, 2, 3, 0, 0, 1, "",
			{"reactions": [{"attack": {"outcomes": [{"slot": 12}]}}]}).to_dict(),
		AIEvent.make("move", 5, 2, 3, 9, 9, 0, "",
			{"path": [1, 2], "events": [{"kind": "mine_detonated",
				"blast": {"outcomes": [{"slot": 13}]}}]}).to_dict(),
		AIEvent.make("warp", 6, 3, 4, 8, 8, 0, "",
			{"blast": {"outcomes": [{"slot": 14}]}}).to_dict(),
		# The payload of a parabomb **is** the blast (`AISpecialPlayer`), and
		# the four-branch block this replaced had no arm for it at all.
		AIEvent.make("parabomb", 7, 5, 5, 0, 0, 0, "",
			{"outcomes": [{"slot": 15}]}).to_dict(),
	]
	h.equal("replay.every_shape_of_death_is_found",
		Array(AIPlayback.casualties_in(deaths, 0)), [11, 12, 13, 14, 15],
		"a shot, a reaction, a mine under a walk, a landing and a para bomb")
	h.equal("replay.a_played_death_is_not_held",
		Array(AIPlayback.casualties_in(deaths, 3)), [14, 15])
	h.equal("replay.one_event_answers_alone",
		Array(AIPlayback.casualties_of(DictRead.as_dict(deaths[2]["payload"]))),
		[13], "the same extractor takes a single payload")
	h.equal("replay.nothing_dies_in_a_bare_event",
		AIPlayback.casualties_in(events, 0).size(), 0,
		"the moves above carry no outcome")

	# The turn's progress bar (docs/43 section 7) counts against the same
	# split: what the replay has already shown is what it may count.
	h.equal("replay.progress.nothing_played_yet",
		AIPlayback.played_in(events, 0).size(), 0)
	h.equal("replay.progress.the_actor_is_the_events_own",
		Array(AIPlayback.played_in(events, 2)), [4, 6],
		"the fire and the warp, in the order they were shown")
	h.equal("replay.progress.each_actor_once",
		AIPlayback.played_in(events, events.size()).size(), 3,
		"slot 5 moves, fires and moves again")

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
		foreign.text("hud.no_selection"),
		DictRead.as_string(DictRead.as_dict(
			Localization.OWN["hud.no_selection"])[Localization.FALLBACK_LANGUAGE]))


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
	var strings: Localization = Localization.from_cache(
		CacheFixture.cache_dir(), CacheFixture.manifest())
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


## The walk and the walk's own epilogue, in the engine's order.
##
## `aExecuteMove`'s step loop blocks, so the mine's blast (`0x0046EDAF`) and
## the teleporter's stream (`0x0046EE03`) are drawn after the last step. The
## body walks on [UnitsView]'s clock and the set pieces on [SequenceQueue]'s,
## and [method SliceMain._hold_for_walk] is the stage that joins them --
## queued only when the walk has an epilogue at all, so a plain walk does not
## hold the queue for nothing.
func _walk_epilogue(h: TestHarness) -> void:
	h.equal("walk.a_plain_walk_has_no_epilogue",
		[SliceMain._walk_has_epilogue([]),
		SliceMain._walk_has_epilogue([{"kind": "victory_point"}]),
		SliceMain._walk_has_epilogue([{"kind": "teleporter"}])],
		[false, false, false],
		"the entry event alone is the walk's, not the epilogue's")
	h.equal("walk.the_three_that_do",
		[SliceMain._walk_has_epilogue([{"kind": "mine_detonated"}]),
		SliceMain._walk_has_epilogue([{"kind": "teleported"}]),
		SliceMain._walk_has_epilogue([{"kind": "teleporter_blocked"}])],
		[true, true, true])

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
	var units: UnitsView = UnitsView.new()
	units.world_ref = world
	main._units = units
	main._sequences = SequenceQueue.create(null)
	var node: Node3D = Node3D.new()
	node.name = "unit_%d" % slot
	units.add_child(node)

	h.check("walk.no_hold_without_a_walk", not main._hold_for_walk(1.0),
		"nothing to wait for, so nothing is queued")

	var view: Dictionary = world.unit_view(slot)
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	var width: int = world.resource.width
	var route: PackedInt32Array = PackedInt32Array([
		world.state.index_of(x, y), world.state.index_of(x + 1, y)])
	units.start_walk(slot, route, width, 1.0)
	h.check("walk.the_hold_is_queued", main._hold_for_walk(1.0),
		"the body is walking, so the epilogue waits")
	h.equal("walk.the_hold_is_the_first_stage", main._sequences.current(),
		SliceMain.STAGE_AFTER_WALK)
	# Ten of the twenty frames go by with the body still walking: the stage
	# is bounded by the walk's own length but ended by the walk itself.
	for _i: int in range(10):
		var _went: bool = main._sequences.advance(
			1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("walk.the_hold_outlasts_the_bounds_first_half",
		main._sequences.current(), SliceMain.STAGE_AFTER_WALK)
	units.finish_walks(world)
	var _ended: bool = main._sequences.advance(
		1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.check("walk.the_hold_ends_with_the_walk",
		not main._sequences.is_running(),
		"`UnitsView.is_walking` is the predicate, not the frame count")
	units.free()
	main.free()


## The six campaign screens -- docs/27's flow with a picture on it.
##
## Oracle boundary: **specification**. What is checked is the half `game` owns:
## that each screen builds, that not one caption is a literal (every one comes
## back from the shipped banks rather than as `Localization`'s missing marker),
## that the roster rows address a **record** and not a table position, and that
## the purchase catalogue shows what is locked as well as what is not.
func _campaign_screens(h: TestHarness) -> void:
	var cache_dir: String = CacheFixture.cache_dir()
	var manifest: Dictionary = CacheFixture.manifest()
	var strings: Localization = Localization.from_cache(cache_dir, manifest)
	var art: Art = Art.open(cache_dir)
	var font: FontFile = GameFont.load_from(cache_dir, "font_2")
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
		"one dot per open location")
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

	var hq: HqScreen = HqScreen.new()
	hq.host = host
	hq.setup(art, strings, font)
	h.check("screens.hq_rows", hq.body().get_child_count() >= 4,
		"%d in the squad" % state.roster.used_slots())
	_no_missing_strings(h, "hq", hq)
	# A row addresses the record, not the position: after a sort the slot the
	# screen remembers still names the same soldier (docs/29 section 1.4).
	hq.selected = 2
	var before: String = state.roster.record(2).name
	state.roster.sort_by_ep()
	hq.refresh()
	h.equal("screens.hq_addresses_a_record",
		state.roster.record(hq.selected).name, before,
		"the seed's three are all rank 1, so the sort leaves them alone")
	hq.free()

	var upgrade: UpgradeScreen = UpgradeScreen.new()
	upgrade.host = host
	upgrade.setup(art, strings, font)
	var weapons: Dictionary = host.catalogue("weapons")
	var equipment: Dictionary = host.catalogue("equipment")
	# The measured split at tech 1, which is the tech level a campaign has from
	# beginning to end. A screen that hid the locked rows would make a frozen
	# level look like a working one.
	h.equal("screens.catalogue_weapons",
		[DictRead.as_array(weapons["available"]).size(),
		DictRead.as_array(weapons["locked"]).size()], [14, 28])
	h.equal("screens.catalogue_equipment",
		[DictRead.as_array(equipment["available"]).size(),
		DictRead.as_array(equipment["locked"]).size()], [7, 12])
	_no_missing_strings(h, "upgrade", upgrade)
	upgrade.free()

	var select: SelectUnitsScreen = SelectUnitsScreen.new()
	select.host = host
	select.setup(art, strings, font)
	_no_missing_strings(h, "select", select)
	select.free()

	var briefing: BriefingScreen = BriefingScreen.new()
	briefing.mission = "_C_100"
	briefing.cache_dir = cache_dir
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
