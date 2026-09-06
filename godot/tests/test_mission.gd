extends TestSuite

## Oracle boundary: **specification** -- and the stage's gate.
##
## docs/20's win conditions, played rather than asserted: `_C_140` is loaded
## from the cache with its own program attached, its squad is walked to the
## evacuation zone through [method World.submit_move], the turn is handed over
## through [method World.submit_end_turn], and the mission is expected to end
## because the script decided it did.
##
## What makes this a gate rather than a demonstration: **nothing here writes
## `game_control`**. Slot 0 is set by `SetGameControl (0,1)` inside `_C_140`'s
## own `NEXT PLAYER` body, which runs only if the interpreter reached it, which
## needs the two `GetUnits` counts to agree and a unit to be standing on
## `(3,18)` -- so the assertion at the end is a statement about the whole stack
## from the move map up.
##
## The mission's own text, decoded:
## [codeblock]
## >UnitOnField (0,3,18);          SetVarNum (_F,1);           <
## >VarCmpNum (_F,1); &VarCmpVar (_A,_G);  SetGameControl (0,1); <
## [/codeblock]
## `_A` is `GetUnits (0)` and `_G` is `GetUnitsInArea (0, 0,13, 8,19)`, so the
## whole squad must be inside the zone **and** one of them on the marker.

const MISSION: String = "_C_140"
## The evacuation zone `GetUnitsInArea (_G,0,0,13,8,19)` names, and the marker
## `UnitOnField (0,3,18)` names.
const MARKER: Vector2i = Vector2i(3, 18)
const ZONE_TOP_LEFT: Vector2i = Vector2i(0, 13)
const ZONE_BOTTOM_RIGHT: Vector2i = Vector2i(8, 19)
## Where the four squad members are sent. The first is the marker; the other
## three are free cells beside it, inside the zone.
const TARGETS: Array[Vector2i] = [Vector2i(3, 18), Vector2i(4, 18),
	Vector2i(3, 17), Vector2i(4, 17)]

## A bound, not a prediction. The walk used to take 17 player turns against a
## motionless opponent; against one that closes and shoots it takes longer,
## because every shot the squad fires is movement it does not spend. Anything
## past this is a regression that would otherwise hang the run.
const TURN_LIMIT: int = 200
## The movement points the potential fill is given -- enough to flood the whole
## reachable component of a 20x20 map many times over.
const FLOOD_MP: int = 2000
## The turn `_C_140`'s script first inserts reinforcements (`EnvVarGreaterNum
## (_B,4)`), which is what makes the mid-mission save carry a spawned unit.
const FIRST_INSERT_TURN: int = 5
## The fitness at or below which a squad member rests instead of advancing.
## 1 is the last value that still leaves two movement points; 0 leaves one.
const REST_BELOW_FITNESS: int = 1
## `Sgt. Bratt`, `_C_140`'s hero: the squad can lose three soldiers and still
## win, and cannot lose this one at all.
const HERO_TYPE: int = 23
## How close an alien has to be before resting is a bad idea. Every alien on
## this map has range 1, so anything that can reach contact next turn counts.
const DANGER_RANGE: int = 4
## How close an alien has to be before the squad spends points shooting at it.
const ENGAGE_RANGE: int = 6


