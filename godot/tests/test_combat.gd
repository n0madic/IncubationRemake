extends TestSuite

## Oracle boundary: **specification**. docs/22 sections 5 to 9, docs/25 section
## 6, docs/26.
##
## `test_combat_native.gd` compares `core/` with the engine's own bytes on
## `_C_141`; this one covers what that capture cannot reach -- the reaction
## queue (no shipped `.lev` places a unit on overwatch), the interaction arms
## whose action point no probed cell carried, and the invariants a single map
## cannot demonstrate.
##
## Every scene here is built rather than loaded, and each check names the rule
## it is holding rather than the value it happens to produce.

## `Sniper Rifle`: `def_mode` 1, range 1..30 and `Hit (%)` 20, so the curve
## gives `100 - 2 * d` and a shot at two fields has a chance the queue's own
## gate will accept.  A weapon whose chance came out zero would make every
## reaction check pass by refusing.
const REACTION_WEAPON: int = 3
const SCENE_SIZE: int = 8


## One built world, with **typed** members.
##
## A `Dictionary` would do the job and would not compile: reading `scene.state`
## out of one yields a `Variant`, and `unsafe_call_argument` is an error
## project-wide, so every call would need a narrowing local first.  The class is
## the narrowing, once.
class Scene extends RefCounted:
	var state: MapState
	var units: Dictionary = {}
	var types: UnitTypeTable
	var weapons: WeaponTable


func run(h: TestHarness) -> void:
	h.begin("combat", TestHarness.ORACLE_SPEC)
	_direction_and_arc(h)
	_world_wiring(h)
	_hit_curve(h)
	_line_of_sight(h)
	_damage(h)
	_overheat(h)
	_visibility(h)
	_defence_gate(h)
	_reaction_queue(h)
	_interaction(h)


# --- the tables --------------------------------------------------------------

static func _weapons() -> WeaponTable:
	# Two rows, written out rather than loaded: the shipped table is what
	# `test_combat_native.gd` uses, and a spec check that reached for it would
	# assert the data instead of the rule.
	return WeaponTable.from_rows([
		{"id": REACTION_WEAPON, "heat": 4, "toggle": REACTION_WEAPON,
			"mun": 15, "hit": 20, "damage": 4, "range_min": 1,
			"range_max": 30, "type": 1, "special": 0, "def_mode": 1,
			"mun_per_fight": 1},
		# A flamethrower-shaped row: `def_mode` 0, so it can never go on
		# overwatch, and no heat cap at all.
		{"id": 5, "heat": 255, "toggle": 5, "mun": 255, "hit": 50,
			"damage": 10, "range_min": 1, "range_max": 4, "type": 1,
			"special": 0, "def_mode": 0, "mun_per_fight": 1},
		# The `ParaBomb` a mine resolves as, and the only `aim_and_neighbours`
		# row here.
		{"id": Combat.BOMB_WEAPON, "heat": 255, "toggle": Combat.BOMB_WEAPON,
			"mun": 255, "hit": 100, "damage": 100, "range_min": 1,
			"range_max": 1, "type": 1, "special": 0, "def_mode": 0,
			"mun_per_fight": 1},
	])


static func _types() -> UnitTypeTable:
	return UnitTypeTable.from_rows([
		{"id": 0, "mp_max": 4, "fp_max": 0, "hp_max": 20, "special": 0,
			"size": 0, "species": 0, "height": 20, "model": "",
			"description": "soldier"},
		# A pushable crate: species 2, which the fog pass treats as scenery.
		#
		# **Taller than the soldiers.**  Vision runs the ray at `fullHeight`,
		# 20 * 160 = 3200, and a crate of height 10 tops out at 1600 -- so a
		# short one is walked straight over and blocks nothing.  A "a body does
		# not hide" check built on one passes on a model that rejects 254.
		{"id": 30, "mp_max": 0, "fp_max": 255, "hp_max": 10, "special": 0,
			"size": 0, "species": 2, "height": 40, "model": "",
			"description": "barrel"},
	])


static func _scene(w: int = SCENE_SIZE, hgt: int = SCENE_SIZE) -> Scene:
	var n: int = w * hgt
	var zeros: Array = []
	var ones: Array = []
	var links: Array = []
	for _i: int in range(n):
		zeros.append(0)
		ones.append(Interact.FIELD_TYPE_FREE)
		links.append(-1)
	var document: Dictionary = {
		"width": w, "height": hgt,
		"header": {"name": "combat_spec", "next_map": "", "map_type": 0,
			"mission_id": 0, "world_set": "", "world_scene": "",
			"camera_height": 0, "equip_points": [0, 0, 0, 0],
			"skill_level": 0, "tech_level": 0},
		"cells": {"height": zeros, "field_type": ones, "action_point": zeros,
			"unit": links, "effect0": zeros, "effect1": zeros,
			"effect2": zeros, "effect3": zeros, "land": zeros,
			"start_index": links, "decal0": zeros, "decal1": zeros},
	}
	var res: MapResource = MapResource.from_document(document)
	var scene: Scene = Scene.new()
	scene.state = MapState.from_resource(res)
	scene.types = _types()
	scene.weapons = _weapons()
	return scene


static func _place(scene: Scene, slot: int, player: int, x: int, y: int,
		facing: int, type_id: int = 0) -> UnitState:
	var unit: UnitState = UnitState.new()
	unit.slot = slot
	unit.player = player
	unit.type_id = type_id
	unit.x = x
	unit.y = y
	unit.facing = facing
	unit.hp = 1000
	unit.fp = 5
	unit.mp = 4
	unit.weapon = REACTION_WEAPON
	unit.ammo = 15
	scene.units[slot] = unit
	scene.state.set_unit(scene.state.index_of(x, y), slot)
	return unit


# --- docs/22 section 7.4 -----------------------------------------------------

