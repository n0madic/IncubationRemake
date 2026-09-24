extends TestSuite

## Oracle boundary: **specification**. The level tester's switches ([Cheats]),
## the hidden code line ([CheatEntry]) and the two launch entries.
##
## Nothing here compares against the engine, and it could not: the shipped
## game has no cheats, so every rule in this file is the remake's own and the
## suite is the whole of its verification.
##
## **Two halves, and the second is what matters.** The first exercises the
## objects; the second fires shots and walks in a built world and checks that
## with a switch off the damage, the ammunition and the movement points all
## still move -- a shield check that never had anything to shield would pass
## on a world where nobody can hurt anybody.

## A weapon that reaches across the scene and hurts: `Hit (%)` 100 so no roll
## can miss it, damage 8 so the loss is unmistakable, and a magazine so a
## spend is visible.
const GUN: int = 3
## `High Energy Laser B`, the stun mode -- docs/22 section 7.2's `0x46AEBD`.
const STUN_WEAPON: int = 45
const SCENE_SIZE: int = 8
## A soldier type with no fitness override -- `fp` 255 -- so the damage roll's
## fatigue arms stay out of the way.
const SOLDIER: int = 0
## The crate: docs/21 section 5's species 2, which [method
## World.cheat_kill_enemies] leaves standing.
const CRATE: int = 30
## Health high enough that one ordinary shot cannot empty it, so "killed in
## one" is a claim about the switch and not about the weapon.
const TOUGH_HP: int = 500
## What [method Allowance.for_unit] gives a [method TestFixtures.unit_type]
## soldier: the type's `mp_max`, **not** the record's authored 4. The refund
## is the allowance a hand-over would have given, which is the whole of the
## rule -- so the number to expect is the type's and not the record's.
const REFUNDED_MP: int = 6


class Scene extends RefCounted:
	var state: MapState
	var units: Dictionary = {}
	var types: UnitTypeTable
	var weapons: WeaponTable
	var turn: TurnState
	var rng: IncRandom


func run(h: TestHarness) -> void:
	h.begin("cheats", TestHarness.ORACLE_SPEC)
	_switches(h)
	_parse_list(h)
	_controlled(h)
	_entry(h)
	_resolve(h)
	_launch_args(h)
	_shield(h)
	_one_shot(h)
	_ammunition(h)
	_movement(h)
	_nuke(h)
	_world_carries_them(h)


# --- the object --------------------------------------------------------------

func _switches(h: TestHarness) -> void:
	var c: Cheats = Cheats.new()
	h.check("switches.off_by_default", not c.any(),
		"a world nobody asked plays straight")
	h.equal("switches.none_active", Array(c.active()), [])
	h.equal("switches.dict_names", c.to_dict().keys(), Cheats.NAMES)

	var wrong: Array[String] = []
	for name: String in Cheats.NAMES:
		if c.enabled(name):
			wrong.append("%s starts on" % name)
		if not c.set_enabled(name, true) or not c.enabled(name):
			wrong.append("%s will not turn on" % name)
		if c.toggle(name) or c.enabled(name):
			wrong.append("%s will not toggle off" % name)
		if not c.toggle(name) or not c.enabled(name):
			wrong.append("%s will not toggle on" % name)
	h.check("switches.each_one_works", wrong.is_empty(), ", ".join(wrong))
	h.check("switches.any_after_all_on", c.any())
	h.equal("switches.active_is_names_order", Array(c.active()),
		Cheats.NAMES)

	# An unknown word changes nothing and says so, which is what lets the code
	# line and the agent report a typo rather than silently doing nothing.
	h.check("switches.unknown_refused", not c.set_enabled("iddqd", true))
	h.check("switches.unknown_not_known", not Cheats.known("iddqd"))
	h.check("switches.unknown_toggle_false", not c.toggle("iddqd"))
	h.check("switches.nuke_is_not_a_switch",
		not Cheats.known(Cheats.ACTION_NUKE),
		"a one-off action has no state to be in")

	var copy: Cheats = c.duplicate()
	h.equal("switches.duplicate_matches", copy.to_dict(), c.to_dict())
	c.clear()
	h.check("switches.clear_clears", not c.any())
	h.check("switches.duplicate_is_independent", copy.any(),
		"clearing the original must not clear the copy")


func _parse_list(h: TestHarness) -> void:
	var parsed: Dictionary = Cheats.parse_list(" god , ammo ,GOD, nope ,")
	h.equal("parse.names", Array(DictRead.to_strings(parsed["names"])),
		["god", "ammo"], "case-folded, de-duplicated, in the order written")
	h.equal("parse.unknown", Array(DictRead.to_strings(parsed["unknown"])),
		["nope"])
	var empty: Dictionary = Cheats.parse_list("")
	h.equal("parse.empty_names",
		Array(DictRead.to_strings(empty["names"])), [])
	h.equal("parse.empty_unknown",
		Array(DictRead.to_strings(empty["unknown"])), [])