func run(h: TestHarness) -> void:
	h.begin("mission", TestHarness.ORACLE_SPEC)
	var loaded: Dictionary = CacheFixture.load_mission(MISSION)
	if loaded.is_empty():
		h.check("cache", false,
			"no %s in the cache; run tools/remake_convert.py" % MISSION)
		return
	var world: World = loaded["world"]
	h.check("script.attached", DictRead.as_bool(loaded["script_attached"]),
		"missions/%s/script.json" % MISSION)
	h.check("script.is_the_real_one", world.script_program != null
			and world.script_program.labels.has("NextPlayer"),
		"the entry points the dispatcher jumps to")

	var squad: PackedInt32Array = _squad(world)
	h.equal("squad.size", squad.size(), TARGETS.size(),
		"_C_140 places four units of player 0")
	h.check("squad.starts_outside_the_zone", not _all_in_zone(world, squad),
		"a mission that began won would prove nothing")
	h.equal("control.starts_unset", world.game_control.mission_ended(), false)

	# **Twice, from two fresh worlds, with the same player policy.**
	#
	# The first run is the stage's own claim: the opponent moves, closes and
	# shoots, and the mission ends the way `_C_140` says it ends. The second
	# turns the engine's own "the computer may fire" global off
	# ([member World.ai_may_fire], `0x004FAE40`) and asks the weaker question
	# the second slice used to ask -- can the squad still complete the
	# objective through the whole stack -- so that a failure to *win* is not
	# confused with a failure to *work*.
	var played: Dictionary = _play(h, "live", world, squad,
		DictRead.as_dict(loaded["document"]))

	var quiet_load: Dictionary = CacheFixture.load_mission(MISSION)
	var quiet: World = quiet_load["world"]
	quiet.ai_may_fire = false
	var held: Dictionary = _play(h, "held_fire", quiet, _squad(quiet),
		DictRead.as_dict(quiet_load["document"]))

	# **The acceptance claim, with a check under it.** The comment inside
	# `_play` says "the `held_fire` run below proves it end to end", and until
	# now nothing asserted that: the return value was discarded and `_play`'s
	# own `else` arm accepts a deadlock. So a change that broke the walk badly
	# enough for `_C_140` never to be won on either run left the suite green
	# while the claim stayed in the comment. This is the claim.
	_the_turn_always_comes_back(h)

	h.check("outcome.the_mission_is_completable",
		DictRead.as_bool(held["squad_won"]),
		"with the computer's fire held, the squad still reaches the "
		+ "evacuation zone and _C_140's own SetGameControl (0,1) fires: "
		+ DictRead.as_string(held["summary"]))

	# The one thing only the live run can show, and the first time this
	# project has been able to show it: **the computer can win.** docs/23's
	# planner is what closes on the squad, and `_C_140`'s own
	# `SetGameControl (4,1)` is what records it.
	# **One of the two runs must have carried the script's reinforcements into
	# a save.** Each run alone may end before turn 5 -- the `live` one is
	# meant to be losable -- so the codec claim is made of the pair.
	h.check("outcome.a_save_carried_the_scripts_units",
		DictRead.as_int(played["saved_units"]) > 0
			or DictRead.as_int(held["saved_units"]) > 0,
		"neither run reached a roster the .lev does not describe: live %d, "
		% DictRead.as_int(played["saved_units"])
		+ "held_fire %d" % DictRead.as_int(held["saved_units"]))

	h.check("outcome.defeat_is_reachable",
		DictRead.as_bool(played["computer_won"])
			or DictRead.as_bool(played["hero_died"]),
		"the aliens killed the hero or wiped the squad out: "
		+ DictRead.as_string(played["summary"]))


## `submit_end_turn` never returns with the computer still holding the turn.
##
## docs/25 section 4.1: `aNextPlayerHandling` is
## `do { ... } while (g_currentPlayer == 255 && result == 1)`, and its own
## documentation of that loop is "what lets the computer take its turn without
## returning to the interface". A hand-over that came back with player 255
## holding therefore cannot happen in the engine -- and when it happened here
## it was not cosmetic: [method World.may_command] compares a unit's owner
## against whoever holds the turn, so **the aliens became selectable and the
## player could spend their turn for them**, with the interface waiting for a
## press that only ended a turn that was not theirs.
##
## The case that produced it is turn **zero**: `0x0047D600` runs the planner
## only `if (g_turn != 0)`, so [member TurnResult.ai_turn] is false while the
## computer holds the turn, and a loop written on that flag stopped there. It
## is therefore the *first* press of the button on every mission, which is why
## this walks from a fresh world rather than from the middle of one.
func _the_turn_always_comes_back(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission(MISSION)
	if loaded.is_empty():
		h.check("rotation.cache", false, "no %s in the cache" % MISSION)
		return
	var world: World = loaded["world"]
	var stops: PackedStringArray = PackedStringArray()
	var commandable: PackedStringArray = PackedStringArray()
	var handed: int = 0
	for _i: int in range(TURN_LIMIT):
		var result: TurnResult = world.submit_end_turn(EndTurnCommand.create())
		if not result.ok():
			break
		handed += 1
		if world.turn.current_player == TurnState.PLAYER_COMPUTER:
			stops.append("turn %d" % world.turn.turn)
		for slot: int in world.unit_slots():
			var view: Dictionary = world.unit_view(slot)
			if world.may_command(slot) \
					and DictRead.as_int(view["player"]) \
						== TurnState.PLAYER_COMPUTER:
				commandable.append("turn %d slot %d" % [world.turn.turn, slot])
		if world.game_control.mission_ended():
			break
	h.check("rotation.hand_overs_happened", handed > 1,
		"%d hand-overs returned ok" % handed)
	h.equal("rotation.never_stops_on_the_computer", stops,
		PackedStringArray(),
		"an ok hand-over always comes back to a human player")
	h.equal("rotation.the_aliens_are_never_commandable", commandable,
		PackedStringArray(),
		"World.may_command refuses every alien after every hand-over")


## The squad, in slot order.
static func _squad(world: World) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["player"]) == 0 \
				and DictRead.as_int(view["hp"]) > 0:
			out.append(slot)
	return out


