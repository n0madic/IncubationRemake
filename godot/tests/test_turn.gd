extends TestSuite

## Oracle boundary: **executable Python**, which is itself pinned to the native
## runtime.  `tools/turn_gold.py --check` diffs `tools/inclib/turn.py` against
## `0x0043B320` and `0x004781C0` inside a live `Incubation.exe`; this suite
## diffs `core/` against the same rules.
##
## The rotation cases come straight from that capture's shape: a campaign save
## has one human slot and the computer, so the cycle is `0, 255, 0, ...` and
## `any_player_left_this_turn` alternates with it because the computer moves
## last.

const PLAYER_COMPUTER: int = TurnState.PLAYER_COMPUTER


func _campaign_state() -> TurnState:
	var state: TurnState = TurnState.create()
	state.turn = 1
	state.current_player = 0
	state.player_count = 1
	state.player_kind = PackedInt32Array([1, 0, 0, 0])
	state.end_state = PackedInt32Array([1, 0, 0, 0])
	state.solo_flag = true
	state.ai_level = 0
	return state


func run(h: TestHarness) -> void:
	h.begin("turn", TestHarness.ORACLE_PYTHON)
	_rotation(h)
	_turn_counter(h)
	_refresh(h)
	_stand_down_and_stimulant(h)
	_load_sweep(h)
	_hash_and_save(h)


## `0x004783D0` -- the post-load sweep, all three of its arms.
##
## The session is the default one every campaign save reads,
## `player_kind = [1, 0, 0, 0]` with one human, so: player 0 and player 255
## stay and are recomputed, a player-1 marine comes off the map, and a
## player-1 *inanimate* (species 2, the owner of 181 shipped barrels and
## cases) stays because the sweep forgives it. Weapon 3 is the Sniper Rifle,
## whose magazine is 15 -- authored here as 1 so the recompute is visible.
func _load_sweep(h: TestHarness) -> void:
	var mine: Dictionary = TestFixtures.unit(0, 1, 1, 0, 0, 4, 0, [], 3, 1)
	var alien: Dictionary = TestFixtures.unit(1, 3, 1, 0,
		UnitState.PLAYER_ALIEN, 4, 0, [], 3, 1)
	var absent: Dictionary = TestFixtures.unit(2, 5, 1, 0, 1, 4, 0, [], 3, 1)
	var barrel: Dictionary = TestFixtures.unit(3, 1, 3,
		TestFixtures.INANIMATE_TYPE, 1, 4, 0, [], 3, 1)
	var world: World = World.create(TestFixtures.map_document(7, 7,
		[mine, alien, absent, barrel]), TestFixtures.balance(), 1.0)
	# One human, which is what every campaign save reads.
	h.equal_ints("load_sweep.session", world.turn.player_kind,
		PackedInt32Array([1, 0, 0, 0]))

	var removed: int = world.load_sweep()
	h.equal("load_sweep.removed", removed, 1,
		"only the player-1 marine; the barrel's species forgives its owner")
	# The record stays in the array with a zero hit-point byte -- that byte
	# **is** the free-slot marker, and `0x00477ABD` is all `aUI_KillUnit`
	# writes. So the slot is still there and no longer alive.
	h.equal_ints("load_sweep.slots_stay", world.unit_slots(),
		PackedInt32Array([0, 1, 2, 3]))
	h.equal("load_sweep.the_absent_owner_is_dead",
		DictRead.as_int(world.unit_view(2)["hp"]), 0)
	h.equal("load_sweep.the_absent_owner_is_off_the_cell",
		world.state.unit_at(world.state.index_of(5, 1)), MapState.NO_UNIT)
	# `aUI_KillUnit` is not a death: `0x0043B8D0` is at the call sites.
	h.equal_ints("load_sweep.nothing_was_counted_as_lost",
		world.turn.mission_lost, PackedInt32Array([0, 0, 0, 0]))

	var magazine: int = world.weapons().magazine(3)
	h.check("load_sweep.the_fixture_authored_a_wrong_magazine", magazine != 1,
		"weapon 3 holds %d, the record was authored with 1" % magazine)
	for slot: int in [0, 1, 3]:
		var view: Dictionary = world.unit_view(slot)
		h.equal("load_sweep.slot_%d.ammo" % slot,
			DictRead.as_int(view["ammo"]), magazine)
		h.equal("load_sweep.slot_%d.hp" % slot, DictRead.as_int(view["hp"]),
			world.max_hit_points(slot),
			"the recompute fills the hit points to the ceiling")