func _direction_and_arc(h: TestHarness) -> void:
	# The eight octants, each from its own unit vector.
	var wrong: Array[String] = []
	for code: int in range(Combat.FACINGS):
		var dx: int = Combat.DIRECTION_DX[code]
		var dy: int = Combat.DIRECTION_DY[code]
		if Combat.direction(0, 0, dx * 3, dy * 3) != code:
			wrong.append("%d -> %d" % [code,
				Combat.direction(0, 0, dx * 3, dy * 3)])
	h.check("direction.round_trips", wrong.is_empty(), ", ".join(wrong))
	h.equal("direction.same_cell_is_zero", Combat.direction(4, 4, 4, 4), 0)

	var widths: Dictionary = {}
	var covered: Dictionary = {}
	for centre: int in range(Combat.FACINGS):
		var n: int = 0
		for facing: int in range(Combat.FACINGS):
			if Combat.in_arc(centre, facing):
				n += 1
				covered[facing] = true
		widths[n] = true
	h.equal("arc.three_octants_wide", widths.keys(), [3],
		"three of eight is 135 degrees")
	h.equal("arc.every_octant_is_somebody_rear", covered.size(),
		Combat.FACINGS)
	# The rule stated the way docs/22 states it: a defender is shot in the back
	# when the attacker fires in the direction the defender is *looking*.
	h.check("arc.same_direction_is_the_back", Combat.is_rear_shot(0, 0),
		"attacker and defender both facing 0")
	h.check("arc.head_on_is_the_front", not Combat.is_rear_shot(0, 2),
		"facing 2 shot from octant 0")


# --- docs/22 section 5 -------------------------------------------------------

func _hit_curve(h: TestHarness) -> void:
	# `100 - ((101 - acc) / rangeMax) * d`, with the slope truncated **before**
	# the multiply.  Written out here rather than taken from HitChance, so the
	# check does not re-derive the model's own answer.
	h.equal("curve.sniper_at_one_field", HitChance.percent_at(20, 30, 1), 98)
	h.equal("curve.sniper_at_ten_fields", HitChance.percent_at(20, 30, 10), 80)
	h.check("curve.flat_when_the_slope_truncates_to_zero",
		HitChance.percent_at(50, 60, 9) == 100,
		"acc + rangeMax > 101 gives a slope of 0, so the curve never falls")
	var monotone: bool = true
	for d: int in range(1, 30):
		if HitChance.percent_at(20, 30, d + 1) > HitChance.percent_at(20, 30, d):
			monotone = false
	h.check("curve.monotone_non_increasing", monotone, "over 1..30 fields")

	# docs/22 section 5.1 -- a large participant costs one field **each**, and
	# no shipped map on the capture holds one, so this is the only place the
	# rule is exercised at all.
	var big: UnitTypeTable = UnitTypeTable.from_rows([
		{"id": 0, "mp_max": 4, "fp_max": 0, "hp_max": 20, "special": 0,
			"size": 0, "species": 0, "height": 20, "model": "",
			"description": "small"},
		{"id": 1, "mp_max": 4, "fp_max": 0, "hp_max": 20, "special": 0,
			"size": UnitTypeTable.SIZE_LARGE, "species": 0, "height": 20,
			"model": "", "description": "large"}])
	var scene: Scene = _scene()
	var small_a: UnitState = _place(scene, 0, 0, 1, 1, 0)
	var small_b: UnitState = _place(scene, 1, 255, 6, 1, 0)
	var sizes: Array[int] = []
	for pair: Array in [[0, 0], [1, 0], [1, 1]]:
		small_a.type_id = DictRead.as_int(pair[0])
		small_b.type_id = DictRead.as_int(pair[1])
		sizes.append(HitChance.combat_distance(scene.state, big,
			scene.weapons, small_a, small_b, REACTION_WEAPON))
	h.equal("distance.a_large_participant_costs_one_field_each", sizes,
		[5, 4, 3], "five fields apart, then one large, then both")

	# `0x0046A35C`, over the height range a shipped map can hold.
	h.equal("distance.magic_divide", [
		HitChance.magic_div_2400_plus_1(2401),
		HitChance.magic_div_2400_plus_1(4800),
		HitChance.magic_div_2400_plus_1(24000)], [2, 3, 11])


func _line_of_sight(h: TestHarness) -> void:
	var scene: Scene = _scene()
	var state: MapState = scene.state
	var units: Dictionary = scene.units
	var utab: UnitTypeTable = scene.types
	var eye: int = HitChance.eye_height(utab, 0)
	h.equal("los.same_cell_is_clear",
		LineOfSight.check(state, units, utab, 2, 2, eye, 2, 2, eye, 1, 1, 1),
		LineOfSight.CLEAR)
	h.equal("los.open_ground_is_clear",
		LineOfSight.check(state, units, utab, 1, 1, eye, 6, 6, eye, 1, 1, 1),
		LineOfSight.CLEAR)

	# A wall of terrain across the middle.
	for x: int in range(SCENE_SIZE):
		state.set_height(state.index_of(x, 4), 10000)
	h.equal("los.terrain_blocks",
		LineOfSight.check(state, units, utab, 3, 1, eye, 3, 7, eye, 1, 1, 1),
		LineOfSight.TERRAIN)

	# A body in the way is 254, which is **below** terrain -- so the fog pass
	# accepts it and reveals what is behind, and a shot does not.
	var open_scene: Scene = _scene()
	var open_state: MapState = open_scene.state
	var open_units: Dictionary = open_scene.units
	_place(open_scene, 1, 0, 3, 4, 0)
	h.equal("los.a_body_reports_254",
		LineOfSight.check(open_state, open_units, utab, 3, 1, eye, 3, 7, eye,
			1, 1, 1),
		LineOfSight.UNIT)
	# A body **and then** terrain must report the terrain.  This is the half of
	# "the walk runs to the target cell" that has teeth: reporting 254 at the
	# crate would call a target behind a wall merely shielded.
	var both: Scene = _scene()
	var both_state: MapState = both.state
	_place(both, 1, 0, 3, 3, 0, 30)
	for wx: int in range(SCENE_SIZE):
		both_state.set_height(both_state.index_of(wx, 5), 20000)
	h.equal("los.a_body_then_terrain_reports_terrain",
		LineOfSight.check(both_state, both.units, utab, 3, 1, eye, 3, 7, eye,
			1, 1, 1),
		LineOfSight.TERRAIN)

	h.check("los.a_body_is_below_terrain",
		LineOfSight.UNIT < LineOfSight.TERRAIN,
		"which is why vision accepts it and fire does not")
	# Four-ray symmetry: the mode-1 form samples both directions in a
	# multiplayer session, so it cannot disagree with itself.
	h.equal("los.four_ray_form_is_symmetric",
		LineOfSight.check(open_state, open_units, utab, 1, 1, eye, 6, 6, eye,
			1, 2, 1),
		LineOfSight.check(open_state, open_units, utab, 6, 6, eye, 1, 1, eye,
			1, 2, 1))
	# docs/22 section 6.2: `dz` is divided by the **Euclidean** distance while
	# the walk advances along the dominant axis, so on a perfect diagonal the
	# ray climbs about 1.41x more slowly than its endpoints imply and arrives
	# low.  A step on the diagonal, with a ridge exactly between: dividing by
	# the stepped axis instead would clear it.
	var slope_scene: Scene = _scene()
	var slope_state: MapState = slope_scene.state
	slope_state.set_height(slope_state.index_of(3, 3), 3000)
	h.equal("los.the_climb_uses_the_euclidean_distance",
		LineOfSight.check(slope_state, slope_scene.units, utab, 1, 1, 0, 5, 5,
			6000, 1, 1, 1),
		LineOfSight.TERRAIN,
		"the ray arrives low on a diagonal; dividing dz by the stepped axis "
		+ "would lift it over the ridge at (3,3)")

	h.equal("los.too_steep_is_terrain",
		LineOfSight.check(open_state, open_units, utab, 1, 1, 0, 2, 1, 900000,
			1, 1, 1),
		LineOfSight.TERRAIN)