## Whether every **live** squad member is inside the zone.
##
## Live, not placed: `_C_140`'s own condition is `GetUnits (0)` against
## `GetUnitsInArea (0, 0,13, 8,19)`, and both count the living. A member the
## aliens killed on the way in does not keep the mission from being won -- and
## with an opponent that shoots back, one of them usually does not make it.
static func _all_in_zone(world: World, squad: PackedInt32Array) -> bool:
	for slot: int in _squad(world):
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			continue
		var x: int = DictRead.as_int(view["x"])
		var y: int = DictRead.as_int(view["y"])
		if x < ZONE_TOP_LEFT.x or x > ZONE_BOTTOM_RIGHT.x \
				or y < ZONE_TOP_LEFT.y or y > ZONE_BOTTOM_RIGHT.y:
			return false
	return true


## Walk the squad in, handing the turn over between rounds, until the script
## ends the mission.
func _play(h: TestHarness, label: String, world: World,
		squad: PackedInt32Array, document: Dictionary) -> Dictionary:
	# One fill per target, from the target outwards, on the map as authored.
	# `mp_left` is then a proximity field: higher is closer. A greedy walk on
	# the Chebyshev distance instead walks into the wall across row 12 and
	# stops -- measured, on this map, before this was written.
	var potential: Array[PackedInt32Array] = []
	for i: int in range(squad.size()):
		var view: Dictionary = world.unit_view(squad[i])
		potential.append(_potential(document, world.unit_types(),
			world.ctrlmap(), DictRead.as_int(view["type_id"]), TARGETS[i]))

	# The first hand-over: `arg != 0` searches from slot 0 instead of advancing,
	# which is how a mission starts (docs/25 section 3.1).
	var first: TurnResult = world.submit_end_turn(EndTurnCommand.create(1))
	h.equal("%s.first_hand_over" % label, first.code, TurnResult.OK,
		"arg 1 searches from slot 0")

	var saved: PackedByteArray = PackedByteArray()
	var saved_hash: String = ""
	var saved_units: int = 0
	var rounds: int = 0
	var moves: int = 0
	var shots: int = 0
	var rests: int = 0
	var last_code: int = -1
	var last_refreshed: int = -1
	var last_ai: bool = false
	while rounds < TURN_LIMIT and not world.game_control.mission_ended():
		rounds += 1
		if world.turn.current_player == 0:
			# **Move first, then shoot with whatever is left.** Both cost the
			# same movement points now that the player's shot is charged for
			# (`aUI.cpp:3516`), and a squad that fires before it walks spends
			# its turn standing still -- measured, on this map, before this
			# comment was written.
			# **Shoot first, then take one step, and rest only when nothing
			# is close.** Every alien on `_C_140` is a melee type -- weapon 20
			# and 21, range 1, and `Giant Claws` does 20 damage against
			# soldiers with eight to ten hit points -- so one that reaches
			# contact kills. The squad has to kill them at range 10 on the way
			# past, and the script keeps inserting more from turn 5, so it
			# also has to keep walking. [method _fight] leaves one point in
			# reserve and [method _step] spends it.
			for i: int in range(squad.size()):
				var view: Dictionary = world.unit_view(squad[i])
				if view.is_empty() or DictRead.as_int(view["hp"]) == 0 \
						or DictRead.as_int(view["player"]) != 0:
					# **The slot may not be ours any more.** `InsertUnit`
					# takes the first record with no hit points, so a squad
					# member the aliens killed is reused by the script's own
					# reinforcements a few turns later -- and commanding it
					# would be commanding an alien.
					continue
				# **Fight the opening, then walk.** Up to and including the
				# turn the script starts inserting reinforcements the squad
				# spends everything on what is in front of it; after that it
				# takes its step first and fires with what is left. Both
				# halves are needed and neither works alone -- see the note
				# on [method _step].
				var stepped: bool = false
				if world.turn.turn <= FIRST_INSERT_TURN:
					shots += _fight(world, squad[i])
					stepped = _step(world, squad[i], potential[i], false)
				else:
					stepped = _step(world, squad[i], potential[i], true)
					shots += _fight(world, squad[i])
				if stepped:
					moves += 1
					continue
				# It could not move: either it is out of points or the path
				# runs through somebody. docs/10 section 5.5 -- fitness 0
				# forces the allowance to one point, and one point a turn does
				# not cross this map, so a turn spent standing down buys a
				# point of fitness back (docs/25 section 8). Never within
				# reach of something that kills in one blow.
				if DictRead.as_int(view["fp"]) <= REST_BELOW_FITNESS \
						and not _enemy_within(world, squad[i], DANGER_RANGE):
					if world.submit_stand_down(
							StandDownCommand.create(squad[i])):
						rests += 1
		# The mid-mission save is taken once the script has inserted at least
		# one unit, so the hash it preserves covers a roster the `.lev` does
		# not describe.
		if saved.is_empty() and world.turn.turn >= FIRST_INSERT_TURN \
				and world.unit_slots().size() > squad.size() + 2:
			saved = world.save({})
			saved_hash = world.canonical_hash_hex()
			saved_units = world.unit_slots().size()
		var handed: TurnResult = world.submit_end_turn(EndTurnCommand.create())
		last_code = handed.code
		last_refreshed = handed.refreshed.size()
		last_ai = handed.ai_result != null
		if handed.code != TurnResult.OK and not handed.mission_ended:
			h.check("%s.hand_over_%d" % [label, rounds], false,
				"code %d at turn %d" % [handed.code, world.turn.turn])
			return _outcome(world, "stopped at round %d" % rounds)

	var ended: bool = world.game_control.mission_ended()
	var summary: String = ("%d round(s), %d move(s), %d shot(s), %d rest(s); "
		% [rounds, moves, shots, rests]
		+ "%d of the squad alive; in the zone %s"
		% [_squad(world).size(), _zone_census(world)])
	h.check("%s.moved" % label, moves > 0, summary)
	# `rests >= 0` stood here and **could not fail**: the counter starts at
	# zero and is only ever incremented. Replacing it with `rests > 0` showed
	# what it had been hiding -- **the walk never rests.** The arm needs a
	# squad member at fitness 1 or less with no enemy inside
	# [constant DANGER_RANGE], and on this map that pair of conditions never
	# meets: the squad is either fresher than that or in contact. So the
	# number is recorded as the census it is, and it fails if the walk's
	# behaviour moves. The stand-down command itself is checked where it can
	# be built deliberately, in `test_combat.gd`'s overwatch scene.
	h.equal("%s.rests" % label, rests, 0,
		"nobody tires to fitness 1 while out of contact on this map")
	h.check("%s.fought" % label, shots > 0,
		"%d shot(s) -- the squad has to fight its way in now that the aliens "
		% shots + "close and shoot back (docs/23)")

	# **A run that reaches the bound is a stalemate, and is recorded as one.**
	#
	# Against a motionless opponent this walk finished in 17 rounds. Against
	# docs/23's planner it does not finish at all: the script inserts a
	# reinforcement almost every turn from turn 5, they converge on the squad,
	# and the corridor into the evacuation zone ends up plugged by aliens the
	# squad has no line of sight to. So the bound is not a failure here -- it
	# is the outcome -- and what has to stay true is that the run **ended
	# somewhere definite**: either the mission decided, or it deadlocked with
	# the squad still alive and still trying.
	#
	# This is the honest state of the stage's seventh acceptance item: the
	# mission is winnable through the whole stack (the `held_fire` run below
	# proves it end to end) and losable to the live opponent
	# (`outcome.defeat_is_reachable`), and a *scripted* squad does not beat
	# this opponent on this map. docs/95 records it as an open question rather
	# than as a check that was quietly relaxed.
	#
	# `ended or rounds >= TURN_LIMIT` stood here and **could not fail**: the
	# loop above exits on exactly those two conditions, so the check restated
	# its own guard. What the run has to show instead is that it got somewhere
	# under its own power -- the squad still has units, the walk both moved and
	# fired, and if it did not end then it used its whole budget rather than
	# stopping early for a reason nobody recorded.
	h.check("%s.ran_to_a_definite_end" % label,
		(ended and rounds < TURN_LIMIT) or (not ended
			and rounds == TURN_LIMIT and not _squad(world).is_empty()),
		summary)

	# **Each of the three outcomes is asserted for what it is**, rather than
	# one of them being asserted and the others tolerated. `_C_140`'s own
	# NEXT PLAYER body sets slot 0 when every live squad member is inside the
	# zone with one on the marker, and slot 4 when player 0 has nobody left or
	# the hero is dead.
	var squad_won: bool = world.game_control.get_slot(0) == 1
	var computer_won: bool = world.game_control.get_slot(4) == 1
	h.check("%s.exactly_one_outcome" % label,
		int(squad_won) + int(computer_won) <= 1,
		"slot 0 %d slot 4 %d" % [world.game_control.get_slot(0),
			world.game_control.get_slot(4)])
	if squad_won:
		h.check("%s.win_puts_the_squad_in_the_zone" % label,
			_all_in_zone(world, squad),
			"the whole live squad inside (0,13)-(8,19); at "
			+ _where(world, squad))
		h.check("%s.win_puts_a_unit_on_the_marker" % label,
			_on_marker(world, squad), "UnitOnField (0,3,18)")
	elif computer_won:
		h.check("%s.defeat_lost_the_squad_or_the_hero" % label,
			_squad(world).is_empty() or not _hero_alive(world),
			"`VarCmpNum (_A_p0,0) | HeroKilled (0)`: %d alive, hero %s"
			% [_squad(world).size(),
				"alive" if _hero_alive(world) else "dead"])
	else:
		h.check("%s.deadlock_leaves_the_squad_in_the_field" % label,
			not _squad(world).is_empty() and rounds >= TURN_LIMIT,
			"neither condition fired inside the bound: " + summary)
	# `the_script_decided` stood here with the same expression as the check
	# above -- two names over one tautology. What the mission's own body
	# actually promises is that it never sets **both** outcome slots and never
	# sets one to a value it has no arm for, which is a statement the run can
	# violate.
	h.check("%s.the_script_wrote_a_value_it_has_an_arm_for" % label,
		world.game_control.get_slot(0) in [0, 1]
			and world.game_control.get_slot(4) in [0, 1],
		"_C_140's NEXT PLAYER body writes only SetGameControl (0,1) and "
		+ "(4,1): slot 0 %d slot 4 %d" % [world.game_control.get_slot(0),
			world.game_control.get_slot(4)])
	h.equal("%s.the_next_map_is_named" % label, world.next_map, "_C_141",
		"EnterNameOfNextMap from the InitMap entry -- or the header, which agrees")
	

	# The mid-mission save, with the script's own reinforcements in it.
	#
	# **A run that ended before turn 5 has none to take**, and that is not a
	# failure of the codec: `_C_140` inserts nothing until
	# [constant FIRST_INSERT_TURN]. Both runs pass that turn under the policy
	# of [method _step], so this is a demand and not an excuse -- the
	# `or ended` clause that stood here while the `live` run was dying at
	# round 5 made it unfalsifiable, and is gone.
	h.check("%s.save_taken_mid_mission" % label,
		not saved.is_empty() or world.turn.turn < FIRST_INSERT_TURN,
		"%d unit(s) at the time, against the %d the .lev places, at turn %d"
			% [saved_units, squad.size() + 2, world.turn.turn])
	if saved.is_empty():
		return _outcome(world, summary)
	h.check("%s.save_carries_inserted_units" % label, saved_units > squad.size() + 2,
		"the roster grew before the save was taken")
	var restored: World = CacheFixture.load_mission(MISSION)["world"]
	h.equal("%s.save_loads" % label, restored.load_save(saved), SaveCodec.Result.OK)
	h.equal("%s.save_round_trip_preserves_the_hash" % label,
		restored.canonical_hash_hex(), saved_hash,
		"including both generators, the turn and the game-control slots")
	h.equal("%s.save_round_trip_preserves_the_roster" % label,
		restored.unit_slots().size(), saved_units)
	return _outcome(world, summary, saved_units)