## docs/25 section 8 -- the two one-screen routines, and the hand-over that
## pays for them.
##
## No shipped `.lev` carries a unit that has stood down or spent a stimulant --
## `+0x41` is 0 and `+0x58` is its charge in every placed record -- so the only
## way to reach either arm of [Refresh] from *play* is through these commands.
## Before they existed the refresh's two rewards were tested and unreachable.
func _stand_down_and_stimulant(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var slot: int = world.unit_slots()[0]
	var before: int = DictRead.as_int(world.unit_view(slot)["mp"])
	h.check("stand_down.spends_the_turn",
		world.submit_stand_down(StandDownCommand.create(slot)),
		"mp was %d" % before)
	var after: Dictionary = world.unit_view(slot)
	h.equal("stand_down.zeroes_the_movement_points",
		DictRead.as_int(after["mp"]), 0)
	h.equal("stand_down.sets_action_state_7",
		DictRead.as_int(after["action_state"]), Refresh.ACTION_STOOD_DOWN)
	h.check("stand_down.had_points_to_spend", before > 0,
		"a unit with none already would prove nothing")
	h.equal("stand_down.a_missing_slot_is_refused",
		world.submit_stand_down(StandDownCommand.create(99)), false)

	# The reward, end to end: the hand-over turns state 7 into `rested = 1`,
	# which the allowance formula reads. This is the arm that was unreachable.
	var rested: World = TestFixtures.tiny_world()
	var rested_slot: int = rested.unit_slots()[0]
	var _stood: bool = rested.submit_stand_down(
		StandDownCommand.create(rested_slot))
	var _handed: TurnResult = rested.submit_end_turn(
		EndTurnCommand.create(1))
	h.equal("stand_down.the_refresh_pays_for_it",
		DictRead.as_int(rested.unit_view(rested_slot)["rested"]), 1,
		"docs/25 section 5: the hand-over reads +0x41 == 7 and writes +0x57")

	# The stimulant: the **old** value is what is added, and 255 is "spent this
	# turn" rather than "gone".
	var empty: World = TestFixtures.tiny_world()
	h.equal("stimulant.a_unit_with_none_cannot_spend_one",
		empty.submit_stimulant(
			SpendStimulantCommand.create(empty.unit_slots()[0])),
		false, "the fixture's units carry 0")

	# The charge is a **fixture parameter**, not a setter: `core` hands out no
	# live [UnitState], and adding one so a test could arm a unit would be the
	# hole `test_isolation.gd` exists to prevent.
	var dosed: World = World.create(TestFixtures.map_document(7, 7,
		[TestFixtures.unit(0, 2, 2, 0, 0, 4, 0, [], 0, 0, 0, 10, 2)]),
		TestFixtures.balance(), 1.0)
	var dosed_slot: int = 0
	var mp_before: int = DictRead.as_int(dosed.unit_view(dosed_slot)["mp"])
	h.check("stimulant.spends",
		dosed.submit_stimulant(SpendStimulantCommand.create(dosed_slot)),
		"a Heavy Stimulant")
	h.equal("stimulant.a_heavy_one_is_worth_two",
		DictRead.as_int(dosed.unit_view(dosed_slot)["mp"]), mp_before + 2)
	h.equal("stimulant.spending_writes_255",
		DictRead.as_int(dosed.unit_view(dosed_slot)["stimulant"]),
		Refresh.STIMULANT_SPENT)
	h.equal("stimulant.only_once_a_turn",
		dosed.submit_stimulant(SpendStimulantCommand.create(dosed_slot)),
		false)
	var _handed_again: TurnResult = dosed.submit_end_turn(
		EndTurnCommand.create(1))
	h.equal("stimulant.the_refresh_gives_it_back",
		DictRead.as_int(dosed.unit_view(dosed_slot)["stimulant"]), 0,
		"docs/25 section 8: not consumed, a once-a-turn button")



## The turn is simulation state, so it is in the canonical hash and it survives
## a save -- docs/92 section 7.3, and acceptance item 10 of this slice.
##
## Each field is moved on its own and the hash re-taken, because a digest that
## covered only the turn counter would pass a "the turn is hashed" test written
## against the counter alone.
func _hash_and_save(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var base: String = world.canonical_hash_hex()

	# Each field is moved on its own, from a fresh world each time, so a digest
	# that happened to cover only the counter cannot pass this.
	var fields: Array[String] = ["turn", "current_player", "previous_player",
		"player_count", "ai_level", "solo_flag", "player_kind", "end_state",
		"reaction_counter", "hero_killed", "turn_control"]
	for field: String in fields:
		var moved: World = TestFixtures.tiny_world()
		match field:
			"turn": moved.turn.turn = 7
			"current_player": moved.turn.current_player = 255
			"previous_player": moved.turn.previous_player = 3
			"player_count": moved.turn.player_count = 2
			"ai_level": moved.turn.ai_level = 2
			"solo_flag": moved.turn.solo_flag = false
			"player_kind": moved.turn.player_kind = PackedInt32Array([1, 1, 0, 0])
			"end_state": moved.turn.end_state = PackedInt32Array([0, 5, 0, 0])
			"reaction_counter": moved.turn.reaction_counter = \
				PackedInt32Array([0, 0, 0, 9])
			"hero_killed": moved.turn.hero_killed = \
				PackedInt32Array([0, 1, 0, 0])
			"turn_control": moved.turn.turn_control = 4
		h.check("hash.covers_%s" % field,
			moved.canonical_hash_hex() != base,
			"moving %s must change the digest" % field)

	# The round trip, mid-turn: the state that comes back has to hash the same.
	var live: World = TestFixtures.tiny_world()
	live.turn.turn = 5
	live.turn.current_player = 255
	live.turn.previous_player = 0
	live.turn.reaction_counter = PackedInt32Array([2, 0, 0, 0])
	# The hero counter is live gameplay state now (docs/22 section 9.5), so a
	# save that dropped it would un-fire a mission's defeat condition on
	# reload. It is checked in both directions: it must reach the digest above
	# and it must come back out of the blob below.
	live.turn.hero_killed = PackedInt32Array([0, 0, 3, 0])
	# **A load ends with a fog pass** -- `aLoad.cpp:1649` (`0x004490A9`) calls
	# `aBuildVisibleMap(aGetCurrentPlayer())` after the objectives are read
	# back, so the `+0x4F` bytes a save carries are not the ones the loaded
	# mission plays with. The digest is therefore stable across a round trip
	# from a world whose fog is already that pass's, and a world whose fog is
	# whatever its `.lev` authored moves on the first load. Both are checked.
	var authored: String = live.canonical_hash_hex()
	var first: PackedByteArray = live.save({"x": 1.0})
	var settled: World = TestFixtures.tiny_world()
	h.check("save.the_load_rebuilds_the_fog",
		settled.load_save(first) == SaveCodec.Result.OK
			and settled.canonical_hash_hex() != authored,
		"the authored +0x4F bytes survived a load, so the pass did not run")
	var before: String = settled.canonical_hash_hex()
	var blob: PackedByteArray = settled.save({"x": 1.0})
	var reloaded: World = TestFixtures.tiny_world()
	var code: int = reloaded.load_save(blob)
	h.check("save.round_trip_accepts", code == SaveCodec.Result.OK,
		"result %d" % code)
	h.check("save.round_trip_preserves_the_hash",
		reloaded.canonical_hash_hex() == before, "digest differs")
	h.check("save.round_trip_preserves_the_turn",
		reloaded.turn.turn == 5
			and reloaded.turn.current_player == 255
			and reloaded.turn.reaction_counter == PackedInt32Array([2, 0, 0, 0]),
		str(reloaded.turn.view()))
	h.equal("save.round_trip_preserves_the_hero_counter",
		reloaded.turn.hero_killed, PackedInt32Array([0, 0, 3, 0]),
		"docs/22 section 9.5: HeroKilled has to survive a save")
	# **The one-shot latch is saved too**, by `aSaveViewPlayer` /
	# `aLoadViewPlayer` (`0x0047DBE0` / `0x0047DC20`, 0x44C bytes from
	# `0x005229D0`). This remake derives it from the turn counter instead, so
	# a mid-mission save must not let the reset inside the one-shot run again
	# and wipe the counter it just restored.
	reloaded.submit_end_turn(EndTurnCommand.create())
	h.equal("save.a_loaded_turn_does_not_re_run_the_one_shot",
		reloaded.turn.hero_killed, PackedInt32Array([0, 0, 3, 0]),
		"0x0043B78C clears +0x24, and a spent latch is what stops it")
	# The schema rose to 4 with this slice, so a slice-1 save is refused by
	# name rather than misread.
	var stale: PackedByteArray = blob.duplicate()
	stale.encode_s32(4, 3)
	h.check("save.refuses_the_previous_schema",
		reloaded.load_save(stale) == SaveCodec.Result.BAD_SCHEMA,
		"a version-3 save must not load")


func _rotation(h: TestHarness) -> void:
	var state: TurnState = _campaign_state()
	var live: Callable = func(_slot: int) -> int: return 1
	var seen_current: Array[int] = []
	var seen_left: Array[bool] = []
	for _step: int in range(12):
		seen_current.append(state.current_player)
		seen_left.append(Rotation.any_player_left_this_turn(state, live))
		h.check("rotation.advance_returns_true",
			Rotation.advance_player(state, live), "step accepted")
	h.check("rotation.cycles_player_and_computer",
		seen_current == [0, PLAYER_COMPUTER, 0, PLAYER_COMPUTER, 0,
			PLAYER_COMPUTER, 0, PLAYER_COMPUTER, 0, PLAYER_COMPUTER, 0,
			PLAYER_COMPUTER],
		str(seen_current))
	# The computer moves last, so with it current there is never anybody left.
	h.check("rotation.any_left_alternates",
		seen_left == [true, false, true, false, true, false, true, false,
			true, false, true, false],
		str(seen_left))
	h.check("rotation.previous_is_the_one_before",
		state.previous_player == PLAYER_COMPUTER,
		"previous %d" % state.previous_player)
	# docs/25 section 7: 252 is never stored in the current-player byte.
	h.check("rotation.never_yields_the_prop_owner",
		not seen_current.has(TurnState.PLAYER_PROPS), "no 252")


func _turn_counter(h: TestHarness) -> void:
	var state: TurnState = TurnState.create()
	state.turn = TurnState.TURN_WRAP - 1
	h.check("turn.wraps_at_200", state.advance_turn() == 0,
		"turn %d" % state.turn)
	h.check("turn.counts_up", state.advance_turn() == 1, "turn %d" % state.turn)
	_skip_rule(h)


## `0x0043B1F0` and the two clauses in front of the live-unit count.
##
## docs/25 section 3.1 quotes them in the order the disassembly has them:
## `if (!0x0043B1F0()) return TRUE;` comes **before** `if (g_turn == 0)`. So a
## campaign, which fails the gate, never skips a player at all -- the human
## keeps being handed its turn with nothing left alive, and the mission ends
## through the game-control slots instead.
##
## This suite used to assert the opposite, and it passed: the GDScript rotation
## had no gate, the native capture is a campaign save whose player 0 is alive
## throughout, and `inclib/turn.py` -- which has always had the gate -- is never
## compared with `core/` on a state that separates them. Both directions are
## asserted now, so neither can be dropped again unnoticed.
func _skip_rule(h: TestHarness) -> void:
	var none: Callable = func(_slot: int) -> int: return 0
	var one: Callable = func(_slot: int) -> int: return 1

	var campaign: TurnState = _campaign_state()
	campaign.end_state = PackedInt32Array([0, 0, 0, 0])
	campaign.mode = TurnState.MODE_CAMPAIGN
	h.check("turn.a_campaign_does_not_skip_empty_players",
		not campaign.skips_empty_players(), "0x0043B1F0 is false in mode 1")
	campaign.turn = 0
	h.check("turn.campaign_turn_zero_qualifies",
		Rotation.slot_qualifies(campaign, 0, none), "slot 0 qualifies")
	campaign.turn = 1
	h.check("turn.campaign_past_zero_still_qualifies",
		Rotation.slot_qualifies(campaign, 0, none),
		"a campaign player with nothing alive keeps its turn")

	# The one session kind that does skip: net, where the gate is true.
	var net: TurnState = _campaign_state()
	net.end_state = PackedInt32Array([0, 0, 0, 0])
	net.mode = TurnState.MODE_NET
	h.check("turn.a_net_session_skips_empty_players",
		net.skips_empty_players(), "0x0043B1F0 is true in mode 2")
	net.turn = 0
	h.check("turn.net_turn_zero_disables_the_skip_rule",
		Rotation.slot_qualifies(net, 0, none),
		"the first hand-over reaches every slot, placed or not")
	net.turn = 1
	h.check("turn.net_past_zero_the_skip_rule_bites",
		not Rotation.slot_qualifies(net, 0, none), "slot 0 skipped")
	h.check("turn.and_only_when_the_slot_is_empty",
		Rotation.slot_qualifies(net, 0, one), "one live unit is enough")

	# `local` cannot fire it at all: the solo flag is only ever set with at
	# most one human, so the `humanCount() > 1` arm is unreachable -- which
	# docs/25 section 3.1 states and nothing else here would show.
	var local: TurnState = _campaign_state()
	local.mode = TurnState.MODE_LOCAL
	h.check("turn.local_with_one_human_does_not_skip",
		not local.skips_empty_players(), "humanCount() is 1")


func _refresh(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var units: Dictionary = {}
	var unit: UnitState = UnitState.new()
	unit.slot = 0
	unit.player = 0
	unit.type_id = 0
	unit.hp = 10
	unit.x = 1
	unit.y = 1
	unit.fp = 1
	unit.mp = 0
	unit.action_state = Refresh.ACTION_STOOD_DOWN
	unit.walked = 40
	unit.stimulant = Refresh.STIMULANT_SPENT
	unit.ticket = 7
	unit.acted = 1
	unit.malfunction = 2
	units[0] = unit

	var state: TurnState = _campaign_state()
	state.reaction_counter = PackedInt32Array([3, 3, 3, 3])
	var no_banner: Callable = func(_slot: int) -> bool: return false
	var touched: PackedInt32Array = Refresh.player(state, 0, units,
		world.unit_types(), WeaponTable.from_rows([]), no_banner)

	h.check("refresh.touches_the_incoming_player", touched == PackedInt32Array([0]),
		str(touched))
	h.check("refresh.zeroes_the_reaction_counters",
		state.reaction_counter == PackedInt32Array([0, 0, 0, 0]),
		str(state.reaction_counter))
	h.check("refresh.clears_a_spent_stimulant", unit.stimulant == 0,
		"stimulant %d" % unit.stimulant)
	h.check("refresh.records_where_the_turn_began",
		unit.turn_start_x == 1 and unit.turn_start_y == 1,
		"(%d,%d)" % [unit.turn_start_x, unit.turn_start_y])
	h.check("refresh.resets_the_walked_distance", unit.walked == 0,
		"walked %d" % unit.walked)
	# `rested` is set from the state *before* it is cleared, which is the only
	# way the "did not act last turn" bonus can ever be earned.
	h.check("refresh.stood_down_becomes_rested", unit.rested == 1,
		"rested %d" % unit.rested)
	h.check("refresh.clears_the_action_state", unit.action_state == 0,
		"action_state %d" % unit.action_state)
	h.check("refresh.clears_the_acted_flag", unit.acted == 0,
		"acted %d" % unit.acted)
	h.check("refresh.clears_the_reaction_ticket", unit.ticket == 0,
		"ticket %d" % unit.ticket)
	h.check("refresh.steps_the_malfunction_ladder", unit.malfunction == 1,
		"malfunction %d" % unit.malfunction)
	# The movement points are **restored**, which is the correction this slice
	# made to docs/25 section 5: `0x004759B0` stores `aGetMovePoints`'s answer.
	h.check("refresh.restores_the_movement_points", unit.mp > 0,
		"mp %d" % unit.mp)
	# The ordering inside the refresh is what earns the rested bonus, and it is
	# the part a reimplementation is most likely to get wrong: `rested` is set
	# from the *incoming* action state, and only then is the allowance asked
	# for.  Clearing the state first would silently drop the point.  Compared
	# against a unit identical but for having acted.
	var busy: UnitState = UnitState.new()
	busy.slot = 1
	busy.player = 0
	busy.type_id = unit.type_id
	busy.hp = 10
	busy.x = 2
	busy.y = 2
	busy.fp = 1
	busy.action_state = 0
	var busy_units: Dictionary = {1: busy}
	var busy_state: TurnState = _campaign_state()
	Refresh.player(busy_state, 0, busy_units, world.unit_types(),
		WeaponTable.from_rows([]), no_banner)
	h.check("refresh.standing_down_is_worth_one_movement_point",
		unit.mp == busy.mp + 1,
		"stood down %d, acted %d" % [unit.mp, busy.mp])
	h.check("refresh.the_busy_unit_is_not_rested", busy.rested == 0,
		"rested %d" % busy.rested)

	# The ordering the refresh comments on is only observable through action
	# states 5 and 6, the two `Allowance` zeroes: `0x004759B0` asks
	# `aGetMovePoints`, which reads `+0x41`, and the state is cleared only
	# afterwards.  Clearing it first would hand such a unit a full allowance.
	# A unit in state 7 cannot show this -- 7 is not a suppressing state -- so
	# an ordering test written on the stood-down unit above passes either way.
	var suppressed: UnitState = UnitState.new()
	suppressed.slot = 2
	suppressed.player = 0
	suppressed.type_id = unit.type_id
	suppressed.hp = 10
	suppressed.x = 3
	suppressed.y = 3
	suppressed.fp = 1
	suppressed.mp = 9
	suppressed.action_state = Allowance.ACTION_STATE_SUPPRESSED[0]
	var suppressed_units: Dictionary = {2: suppressed}
	Refresh.player(_campaign_state(), 0, suppressed_units,
		world.unit_types(), WeaponTable.from_rows([]), no_banner)
	h.check("refresh.recomputes_before_clearing_the_action_state",
		suppressed.mp == 0,
		"a unit in state %d keeps a zero allowance, got %d"
			% [Allowance.ACTION_STATE_SUPPRESSED[0], suppressed.mp])
	h.check("refresh.still_clears_that_action_state",
		suppressed.action_state == 0,
		"action_state %d" % suppressed.action_state)

	# The ladder, every rung, because the fixture above only walks one.
	var ladder: Array[int] = []
	for rung: int in [0, 1, 2, 3, 4, 5, 6]:
		ladder.append(Refresh.malfunction_step(rung))
	h.check("refresh.malfunction_ladder_is_the_documented_one",
		ladder == [0, 0, 1, 0, 3, 4, 6], str(ladder))