func _controlled(h: TestHarness) -> void:
	var turn: TurnState = TurnState.new()
	turn.player_kind = PackedInt32Array([TurnState.KIND_HUMAN, 0, 0, 0])
	h.check("controlled.human_seat", Cheats.controlled(_bare(0), turn))
	h.check("controlled.absent_seat", not Cheats.controlled(_bare(1), turn))
	h.check("controlled.aliens",
		not Cheats.controlled(_bare(UnitState.PLAYER_ALIEN), turn),
		"player 255 is outside the array and must not index it")
	h.check("controlled.no_unit", not Cheats.controlled(null, turn))
	h.check("controlled.no_turn", not Cheats.controlled(_bare(0), null))

	# The four questions the rules ask, each false without a `Cheats` at all --
	# which is what keeps the default argument from changing any caller.
	var on: Cheats = Cheats.new()
	for name: String in Cheats.NAMES:
		var _set: bool = on.set_enabled(name, true)
	h.check("controlled.null_shields", not Cheats.shielded(null, _bare(0),
		turn))
	h.check("controlled.null_arms", not Cheats.armed(null, _bare(0), turn))
	h.check("controlled.null_lethal", not Cheats.lethal(null, _bare(0), turn))
	h.check("controlled.null_tireless", not Cheats.tireless(null, _bare(0),
		turn))
	h.check("controlled.shields_the_human",
		Cheats.shielded(on, _bare(0), turn))
	h.check("controlled.spares_the_enemy",
		not Cheats.shielded(on, _bare(UnitState.PLAYER_ALIEN), turn))


static func _bare(player: int) -> UnitState:
	var unit: UnitState = UnitState.new()
	unit.player = player
	return unit


# --- the hidden code line ----------------------------------------------------

func _entry(h: TestHarness) -> void:
	var entry: CheatEntry = CheatEntry.new()
	h.check("entry.closed_at_rest", not entry.is_open())
	h.equal("entry.ordinary_key_ignored", entry.feed(KEY_G, 0x67),
		CheatEntry.IGNORED, "the camera keys must still reach the camera")
	h.equal("entry.opens", entry.feed(CheatEntry.OPEN_KEY, 0x60),
		CheatEntry.OPENED)
	h.check("entry.open", entry.is_open())
	h.equal("entry.types", entry.feed(KEY_G, 0x47), CheatEntry.TYPED)
	var _o: String = entry.feed(KEY_O, 0x6F)
	var _d: String = entry.feed(KEY_D, 0x64)
	h.equal("entry.buffer", entry.buffer(), "God")
	var _x: String = entry.feed(KEY_X, 0x78)
	var _back: String = entry.feed(KEY_BACKSPACE, 0)
	h.equal("entry.backspace", entry.buffer(), "God")
	h.equal("entry.submits", entry.feed(KEY_ENTER, 0),
		CheatEntry.SUBMITTED)
	h.equal("entry.code_is_folded", entry.code(), "god")
	h.check("entry.closes_on_submit", not entry.is_open())
	h.equal("entry.buffer_cleared", entry.buffer(), "")

	# Cancelling, both ways, and `ESC` first: while the line is open it owns
	# the keyboard, so `ESC` must not reach the shell.
	var _open2: String = entry.feed(CheatEntry.OPEN_KEY, 0x60)
	var _a: String = entry.feed(KEY_A, 0x61)
	h.equal("entry.escape_cancels", entry.feed(KEY_ESCAPE, 0),
		CheatEntry.CANCELLED)
	h.check("entry.closed_after_escape", not entry.is_open())
	var _open3: String = entry.feed(CheatEntry.OPEN_KEY, 0x60)
	h.equal("entry.open_key_cancels",
		entry.feed(CheatEntry.OPEN_KEY, 0x60), CheatEntry.CANCELLED)

	# The line cannot grow without bound, and a control character cannot get
	# into it -- a key held down and a modifier chord respectively.
	var _open4: String = entry.feed(CheatEntry.OPEN_KEY, 0x60)
	for _i: int in range(CheatEntry.MAX_LENGTH + 8):
		var _k: String = entry.feed(KEY_A, 0x61)
	h.equal("entry.length_capped", entry.buffer().length(),
		CheatEntry.MAX_LENGTH)
	var _clear: String = entry.feed(CheatEntry.OPEN_KEY, 0x60)
	var _open5: String = entry.feed(CheatEntry.OPEN_KEY, 0x60)
	var _ctrl: String = entry.feed(KEY_F1, 0x01)
	h.equal("entry.control_characters_dropped", entry.buffer(), "")