## What the run came to, for the caller that compares the two.
static func _outcome(world: World, summary: String,
		saved_units: int = 0) -> Dictionary:
	return {
		"computer_won": world.game_control.get_slot(4) == 1,
		"squad_won": world.game_control.get_slot(0) == 1,
		# How many records the mid-mission save carried, or 0 when the run
		# never reached a grown roster -- see `save_taken_mid_mission`.
		"saved_units": saved_units,
		# The hero is the one type the squad cannot lose: `_C_140`'s own
		# `HeroKilled (0)` is what sets slot 4 beside a wipe-out.
		"hero_died": not _hero_alive(world),
		"summary": summary,
	}


## docs/20 section 7.4 -- `HeroKilled (player)` looks for a live unit whose
## type is a named character rather than a rank-and-file soldier. On `_C_140`
## that is slot 2, `Sgt. Bratt`.
static func _hero_alive(world: World) -> bool:
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["player"]) != 0:
			continue
		if DictRead.as_int(view["hp"]) == 0:
			continue
		if DictRead.as_int(view["type_id"]) == HERO_TYPE:
			return true
	return false


## Shoot at the best target in range, until the points run out.
##
## The rule is the computer's own (docs/23 section 6): the highest hit chance
## wins, with no weighting for health or threat. Written out here rather than
## reached through `core/ai/` because this is the *player* firing, and the
## player's shot goes through [method World.submit_attack] like every other
## command a person could give.
static func _fight(world: World, slot: int) -> int:
	var shots: int = 0
	while true:
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			return shots
		var weapon: int = DictRead.as_int(view["weapon"])
		# Everything that is left, the walk having already happened -- see
		# [method _step], which is what keeps a shot affordable.
		if DictRead.as_int(view["mp"]) < world.weapons().ap(weapon):
			return shots
		# **Only what is close enough to matter.** Every alien on this map is
		# melee, so one at range 10 is not a threat this turn and a point
		# spent on it is a point not spent getting to the zone.
		if not _enemy_within(world, slot, ENGAGE_RANGE):
			return shots
		var target: Vector2i = _best_target(world, slot)
		if target.x < 0:
			return shots
		var shot: AttackResult = world.submit_attack(
			AttackCommand.create(slot, target.x, target.y))
		if not shot.fired:
			return shots
		shots += 1
		if shots > TURN_LIMIT:
			return shots
	return shots