# --- docs/22 section 7.4 -----------------------------------------------------

func _damage(h: TestHarness) -> void:
	var rng: IncRandom = IncRandom.new()
	var target: UnitState = UnitState.new()
	target.hp = 1000
	target.fp = 5

	rng.randomize_seed(1.0)
	h.equal("damage.sentinel_deals_exactly_two",
		Combat.apply_damage(target, Combat.DAMAGE_SENTINEL, 0, 1, 1, 1, rng),
		Combat.SENTINEL_DAMAGE_DEALT,
		"ignoring the roll, fatigue, armour and the difficulty level")
	h.equal("damage.the_sentinel_draws_nothing", rng.calls, 0,
		"a model that rolled first and then overrode would advance the seed")

	# The floor is `(D+1)/2` at every level and only the span grows.
	var floors: Array[int] = []
	var ceilings: Array[int] = []
	for level: int in [0, 1, 2]:
		var lo: int = 1 << 30
		var hi: int = -1
		for i: int in range(400):
			var probe: UnitState = UnitState.new()
			probe.hp = 1 << 20
			probe.fp = 5
			rng.randomize_seed(float(i + 1))
			var dealt: int = Combat.apply_damage(probe, 10, 0, level, 1, 1, rng)
			lo = mini(lo, dealt)
			hi = maxi(hi, dealt)
		floors.append(lo)
		ceilings.append(hi)
	h.equal("damage.floor_is_level_independent", floors,
		[floors[0], floors[0], floors[0]])
	h.check("damage.span_widens_with_the_level",
		ceilings[0] < ceilings[1] and ceilings[1] < ceilings[2],
		"maxima %s" % [ceilings])

	# Fatigue is a multiplier on the receiving end, and it is spent as **extra
	# draws**: two at `fp == 0`, one at `fp == 1`, none above.  Counting the
	# draws says so where comparing the totals would not -- a model that added
	# a constant instead would land in the same band.
	var draws: Array[int] = []
	for fp: int in [0, 1, 5]:
		var tired: UnitState = UnitState.new()
		tired.hp = 1 << 20
		tired.fp = fp
		rng.randomize_seed(11.0)
		Combat.apply_damage(tired, 10, 0, 1, 1, 1, rng)
		draws.append(rng.calls)
	h.equal("damage.fatigue_costs_extra_draws", draws, [3, 2, 1],
		"one roll always, plus one at fp 1 and two at fp 0")

	# The immune type and the floor at zero.
	var immune: UnitState = UnitState.new()
	immune.hp = 50
	immune.type_id = Combat.IMMUNE_UNIT_TYPE
	rng.randomize_seed(1.0)
	h.equal("damage.immune_type_takes_none",
		Combat.apply_damage(immune, 100, 0, 1, 1, 1, rng), 0)
	h.equal("damage.immune_type_keeps_its_hit_points", immune.hp, 50)
	var frail: UnitState = UnitState.new()
	frail.hp = 1
	frail.fp = 5
	rng.randomize_seed(7.0)
	var _dealt: int = Combat.apply_damage(frail, 100, 0, 1, 1, 1, rng)
	h.equal("damage.hit_points_floor_at_zero", frail.hp, 0)

	# The rear arc picks the other armour value.
	var armoured: UnitState = UnitState.new()
	armoured.hp = 1 << 20
	armoured.fp = 5
	armoured.facing = 0
	armoured.armour_front = 0
	armoured.armour_rear = 40
	rng.randomize_seed(3.0)
	var from_front: int = Combat.apply_damage(armoured, 10, 2, 1, 1, 1, rng)
	rng.randomize_seed(3.0)
	var from_rear: int = Combat.apply_damage(armoured, 10, 0, 1, 1, 1, rng)
	h.check("damage.the_rear_arc_selects_the_rear_armour",
		from_rear < from_front,
		"%d from the back, %d from the front, same seed" % [from_rear,
			from_front])