func _resolve(h: TestHarness) -> void:
	var wrong: Array[String] = []
	for name: String in Cheats.NAMES:
		var found: Dictionary = CheatEntry.resolve(name.to_upper())
		if DictRead.as_string(found["kind"]) != CheatEntry.KIND_SWITCH \
				or DictRead.as_string(found["name"]) != name:
			wrong.append(name)
	h.check("resolve.every_switch_is_typable", wrong.is_empty(),
		", ".join(wrong))
	h.equal("resolve.nuke",
		DictRead.as_string(CheatEntry.resolve(Cheats.ACTION_NUKE)["kind"]),
		CheatEntry.KIND_NUKE)
	h.equal("resolve.report",
		DictRead.as_string(CheatEntry.resolve(" Cheats ")["kind"]),
		CheatEntry.KIND_REPORT)
	h.equal("resolve.unknown",
		DictRead.as_string(CheatEntry.resolve("iddqd")["kind"]),
		CheatEntry.KIND_UNKNOWN)
	h.equal("resolve.empty",
		DictRead.as_string(CheatEntry.resolve("")["kind"]),
		CheatEntry.KIND_UNKNOWN)


func _launch_args(h: TestHarness) -> void:
	var none: Cheats = Cheats.new()
	var quiet: PackedStringArray = SliceMain.apply_cheat_args(
		PackedStringArray(["--mission=_C_140"]), none)
	h.check("args.absent_changes_nothing", not none.any())
	h.equal("args.absent_is_silent", Array(quiet), [])

	var some: Cheats = Cheats.new()
	var said: PackedStringArray = SliceMain.apply_cheat_args(
		PackedStringArray(["--cheats=god,nope", "--cheats=ammo,kill"]), some)
	h.equal("args.last_flag_wins", Array(some.active()), ["ammo", "kill"],
		"a wrapper script may append one over another")
	h.equal("args.unknown_warned", said.size(), 0,
		"the losing flag's unknown name is not reached")
	var one: Cheats = Cheats.new()
	var warned: PackedStringArray = SliceMain.apply_cheat_args(
		PackedStringArray(["--cheats=god,nope"]), one)
	h.equal("args.known_still_applied", Array(one.active()), ["god"])
	h.equal("args.unknown_reported", warned.size(), 1)
	h.check("args.warning_names_it", warned[0].contains("nope"), warned[0])
	h.equal("args.no_target_is_safe", SliceMain.apply_cheat_args(
		PackedStringArray(["--cheats=god"]), null).size(), 0)


# --- the rules, in a built world ---------------------------------------------

func _shield(h: TestHarness) -> void:
	# The enemy shoots the marine, twice over: once straight and once with the
	# switch on. The straight shot is the control -- without it a shield check
	# would pass on a scene where the gun cannot hurt anybody.
	var plain: Scene = _scene()
	var marine: UnitState = _place(plain, 0, 0, 2, 2)
	var alien: UnitState = _place(plain, 1, UnitState.PLAYER_ALIEN, 5, 2)
	var _shot: AttackResult = Combat.attack(plain.state, plain.units,
		plain.types, plain.weapons, alien.x, alien.y, marine.x, marine.y,
		0, 1, TurnState.MODE_CAMPAIGN, plain.turn, plain.rng)
	h.check("shield.control_shot_hurts", marine.hp < TOUGH_HP,
		"hp %d of %d" % [marine.hp, TOUGH_HP])

	var guarded: Scene = _scene()
	var safe: UnitState = _place(guarded, 0, 0, 2, 2)
	var shooter: UnitState = _place(guarded, 1, UnitState.PLAYER_ALIEN, 5, 2)
	var on: Cheats = _with("god")
	var covered: AttackResult = Combat.attack(guarded.state, guarded.units,
		guarded.types, guarded.weapons, shooter.x, shooter.y, safe.x, safe.y,
		0, 1, TurnState.MODE_CAMPAIGN, guarded.turn, guarded.rng, false, on)
	h.equal("shield.hp_untouched", safe.hp, TOUGH_HP)
	h.check("shield.the_shot_still_fired", covered.fired,
		"the switch zeroes the damage, it does not refuse the shot")
	h.equal("shield.dealt_nothing",
		DictRead.as_int(DictRead.as_dict(covered.outcomes[0])["dealt"]), 0)
	# The draw order is unchanged, which is what keeps a cheated world's
	# picture and truth in step: the generator has to land where it would.
	h.equal("shield.same_number_of_draws", guarded.rng.calls,
		plain.rng.calls)

	# The mine is the second and last way a weapon reaches a unit.
	var mined: Scene = _scene()
	var standing: UnitState = _place(mined, 0, 0, 3, 3)
	var _blast: AttackResult = Interact.execute_bomb(mined.state, mined.units,
		mined.types, mined.weapons, 3, 3, 0, 1, TurnState.MODE_CAMPAIGN,
		mined.turn, mined.rng)
	h.check("shield.control_mine_hurts", standing.hp < TOUGH_HP,
		"hp %d" % standing.hp)
	var mined2: Scene = _scene()
	var walker: UnitState = _place(mined2, 0, 0, 3, 3)
	var _safe: AttackResult = Interact.execute_bomb(mined2.state,
		mined2.units, mined2.types, mined2.weapons, 3, 3, 0, 1,
		TurnState.MODE_CAMPAIGN, mined2.turn, mined2.rng, on)
	h.equal("shield.mine_untouched", walker.hp, TOUGH_HP)
	_pushed_mine(h)
	_ground_fire(h)
	_own_gun(h)