## Whether a live enemy is within `fields` of this unit.
static func _zone_census(world: World) -> String:
	var by_player: Dictionary = {}
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["hp"]) == 0:
			continue
		var x: int = DictRead.as_int(view["x"])
		var y: int = DictRead.as_int(view["y"])
		if x < ZONE_TOP_LEFT.x or x > ZONE_BOTTOM_RIGHT.x \
				or y < ZONE_TOP_LEFT.y or y > ZONE_BOTTOM_RIGHT.y:
			continue
		var player: int = DictRead.as_int(view["player"])
		by_player[player] = DictRead.as_int(by_player.get(player, 0)) + 1
	return str(by_player)


static func _enemy_within(world: World, slot: int, fields: int) -> bool:
	var view: Dictionary = world.unit_view(slot)
	if view.is_empty():
		return false
	for other: int in world.unit_slots():
		var them: Dictionary = world.unit_view(other)
		if DictRead.as_int(them["hp"]) == 0:
			continue
		if DictRead.as_int(them["player"]) == DictRead.as_int(view["player"]):
			continue
		if MoveMap.distance(DictRead.as_int(view["x"]),
				DictRead.as_int(view["y"]), DictRead.as_int(them["x"]),
				DictRead.as_int(them["y"])) <= fields:
			return true
	return false