func _overheat(h: TestHarness) -> void:
	var wtab: WeaponTable = _weapons()
	var unit: UnitState = UnitState.new()
	unit.hp = 10
	unit.weapon = REACTION_WEAPON
	var rng: IncRandom = IncRandom.new()

	unit.heat = wtab.heat(REACTION_WEAPON) - 1
	rng.randomize_seed(5.0)
	h.equal("overheat.below_the_cap_does_nothing",
		Combat.check_weapon_damage(wtab, unit, rng), Combat.OVERHEAT_NONE)
	h.equal("overheat.below_the_cap_draws_nothing", rng.calls, 0,
		"the gate is `heat == cap`, so nothing is rolled below it")

	# A weapon with no heat cap at all can never overheat.
	unit.weapon = 5
	unit.heat = 255
	h.equal("overheat.a_capless_weapon_never_rolls",
		Combat.check_weapon_damage(wtab, unit, rng), Combat.OVERHEAT_NONE)

	# The `Cooler` doubles the cap, which is what takes the unit *off* the gate.
	unit.weapon = REACTION_WEAPON
	h.equal("overheat.the_cooler_doubles_the_cap",
		Combat.max_heat(wtab, unit), wtab.heat(REACTION_WEAPON))
	unit.equipment = PackedInt32Array([Combat.EQUIP_COOLER])
	h.equal("overheat.the_cooler_doubles_it",
		Combat.max_heat(wtab, unit), wtab.heat(REACTION_WEAPON) * 2)

	# The span is the constant 40 and **not** the cap, so a weapon with a cap of
	# 4 can still be destroyed.  That is the correction the native capture made.
	unit.equipment = PackedInt32Array()
	var arms: Dictionary = {}
	for i: int in range(400):
		unit.heat = wtab.heat(REACTION_WEAPON)
		unit.malfunction = 0
		unit.hp = 10
		rng.randomize_seed(float(i + 1))
		arms[Combat.check_weapon_damage(wtab, unit, rng)] = true
	h.check("overheat.a_low_cap_still_reaches_every_arm", arms.size() >= 3,
		"arms reached over 400 seeds: %s" % [arms.keys()])
	h.check("overheat.the_span_is_a_constant",
		Combat.OVERHEAT_SPAN == 40 and wtab.heat(REACTION_WEAPON) != 40,
		"0x0046D1D6 pushes 0x28; docs/22 section 8 said the cap for years")


# --- docs/22 section 9 -------------------------------------------------------

func _visibility(h: TestHarness) -> void:
	var scene: Scene = _scene()
	var state: MapState = scene.state
	var units: Dictionary = scene.units
	var utab: UnitTypeTable = scene.types
	var mine: UnitState = _place(scene, 0, 0, 1, 1, 0)
	var seen: UnitState = _place(scene, 1, UnitState.PLAYER_ALIEN, 5, 5, 0)
	var crate: UnitState = _place(scene, 2, 252, 2, 1, 0, 30)

	Visibility.build(state, units, utab, 0, 1, 1)
	h.equal("fog.my_own_unit_is_always_full", mine.visibility,
		Visibility.FULL)
	h.equal("fog.an_alien_in_the_open_is_seen", seen.visibility,
		Visibility.FULL)
	h.equal("fog.scenery_is_always_full", crate.visibility, Visibility.FULL,
		"species 2 is never hidden and is never an observer's target")

	# Behind terrain: hidden by the first pass, then promoted to a lone contact
	# by the neighbour-cluster pass.
	for x: int in range(SCENE_SIZE):
		state.set_height(state.index_of(x, 3), 20000)
	Visibility.build(state, units, utab, 0, 1, 1)
	h.equal("fog.terrain_hides", seen.visibility, Visibility.CONTACT,
		"hidden by the first pass, promoted by the neighbour-cluster pass")

	# A **body** in the way does not hide: vision accepts 254.
	var open_scene: Scene = _scene()
	var open_state: MapState = open_scene.state
	var open_units: Dictionary = open_scene.units
	# **The body in the way must not be an observer.**  A friendly soldier
	# standing there sees the alien himself, so the pass reveals it whatever
	# the ray through him reported, and the check passes on a model that
	# rejects 254.  A crate cannot see.
	_place(open_scene, 0, 0, 3, 1, 0)
	_place(open_scene, 1, 252, 3, 3, 0, 30)
	var behind: UnitState = _place(open_scene, 2, UnitState.PLAYER_ALIEN, 3, 5,
		0)
	Visibility.build(open_state, open_units, open_scene.types, 0, 1, 1)
	h.equal("fog.a_body_does_not_hide", behind.visibility, Visibility.FULL,
		"docs/22 section 9.3: a unit blocks a shot but not the sight of it")

	# The alert: seeing a neutral on an alerting order promotes its group's
	# secondary order over its primary.
	var alert_scene: Scene = _scene()
	_place(alert_scene, 0, 0, 1, 1, 0)
	var sleeper: UnitState = _place(alert_scene, 1, UnitState.PLAYER_ALIEN, 5,
		5, 0)
	sleeper.order = Visibility.ALERTING_ORDERS[0]
	sleeper.order2 = 9
	sleeper.order2_param = 7
	sleeper.group = 3
	var bystander: UnitState = _place(alert_scene, 2, UnitState.PLAYER_ALIEN,
		6, 5, 0)
	bystander.order = 1
	bystander.order2 = 4
	bystander.group = 3
	Visibility.build(alert_scene.state, alert_scene.units,
		alert_scene.types, 0, 1, 1)
	h.equal("fog.seeing_an_alerting_order_wakes_the_group",
		[sleeper.order, sleeper.order_param, bystander.order],
		[9, 7, 4],
		"0x0047A810 copies +0x49/+0x4A over +0x47/+0x48 for the whole group")


# --- docs/21 section 4 and docs/25 section 6 ---------------------------------