## docs/26 section 6.2 -- the **third** way a mine reaches a unit: a crate
## pushed onto one detonates where it stops, and the blast is the aim cell
## plus its eight neighbours. The pusher is two cells away and outside it; a
## marine standing beside the crate's landing is not.
func _pushed_mine(h: TestHarness) -> void:
	var plain: Scene = _pushed_mine_scene(null)
	var hurt: UnitState = plain.units[2]
	h.check("shield.control_pushed_mine_hurts", hurt.hp < TOUGH_HP,
		"hp %d" % hurt.hp)
	var safe: Scene = _pushed_mine_scene(_with("god"))
	var spared: UnitState = safe.units[2]
	h.equal("shield.pushed_mine_untouched", spared.hp, TOUGH_HP,
		"the push path reaches execute_bomb through push_object")
	var crate: UnitState = safe.units[1]
	h.equal("shield.the_crate_still_slid", crate.x, 4,
		"the shield is the damage, not the push")


## docs/42 section 9.1 -- the flames weapon 40 lays **remove** what they
## reach; they roll nothing, so the shield here is the removal not happening.
func _ground_fire(h: TestHarness) -> void:
	var burnt: World = _burning_world(null)
	h.equal("shield.control_ground_fire_kills",
		DictRead.as_int(burnt.unit_view(0).get("hp", 0)), 0,
		"a marine standing in an ignited glow is removed")
	var spared: World = _burning_world(_with("god"))
	h.check("shield.ground_fire_spared",
		DictRead.as_int(spared.unit_view(0).get("hp", 0)) > 0,
		"the flames are a weapon reaching a unit")
	h.equal("shield.ground_fire_still_counted", spared.live_unit_count(0), 1,
		"and the cell link is not broken either")


## `aCheckWeaponDamage` `0x0046D1B0` -- one roll in forty at the heat cap
## kills the shooter with its own gun. `god` must not let that be the thing
## that kills a marine; `ammo` skips the call outright.
func _own_gun(h: TestHarness) -> void:
	var found: bool = false
	var protected: bool = true
	var jammed: bool = true
	# The roll is `aRandom(0, 40)` off the scene's own seed, so the search is
	# over start seeds rather than over a written roll: the first that
	# destroys the gun is the case, and the same seed is then replayed with
	# the switch on.
	for start: int in range(1, 400):
		var bare: Scene = _scene(float(start))
		var gunner: UnitState = _place(bare, 0, 0, 2, 2)
		var mark: UnitState = _place(bare, 1, UnitState.PLAYER_ALIEN, 5, 2)
		gunner.heat = Combat.max_heat(bare.weapons, gunner)
		var plain: AttackResult = Combat.attack(bare.state, bare.units,
			bare.types, bare.weapons, gunner.x, gunner.y, mark.x, mark.y,
			0, 1, TurnState.MODE_CAMPAIGN, bare.turn, bare.rng)
		if plain.overheat != Combat.OVERHEAT_DESTROYED:
			continue
		found = true
		var safe: Scene = _scene(float(start))
		var marine: UnitState = _place(safe, 0, 0, 2, 2)
		var alien: UnitState = _place(safe, 1, UnitState.PLAYER_ALIEN, 5, 2)
		marine.heat = Combat.max_heat(safe.weapons, marine)
		var covered: AttackResult = Combat.attack(safe.state, safe.units,
			safe.types, safe.weapons, marine.x, marine.y, alien.x, alien.y,
			0, 1, TurnState.MODE_CAMPAIGN, safe.turn, safe.rng, false,
			_with("god"))
		protected = marine.is_alive()
		jammed = covered.overheat == Combat.OVERHEAT_DAMAGE \
			and marine.malfunction == Combat.MALFUNCTION_DAMAGED
		break
	h.check("shield.found_a_destroying_roll", found,
		"no seed in 1..399 destroyed the gun; the case was never exercised")
	h.check("shield.own_gun_does_not_kill", protected)
	h.check("shield.own_gun_is_downgraded", jammed,
		"the arm becomes the damaged-weapon one it shares an instruction with")


## The first cell the Jet Pack fill marked as a warp target, or `(-1, -1)`.
## The walk's own reachable cells are **not** warp targets -- the warp pass
## skips every cell the fill already took ([method MoveMap._warp_pass]) -- so
## the pad cannot be guessed from the distance.
static func _first_warp_cell(world: World) -> Vector2i:
	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(0))
	for y: int in range(SCENE_SIZE):
		for x: int in range(SCENE_SIZE):
			if fill.is_warp_target(x, y):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