## The visible enemy with the highest hit chance, or `(-1, -1)`.
static func _best_target(world: World, slot: int) -> Vector2i:
	var shooter: Dictionary = world.unit_view(slot)
	var best: Vector2i = Vector2i(-1, -1)
	var best_chance: int = 0
	for other: int in world.unit_slots():
		var view: Dictionary = world.unit_view(other)
		if DictRead.as_int(view["hp"]) == 0:
			continue
		if DictRead.as_int(view["player"]) == DictRead.as_int(shooter["player"]):
			continue
		# docs/22 section 9.1 -- 0 is fully visible and 1 is *contact*, which
		# is still a unit the player can see and shoot at. Only 3 is hidden.
		# Requiring exactly 0 here left the squad refusing to fire at aliens
		# standing in the corridor in front of it: 25 shots in 200 rounds.
		if DictRead.as_int(view["visibility"]) == UnitState.VISIBILITY_HIDDEN:
			continue
		var chance: int = world.hit_chance(slot, other)
		if chance > best_chance:
			best_chance = chance
			best = Vector2i(DictRead.as_int(view["x"]),
				DictRead.as_int(view["y"]))
	return best


static func _where(world: World, squad: PackedInt32Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for slot: int in _squad(world):
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty():
			parts.append("%d gone" % slot)
			continue
		parts.append("%d(%d,%d) hp%d mp%d fp%d st%d alw%d p%d" % [slot,
			DictRead.as_int(view["x"]), DictRead.as_int(view["y"]),
			DictRead.as_int(view["hp"]), DictRead.as_int(view["mp"]),
			DictRead.as_int(view["fp"]), DictRead.as_int(view["action_state"]),
			world.movement_allowance(slot), DictRead.as_int(view["player"])])
	return ", ".join(parts)


static func _on_marker(world: World, squad: PackedInt32Array) -> bool:
	for slot: int in _squad(world):
		var view: Dictionary = world.unit_view(slot)
		if Vector2i(DictRead.as_int(view["x"]),
				DictRead.as_int(view["y"])) == MARKER:
			return true
	return false


## A fill run **from** a target with more movement points than any map needs.
##
## The result's `mp_left` is a monotone proximity field over the component the
## target sits in, which is what turns "walk toward it" into something that
## survives a wall. A greedy walk on the Chebyshev distance instead stops
## against the wall across row 12 -- measured, on this map, before this was
## written.
##
## Built on **its own** [MapState] with an empty roster, not on the world's:
## `core` hands out no live [UnitState], and a test that reached in to move one
## would put a hole in exactly the isolation `test_isolation.gd` guards.
static func _potential(document: Dictionary, utab: UnitTypeTable,
		ctab: CtrlMapTable, type_id: int,
		target: Vector2i) -> PackedInt32Array:
	var state: MapState = MapState.from_resource(
		MapResource.from_document(document))
	for i: int in range(state.cell_count()):
		state.set_unit(i, MapState.NO_UNIT)
	var probe: UnitState = UnitState.new()
	probe.slot = 0
	probe.type_id = type_id
	probe.player = 0
	probe.x = target.x
	probe.y = target.y
	probe.hp = 1
	probe.fp = 255
	probe.mp = FLOOD_MP
	state.set_unit(state.index_of(target.x, target.y), 0)
	return MoveMap.build(state, {0: probe}, utab, ctab, 0, false, FLOOD_MP,
		FLOOD_MP).mp_left()


## One unit's move for one turn: the reachable cell with the highest potential,
## preferring one that still pays for a shot when *keep_a_shot* asks for it.
##
## **Why the policy has two halves, both measured.** The close-combat swap of
## docs/21 section 6 is what made this visible: a `special` 1 gun becomes a
## bayonet with `mun` 255 when the target is next door, so a squad in contact
## never runs dry again. The magazine had been doing a movement reserve's job
## by accident, and once it stopped:
##
## * firing first with everything, every turn, is 200 rounds of stabbing the
##   reinforcements and 37 moves -- the squad never leaves the middle of the
##   map (measured);
## * a flat one-point reserve in [method _fight] buys the walk back and costs
##   a round of fire a turn: `held_fire` still wins and `live` is dead by
##   turn 5, before `_C_140` has inserted anything at all, so the mid-mission
##   save has nothing to carry (measured);
## * walking first and firing with the remainder is better at the walk and no
##   better at surviving -- `held_fire` wins in 16, `live` still dies at turn
##   5 with 8 shots fired (measured);
## * **fighting the opening and walking after it** is what does both:
##   everything goes into the fight up to and including
##   [constant FIRST_INSERT_TURN], and from the turn after that the step comes
##   first and keeps one shot affordable. `held_fire` wins, and `live` lives
##   to turn 6 -- one turn past the first insertion -- so its mid-mission save
##   carries a roster the `.lev` does not describe (measured).
##
## The reserve itself is the fill's own `mp_left`: it says what each reachable
## cell leaves behind, so the cells that still pay for a round are preferred
## and the rest are tried after them rather than refused.
static func _step(world: World, slot: int,
		potential: PackedInt32Array, keep_a_shot: bool) -> bool:
	var view: Dictionary = world.unit_view(slot)
	if DictRead.as_int(view["hp"]) <= 0:
		return false
	var here: int = world.state.index_of(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))
	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(slot))
	# **Reachable, not "reachable with points to spare".** `mp_left` is zero on
	# the cells at the very edge of the fill -- the furthest a unit can get
	# this turn -- and those are exactly the ones that make progress. Testing
	# it for `> 0` capped every step at the unit's allowance minus one and
	# left the squad shuffling: 24 moves in 120 rounds, measured.
	var reach: PackedByteArray = fill.states()
	# What each reachable cell leaves behind, so a step can stop one cell
	# short and still pay for the shot [method _fight] takes after it.
	var left: PackedInt32Array = fill.mp_left()
	var keep: int = 0
	if keep_a_shot and _enemy_within(world, slot, ENGAGE_RANGE):
		keep = world.weapons().ap(DictRead.as_int(view["weapon"]))
	# **Every candidate, best first, until one of them can actually be
	# walked.** `submit_move` refuses a path that runs through a unit
	# (docs/23 section 5.3: `blocked != 0` moves nothing), and with four
	# soldiers advancing together and aliens closing on them, the single best
	# cell is very often behind somebody. Taking only that one left the squad
	# stalled in the middle of the map -- 17 moves in 120 rounds, measured.
	var candidates: Array[int] = []
	for i: int in range(reach.size()):
		if reach[i] == MoveMapResult.STATE_REACHABLE \
				and potential[i] > potential[here] \
				and world.state.unit_at(i) == MapState.NO_UNIT:
			candidates.append(i)
	if candidates.is_empty():
		return false
	candidates.sort_custom(func(a: int, b: int) -> bool:
		return potential[a] > potential[b])
	# **The cells that still pay for a shot, best first, and then the rest.**
	# Not a filter: a squad that refused to move because no affordable cell
	# was better off would stand in front of an alien rather than walk past
	# it, which is neither the mission nor a fight.
	var order: Array[int] = []
	if keep > 0:
		for index: int in candidates:
			if left[index] >= keep:
				order.append(index)
	for index: int in candidates:
		if not order.has(index):
			order.append(index)
	for index: int in order:
		var moved: MoveResult = world.submit_move(MoveCommand.create(slot,
			index % world.state.width, index / world.state.width))
		if moved.ok and moved.steps > 0:
			return true
	return false