func _defence_gate(h: TestHarness) -> void:
	var wtab: WeaponTable = _weapons()
	var ready: UnitState = UnitState.new()
	ready.hp = 10
	ready.mp = Reaction.MIN_MP
	ready.ammo = 1
	ready.weapon = REACTION_WEAPON
	h.check("defence.the_ui_gate_accepts_a_ready_unit",
		Reaction.may_enter_defence(wtab, ready), "def_mode 1")

	var refusals: Dictionary = {
		"too_few_movement_points": "mp",
		"a_jammed_weapon": "malfunction",
		"an_empty_magazine": "ammo",
		"already_waiting": "action_state",
	}
	var values: Dictionary = {
		"mp": Reaction.MIN_MP - 1, "malfunction": 1, "ammo": 0,
		"action_state": Reaction.WAITING,
	}
	for name: String in refusals:
		var field: String = DictRead.as_string(refusals[name])
		var probe: UnitState = UnitState.new()
		probe.hp = 10
		probe.mp = Reaction.MIN_MP
		probe.ammo = 1
		probe.weapon = REACTION_WEAPON
		probe.set(field, DictRead.as_int(values[field]))
		h.check("defence.the_ui_gate_refuses_%s" % name,
			not Reaction.may_enter_defence(wtab, probe), field)

	# The weapon flag itself.
	var flamer: UnitState = UnitState.new()
	flamer.hp = 10
	flamer.mp = Reaction.MIN_MP
	flamer.ammo = 1
	flamer.weapon = 5
	h.check("defence.a_def_mode_zero_weapon_is_refused",
		not Reaction.may_enter_defence(wtab, flamer)
			and not Reaction.auto_enter_defence(wtab, flamer),
		"both gates agree on 0")

	# The one value the two gates disagree about.  It never ships, so it has to
	# be constructed to be seen at all -- docs/21 section 4.
	var odd: WeaponTable = WeaponTable.from_rows([
		{"id": 1, "heat": 255, "toggle": 1, "mun": 9, "hit": 20, "damage": 1,
			"range_min": 1, "range_max": 10, "type": 1, "special": 0,
			"def_mode": 4, "mun_per_fight": 1}])
	var four: UnitState = UnitState.new()
	four.hp = 10
	four.mp = Reaction.MIN_MP
	four.ammo = 1
	four.weapon = 1
	h.equal("defence.def_mode_4_splits_the_two_gates",
		[Reaction.may_enter_defence(odd, four),
			Reaction.auto_enter_defence(odd, four)], [false, true],
		"0x004753E0 tests `& 1` and 0x0040A710 tests `== 1 || == 4`")

	# The ticket.
	var state: TurnState = TurnState.create()
	var first: UnitState = UnitState.new()
	first.hp = 10
	first.mp = 4
	var second: UnitState = UnitState.new()
	second.hp = 10
	second.mp = 4
	h.equal("defence.tickets_are_consecutive_from_one",
		[Reaction.enter_defence(state, first),
			Reaction.enter_defence(state, second)], [1, 2])
	h.equal("defence.entering_stamps_the_acted_byte",
		[first.acted, first.action_state], [Reaction.ACTED, Reaction.WAITING])
	h.equal("defence.a_second_press_spends_the_movement_points",
		[Reaction.enter_defence(state, first), first.mp], [3, 0],
		"0x00478500 zeroes +0x15 when the unit was already waiting")


## The queue, on a scene built for it: **no shipped `.lev` places a unit on
## overwatch**, so nothing loaded can reach this at all.
##
## The reactor with the *lower* ticket sits in the *higher* slot, which is the
## smallest world in which the two drain orders can disagree.  Both are given an
## off-centre facing from their own arc, so `aAttackUnit`'s turn-to-face is not
## a no-op and the save-and-restore is visible.
func _reaction_queue(h: TestHarness) -> void:
	var scene: Scene = _reaction_scene()
	var mover: UnitState = _at(scene, 0)
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	var fired: Array[Dictionary] = Reaction.drain(scene.state,
		scene.units, scene.types, scene.weapons, mover, 1, 1,
		TurnState.MODE_CAMPAIGN, rng)
	var tickets: Array[int] = []
	var reactors: Array[int] = []
	for shot: Dictionary in fired:
		tickets.append(DictRead.as_int(shot["ticket"]))
		reactors.append(DictRead.as_int(shot["reactor"]))
	h.equal("reaction.campaign_drains_in_ticket_order", tickets, [1, 2],
		"0x0046CCA0 counts up from ticket 1, so the unit that went on "
		+ "overwatch first shoots first")
	h.equal("reaction.ticket_order_is_not_slot_order", reactors, [2, 1])
	h.equal("reaction.the_flag_survives_the_shot",
		[_at(scene, 1).action_state, _at(scene, 2).action_state],
		[Reaction.WAITING, Reaction.WAITING],
		"docs/25 section 6: nothing in the drain stores into +0x41, so a unit "
		+ "on overwatch fires at every enemy that walks past")
	h.equal("reaction.the_shot_would_have_turned_them",
		[Combat.direction(4, 2, 4, 4), Combat.direction(4, 6, 4, 4)], [0, 2],
		"the headings differ from the facings the scene sets, so a restore "
		+ "that does nothing is visible")
	h.equal("reaction.the_facing_is_restored",
		[_at(scene, 1).facing, _at(scene, 2).facing], [6, 4])
	h.equal("reaction.the_shots_spent_ammunition",
		[_at(scene, 1).ammo, _at(scene, 2).ammo], [14, 14])

	# Every other mode ignores the ticket and walks the slots in index order.
	var net: Scene = _reaction_scene()
	var net_mover: UnitState = _at(net, 0)
	rng.randomize_seed(1.0)
	var net_fired: Array[Dictionary] = Reaction.drain(net.state,
		net.units, net.types, net.weapons, net_mover, 1, 2,
		TurnState.MODE_NET, rng)
	var net_order: Array[int] = []
	for shot: Dictionary in net_fired:
		net_order.append(DictRead.as_int(shot["reactor"]))
	h.equal("reaction.other_modes_drain_in_slot_order", net_order, [1, 2],
		"the tickets are still written; only the order differs")

	# The arc, and the Banner that lifts it.
	var arc: Scene = _reaction_scene()
	var arc_mover: UnitState = _at(arc, 0)
	var north: UnitState = _at(arc, 1)
	var south: UnitState = _at(arc, 2)
	north.facing = 2
	south.facing = 0
	h.equal("reaction.looking_away_is_not_a_candidate",
		Reaction.candidates(arc.state, arc.units, arc.types,
			arc.weapons, arc_mover, 1, 1).size(), 0)
	var carrier: UnitState = _place(arc, 3, UnitState.PLAYER_ALIEN, 5, 4, 0)
	carrier.equipment = PackedInt32Array([Combat.EQUIP_BANNER])
	carrier.action_state = 0
	h.check("reaction.the_carrier_covers_both_reactors",
		MoveMap.distance(5, 4, north.x, north.y) < Combat.BANNER_RANGE
			and MoveMap.distance(5, 4, south.x, south.y)
				< Combat.BANNER_RANGE,
		"0x0046FAD0 is a strict `< 4`")
	h.equal("reaction.a_banner_lifts_the_arc",
		Reaction.candidates(arc.state, arc.units, arc.types,
			arc.weapons, arc_mover, 1, 1).size(), 2)

	# A dead mover draws nothing, and one that dies mid-drain stops it.
	var dead: Scene = _reaction_scene()
	var corpse: UnitState = _at(dead, 0)
	corpse.hp = 0
	rng.randomize_seed(1.0)
	h.equal("reaction.a_dead_mover_draws_nothing",
		Reaction.drain(dead.state, dead.units, dead.types,
			dead.weapons, corpse, 1, 1, TurnState.MODE_CAMPAIGN,
			rng).size(), 0)
	var frail_scene: Scene = _reaction_scene()
	var frail: UnitState = _at(frail_scene, 0)
	frail.hp = 1
	rng.randomize_seed(1.0)
	var stopped: Array[Dictionary] = Reaction.drain(frail_scene.state,
		frail_scene.units, frail_scene.types, frail_scene.weapons,
		frail, 1, 1, TurnState.MODE_CAMPAIGN, rng)
	h.check("reaction.death_stops_the_drain",
		not frail.is_alive() and stopped.size() == 1,
		"%d shot(s) before hp %d" % [stopped.size(), frail.hp])