## A scene where using the crate in front pushes it onto a mine, with a second
## marine standing where the blast reaches. Built as a [Scene] and driven
## through [method Interact.execute] rather than through [World], because a
## world's own `submit_use` cannot place a crate on an authored map.
static func _pushed_mine_scene(with_cheats: Cheats) -> Scene:
	var scene: Scene = _scene()
	var pusher: UnitState = _place(scene, 0, 0, 2, 2)
	# Facing 3 is `+x` ([constant Interact.FACING_DX]), so the cell in front
	# is the crate's and the slide runs along the row.
	pusher.facing = 3
	var _crate: UnitState = _place(scene, 1, 0, 3, 2, CRATE)
	var _bystander: UnitState = _place(scene, 2, 0, 5, 2)
	var _laid: int = CellObjects.place_mine(scene.state, 4, 2)
	var _used: UseResult = Interact.execute(scene.state, scene.units,
		scene.types, scene.weapons, GameControl.create(), pusher, 0, 1,
		TurnState.MODE_CAMPAIGN, scene.turn, scene.rng, with_cheats)
	return scene


## A world whose marine stands on a glow, played until the flames sweep it.
static func _burning_world(with_cheats: Cheats) -> World:
	var world: World = _armed_world()
	if with_cheats != null:
		world.cheats = with_cheats
	world.state.set_special_models(PackedStringArray([
		CellObjects.GLOW_MODEL_LIT, CellObjects.GLOW_MODEL_FRESH]))
	var _laid: int = CellObjects.place_glow(world.state, 2, 2,
		CellObjects.GLOW_PHASE_FRESH)
	var passes: int = 0
	while passes < 8 \
			and DictRead.as_int(world.unit_view(0).get("hp", 0)) > 0:
		var _next: TurnResult = world.submit_end_turn(EndTurnCommand.create())
		passes += 1
	return world


func _one_shot(h: TestHarness) -> void:
	var field: Scene = _scene()
	var marine: UnitState = _place(field, 0, 0, 2, 2)
	var alien: UnitState = _place(field, 1, UnitState.PLAYER_ALIEN, 5, 2)
	# Armour that an ordinary roll cannot get through, so "it died" is the
	# switch and not the dice.
	alien.armour_front = 200
	alien.armour_rear = 200
	var on: Cheats = _with("kill")
	var shot: AttackResult = Combat.attack(field.state, field.units,
		field.types, field.weapons, marine.x, marine.y, alien.x, alien.y,
		0, 1, TurnState.MODE_CAMPAIGN, field.turn, field.rng, false, on)
	h.check("kill.dead_in_one", not alien.is_alive(), "hp %d" % alien.hp)
	var outcome: Dictionary = DictRead.as_dict(shot.outcomes[0])
	h.equal("kill.marker", DictRead.as_int(outcome["marker"]),
		Combat.MARKER_KILLED)
	h.equal("kill.dealt_is_the_whole_of_it",
		DictRead.as_int(outcome["dealt"]), TOUGH_HP)

	# The switch is the shooter's, and the aliens are not it.
	var back: Scene = _scene()
	var target: UnitState = _place(back, 0, 0, 2, 2)
	var enemy: UnitState = _place(back, 1, UnitState.PLAYER_ALIEN, 5, 2)
	var _return: AttackResult = Combat.attack(back.state, back.units,
		back.types, back.weapons, enemy.x, enemy.y, target.x, target.y,
		0, 1, TurnState.MODE_CAMPAIGN, back.turn, back.rng, false, on)
	h.check("kill.only_the_human_shooter", target.is_alive(),
		"an alien holding the same switch must not one-shot a marine")

	# Both switches at once: friendly fire is still not lethal.
	var mixed: Scene = _scene()
	var one: UnitState = _place(mixed, 0, 0, 2, 2)
	var two: UnitState = _place(mixed, 1, 0, 5, 2)
	var both: Cheats = _with("kill")
	var _god: bool = both.set_enabled("god", true)
	var _friendly: AttackResult = Combat.attack(mixed.state, mixed.units,
		mixed.types, mixed.weapons, one.x, one.y, two.x, two.y,
		0, 1, TurnState.MODE_CAMPAIGN, mixed.turn, mixed.rng, false, both)
	h.equal("kill.friendly_fire_is_shielded", two.hp, TOUGH_HP)

	# The non-lethal modes stay non-lethal: the Enhanced Laser's second mode
	# converts and the High Energy Laser's stuns, and a mission (`_C_173`)
	# may need its target alive.
	var taming: Scene = _scene()
	var tamer: UnitState = _place(taming, 0, 0, 2, 2)
	tamer.weapon = Combat.CONVERTER_WEAPON
	var beast: UnitState = _place(taming, 1, UnitState.PLAYER_ALIEN, 5, 2)
	# Weapon 47 is set to its heat cap before every shot, so its overheat
	# roll can jam it; the ammunition switch takes that roll away, which
	# leaves the kill switch the only thing under test.
	var tame: Cheats = _with("kill")
	var _armed: bool = tame.set_enabled("ammo", true)
	var _tamed: AttackResult = Combat.attack(taming.state, taming.units,
		taming.types, taming.weapons, tamer.x, tamer.y, beast.x, beast.y,
		0, 1, TurnState.MODE_CAMPAIGN, taming.turn, taming.rng, false, tame)
	h.check("kill.the_converter_does_not_kill", beast.is_alive(),
		"hp %d" % beast.hp)
	h.equal("kill.the_converter_converts", beast.player, 0,
		"the guaranteed hit lands and 0x0046BDAD takes it over")
	var dazing: Scene = _scene()
	var dazer: UnitState = _place(dazing, 0, 0, 2, 2)
	dazer.weapon = STUN_WEAPON
	var dazed: UnitState = _place(dazing, 1, UnitState.PLAYER_ALIEN, 5, 2)
	var _stun: AttackResult = Combat.attack(dazing.state, dazing.units,
		dazing.types, dazing.weapons, dazer.x, dazer.y, dazed.x, dazed.y,
		0, 1, TurnState.MODE_CAMPAIGN, dazing.turn, dazing.rng, false, on)
	h.check("kill.the_stun_does_not_kill", dazed.is_alive(), "hp %d" % dazed.hp)
	h.equal("kill.the_stun_stuns", dazed.action_state,
		Combat.STUNNED_ACTION_STATE)


func _ammunition(h: TestHarness) -> void:
	var plain: Scene = _scene()
	var gunner: UnitState = _place(plain, 0, 0, 2, 2)
	var mark: UnitState = _place(plain, 1, UnitState.PLAYER_ALIEN, 5, 2)
	var before: int = gunner.ammo
	var _shot: AttackResult = Combat.attack(plain.state, plain.units,
		plain.types, plain.weapons, gunner.x, gunner.y, mark.x, mark.y,
		0, 1, TurnState.MODE_CAMPAIGN, plain.turn, plain.rng)
	h.check("ammo.control_spends", gunner.ammo < before,
		"%d -> %d" % [before, gunner.ammo])
	h.check("ammo.control_heats", gunner.heat > 0, "heat %d" % gunner.heat)

	var free: Scene = _scene()
	var tester: UnitState = _place(free, 0, 0, 2, 2)
	var alien: UnitState = _place(free, 1, UnitState.PLAYER_ALIEN, 5, 2)
	# At the cap and jammed: the switch has to undo both, because
	# `aCheckWeaponDamage` is what destroys the gun and, on one roll in forty,
	# the shooter with it.
	tester.heat = Combat.max_heat(free.weapons, tester)
	tester.malfunction = 1
	var on: Cheats = _with("ammo")
	var shot: AttackResult = Combat.attack(free.state, free.units,
		free.types, free.weapons, tester.x, tester.y, alien.x, alien.y,
		0, 1, TurnState.MODE_CAMPAIGN, free.turn, free.rng, false, on)
	h.check("ammo.fires_while_jammed", shot.fired, shot.reason)
	h.equal("ammo.magazine_untouched", tester.ammo, before)
	h.equal("ammo.jam_cleared", tester.malfunction, 0)
	h.equal("ammo.heat_stays_at_the_cap", tester.heat,
		Combat.max_heat(free.weapons, tester))
	h.check("ammo.the_alien_was_hit", alien.hp < TOUGH_HP,
		"hp %d" % alien.hp)

	# The call site's own refusal, which is a second gate and not the same one.
	var world: World = _armed_world()
	var empty: AttackResult = world.submit_attack(
		AttackCommand.create(0, 5, 2))
	h.equal("ammo.control_refuses_empty", empty.reason, "no ammunition")
	world.cheats = _with("ammo")
	var fired: AttackResult = world.submit_attack(
		AttackCommand.create(0, 5, 2))
	h.check("ammo.empty_magazine_fires", fired.fired, fired.reason)