## One unit out of a scene, narrowed.  `scene.units` is an untyped
## [Dictionary], so every read of it needs this or the call it feeds does not
## compile.
static func _at(scene: Scene, slot: int) -> UnitState:
	return scene.units[slot]


static func _reaction_scene() -> Scene:
	var scene: Scene = _scene()
	var mover: UnitState = _place(scene, 0, 0, 4, 4, 0)
	mover.action_state = 0
	var high_ticket: UnitState = _place(scene, 1, UnitState.PLAYER_ALIEN, 4, 2,
		6)
	high_ticket.action_state = Reaction.WAITING
	high_ticket.ticket = 2
	var low_ticket: UnitState = _place(scene, 2, UnitState.PLAYER_ALIEN, 4, 6,
		4)
	low_ticket.action_state = Reaction.WAITING
	low_ticket.ticket = 1
	return scene


# --- docs/26 -----------------------------------------------------------------

func _interaction(h: TestHarness) -> void:
	var wtab: WeaponTable = _weapons()

	# The gate: the band, the crowbar and the jammed door's one-way opening.
	var scene: Scene = _scene()
	var state: MapState = scene.state
	var unit: UnitState = _place(scene, 0, 0, 1, 1, 3)
	var at: int = state.index_of(2, 1)
	state.set_action_point(at, Interact.BAND_LOW - 1)
	h.equal("use.below_the_band_is_refused",
		Interact.use_target(state, unit), -1)
	state.set_action_point(at, Interact.BAND_HIGH + 1)
	h.equal("use.above_the_band_is_refused",
		Interact.use_target(state, unit), -1)
	state.set_action_point(at, 17)
	h.equal("use.inside_the_band_is_accepted",
		Interact.use_target(state, unit), 17)
	state.set_action_point(at, Interact.DOOR_JAMMED_CLOSED)
	h.equal("use.a_jammed_door_needs_the_crowbar",
		Interact.use_target(state, unit), -1)
	unit.equipment = PackedInt32Array([Interact.EQUIP_CROWBAR])
	h.equal("use.the_crowbar_opens_it",
		Interact.use_target(state, unit), Interact.DOOR_JAMMED_CLOSED)

	var control: GameControl = GameControl.create()
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	var opened: UseResult = Interact.execute(state, scene.units,
		scene.types, wtab, control, unit, 1, 1, 1, rng)
	h.equal("use.the_jammed_door_becomes_jammed_open",
		[opened.kind, state.action_point_at(at)],
		["door", Interact.DOOR_JAMMED_OPEN])
	h.equal("use.and_can_never_be_closed_again",
		Interact.use_target(state, unit), -1,
		"docs/26 section 2 refuses id 32 unconditionally, which is why the "
		+ "corpus census finds zero cells carrying it")

	# Exactly one facing reaches the cell -- the whole input is +0x46.
	var facing_scene: Scene = _scene()
	var facing_state: MapState = facing_scene.state
	var walker: UnitState = _place(facing_scene, 0, 0, 2, 2, 0)
	facing_state.set_action_point(facing_state.index_of(3, 2), 17)
	var hits: Array[int] = []
	for f: int in range(8):
		walker.facing = f
		if Interact.use_target(facing_state, walker) >= 0:
			hits.append(f)
	h.equal("use.exactly_one_facing_reaches_the_point", hits, [3],
		"FACING_DX[3] is +1, which docs/26's native sweep confirmed")

	# Class 12 **assigns** the magazine -- docs/26 section 3.2.
	var full: Scene = _scene()
	var full_state: MapState = full.state
	var soldier: UnitState = _place(full, 0, 0, 1, 1, 3)
	soldier.ammo = wtab.magazine(REACTION_WEAPON)
	full_state.set_action_point(full_state.index_of(2, 1), 12)
	var kept: UseResult = Interact.execute(full_state, full.units,
		full.types, wtab, control, soldier, 1, 1, 1, rng)
	h.equal("use.a_full_magazine_is_a_visible_no_op",
		[soldier.ammo, full_state.action_point_at(full_state.index_of(2, 1)),
			kept.kind],
		[wtab.magazine(REACTION_WEAPON), 0, "full_munition"],
		"a test written as 'ammunition increased' fails on correct behaviour")

	# Class 16 guards on Battle Fitness -- docs/26 section 3.3.
	var bug: Scene = _scene()
	var bug_state: MapState = bug.state
	var trainee: UnitState = _place(bug, 0, 0, 1, 1, 3)
	trainee.skills = PackedInt32Array([3, 0, 0, 9, 0, 0])
	bug_state.set_action_point(bug_state.index_of(2, 1), 16)
	Interact.execute(bug_state, bug.units, bug.types, wtab, control,
		trainee, 1, 1, 1, rng)
	h.equal("use.the_technical_box_pushes_past_the_cap",
		trainee.skills[UnitState.SKILL_TS], 10,
		"the guard reads CON, so nothing bounds TS")
	trainee.skills = PackedInt32Array([Interact.SKILL_CAP, 0, 0, 1, 0, 0])
	bug_state.set_action_point(bug_state.index_of(2, 1), 16)
	Interact.execute(bug_state, bug.units, bug.types, wtab, control,
		trainee, 1, 1, 1, rng)
	h.equal("use.the_technical_box_stops_at_a_capped_condition",
		trainee.skills[UnitState.SKILL_TS], 1,
		"inert for a unit whose Battle Fitness is 6 -- the bug, reproduced")

	# The equipment-point slot.
	var points: Scene = _scene()
	var points_state: MapState = points.state
	var finder: UnitState = _place(points, 0, 0, 1, 1, 3)
	var bonus: GameControl = GameControl.create()
	points_state.set_action_point(points_state.index_of(2, 1), 13)
	Interact.execute(points_state, points.units, points.types, wtab,
		bonus, finder, 1, 1, 1, rng)
	h.equal("use.class_13_adds_fifty_equipment_points",
		bonus.get_slot(GameControl.SLOT_EQUIPMENT_POINTS), 50)

	# The door round trip.
	var door: Scene = _scene()
	var door_state: MapState = door.state
	var opener: UnitState = _place(door, 0, 0, 1, 1, 3)
	var door_at: int = door_state.index_of(2, 1)
	door_state.set_action_point(door_at, 31)
	door_state.set_field_type(door_at, Interact.FIELD_TYPE_WALL)
	door_state.set_height(door_at, Interact.DOOR_HEIGHT_STEP)
	Interact.execute(door_state, door.units, door.types, wtab, control,
		opener, 1, 1, 1, rng)
	h.equal("use.opening_drops_the_panel_to_the_floor",
		[door_state.action_point_at(door_at),
			door_state.field_type_at(door_at), door_state.height_at(door_at)],
		[30, Interact.FIELD_TYPE_FREE, 0])
	Interact.execute(door_state, door.units, door.types, wtab, control,
		opener, 1, 1, 1, rng)
	h.equal("use.closing_raises_it_one_tile",
		[door_state.action_point_at(door_at),
			door_state.field_type_at(door_at), door_state.height_at(door_at)],
		[31, Interact.FIELD_TYPE_WALL, Interact.DOOR_HEIGHT_STEP],
		"the round trip restores every byte it touched")

	# An id the switch does not handle reaches the default arm and nothing else.
	var script_only: Scene = _scene()
	var script_state: MapState = script_only.state
	var presser: UnitState = _place(script_only, 0, 0, 1, 1, 3)
	script_state.set_action_point(script_state.index_of(2, 1), 25)
	var pressed: UseResult = Interact.execute(script_state,
		script_only.units, script_only.types, wtab, control, presser, 1,
		1, 1, rng)
	h.equal("use.an_unhandled_in_band_id_is_script_only",
		[pressed.kind, pressed.fires_script_event,
			script_state.action_point_at(script_state.index_of(2, 1))],
		["script_only", true, 25],
		"docs/26 section 2: buttons and mission gadgets are exactly this")

	_turn_to_face(h)
	_push(h, wtab, control, rng)