func _movement(h: TestHarness) -> void:
	var plain: World = _armed_world()
	var walked: MoveResult = plain.submit_move(MoveCommand.create(0, 3, 2))
	h.check("moves.control_walks", walked.ok, walked.reason)
	h.check("moves.control_charges",
		DictRead.as_int(plain.unit_view(0)["mp"]) < 4,
		"mp %d" % DictRead.as_int(plain.unit_view(0)["mp"]))

	var free: World = _armed_world()
	free.cheats = _with("moves")
	var again: MoveResult = free.submit_move(MoveCommand.create(0, 3, 2))
	h.check("moves.still_walks", again.ok, again.reason)
	h.equal("moves.refunded", DictRead.as_int(free.unit_view(0)["mp"]),
		REFUNDED_MP, "the allowance, not the value before the charge")
	h.check("moves.refund_beats_the_charge",
		DictRead.as_int(free.unit_view(0)["mp"])
			> DictRead.as_int(plain.unit_view(0)["mp"]),
		"the same walk, charged and not")
	# **The shot's own refund needs a loaded magazine**, or the call site
	# refuses before it charges anything and the check passes on a shot that
	# never happened.
	var shooting: World = _armed_world(false, 5)
	shooting.cheats = _with("moves")
	var shot: AttackResult = shooting.submit_attack(
		AttackCommand.create(0, 5, 2))
	h.check("moves.the_shot_fired", shot.fired, shot.reason)
	h.equal("moves.refunded_after_a_shot",
		DictRead.as_int(shooting.unit_view(0)["mp"]), REFUNDED_MP)
	# The enemy walks in the **same** world, with the switch on, and is
	# charged: the refund is the human seats' and nobody else's.
	var walked_enemy: MoveResult = free.submit_move(MoveCommand.create(1, 6, 3))
	h.check("moves.the_enemy_walked", walked_enemy.ok, walked_enemy.reason)
	# The warp is the fourth charge, and `aExecuteWarp`'s call site zeroes the
	# points outright rather than subtracting them.
	var jumping: World = _armed_world(false, 0, true)
	var pad: Vector2i = _first_warp_cell(jumping)
	h.check("moves.a_warp_cell_exists", pad.x >= 0,
		"the Jet Pack fill marked nothing, so the warp was never exercised")
	var landed: WarpResult = jumping.submit_warp(
		WarpCommand.create(0, pad.x, pad.y))
	h.check("moves.control_warp_zeroes", landed.ok
		and DictRead.as_int(jumping.unit_view(0)["mp"]) == 0,
		landed.reason if not landed.ok
			else "mp %d" % DictRead.as_int(jumping.unit_view(0)["mp"]))
	var free_jump: World = _armed_world(false, 0, true)
	free_jump.cheats = _with("moves")
	var jumped: WarpResult = free_jump.submit_warp(
		WarpCommand.create(0, pad.x, pad.y))
	h.check("moves.warp_refunded", jumped.ok
		and DictRead.as_int(free_jump.unit_view(0)["mp"]) == REFUNDED_MP,
		jumped.reason if not jumped.ok
			else "mp %d" % DictRead.as_int(free_jump.unit_view(0)["mp"]))
	h.check("moves.enemy_is_charged",
		DictRead.as_int(free.unit_view(1)["mp"]) < 4,
		"mp %d" % DictRead.as_int(free.unit_view(1)["mp"]))


func _nuke(h: TestHarness) -> void:
	var world: World = _armed_world(true)
	var alive_before: int = world.unit_slots().size()
	var killed: int = world.cheat_kill_enemies()
	h.equal("nuke.killed_the_alien", killed, 1)
	h.check("nuke.marine_lives",
		DictRead.as_int(world.unit_view(0)["hp"]) > 0)
	h.check("nuke.crate_stands",
		DictRead.as_int(world.unit_view(2)["hp"]) > 0,
		"docs/21 section 5's species 2 is scenery, not an enemy")
	h.equal("nuke.slots_are_not_erased", world.unit_slots().size(),
		alive_before, "a killed record stays in the roster")
	h.equal("nuke.counts_the_kill", world.turn.mission_kills[0], 1,
		"a mission whose win condition counts kills has to be able to end")
	h.equal("nuke.twice_is_a_no_op", world.cheat_kill_enemies(), 0)


func _world_carries_them(h: TestHarness) -> void:
	var world: World = _armed_world()
	var before: String = world.canonical_hash_hex()
	world.cheats = _with("god")
	h.equal("world.outside_the_hash", world.canonical_hash_hex(), before,
		"two worlds differing only in a switch are the same state")
	var mirror: World = world.clone()
	h.equal("world.clone_carries_them", mirror.cheats.to_dict(),
		world.cheats.to_dict())
	var _off: bool = world.cheats.set_enabled("god", false)
	h.check("world.clone_shares_them", not mirror.cheats.god,
		"a snapshot would freeze at clone time and diverge on the next toggle")
	var blob: PackedByteArray = world.save({})
	var restored: World = _armed_world()
	restored.cheats = _with("kill")
	var code: int = restored.load_save(blob)
	h.equal("world.save_loads", code, SaveCodec.Result.OK)
	h.check("world.save_carries_nothing", restored.cheats.kill,
		"a save must neither carry a switch nor clear one")


# --- the scenes --------------------------------------------------------------

static func _with(name: String) -> Cheats:
	var c: Cheats = Cheats.new()
	var _on: bool = c.set_enabled(name, true)
	return c


## A bare scene: [MapState], the two tables and a campaign turn whose player 0
## is the one human seat.
static func _scene(rng_seed: float = 1.0) -> Scene:
	var n: int = SCENE_SIZE * SCENE_SIZE
	var zeros: Array = []
	var free: Array = []
	var links: Array = []
	var idle: Array = []
	for _i: int in range(n):
		zeros.append(0)
		free.append(Interact.FIELD_TYPE_FREE)
		links.append(-1)
		idle.append(255)
	var document: Dictionary = {
		"width": SCENE_SIZE, "height": SCENE_SIZE,
		"header": {"name": "cheats_spec", "next_map": "", "map_type": 0,
			"mission_id": 0, "world_set": "", "world_scene": "",
			"camera_height": 0, "equip_points": [0, 0, 0, 0],
			"skill_level": 0, "tech_level": 0},
		"cells": {"height": zeros, "field_type": free, "action_point": zeros,
			"unit": links, "effect0": zeros, "effect1": idle,
			"effect2": idle, "effect3": idle, "effect4": zeros,
			"effect5": idle, "land": zeros, "start_index": links},
	}
	var scene: Scene = Scene.new()
	scene.state = MapState.from_resource(MapResource.from_document(document))
	scene.types = UnitTypeTable.from_rows([
		{"id": SOLDIER, "mp_max": 4, "fp_max": 0, "hp_max": 20, "special": 0,
			"size": 0, "species": 0, "height": 20, "model": "",
			"description": "soldier"},
		{"id": CRATE, "mp_max": 0, "fp_max": 255, "hp_max": 10, "special": 0,
			"size": 0, "species": World.SPECIES_INANIMATE, "height": 40,
			"model": "", "description": "crate"},
	])
	scene.weapons = WeaponTable.from_rows([
		{"id": GUN, "heat": 4, "toggle": GUN, "mun": 15, "hit": 100,
			"damage": 8, "range_min": 1, "range_max": 30, "type": 1,
			"special": 0, "def_mode": 0, "mun_per_fight": 1},
		{"id": Combat.CONVERTER_WEAPON, "heat": 4,
			"toggle": Combat.CONVERTER_WEAPON, "mun": 255, "hit": 90,
			"damage": 1, "range_min": 1, "range_max": 30, "type": 1,
			"special": 0, "def_mode": 0, "mun_per_fight": 1},
		{"id": STUN_WEAPON, "heat": 4, "toggle": STUN_WEAPON, "mun": 255,
			"hit": 90, "damage": 10, "range_min": 1, "range_max": 30,
			"type": 0, "special": 0, "def_mode": 0, "mun_per_fight": 1},
		{"id": Combat.BOMB_WEAPON, "heat": 255,
			"toggle": Combat.BOMB_WEAPON, "mun": 255, "hit": 100,
			"damage": 100, "range_min": 1, "range_max": 1, "type": 1,
			"special": 0, "def_mode": 0, "mun_per_fight": 1},
	])
	scene.turn = TurnState.new()
	scene.turn.mode = TurnState.MODE_CAMPAIGN
	scene.turn.player_kind = PackedInt32Array([TurnState.KIND_HUMAN, 0, 0, 0])
	scene.rng = IncRandom.new()
	scene.rng.randomize_seed(rng_seed)
	return scene


static func _place(scene: Scene, slot: int, player: int, x: int,
		y: int, type_id: int = SOLDIER) -> UnitState:
	var unit: UnitState = UnitState.new()
	unit.slot = slot
	unit.player = player
	unit.type_id = type_id
	unit.x = x
	unit.y = y
	unit.hp = TOUGH_HP
	unit.fp = 255
	unit.mp = 4
	unit.weapon = GUN
	unit.ammo = 15
	scene.units[slot] = unit
	scene.state.set_unit(scene.state.index_of(x, y), slot)
	return unit


## A [World] with an armed marine on a human seat, an armed alien facing it
## and -- when *with_crate* -- one inanimate object beside them.
##
## The marine's magazine is **empty by default**, which is what the ammunition
## gate needs to refuse; a check that wants the shot to happen asks for rounds.
static func _armed_world(with_crate: bool = false,
		marine_ammo: int = 0, jet_pack: bool = false) -> World:
	var kit: Array = [UnitState.JET_PACK_EQUIP_ID] if jet_pack else []
	var records: Array = [
		TestFixtures.unit(0, 2, 2, 0, 0, 4, 0, kit, 3, marine_ammo),
		TestFixtures.unit(1, 5, 2, 0, UnitState.PLAYER_ALIEN, 4, 0, [], 3, 5),
	]
	if with_crate:
		records.append(TestFixtures.unit(2, 6, 6,
			TestFixtures.INANIMATE_TYPE, UnitState.PLAYER_ALIEN))
	var world: World = World.create(
		TestFixtures.map_document(SCENE_SIZE, SCENE_SIZE, records),
		TestFixtures.balance(), 1.0)
	world.turn.mode = TurnState.MODE_CAMPAIGN
	return world