## docs/22 section 7.4 -- `aAttackUnit` writes the shooter's own `+0x46` before
## it resolves anything, and the rear-arc test then reads it.  A model that left
## the facing alone would still deal damage, and would pick the wrong armour.
func _turn_to_face(h: TestHarness) -> void:
	var scene: Scene = _scene()
	var shooter: UnitState = _place(scene, 0, 0, 1, 1, 2)
	var target: UnitState = _place(scene, 1, UnitState.PLAYER_ALIEN, 5, 1, 0)
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	var shot: AttackResult = Combat.attack(scene.state, scene.units,
		scene.types, scene.weapons, 1, 1, 5, 1, 1, 1, 1, rng)
	h.equal("attack.the_shooter_turns_to_face",
		[shooter.facing, shot.facing], [3, 3],
		"the heading from (1,1) to (5,1) is octant 3, and the shooter began "
		+ "at 2")
	h.check("attack.it_resolved_the_target", not shot.outcomes.is_empty(),
		"%d outcome(s), so the facing above was written on a live path"
			% shot.outcomes.size())
	h.check("attack.the_shot_spent_a_round", target.hp <= 1000,
		"hp %d" % target.hp)


func _push(h: TestHarness, wtab: WeaponTable, control: GameControl,
		rng: IncRandom) -> void:
	var scene: Scene = _scene(10, 10)
	var state: MapState = scene.state
	var pusher: UnitState = _place(scene, 0, 0, 1, 5, 3)
	var crate: UnitState = _place(scene, 1, 252, 2, 5, 0, 30)
	var slid: UseResult = Interact.execute(state, scene.units,
		scene.types, wtab, control, pusher, 1, 1, 1, rng)
	h.equal("push.slides_at_most_four_cells", slid.pushed.size(),
		Interact.PUSH_MAX_STEPS)
	h.equal("push.the_object_ends_where_the_slide_did",
		[crate.x, crate.y], [6, 5])
	h.equal("push.the_pusher_does_not_move", [pusher.x, pusher.y], [1, 5],
		"0x0046D530 re-tests with the object's coordinates")
	h.check("push.never_reaches_the_script", not slid.fires_script_event,
		"docs/26 section 3: a push returns before the default arm")

	# The Parabomb sits between two pushable ids and is not one of them.
	h.check("push.the_parabomb_is_excluded",
		not Interact.PUSHABLE_TYPES.has(31)
			and Interact.PUSHABLE_TYPES.has(30)
			and Interact.PUSHABLE_TYPES.has(32),
		"docs/26 section 4 lists 30, 32, 33, 34, 35")

	# A hole swallows it.
	var hole: Scene = _scene(10, 10)
	var hole_state: MapState = hole.state
	var shover: UnitState = _place(hole, 0, 0, 1, 5, 3)
	var doomed: UnitState = _place(hole, 1, 252, 2, 5, 0, 30)
	hole_state.set_field_type(hole_state.index_of(3, 5),
		Interact.FIELD_TYPE_DEEP_HOLE)
	var fell: UseResult = Interact.execute(hole_state, hole.units,
		hole.types, wtab, control, shover, 1, 1, 1, rng)
	h.equal("push.a_hole_swallows_it",
		[fell.kind, doomed.hp,
			hole_state.unit_at(hole_state.index_of(3, 5))],
		["push_into_hole", 0, MapState.NO_UNIT])

	# Defusing a mine: nothing explodes, and it never reaches the script.
	var mine: Scene = _scene(10, 10)
	var mine_state: MapState = mine.state
	var sapper: UnitState = _place(mine, 0, 0, 1, 5, 3)
	var bystander: UnitState = _place(mine, 2, 0, 2, 6, 0)
	mine_state.set_obstacle(mine_state.index_of(2, 5), Interact.EFFECT_MINE)
	h.check("mine.the_gate_offers_a_defuse",
		Interact.may_use(mine_state, mine.units, mine.types, sapper),
		"predicate 4 reads +0x10")
	var mine_at: int = mine_state.index_of(2, 5)
	mine_state.set_action_point(mine_at, 17)
	mine_state.set_height(mine_at, 640)
	var defused: UseResult = Interact.execute(mine_state, mine.units,
		mine.types, wtab, control, sapper, 1, 1, 1, rng)
	# docs/26 section 4.1: the defuse frees the effect object and touches
	# nothing else.  The action point in particular survives -- a defuse is not
	# a pickup, and the point under the mine is still there to be used.
	h.equal("mine.defusing_touches_only_the_effect_byte",
		[mine_state.action_point_at(mine_at), mine_state.height_at(mine_at),
			mine_state.field_type_at(mine_at)],
		[17, 640, Interact.FIELD_TYPE_FREE])
	h.equal("mine.defusing_removes_it_without_an_explosion",
		[defused.kind, mine_state.obstacle_at(mine_state.index_of(2, 5)),
			bystander.hp, defused.fires_script_event],
		["defuse_mine", Interact.EFFECT_NONE, 1000, false])


## The seams, at the [World] level.
##
## Everything above tests the algorithms on built scenes. This tests that the
## world **calls** them -- which is a separate failure: every check in this file
## passed while `submit_move` drew no reactions and `submit_end_turn` rebuilt no
## fog, because nothing asked.
func _world_wiring(h: TestHarness) -> void:
	# --- the fog, at the hand-over ---------------------------------------
	var world: World = _wired_world()
	var alien_before: Dictionary = world.unit_view(1)
	h.equal("world.the_alien_starts_hidden",
		DictRead.as_int(alien_before["visibility"]), Visibility.HIDDEN,
		"the fixture places it hidden, so a pass that ran would be visible")
	var handed: TurnResult = world.submit_end_turn(EndTurnCommand.create())
	h.check("world.the_hand_over_rebuilt_the_fog", handed.fog_rebuilt,
		"code %d" % handed.code)
	h.equal("world.the_fog_pass_revealed_the_alien",
		DictRead.as_int(DictRead.as_dict(world.unit_view(1))["visibility"]),
		Visibility.FULL,
		"in the open at four fields, so the ray is clear")

	# --- the reaction drain, after a move --------------------------------
	var battle: World = _wired_world()
	var ticket: int = battle.submit_defend(DefendCommand.create(1))
	h.equal("world.the_def_button_stamps_a_ticket", ticket, 1,
		"the alien carries a def_mode 1 weapon and two movement points")
	# The gate, from the other side: the mover carries weapon 0, whose
	# `def_mode` is 0, so pressing Def on it must return 0 and stamp nothing.
	# Without this the whole gate could be deleted and every check still pass.
	h.equal("world.the_def_button_refuses_a_def_mode_zero_weapon",
		battle.submit_defend(DefendCommand.create(2)), 0,
		"slot 2 carries weapon 0")
	h.equal("world.a_refused_def_stamps_no_ticket",
		DictRead.as_int(DictRead.as_dict(battle.unit_view(2))["ticket"]), 0)
	var walked: MoveResult = battle.submit_move(MoveCommand.create(0, 2, 3))
	h.check("world.the_move_drew_a_reaction", walked.reactions.size() == 1,
		"%d reaction(s)" % walked.reactions.size())
	h.check("world.the_reactor_is_still_waiting",
		DictRead.as_int(DictRead.as_dict(battle.unit_view(1))["action_state"])
			== Reaction.WAITING,
		"docs/25 section 6: the drain never clears +0x41")

	# --- the shot ---------------------------------------------------------
	var range_world: World = _wired_world()
	var shot: AttackResult = range_world.submit_attack(
		AttackCommand.create(0, 6, 2))
	h.check("world.the_shot_fired", shot.fired, shot.reason)
	h.check("world.the_shot_resolved_the_target", not shot.outcomes.is_empty(),
		"%d outcome(s)" % shot.outcomes.size())
	h.equal("world.a_shot_from_a_missing_slot_is_refused",
		range_world.submit_attack(AttackCommand.create(99, 1, 1)).fired, false)

	# --- the use, and its one movement point ------------------------------
	var pad: World = _wired_world()
	var before_mp: int = DictRead.as_int(
		DictRead.as_dict(pad.unit_view(0))["mp"])
	pad.state.set_action_point(pad.state.index_of(3, 2), 17)
	var used: UseResult = pad.submit_use(UseCommand.create(0))
	h.equal("world.the_use_reached_its_arm", used.kind, "equipment_points")
	h.equal("world.the_command_pad_charges_one_point",
		DictRead.as_int(DictRead.as_dict(pad.unit_view(0))["mp"]),
		before_mp - 1,
		"0x004734C0 spends it; aExecuteUse itself takes nothing")
	h.equal("world.the_bonus_reached_the_game_control_slot",
		pad.game_control.get_slot(GameControl.SLOT_EQUIPMENT_POINTS), 20)


## A world with two units four fields apart, both armed, the alien hidden and
## facing the squad.
##
## Built here rather than in `TestFixtures` because it is the only place that
## wants a *shootable* pair: `tiny_world` places its two units for the movement
## checks and gives them weapon 0, which has no range at all.
static func _wired_world() -> World:
	# Octant 1 is (-1, 0): the alien looks west, straight at the squad, so the
	# 135-degree front arc covers a mover in front of it.
	var units: Array = [
		TestFixtures.unit(0, 2, 2, 0, 0, 6, 0, [], 3, 15, 3, 200),
		TestFixtures.unit(1, 6, 2, 0, UnitState.PLAYER_ALIEN, 6,
			Visibility.HIDDEN, [], 3, 15, 1, 200),
		# Weapon 0: `def_mode` 0, so the Def gate must refuse it. Placed out of
		# the way of the walk and the shot.
		TestFixtures.unit(2, 2, 7, 0, 0, 6, 0, [], 0, 5, 0, 200),
	]
	return World.create(TestFixtures.map_document(9, 9, units),
		TestFixtures.balance(), 1.0)
