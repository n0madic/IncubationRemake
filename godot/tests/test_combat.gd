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
## docs/21 section 6 -- the `special` 1 pair, by their shipped ids.
const CLOSE_COMBAT_GUN: int = 2
const CLOSE_COMBAT_BAYONET: int = 30
## A `size` 1 unit type, for the swap's large-unit subtraction.
const LARGE_TYPE: int = 40


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
	_conversion_and_absorber(h)
	_direction_and_arc(h)
	_world_wiring(h)
	_hit_curve(h)
	_line_of_sight(h)
	_damage(h)
	_overheat(h)
	_visibility(h)
	_reveals(h)
	_defence_gate(h)
	_close_combat(h)
	_reaction_queue(h)
	_jam_and_warp(h)
	_heal(h)
	_interaction(h)
	_the_hatch(h)
	_the_hero_counter(h)
	_fog_probe(h)


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
		# Weapon 47, `Laser Enhanced`: the shipped row's heat cap, damage and
		# type, because the cap is what the shot is set to and the type is
		# what the overheat arm reads.
		{"id": Combat.CONVERTER_WEAPON, "heat": 4,
			"toggle": Combat.CONVERTER_WEAPON, "mun": 255, "hit": 90,
			"damage": 1, "range_min": 0, "range_max": 40, "type": 3,
			"special": 0, "def_mode": 0, "mun_per_fight": 1},
		# The `special` 1 pair of docs/21 section 6, with the shipped ids
		# because [constant Combat.CLOSE_COMBAT_WEAPONS] is read off the
		# revert arm's own three `cmp`s: `Standard Assault Rifle` names
		# `Light Bayonet` 30 and 30 names it back.
		{"id": CLOSE_COMBAT_GUN, "heat": 4, "toggle": CLOSE_COMBAT_GUN,
			"mun": 10, "hit": 4, "damage": 4, "range_min": 1,
			"range_max": 20, "type": 1, "special": Combat.SPECIAL_CLOSE_COMBAT,
			"param": CLOSE_COMBAT_BAYONET, "def_mode": 1, "mun_per_fight": 1},
		{"id": CLOSE_COMBAT_BAYONET, "heat": 255,
			"toggle": CLOSE_COMBAT_BAYONET, "mun": 255, "hit": 100,
			"damage": 3, "range_min": 1, "range_max": 1, "type": 4,
			"special": Combat.SPECIAL_CLOSE_COMBAT, "param": CLOSE_COMBAT_GUN,
			"def_mode": 0, "mun_per_fight": 1},
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
		# A large unit, for the swap's own distance: docs/22 section 5.1
		# takes a field off for each large participant, so one of these
		# reaches a bayonet from two cells away.
		{"id": LARGE_TYPE, "mp_max": 4, "fp_max": 0, "hp_max": 20,
			"special": 0, "size": UnitTypeTable.SIZE_LARGE, "species": 0,
			"height": 20, "model": "", "description": "combot"},
	])


static func _scene(w: int = SCENE_SIZE, hgt: int = SCENE_SIZE) -> Scene:
	var n: int = w * hgt
	var zeros: Array = []
	var ones: Array = []
	var links: Array = []
	# The idle value of the three object slots and the obstacle byte.
	var idle: Array = []
	for _i: int in range(n):
		zeros.append(0)
		ones.append(Interact.FIELD_TYPE_FREE)
		links.append(-1)
		idle.append(255)
	var document: Dictionary = {
		"width": w, "height": hgt,
		"header": {"name": "combat_spec", "next_map": "", "map_type": 0,
			"mission_id": 0, "world_set": "", "world_scene": "",
			"camera_height": 0, "equip_points": [0, 0, 0, 0],
			"skill_level": 0, "tech_level": 0},
		"cells": {"height": zeros, "field_type": ones, "action_point": zeros,
			"unit": links, "effect0": zeros, "effect1": idle,
			"effect2": idle, "effect3": idle, "effect4": zeros,
			"effect5": idle, "land": zeros,
			"start_index": links},
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

	# **The probe: what the pass would say, without the pass happening.**
	#
	# `0x00481F00` (`lNetwork.cpp:1461`) saves all 200 `+0x4F` bytes
	# (`0x00479AA0`), rebuilds the fog, reads what it wanted and restores them
	# (`0x00479AC0`). The restore covers the unit byte and **not** the 3D
	# object's draw flag that `aSetVisibleStateForUnit` writes in the same
	# breath, which is how the original updates the picture on every command
	# while the rules keep reading the fog the last hand-over left. The
	# terrain wall above is still up, so `seen` is a contact by the stored
	# byte; flattening the ridge is the "the squad moved and can see it now"
	# case, and the two answers have to disagree.
	for x: int in range(SCENE_SIZE):
		state.set_height(state.index_of(x, 3), 0)
	var probed: Dictionary[int, int] = Visibility.states_for(state, units,
		utab, 0, 1, 1)
	h.equal("fog.the_probe_sees_what_the_pass_would", probed[seen.slot],
		Visibility.FULL, "the ridge is down, so the alien is in the open")
	h.equal("fog.the_probe_changes_nothing", seen.visibility,
		Visibility.CONTACT,
		"the stored byte is still what the last real pass wrote")
	Visibility.build(state, units, utab, 0, 1, 1)
	h.equal("fog.the_real_pass_agrees_with_the_probe", seen.visibility,
		probed[seen.slot],
		"the probe is the same computation, not a second one")

	# The pass itself is a query and wakes nobody; the wake the engine's
	# restore misses is [method World.probe_fog]'s, once per player command
	# (docs/97 section 34), and it is checked on a real world below.
	var quiet: Scene = _scene()
	_place(quiet, 0, 0, 1, 1, 0)
	var sleeper_probe: UnitState = _place(quiet, 1, UnitState.PLAYER_ALIEN, 3,
		1, 0)
	sleeper_probe.order = Visibility.ALERTING_ORDERS[0]
	sleeper_probe.order2 = 9
	var _probe: Dictionary[int, int] = Visibility.states_for(quiet.state,
		quiet.units, quiet.types, 0, 1, 1)
	h.equal("fog.the_pass_itself_wakes_nobody", sleeper_probe.order,
		Visibility.ALERTING_ORDERS[0],
		"a query that promoted an order would be a command")

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
## A [TurnState] for the resolver's own argument. Its `turn` is 1, not 0:
## `aRemoveUnitElement`'s hero counter is gated on the turn counter being
## non-zero (docs/22 section 9.5), and a fixture stuck at turn 0 could never
## show the counter move.
func _turn(player: int = 0, counter: int = 1) -> TurnState:
	var out: TurnState = TurnState.create()
	out.current_player = player
	out.turn = counter
	return out


# --- docs/21 section 6: the bayonet ------------------------------------------

## `0x0046F7E0` phases 0 and 1 -- the weapon a `special` 1 gun becomes when
## what it is shooting at is standing next to it.
##
## The rule is invisible in the shipped corpus's own captures: all six native
## shots of `tests/fixtures/turn/cases_turn.json` are weapon 2 -- a
## `special` 1 gun -- and every one of them is nine fields out or more, so the
## engine never took this branch there and the model agreed with it by not
## having the branch at all.
func _close_combat(h: TestHarness) -> void:
	var scene: Scene = _scene()
	var shooter: UnitState = _place(scene, 0, 0, 2, 2, 0)
	shooter.weapon = CLOSE_COMBAT_GUN
	shooter.ammo = 10
	var next_door: UnitState = _place(scene, 1, 1, 3, 2, 0)
	h.check("close.swaps_when_adjacent",
		Combat.close_combat_swap(scene.state, scene.types, scene.weapons,
			shooter, next_door),
		"a `special` 1 gun one field away becomes its `param`")
	h.equal("close.becomes_the_param", shooter.weapon, CLOSE_COMBAT_BAYONET)
	h.check("close.reverts", Combat.close_combat_revert(scene.weapons, shooter),
		"and phase 1 puts the gun back")
	h.equal("close.back_to_the_gun", shooter.weapon, CLOSE_COMBAT_GUN)
	# The revert reads the **held** weapon's id, not only its `special`, which
	# is what stops the swap from undoing itself on the way in.
	h.check("close.a_gun_is_not_reverted",
		not Combat.close_combat_revert(scene.weapons, shooter),
		"only ids 30, 31 and 32 are on the way back")

	# The distance, and the two things that move it.
	var far: UnitState = _place(scene, 2, 1, 4, 2, 0)
	h.check("close.refuses_at_two_fields",
		not Combat.close_combat_swap(scene.state, scene.types, scene.weapons,
			shooter, far), "`cmp eax, 1` and nothing else")
	far.type_id = LARGE_TYPE
	h.check("close.a_large_target_is_one_field_nearer",
		Combat.close_combat_swap(scene.state, scene.types, scene.weapons,
			shooter, far), "docs/22 section 5.1's own subtraction")
	shooter.weapon = CLOSE_COMBAT_GUN
	far.type_id = 0
	# The height gate: `abs(dh) / 160 < 16`.
	var levels: int = Combat.CLOSE_COMBAT_HEIGHT_LEVELS
	var step: int = UnitTypeTable.HEIGHT_UNIT
	scene.state.set_height(scene.state.index_of(3, 2), levels * step)
	h.check("close.refuses_a_storey_too_far",
		not Combat.close_combat_swap(scene.state, scene.types, scene.weapons,
			shooter, next_door), "sixteen levels is already too many")
	scene.state.set_height(scene.state.index_of(3, 2), (levels - 1) * step)
	h.check("close.accepts_the_level_below_it",
		Combat.close_combat_swap(scene.state, scene.types, scene.weapons,
			shooter, next_door), "fifteen is still close combat")
	scene.state.set_height(scene.state.index_of(3, 2), 0)
	shooter.weapon = CLOSE_COMBAT_GUN

	# And the whole of it through `aAttackUnit`, which is where a player meets
	# it: **the round is not spent**, because the weapon that fired had
	# `mun` 255 by the time the subtraction of docs/22 section 7.5 read it.
	var rng: IncRandom = IncRandom.new()
	var before: int = shooter.ammo
	var stab: AttackResult = Combat.attack(scene.state, scene.units,
		scene.types, scene.weapons, shooter.x, shooter.y, next_door.x,
		next_door.y, 0, 1, 1, _turn(), rng)
	h.check("close.the_stab_fired", stab.fired, stab.reason)
	h.equal("close.no_round_is_spent", shooter.ammo, before,
		"the bayonet's magazine is 255, so the subtraction is skipped")
	h.equal("close.the_gun_is_back_after_the_shot", shooter.weapon,
		CLOSE_COMBAT_GUN,
		"phase 1 runs before the routine returns, so the animation sees a gun")
	# The control: the same gun at range spends its round.
	var distant: UnitState = _place(scene, 3, 1, 2, 7, 0)
	var spent_before: int = shooter.ammo
	var shot: AttackResult = Combat.attack(scene.state, scene.units,
		scene.types, scene.weapons, shooter.x, shooter.y, distant.x,
		distant.y, 0, 1, 1, _turn(), rng)
	h.check("close.the_distant_shot_fired", shot.fired, shot.reason)
	h.equal("close.a_round_is_spent_at_range", shooter.ammo, spent_before - 1,
		"nothing swapped, so the gun's own magazine is read")
	# A reaction reaches neither arm: `0x0046B592` and `0x0046C319` jump past
	# the dispatcher when `aAttackUnit`'s fifth argument is set.
	var reaction_before: int = shooter.ammo
	var reacted: AttackResult = Combat.attack(scene.state, scene.units,
		scene.types, scene.weapons, shooter.x, shooter.y, next_door.x,
		next_door.y, 0, 1, 1, _turn(), rng, true)
	h.check("close.the_reaction_fired", reacted.fired, reacted.reason)
	h.equal("close.a_reaction_never_reaches_for_it", shooter.ammo,
		reaction_before - 1,
		"a unit on overwatch shoots, whatever walks into the next cell")
	h.equal("close.and_keeps_its_gun", shooter.weapon, CLOSE_COMBAT_GUN)


func _reaction_queue(h: TestHarness) -> void:
	var scene: Scene = _reaction_scene()
	var mover: UnitState = _at(scene, 0)
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	var fired: Array[Dictionary] = Reaction.drain(scene.state,
		scene.units, scene.types, scene.weapons, mover, 1, 1,
		TurnState.MODE_CAMPAIGN, _turn(), rng)
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
		TurnState.MODE_NET, _turn(), rng)
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
			dead.weapons, corpse, 1, 1, TurnState.MODE_CAMPAIGN, _turn(),
			rng).size(), 0)
	var frail_scene: Scene = _reaction_scene()
	var frail: UnitState = _at(frail_scene, 0)
	frail.hp = 1
	rng.randomize_seed(1.0)
	var stopped: Array[Dictionary] = Reaction.drain(frail_scene.state,
		frail_scene.units, frail_scene.types, frail_scene.weapons,
		frail, 1, 1, TurnState.MODE_CAMPAIGN, _turn(), rng)
	h.check("reaction.death_stops_the_drain",
		not frail.is_alive() and stopped.size() == 1,
		"%d shot(s) before hp %d" % [stopped.size(), frail.hp])


## docs/25 section 6's jam arm and the pad's warp arm (docs/97 section 31).
func _jam_and_warp(h: TestHarness) -> void:
	# A reactor whose magazine the shot empties leaves the queue: the shot
	# reports it, and its ticket is cleared for the next drain.
	var scene: Scene = _reaction_scene()
	var mover: UnitState = _at(scene, 0)
	var first: UnitState = _at(scene, 2)
	first.ammo = 1
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	var fired: Array[Dictionary] = Reaction.drain(scene.state, scene.units,
		scene.types, scene.weapons, mover, 1, 1, TurnState.MODE_CAMPAIGN,
		_turn(), rng)
	var by_slot: Dictionary = {}
	for shot: Dictionary in fired:
		by_slot[DictRead.as_int(shot["reactor"])] = shot
	h.check("jam.empty_magazine_jams", by_slot.has(2)
		and DictRead.as_bool(DictRead.as_dict(by_slot[2])["jammed"])
		and first.ticket == 0,
		"0x0046CE0E: `+0x3D == 0` after the shot clears `+0x59`")
	h.check("jam.the_other_reactor_keeps_its_ticket", by_slot.has(1)
		and not DictRead.as_bool(DictRead.as_dict(by_slot[1])["jammed"])
		and _at(scene, 1).ticket == 2, "")
	h.equal("jam.the_shot_reports_its_own_ticket",
		DictRead.as_int(DictRead.as_dict(by_slot[2])["ticket"]), 1,
		"the ticket in the entry is the one the reactor fired with")
	# A heat counter one under the cap reaches it on the reaction shot.
	var hot: Scene = _reaction_scene()
	var heated: UnitState = _at(hot, 2)
	heated.heat = Combat.max_heat(hot.weapons, heated) - 1
	rng.randomize_seed(1.0)
	var hot_fired: Array[Dictionary] = Reaction.drain(hot.state, hot.units,
		hot.types, hot.weapons, _at(hot, 0), 1, 1, TurnState.MODE_CAMPAIGN,
		_turn(), rng)
	h.check("jam.heat_at_cap_jams", hot_fired.size() >= 1
		and DictRead.as_bool(hot_fired[0]["jammed"]) and heated.ticket == 0,
		"heat %d, cap %d" % [heated.heat, Combat.max_heat(hot.weapons, heated)])

	# The warp: the fill is the gate, the record relinks, the points go to
	# zero, `+0x39` is 5, and the queue drains at the landing cell.
	var jumper: Dictionary = TestFixtures.unit(0, 2, 2, 0, 0, 4, 0,
		[UnitState.JET_PACK_EQUIP_ID])
	var world: World = World.create(TestFixtures.map_document(7, 7,
		[jumper, TestFixtures.unit(1, 6, 6, 0, 1)]), TestFixtures.balance(),
		1.0)
	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(0))
	h.check("warp.the_fill_marks_targets", fill.warp_count() > 0,
		"%d warp cell(s)" % fill.warp_count())
	var refused: WarpResult = world.submit_warp(WarpCommand.create(0, 2, 3))
	h.check("warp.a_reachable_cell_is_not_a_warp",
		not refused.ok and DictRead.as_int(world.unit_view(0)["x"]) == 2,
		refused.reason)
	var target: Vector2i = Vector2i(-1, -1)
	for y: int in range(7):
		for x: int in range(7):
			if fill.is_warp_target(x, y) and target.x < 0:
				target = Vector2i(x, y)
	var jumped: WarpResult = world.submit_warp(
		WarpCommand.create(0, target.x, target.y))
	var after: Dictionary = world.unit_view(0)
	h.check("warp.relinks_the_record", jumped.ok
		and DictRead.as_int(after["x"]) == target.x
		and DictRead.as_int(after["y"]) == target.y
		and world.state.unit_at(world.state.index_of(2, 2)) == MapState.NO_UNIT
		and world.state.unit_at(world.state.index_of(target.x, target.y)) == 0,
		"%s -> %s" % [jumped.reason, str(target)])
	h.equal("warp.from_is_kept", Vector2i(jumped.from_x, jumped.from_y),
		Vector2i(2, 2))
	h.equal("warp.mp_zeroed", DictRead.as_int(after["mp"]), 0,
		"`mov byte [esi + 0x15], 0` at 0x00473046")
	h.equal("warp.acted_5", DictRead.as_int(after["acted"]), World.ACTED_WARPED,
		"`mov byte [esi + 0x39], 5` at 0x0047304A")
	h.check("warp.a_stale_slot_is_refused",
		not world.submit_warp(WarpCommand.create(9, 1, 1)).ok, "")


## docs/29 section 1.1's button 2 -- the heal command (docs/97 section 31).
func _heal(h: TestHarness) -> void:
	var scene: Scene = _scene()
	# The fixture type's 20 hit points are **above** the 15 the routine caps
	# a human at (`cmp eax, 0xF`), so every value here stays under 15: a
	# record over the cap is pulled *down* to it by `0x0047B180`.
	var healer: UnitState = _place(scene, 0, 0, 2, 2, 0)
	healer.hp = 13
	healer.equipment = PackedInt32Array([Interact.EQUIP_SMALL_MEDIC_KIT])
	# Facing 0 looks at +y (`Interact.FACING_DY[0]`); the patient stands there.
	var patient: UnitState = _place(scene, 1, 0, 2, 3, 0)
	patient.hp = 12
	h.equal("heal.power.small_kit", Interact.heal_power(healer), 1)
	var large: UnitState = _place(scene, 5, 0, 5, 5, 0)
	large.equipment = PackedInt32Array([Interact.EQUIP_LARGE_MEDIC_KIT])
	h.equal("heal.power.large_kit", Interact.heal_power(large), 3)
	h.equal("heal.power.none", Interact.heal_power(patient), 0)
	large.ep = 25
	h.equal("heal.max_hp.type_plus_ep_over_12",
		Interact.max_hit_points(scene.types, large), 15,
		"20 + 2 capped at 15")
	large.player = UnitState.PLAYER_ALIEN
	h.equal("heal.max_hp.computer_is_type",
		Interact.max_hit_points(scene.types, large), 20)
	var result: Dictionary = Interact.heal_command(scene.state, scene.units,
		scene.types, healer)
	h.check("heal.front.heals_the_patient", DictRead.as_bool(result["ok"])
		and DictRead.as_int(result["target"]) == 1 and patient.hp == 13
		and DictRead.as_int(result["delta"]) == 1, str(result))
	h.equal("heal.front.charges_one_point", healer.mp, 3)
	h.equal("heal.front.acted_3", healer.acted, Interact.ACTED_HEALED)
	patient.hp = 17
	result = Interact.heal_command(scene.state, scene.units, scene.types,
		healer)
	h.check("heal.over_the_cap_is_pulled_down_to_it", patient.hp == 15
		and DictRead.as_int(result["delta"]) == 2,
		"`0x0047B180` writes the ceiling whenever hp + power is not under it")
	# A patient at its ceiling, or another player's, sends the heal home.
	patient.hp = 15
	healer.hp = 14
	result = Interact.heal_command(scene.state, scene.units, scene.types,
		healer)
	h.check("heal.full_patient.falls_back_to_self",
		DictRead.as_bool(result["ok"]) and DictRead.as_bool(result["self_heal"])
		and healer.hp == 15, str(result))
	patient.hp = 10
	patient.player = 1
	healer.hp = 14
	result = Interact.heal_command(scene.state, scene.units, scene.types,
		healer)
	h.check("heal.other_player.falls_back_to_self",
		DictRead.as_bool(result["ok"]) and patient.hp == 10 and healer.hp == 15,
		str(result))
	# Nothing to heal: the command answers 0, the pad still writes `acted`.
	healer.hp = 15
	healer.mp = 4
	healer.acted = 0
	result = Interact.heal_command(scene.state, scene.units, scene.types,
		healer)
	h.check("heal.nothing_to_heal.answers_0_and_still_acts",
		not DictRead.as_bool(result["ok"]) and healer.mp == 4
		and healer.acted == Interact.ACTED_HEALED,
		"the join at 0x004733F3 is after both branches")
	healer.mp = 0
	healer.hp = 10
	result = Interact.heal_command(scene.state, scene.units, scene.types,
		healer)
	h.check("heal.no_mp.refused", not DictRead.as_bool(result["ok"])
		and healer.hp == 10, DictRead.as_string(result["reason"]))
	# The pad's gate `0x0047B4C0`: a kit and somebody to heal.
	healer.hp = 13
	healer.mp = 4
	patient.hp = 12
	patient.player = 0
	h.check("heal.gate.offered_with_a_kit_and_a_patient",
		Interact.may_heal(scene.state, scene.units, scene.types, healer), "")
	healer.equipment = PackedInt32Array()
	h.check("heal.gate.no_kit_not_offered",
		not Interact.may_heal(scene.state, scene.units, scene.types, healer), "")
	healer.equipment = PackedInt32Array([Interact.EQUIP_SMALL_MEDIC_KIT])
	healer.hp = 15
	patient.hp = 15
	h.check("heal.gate.nobody_to_heal_not_offered",
		not Interact.may_heal(scene.state, scene.units, scene.types, healer), "")
	patient.player = 1
	healer.hp = 14
	h.check("heal.gate.self_under_the_ceiling_is_offered",
		Interact.may_heal(scene.state, scene.units, scene.types, healer), "")
	# The world's own command. The fixture's unit carries no kit, so the
	# power is 0: the engine still answers 1 (the unit is under its ceiling),
	# heals nothing, and the pad charges the point -- the pad only offers
	# the button with a kit, which is the UI's gate and not this routine's.
	var world: World = TestFixtures.tiny_world()
	var healed: Dictionary = world.submit_heal(HealCommand.create(0))
	var after: Dictionary = world.unit_view(0)
	h.check("heal.world.no_kit_heals_nothing_but_still_charges",
		DictRead.as_bool(healed["ok"]) and DictRead.as_int(healed["delta"]) == 0
		and DictRead.as_int(after["hp"]) == 10 and DictRead.as_int(after["mp"]) == 3
		and DictRead.as_int(after["acted"]) == Interact.ACTED_HEALED,
		str(healed))
	h.check("heal.world.no_such_unit",
		not DictRead.as_bool(world.submit_heal(HealCommand.create(9))["ok"]), "")
	h.check("heal.world.gate_refuses_without_a_kit", not world.may_heal(0),
		"the pad never offers button 2 to a unit with no kit")


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
		scene.types, wtab, control, unit, 1, 1, 1, _turn(), rng)
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
		full.types, wtab, control, soldier, 1, 1, 1, _turn(), rng)
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
		trainee, 1, 1, 1, _turn(), rng)
	h.equal("use.the_technical_box_pushes_past_the_cap",
		trainee.skills[UnitState.SKILL_TS], 10,
		"the guard reads CON, so nothing bounds TS")
	trainee.skills = PackedInt32Array([Interact.SKILL_CAP, 0, 0, 1, 0, 0])
	bug_state.set_action_point(bug_state.index_of(2, 1), 16)
	Interact.execute(bug_state, bug.units, bug.types, wtab, control,
		trainee, 1, 1, 1, _turn(), rng)
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
		bonus, finder, 1, 1, 1, _turn(), rng)
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
		opener, 1, 1, 1, _turn(), rng)
	h.equal("use.opening_drops_the_panel_to_the_floor",
		[door_state.action_point_at(door_at),
			door_state.field_type_at(door_at), door_state.height_at(door_at)],
		[30, Interact.FIELD_TYPE_FREE, 0])
	Interact.execute(door_state, door.units, door.types, wtab, control,
		opener, 1, 1, 1, _turn(), rng)
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
		1, 1, _turn(), rng)
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
		scene.types, scene.weapons, 1, 1, 5, 1, 1, 1, 1, _turn(), rng)
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
		scene.types, wtab, control, pusher, 1, 1, 1, _turn(), rng)
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
		hole.types, wtab, control, shover, 1, 1, 1, _turn(), rng)
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
		mine.types, wtab, control, sapper, 1, 1, 1, _turn(), rng)
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

	# --- the ground fire, end to end -------------------------------------
	# docs/42 section 9.1: a glow laid at phase 2 is decayed to 1 by one
	# hand-over's tick and burnt by the next one's sweep, and the flames
	# **remove** what they reach -- which since `0x00477ABD` means kill.
	# The mechanism is pinned above (`hero.removal_zeroes_the_hit_points`);
	# this is the path, through `World`, because "removed" and "still counted"
	# is exactly the state that used to leave a burned marine standing.
	var burn: World = _wired_world()
	burn.state.set_special_models(PackedStringArray([
		CellObjects.GLOW_MODEL_LIT, CellObjects.GLOW_MODEL_FRESH]))
	var victim: Dictionary = burn.unit_view(0)
	h.check("ground.the_victim_starts_alive",
		DictRead.as_int(victim["hp"]) > 0 and burn.live_unit_count(0) > 0)
	var counted: int = burn.live_unit_count(0)
	h.check("ground.the_glow_was_laid",
		CellObjects.place_glow(burn.state, DictRead.as_int(victim["x"]),
			DictRead.as_int(victim["y"]), CellObjects.GLOW_PHASE_FRESH) >= 0,
		"phase 2, on the marine's own cell")
	var first_hand: TurnResult = burn.submit_end_turn(EndTurnCommand.create())
	h.check("ground.the_first_hand_over_only_decays",
		first_hand.ok and DictRead.as_int(burn.unit_view(0)["hp"]) > 0,
		"the sweep runs before the decay, so phase 2 does not ignite")
	var passes: int = 0
	while passes < 8 and DictRead.as_int(burn.unit_view(0).get("hp", 0)) > 0:
		var _next: TurnResult = burn.submit_end_turn(EndTurnCommand.create())
		passes += 1
	var burnt: Dictionary = burn.unit_view(0)
	h.equal("ground.the_flames_killed_and_unlinked",
		[DictRead.as_int(burnt["hp"]),
			burn.state.unit_at(burn.state.index_of(
				DictRead.as_int(victim["x"]), DictRead.as_int(victim["y"]))),
			burn.live_unit_count(0)],
		[0, MapState.NO_UNIT, counted - 1],
		"aRemoveUnitElement's own 0x00477ABD, and aGetLiveUnitCount stops "
		+ "counting it for that reason alone")

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

	# **A use that was not offered costs nothing.** docs/26 section 1.1's pad
	# spends the point whatever `aExecuteUse` returned, but `0x00472570` never
	# offers command 8 unless `may_use` accepted -- so the gate is what stops a
	# unit at the map edge, facing outward, from losing a point per press.
	var edge: World = _wired_world()
	var stranded: int = 2
	var kept: int = DictRead.as_int(
		DictRead.as_dict(edge.unit_view(stranded))["mp"])
	var facing_nothing: UseResult = edge.submit_use(
		UseCommand.create(stranded))
	h.equal("world.a_use_with_nothing_in_front_is_refused",
		[facing_nothing.ok, facing_nothing.kind], [false, "refused"],
		facing_nothing.reason)
	h.equal("world.a_refused_use_costs_no_movement_point",
		DictRead.as_int(DictRead.as_dict(edge.unit_view(stranded))["mp"]),
		kept)

	# --- the door, whose animation rebuilds the fog for good ---------------
	#
	# docs/22 section 9.4: `aDoorOpenSequence` (`0x00410A20`) calls
	# `aBuildVisibleMap` on **both** arms -- `0x00410C6A` when the panel drops
	# and `0x00410D60` when it rises -- for `aGetCurrentPlayer`, and outside
	# the save/restore bracket, so unlike the per-command probe it changes what
	# the rules read.  The alien's byte is set to a value the pass cannot
	# produce, so what is checked is that the pass **ran**, not the geometry.
	for opening: bool in [true, false]:
		var door: World = _wired_world()
		var at: int = door.state.index_of(3, 2)
		door.state.set_action_point(at, 31 if opening else 30)
		if opening:
			door.state.set_field_type(at, Interact.FIELD_TYPE_WALL)
			door.state.set_height(at, Interact.DOOR_HEIGHT_STEP)
		var toggled: UseResult = door.submit_use(UseCommand.create(0))
		h.equal("world.the_use_reached_the_door" if opening
				else "world.the_use_closed_the_door", toggled.kind, "door",
			toggled.reason)
		h.equal("world.a_door_rebuilds_the_fog_for_good" if opening
				else "world.a_closing_door_rebuilds_it_too",
			DictRead.as_int(door.unit_view(1)["visibility"]),
			Visibility.FULL,
			"the alien is authored hidden and stands in the open, so only a "
			+ "pass that ran can have revealed it")

	# The computer's turn is the exception: both arms test
	# `aGetCurrentPlayer() != 0xFF` first (`0x00410C5B`, `0x00410D51`).
	var alien_turn: World = _wired_world()
	var alien_at: int = alien_turn.state.index_of(3, 2)
	alien_turn.state.set_action_point(alien_at, 31)
	alien_turn.state.set_field_type(alien_at, Interact.FIELD_TYPE_WALL)
	alien_turn.state.set_height(alien_at, Interact.DOOR_HEIGHT_STEP)
	alien_turn.turn.current_player = UnitState.PLAYER_ALIEN
	var by_computer: UseResult = alien_turn.submit_use(UseCommand.create(0))
	h.equal("world.the_computers_door_still_opens",
		[by_computer.kind, alien_turn.state.height_at(alien_at)], ["door", 0])
	h.equal("world.the_computers_door_leaves_the_fog_alone",
		DictRead.as_int(alien_turn.unit_view(1)["visibility"]),
		Visibility.HIDDEN, "the guard is the engine's, not a convenience")

	# --- the LCL `Use` event ----------------------------------------------
	#
	# docs/26 section 6: every action-point class ends in `RunMissionProgram`
	# with `_A` 4, `_B`/`_C` the cell and `_D` its action point. The four
	# consoles of `_C_105` are ids 34/35 -- the switch's default arm -- and
	# their whole effect is the `Platform` command the `:Use` section runs.
	# Until 2026-09-07 `submit_use` never ran the program, so a console was a
	# click and nothing else.
	var console: World = _wired_world()
	console.state.set_action_point(console.state.index_of(3, 2), 34)
	# The block centred on (4,7) -- cells 3..5 x 6..8, nobody standing there
	# -- rides north by three onto 3..5 x 3..5, which is empty of units too.
	for ox: int in [-1, 0, 1]:
		for oy: int in [-1, 0, 1]:
			console.state.set_height(console.state.index_of(4 + ox, 7 + oy),
				Interact.DOOR_HEIGHT_STEP)
	h.check("world.the_console_program_attached",
		console.attach_script(_use_program([
			_instr("cond", "EnvVarCmpNum", [_var(LclEnv.SLOT_A),
				_num(LclEnv.CALL_USE)]),
			_instr("cond", "EnvVarCmpNum", [_var(LclEnv.SLOT_B), _num(3)], "&"),
			_instr("cond", "EnvVarCmpNum", [_var(LclEnv.SLOT_C), _num(2)], "&"),
			_instr("cond", "EnvVarCmpNum", [_var(LclEnv.SLOT_D), _num(34)], "&"),
			_instr("command", "Platform", [_num(4), _num(7), _num(0), _num(3)]),
			_instr("command", "SetActPt", [_num(3), _num(2), _num(35)]),
			_instr("close", "", []),
		])), "the console program did not load")
	var pressed: UseResult = console.submit_use(UseCommand.create(0))
	h.equal("world.the_console_is_the_default_arm",
		[pressed.kind, pressed.fires_script_event], ["script_only", true])
	h.check("world.the_use_ran_the_mission_program",
		DictRead.as_bool(pressed.script_result.get("ran", false)),
		str(pressed.script_result))
	h.equal("world.the_platform_rode_on_the_use",
		[console.state.height_at(console.state.index_of(4, 4)),
			console.state.field_type_at(console.state.index_of(4, 7))],
		[Interact.DOOR_HEIGHT_STEP, Platform.CTRL_TYPE_DEEP_HOLE],
		"the block's height reached the destination and the source is a "
		+ "deep hole -- the `Platform` command ran")
	h.equal("world.the_script_flipped_the_console",
		console.state.action_point_at(console.state.index_of(3, 2)), 35,
		"`SetActPt` beside the ride, the way `_C_105.lcl` pairs them")
	h.equal("world.the_pad_still_charges_after_the_script",
		DictRead.as_int(DictRead.as_dict(console.unit_view(0))["mp"]),
		before_mp - 1)

	# **`_D` is the cell as the switch left it.** `0x0046E152` loads the
	# action point after the arm has rewritten it, so a lever that read 36
	# hands the script 37 (docs/26 section 6, `_O_066.lcl`'s mirrored pair).
	# A model handing over the value the arm saw would flip the flag cell
	# on 36 and never on 37.
	var lever: World = _wired_world()
	lever.state.set_action_point(lever.state.index_of(3, 2), Interact.LEVER_UP)
	h.check("world.the_lever_program_attached",
		lever.attach_script(_use_program([
			_instr("cond", "EnvVarCmpNum", [_var(LclEnv.SLOT_D),
				_num(Interact.LEVER_DOWN)]),
			_instr("command", "SetActPt", [_num(0), _num(0),
				_num(Interact.LEVER_DOWN)]),
			_instr("close", "", []),
			_instr("cond", "EnvVarCmpNum", [_var(LclEnv.SLOT_D),
				_num(Interact.LEVER_UP)]),
			_instr("command", "SetActPt", [_num(0), _num(0),
				_num(Interact.LEVER_UP)]),
			_instr("close", "", []),
		])), "the lever program did not load")
	var pulled: UseResult = lever.submit_use(UseCommand.create(0))
	h.equal("world.the_lever_toggled_before_the_script_read_it",
		[pulled.kind, pulled.action_point,
			lever.state.action_point_at(lever.state.index_of(0, 0))],
		["lever", Interact.LEVER_UP, Interact.LEVER_DOWN],
		"the result carries the value the arm saw; the script saw the one "
		+ "it wrote")

	# A push returns before the default arm and the program never runs
	# (docs/26 section 3): the flag cell stays untouched.
	var shove: World = World.create(TestFixtures.map_document(9, 9, [
		TestFixtures.unit(0, 2, 2, 0, 0, 6, 0, [], 3, 15, 3, 200),
		TestFixtures.unit(1, 3, 2, PUSHABLE_CRATE_TYPE, 0, 0, 0, [], 0, 0, 0,
			200),
	]), TestFixtures.balance([TestFixtures.unit_type(PUSHABLE_CRATE_TYPE)]),
		1.0)
	h.check("world.the_push_program_attached",
		shove.attach_script(_use_program([
			_instr("command", "SetActPt", [_num(0), _num(0), _num(99)]),
		])), "the push program did not load")
	var shoved: UseResult = shove.submit_use(UseCommand.create(0))
	h.equal("world.a_push_never_runs_the_program",
		[shoved.kind, shoved.script_result.is_empty(),
			shove.state.action_point_at(shove.state.index_of(0, 0))],
		["push", true, 0])

	# --- the script's own rebuilds ----------------------------------------
	#
	# `InsertUnit` (`0x004419B6`) and the `BuildVisibleMap` command
	# (`0x00441F55`) both call `aBuildVisibleMap` for good.  [LclInterpreter]
	# records them as events and performs neither; [World] is where they land.
	var scripted: World = _wired_world()
	h.check("world.the_script_attached", scripted.attach_script({
		"schema": LclProgram.SCHEMA,
		"source": {"mission": "synthetic"},
		"header_line": 1,
		"instructions": [
			{"kind": "command", "name": "BuildVisibleMap", "line": 1,
				"op": ">", "args": [_num(-1)]},
			{"kind": "end", "name": "", "line": 1, "op": ">", "args": []},
		],
		"labels": {},
	}), "the one-command program did not load")
	var ran: Dictionary = scripted.run_init_map()
	h.check("world.the_script_ran", DictRead.as_bool(ran["ok"]),
		str(ran.get("abort", "")))
	h.equal("world.a_scripted_rebuild_is_performed_not_only_recorded",
		DictRead.as_int(scripted.unit_view(1)["visibility"]), Visibility.FULL,
		"the interpreter owns no fog, so the event has to be acted on")

	# **The elevator rebuilds for the rider, not for the current player.**
	# `aPlayElevatorSequence` (`0x004125D0`) reads the unit index out of the
	# elevator's own cell, takes that unit's `+0x45`, and passes it at
	# `0x00412905`; when the tile is empty (`cell[+0x07] == 0xFFFF`) it skips
	# the call entirely (`je` at `0x004128FD`). The rider here is the alien, so
	# a rebuild for **its** player leaves the squad hidden from itself, which
	# no rebuild for player 0 could produce.
	#
	# The discriminator is a wall the whole height of the map at `x = 4`, which
	# puts every player-0 unit on one side and the alien on the other:
	# a pass for player 0 cannot then see the alien, and a pass for player 255
	# marks it [constant Visibility.FULL] because it is that player's own. So
	# the alien's byte says **whose** pass ran, not merely that one did.
	var lift: World = _wired_world()
	_wall_column(lift, 4)
	h.check("world.the_elevator_script_attached",
		lift.attach_script(_elevator_program(6, 2)),
		"the one-command program did not load")
	var blocked_world: World = _wired_world()
	_wall_column(blocked_world, 4)
	blocked_world._first_hand_over()
	h.equal("world.the_wall_hides_the_rider_from_player_zero",
		DictRead.as_int(blocked_world.unit_view(1)["visibility"]),
		Visibility.CONTACT,
		"a pass for player 0 leaves the alien a blip behind the wall; without "
		+ "this the next check could not tell the two passes apart")
	var lifted: Dictionary = lift.run_init_map()
	h.check("world.the_elevator_ran", DictRead.as_bool(lifted["ok"]),
		str(lifted.get("abort", "")))
	h.equal("world.the_elevator_rebuilds_for_the_rider",
		DictRead.as_int(lift.unit_view(1)["visibility"]), Visibility.FULL,
		"the alien is the rider, so the pass ran for player 255 and its own "
		+ "unit is FULL -- a pass for player 0 leaves it a blip")

	# An empty elevator tile: the same command, one field away from anybody.
	var empty: World = _wired_world()
	_wall_column(empty, 4)
	h.check("world.the_empty_elevator_script_attached",
		empty.attach_script(_elevator_program(4, 5)),
		"the one-command program did not load")
	var untouched: Dictionary = empty.run_init_map()
	h.check("world.the_empty_elevator_ran", DictRead.as_bool(untouched["ok"]),
		str(untouched.get("abort", "")))
	h.equal("world.an_empty_elevator_rebuilds_nothing",
		DictRead.as_int(empty.unit_view(1)["visibility"]), Visibility.HIDDEN,
		"the alien is authored hidden and no pass ran, so it is still hidden: "
		+ "nothing stands on the elevator tile, and `je 0x004128FD` is taken")

	# **The first hand-over builds for a literal player 0, in a campaign
	# only.** `aNextPlayerHandling` (`0x0047DCA7`..`0x0047DCD4`) is a one-shot
	# behind `0x005229D0`; the mode getter is `0x0043B740` and the comparison
	# is against 1. A network session reaches the same code and skips the call.
	var opening: World = _wired_world()
	opening.turn.mode = TurnState.MODE_CAMPAIGN
	opening._first_hand_over()
	h.equal("world.the_first_hand_over_builds_for_player_zero",
		DictRead.as_int(opening.unit_view(1)["visibility"]), Visibility.FULL,
		"push 0 at 0x0047DCCD, before the rotation and before the refresh")
	var again: int = DictRead.as_int(opening.unit_view(1)["visibility"])
	opening.state.set_unit(opening.state.index_of(6, 2), MapState.NO_UNIT)
	opening._first_hand_over()
	h.equal("world.the_first_hand_over_is_a_one_shot",
		DictRead.as_int(opening.unit_view(1)["visibility"]), again,
		"0x005229D0 is set on the first run and tested on every one")
	var networked: World = _wired_world()
	networked.turn.mode = TurnState.MODE_NET
	networked._first_hand_over()
	h.equal("world.a_network_session_skips_it",
		DictRead.as_int(networked.unit_view(1)["visibility"]),
		Visibility.HIDDEN,
		"`cmp eax, ebx` at 0x0047DCC9 with ebx == 1")
	# The reset the one-shot runs first, which is **not** guarded by the mode:
	# `0x0043B770`'s last store is `mov byte [eax+0x1c], bl` at `0x0043B78C`,
	# and with the pointer at `record + 8` that is the hero counter's `+0x24`.
	var carried: World = _wired_world()
	carried.turn.mode = TurnState.MODE_NET
	carried.turn.hero_killed = PackedInt32Array([0, 2, 0, 0])
	carried._first_hand_over()
	h.equal("world.the_one_shot_clears_the_hero_counter",
		carried.turn.hero_killed, PackedInt32Array([0, 0, 0, 0]),
		"the reset runs before the mode test, so a network session gets it "
		+ "too")


## A blocking column: every cell of one map column raised well above any unit,
## which is what [LineOfSight] traces against. A single cell is not enough --
## the fixture has two player-0 units and a diagonal ray goes round one wall.
static func _wall_column(world: World, x: int) -> void:
	for y: int in range(9):
		var at: int = world.state.index_of(x, y)
		world.state.set_field_type(at, Interact.FIELD_TYPE_WALL)
		world.state.set_height(at, 20000)


## One numeric argument in the shape [method LclProgram.from_document] reads:
## a bare int contributes to no array at all, which is how a program with the
## wrong argument shape can still run and do nothing.
static func _num(value: int) -> Dictionary:
	return {"kind": "number", "raw": str(value), "value": value}


## A variable argument -- `_A` is slot 0 (docs/20 section 4).
static func _var(slot: int) -> Dictionary:
	return {"kind": "var", "slot_index": slot}


static func _instr(kind: String, name: String, args: Array,
		op: String = ">") -> Dictionary:
	return {"kind": kind, "name": name, "line": 1, "op": op, "args": args}


## The interpreter's own top-level test: `PUSHABLE_TYPES`'s first id, given a
## type row so [method World.create] accepts a unit of it.
const PUSHABLE_CRATE_TYPE: int = 30


## A program of `body` followed by `[END]` -- a `:Use` section with no label,
## since the environment is what selects the arms and a `Goto` is not needed.
static func _use_program(body: Array) -> Dictionary:
	var instructions: Array = body.duplicate()
	instructions.append(_instr("end", "", []))
	return {
		"schema": LclProgram.SCHEMA,
		"source": {"mission": "synthetic"},
		"header_line": 1,
		"instructions": instructions,
		"labels": {},
	}


## A one-command `Elevator (x, y, 0, 1)` program.
static func _elevator_program(x: int, y: int) -> Dictionary:
	return {
		"schema": LclProgram.SCHEMA,
		"source": {"mission": "synthetic"},
		"header_line": 1,
		"instructions": [
			{"kind": "command", "name": "Elevator", "line": 1, "op": ">",
				"args": [_num(x), _num(y), _num(0), _num(1)]},
			{"kind": "end", "name": "", "line": 1, "op": ">", "args": []},
		],
		"labels": {},
	}


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


## docs/21 section 5's `special` 9 -- `0x0046F210` `case 4`, the one arm of the
## effect dispatcher that rewrites the roster.
##
## The oracle is the listing, not a capture: `aPlayFightAnimation` runs after
## `aAttackUnit` returns, so a `dbgcall` capture of `aAttackUnit` alone can
## never contain this and the native suite is not where it belongs. No shipped
## slice mission carries the one type that has it (`Squee'Coo`, 57), which is
## why the scene is synthetic.
func _the_hatch(h: TestHarness) -> void:
	var carrier_type: int = 57
	var types: UnitTypeTable = UnitTypeTable.from_rows([
		{"id": 0, "mp_max": 4, "fp_max": 0, "hp_max": 20, "special": 0,
			"size": 0, "species": 0, "height": 20, "model": "",
			"description": "soldier"},
		{"id": carrier_type, "mp_max": 4, "fp_max": 255, "hp_max": 10,
			"special": Combat.SPECIAL_HATCH, "size": 0, "species": 1,
			"height": 20, "model": "", "description": "carrier"},
		{"id": Combat.HATCH_TYPE, "mp_max": 4, "fp_max": 255, "hp_max": 4,
			"special": 0, "size": 0, "species": 1, "height": 20, "model": "",
			"description": "hatchling"},
	])
	# Two rows that differ only in the `type` column the arm tests.
	var hits: int = 7
	var misses: int = 8
	var weapons: WeaponTable = WeaponTable.from_rows([
		{"id": hits, "heat": 255, "toggle": hits, "mun": 255, "hit": 100,
			"damage": 100, "range_min": 1, "range_max": 30, "type": 1,
			"special": 0, "def_mode": 0, "mun_per_fight": 1},
		{"id": misses, "heat": 255, "toggle": misses, "mun": 255, "hit": 100,
			"damage": 100, "range_min": 1, "range_max": 30, "type": 3,
			"special": 0, "def_mode": 0, "mun_per_fight": 1},
	])

	# --- the three gates, called directly ---------------------------------
	var gate: Scene = _scene()
	gate.types = types
	gate.weapons = weapons
	var gunner: UnitState = _place(gate, 0, 0, 1, 1, 3)
	gunner.weapon = hits
	var frail: UnitState = _place(gate, 1, UnitState.PLAYER_ALIEN, 3, 1, 0,
		carrier_type)
	frail.hp = Combat.HATCH_HP_LIMIT
	frail.group = 9
	# A value no fog pass writes, so "it was rebuilt" is not a guess about the
	# geometry of a synthetic scene: a rebuild for player 0 always ends with
	# player 0's own units at [constant Visibility.FULL].
	gunner.visibility = 7
	var healthy: Scene = _scene()
	healthy.types = types
	healthy.weapons = weapons
	var healthy_gunner: UnitState = _place(healthy, 0, 0, 1, 1, 3)
	healthy_gunner.weapon = hits
	var sturdy: UnitState = _place(healthy, 1, UnitState.PLAYER_ALIEN, 3, 1, 0,
		carrier_type)
	sturdy.hp = Combat.HATCH_HP_LIMIT + 1
	h.equal("hatch.six_hit_points_is_one_too_many",
		Combat.hatch(healthy.state, healthy.units, types, weapons, sturdy,
			healthy_gunner, 1, 1, _turn()), -1,
		"`cmp byte [esi+0x16], 5` then `ja` at 0x0046F286")

	var wrong: Scene = _scene()
	wrong.types = types
	wrong.weapons = weapons
	var wrong_gunner: UnitState = _place(wrong, 0, 0, 1, 1, 3)
	wrong_gunner.weapon = misses
	var wrong_target: UnitState = _place(wrong, 1, UnitState.PLAYER_ALIEN, 3,
		1, 0, carrier_type)
	wrong_target.hp = 1
	h.equal("hatch.the_weapon_type_must_be_one_two_or_four",
		Combat.hatch(wrong.state, wrong.units, types, weapons, wrong_target,
			wrong_gunner, 1, 1, _turn()), -1,
		"the two rows differ only in `type`; 3 is not in {1, 2, 4}")

	# --- the arm itself ---------------------------------------------------
	var made: int = Combat.hatch(gate.state, gate.units, types, weapons, frail,
		gunner, 1, 1, _turn())
	h.check("hatch.it_fired", made >= 0, "hatch returned %d" % made)
	var born: UnitState = gate.units[made]
	h.equal("hatch.the_replacement_is_a_neutral_of_the_named_type",
		[born.type_id, born.player, born.x, born.y],
		[Combat.HATCH_TYPE, UnitState.PLAYER_ALIEN, 3, 1],
		"`push 0x36` and `push 0xff` at 0x0046F338, on the carrier's own cell")
	h.equal("hatch.the_ai_group_is_inherited", born.group, 9,
		"`mov byte [eax+0x4e], bl` at 0x0046F39A")
	h.equal("hatch.the_carrier_is_removed_not_killed",
		[frail.hp, gate.state.unit_at(gate.state.index_of(3, 1))],
		[0, born.slot],
		"aRemoveUnitElement frees the record and the cell takes the new one")
	h.equal("hatch.the_fog_was_rebuilt_for_good", gunner.visibility,
		Visibility.FULL,
		"aBuildVisibleMap(aGetCurrentPlayer()) at 0x0046F3A8, outside the "
		+ "save/restore bracket, so the sentinel cannot survive it")

	# --- through the resolver: hit hatches, killed does not ----------------
	var shot: Scene = _scene()
	shot.types = types
	shot.weapons = weapons
	var shooter: UnitState = _place(shot, 0, 0, 1, 1, 3)
	shooter.weapon = hits
	var shielded: UnitState = _place(shot, 1, UnitState.PLAYER_ALIEN, 3, 1, 0,
		carrier_type)
	shielded.hp = Combat.HATCH_HP_LIMIT
	# A Damage Absorber charge nullifies the damage, so the outcome is a hit
	# and never a kill -- which is the marker the sweep keys on. The charge
	# counts only behind the equipment (`0x00475590`).
	shielded.absorber = 1
	shielded.equipment = PackedInt32Array([Combat.EQUIP_DAMAGE_ABSORBER])
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	var landed: AttackResult = Combat.attack(shot.state, shot.units, types,
		weapons, 1, 1, 3, 1, 1, 1, 1, _turn(), rng)
	var hatched: Array[int] = []
	for outcome: Dictionary in landed.outcomes:
		if outcome.has("hatched"):
			hatched.append(DictRead.as_int(outcome["hatched"]))
	h.equal("hatch.a_hit_runs_the_sweep", hatched.size(), 1,
		"%d outcome(s): %s" % [landed.outcomes.size(), landed.outcomes])

	var lethal: Scene = _scene()
	lethal.types = types
	lethal.weapons = weapons
	var killer: UnitState = _place(lethal, 0, 0, 1, 1, 3)
	killer.weapon = hits
	var doomed: UnitState = _place(lethal, 1, UnitState.PLAYER_ALIEN, 3, 1, 0,
		carrier_type)
	doomed.hp = 1
	rng.randomize_seed(1.0)
	var killed: AttackResult = Combat.attack(lethal.state, lethal.units, types,
		weapons, 1, 1, 3, 1, 1, 1, 1, _turn(), rng)
	var any_hatched: bool = false
	var markers: Array[int] = []
	for outcome: Dictionary in killed.outcomes:
		markers.append(DictRead.as_int(outcome["marker"]))
		any_hatched = any_hatched or outcome.has("hatched")
	h.equal("hatch.a_kill_does_not", [markers, any_hatched],
		[[Combat.MARKER_KILLED], false],
		"0x0040BD70 sweeps cells marked 0x5C, and a kill writes 0x5D")

	# **The gate is the marker and not "the target survived".**  A shielded
	# cell resolves to `0x5B` with the carrier untouched at five hit points, so
	# a sweep that keyed on anything but `0x5C` would hatch it.
	var shielded_cell: Scene = _scene()
	shielded_cell.types = types
	shielded_cell.weapons = weapons
	var blocked_gunner: UnitState = _place(shielded_cell, 0, 0, 1, 1, 3)
	blocked_gunner.weapon = hits
	var safe: UnitState = _place(shielded_cell, 1, UnitState.PLAYER_ALIEN, 3,
		1, 0, carrier_type)
	safe.hp = Combat.HATCH_HP_LIMIT
	shielded_cell.state.set_obstacle(shielded_cell.state.index_of(3, 1),
		Combat.EFFECT_SHIELDED)
	rng.randomize_seed(1.0)
	var resolved: AttackResult = Combat.attack(shielded_cell.state,
		shielded_cell.units, types, weapons, 1, 1, 3, 1, 1, 1, 1, _turn(), rng)
	var resolved_markers: Array[int] = []
	var resolved_hatched: bool = false
	for outcome: Dictionary in resolved.outcomes:
		resolved_markers.append(DictRead.as_int(outcome["marker"]))
		resolved_hatched = resolved_hatched or outcome.has("hatched")
	h.equal("hatch.only_a_hit_marker_runs_it",
		[resolved_markers, resolved_hatched, safe.hp],
		[[Combat.MARKER_RESOLVED], false, Combat.HATCH_HP_LIMIT],
		"a shield writes 0x5B and the sweep only reads 0x5C")


## `aRemoveUnitElement`'s hero counter -- docs/22 section 9.5.
##
## The oracle is the listing: twelve bytes at `0x00477A34`..`0x00477A5E` plus
## the predicate at `0x004409E0`, all pinned by `combat_tables.py`'s
## `hero.counter`. It cannot be a native case either, for the same reason the
## hatch cannot: nothing `dbgcall` captures reads the player record.
func _the_hero_counter(h: TestHarness) -> void:
	var types: UnitTypeTable = _types()
	var weapons: WeaponTable = _weapons()

	# A hero killed by the resolver, on a turn that has started.
	var field: Scene = _scene()
	field.types = types
	field.weapons = weapons
	var shooter: UnitState = _place(field, 0, 0, 1, 1, 3)
	shooter.weapon = REACTION_WEAPON
	var hero: UnitState = _place(field, 1, 2, 3, 1, 0)
	hero.hp = 1
	hero.pool_flag = UnitState.HERO_POOL_FLAG
	var live: TurnState = _turn()
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	var shot: AttackResult = Combat.attack(field.state, field.units, types,
		weapons, 1, 1, 3, 1, 1, 1, 1, live, rng)
	h.equal("hero.a_kill_counts_it",
		[hero.is_alive(), live.hero_killed],
		[false, PackedInt32Array([0, 0, 1, 0])],
		"`inc cl` at 0x00477A5C, into player 2's own record; %s"
			% [shot.outcomes])

	# The other three counters of the same record, which fire on the same kill:
	# `0x0043B810` credits the shooter's `+0x00`, `0x0043B860` charges the
	# victim's `+0x10`, and `0x0043B8D0` charges the victim's `+0x08` from
	# **every** death path rather than only from a kill.
	h.equal("scoreboard.a_kill_counts_three_ways",
		[live.mission_kills, live.mission_lost, live.mission_lost_to_enemy],
		[PackedInt32Array([1, 0, 0, 0]), PackedInt32Array([0, 0, 1, 0]),
		PackedInt32Array([0, 0, 1, 0])],
		"the shooter is player 0 and the hero player 2")

	# Friendly fire is a loss and **not** a kill: `0x0046BF7C`'s `cmp dl, al`
	# skips both `0x0043B860` and `0x0043B810` when the players match.
	var own: Scene = _scene()
	own.types = types
	own.weapons = weapons
	var friend: UnitState = _place(own, 0, 0, 1, 1, 3)
	friend.weapon = REACTION_WEAPON
	var comrade: UnitState = _place(own, 1, 0, 3, 1, 0)
	comrade.hp = 1
	var friendly: TurnState = _turn()
	var own_rng: IncRandom = IncRandom.new()
	own_rng.randomize_seed(1.0)
	var _own_shot: AttackResult = Combat.attack(own.state, own.units, types,
		weapons, 1, 1, 3, 1, 1, 1, 1, friendly, own_rng)
	h.equal("scoreboard.friendly_fire_is_a_loss_not_a_kill",
		[comrade.is_alive(), friendly.mission_kills, friendly.mission_lost,
		friendly.mission_lost_to_enemy],
		[false, PackedInt32Array([0, 0, 0, 0]), PackedInt32Array([1, 0, 0, 0]),
		PackedInt32Array([0, 0, 0, 0])],
		"0x0043B8D0 fires either way; the other two do not")

	# The same shot against a unit whose `+0x4D` is one short of the bound.
	var plain: Scene = _scene()
	plain.types = types
	plain.weapons = weapons
	var gunner: UnitState = _place(plain, 0, 0, 1, 1, 3)
	gunner.weapon = REACTION_WEAPON
	var trooper: UnitState = _place(plain, 1, 2, 3, 1, 0)
	trooper.hp = 1
	trooper.pool_flag = UnitState.HERO_POOL_FLAG - 1
	var ordinary: TurnState = _turn()
	rng.randomize_seed(1.0)
	Combat.attack(plain.state, plain.units, types, weapons, 1, 1, 3, 1, 1, 1,
		1, ordinary, rng)
	h.equal("hero.a_unit_pool_candidate_is_not_a_hero",
		[trooper.is_alive(), ordinary.hero_killed],
		[false, PackedInt32Array([0, 0, 0, 0])],
		"`cmp al, 2` then `jb` at 0x00477A3B is a bound, not an equality")

	# Turn zero: the gate the whole block hangs on.
	var setup: Scene = _scene()
	setup.types = types
	setup.weapons = weapons
	var early_gunner: UnitState = _place(setup, 0, 0, 1, 1, 3)
	early_gunner.weapon = REACTION_WEAPON
	var early_hero: UnitState = _place(setup, 1, 2, 3, 1, 0)
	early_hero.hp = 1
	early_hero.pool_flag = UnitState.HERO_POOL_FLAG
	var unstarted: TurnState = _turn(0, 0)
	rng.randomize_seed(1.0)
	Combat.attack(setup.state, setup.units, types, weapons, 1, 1, 3, 1, 1, 1,
		1, unstarted, rng)
	h.equal("hero.turn_zero_does_not_count",
		[early_hero.is_alive(), unstarted.hero_killed],
		[false, PackedInt32Array([0, 0, 0, 0])],
		"`test al, al` / `jbe` at 0x00477A44 reads the turn counter")

	# The counter is one byte. 256 removals bring it back to zero, which is the
	# only way `HeroKilled` can answer false after a hero has died.
	var wrap: TurnState = _turn()
	wrap.hero_killed[0] = UnitState.HERO_COUNT_WRAP - 1
	var last: Scene = _scene()
	last.types = types
	var doomed: UnitState = _place(last, 0, 0, 2, 2, 0)
	doomed.pool_flag = UnitState.HERO_POOL_FLAG
	h.equal("hero.the_counter_is_a_byte",
		[UnitState.remove(last.state, last.types, wrap, doomed),
			wrap.hero_killed[0]],
		[true, 0],
		"`mov cl, [eax+0x24]; inc cl; mov [eax], cl` is byte-wide")

	# `0x00477ABD` -- the routine's own last instruction, `mov byte
	# [esi+0x16], 0`. Removal kills, which is the whole of a ground fire's
	# lethality (`aPlayGroundFireAnimation` is the one of its twenty call
	# sites that arrives without a damage call first).
	var alive_turn: TurnState = _turn()
	var burnt_scene: Scene = _scene()
	burnt_scene.types = types
	var burnt: UnitState = _place(burnt_scene, 0, 0, 3, 3, 0)
	var before_hp: int = burnt.hp
	var _c: bool = UnitState.remove(burnt_scene.state, burnt_scene.types,
		alive_turn, burnt)
	h.equal("hero.removal_zeroes_the_hit_points",
		[before_hp > 0, burnt.hp, burnt.is_alive(),
			burnt_scene.state.unit_at(burnt_scene.state.index_of(3, 3))],
		[true, 0, false, MapState.NO_UNIT],
		"0x00477ABD is the last thing aRemoveUnitElement does")

	# The hatch removes its carrier through the same routine.
	var carrier_type: int = 57
	var brood: UnitTypeTable = UnitTypeTable.from_rows([
		{"id": 0, "mp_max": 4, "fp_max": 0, "hp_max": 20, "special": 0,
			"size": 0, "species": 0, "height": 20, "model": "",
			"description": "soldier"},
		{"id": carrier_type, "mp_max": 4, "fp_max": 255, "hp_max": 10,
			"special": Combat.SPECIAL_HATCH, "size": 0, "species": 1,
			"height": 20, "model": "", "description": "carrier"},
		{"id": Combat.HATCH_TYPE, "mp_max": 4, "fp_max": 255, "hp_max": 4,
			"special": 0, "size": 0, "species": 1, "height": 20, "model": "",
			"description": "hatchling"},
	])
	var hatch_weapon: int = 7
	var brood_weapons: WeaponTable = WeaponTable.from_rows([
		{"id": hatch_weapon, "heat": 255, "toggle": hatch_weapon, "mun": 255,
			"hit": 100, "damage": 100, "range_min": 1, "range_max": 30,
			"type": 1, "special": 0, "def_mode": 0, "mun_per_fight": 1},
	])
	var nest: Scene = _scene()
	nest.types = brood
	nest.weapons = brood_weapons
	var hunter: UnitState = _place(nest, 0, 0, 1, 1, 3)
	hunter.weapon = hatch_weapon
	var host: UnitState = _place(nest, 1, 3, 3, 1, 0, carrier_type)
	host.hp = Combat.HATCH_HP_LIMIT
	host.pool_flag = UnitState.HERO_POOL_FLAG
	var hatching: TurnState = _turn()
	h.check("hero.the_hatch_removes_through_the_same_routine",
		Combat.hatch(nest.state, nest.units, brood, brood_weapons, host,
			hunter, 1, 1, hatching) >= 0
			and hatching.hero_killed == PackedInt32Array([0, 0, 0, 1]),
		"0x0046F2FB is aRemoveUnitElement, so its counter runs too: %s"
			% [hatching.hero_killed])

	# And a script kill: `KillUnit`, the barrier and the fixed statue all go
	# through [method LclContext.kill], which is what makes `HeroKilled` a
	# predicate a mission can actually see move.
	var scripted: Scene = _scene()
	scripted.types = types
	var victim: UnitState = _place(scripted, 0, 1, 2, 2, 0)
	victim.pool_flag = UnitState.HERO_POOL_FLAG
	var script_turn: TurnState = _turn()
	var context: LclContext = LclContext.create(scripted.state, scripted.units,
		types, script_turn, GameControl.create(), IncRandom.new(),
		CRandom.new(), 0, "")
	var before: PackedInt32Array = script_turn.hero_killed.duplicate()
	context.kill(victim)
	h.equal("hero.a_script_kill_counts_too",
		[before, script_turn.hero_killed, victim.is_alive()],
		[PackedInt32Array([0, 0, 0, 0]), PackedInt32Array([0, 1, 0, 0]),
			false],
		"docs/20 section 7.4's HeroKilled reads the byte 0x00477A5E writes")


## The two reveals inside `aAttackUnit` and the one inside `aExecuteBomb`:
## the shooter once its weapon is cleared to fire (`0x0046B643`), and every
## unit on a marked cell before its roll (`0x0046BA22`, `0x004703A9`) --
## hit or miss, so a hidden shooter is seen firing and a hidden target is
## seen being shot at.
func _reveals(h: TestHarness) -> void:
	var scene: Scene = _scene()
	var shooter: UnitState = _place(scene, 0, 0, 1, 1, 0)
	var target: UnitState = _place(scene, 1, UnitState.PLAYER_ALIEN, 5, 1, 0)
	shooter.visibility = Visibility.HIDDEN
	target.visibility = Visibility.HIDDEN
	var rng: IncRandom = IncRandom.new()
	var shot: AttackResult = Combat.attack(scene.state, scene.units,
		scene.types, scene.weapons, 1, 1, 5, 1, 1, 1, 1, _turn(), rng)
	h.check("reveal.the_shot_was_fired", shot.fired, shot.reason)
	h.equal("reveal.the_shooter_is_seen_firing", shooter.visibility,
		Visibility.FULL, "0x0046B643, after the jam test")
	h.equal("reveal.the_target_is_seen_shot_at", target.visibility,
		Visibility.FULL, "0x0046BA22, before the roll")

	# A jammed weapon never reaches the reveal.
	var jammed: Scene = _scene()
	var stuck: UnitState = _place(jammed, 0, 0, 1, 1, 0)
	stuck.visibility = Visibility.HIDDEN
	stuck.malfunction = 2
	var _victim: UnitState = _place(jammed, 1, UnitState.PLAYER_ALIEN, 5, 1, 0)
	var refused: AttackResult = Combat.attack(jammed.state, jammed.units,
		jammed.types, jammed.weapons, 1, 1, 5, 1, 1, 1, 1, _turn(), rng)
	h.check("reveal.a_jam_fires_nothing", not refused.fired)
	h.equal("reveal.a_jam_reveals_nothing", stuck.visibility,
		Visibility.HIDDEN)

	# The bomb reveals what it lands on.
	var field: Scene = _scene()
	var bystander: UnitState = _place(field, 0, UnitState.PLAYER_ALIEN, 3, 3, 0)
	bystander.visibility = Visibility.HIDDEN
	var _blast: AttackResult = Interact.execute_bomb(field.state, field.units,
		field.types, field.weapons, 3, 3, 1, 1, 1, _turn(), rng)
	h.equal("reveal.a_bomb_reveals_its_target", bystander.visibility,
		Visibility.FULL, "0x004703A9")


# --- docs/22 sections 7.3 and 7.5: weapon 47 and the absorber's gate --------

## Every claim here is one `tools/turn_gold.py` measured in its `reveal` and
## `conversion` phases; the synthetic scenes keep `core/` on the same rules.
func _conversion_and_absorber(h: TestHarness) -> void:
	# Weapon 47 fires at its heat cap. A first draw of 0..10 damages the
	# weapon (type 3 is a damaging type) and nothing fires: seed 1.0's first
	# `aRandom(0, 40)` is 1.
	var jam: Scene = _scene()
	var hot: UnitState = _place(jam, 0, 0, 1, 1, 0)
	hot.weapon = Combat.CONVERTER_WEAPON
	var _mark: UnitState = _place(jam, 1, UnitState.PLAYER_ALIEN, 3, 1, 0)
	var seed_rng: IncRandom = IncRandom.new()
	seed_rng.randomize_seed(1.0)
	var refused: AttackResult = Combat.attack(jam.state, jam.units, jam.types,
		jam.weapons, 1, 1, 3, 1, 0, 1, 1, _turn(), seed_rng)
	h.check("convert.weapon_47_fires_at_its_cap",
		not refused.fired and hot.heat == 4 and hot.malfunction == 5,
		"0x0046B5DF sets +0x3E to maxHeat first; heat %d, malfunction %d"
			% [hot.heat, hot.malfunction])

	# A seed that clears the overheat roll and connects: searched, as the
	# native probe's was. The hit converts the target -- player, points,
	# action state -- and the converted unit looks around for its new side,
	# revealing the alien it now counts as an enemy.
	var converted: bool = false
	for seed: int in range(2, 200):
		var scene: Scene = _scene()
		var shooter: UnitState = _place(scene, 0, 0, 1, 1, 0)
		shooter.weapon = Combat.CONVERTER_WEAPON
		var target: UnitState = _place(scene, 1, UnitState.PLAYER_ALIEN, 3, 1, 0)
		target.action_state = 5
		target.mp = 0
		var watched: UnitState = _place(scene, 2, UnitState.PLAYER_ALIEN, 6, 1, 0)
		watched.visibility = Visibility.HIDDEN
		var rng: IncRandom = IncRandom.new()
		rng.randomize_seed(float(seed))
		var shot: AttackResult = Combat.attack(scene.state, scene.units,
			scene.types, scene.weapons, 1, 1, 3, 1, 0, 1, 1, _turn(), rng)
		var flagged: bool = false
		for outcome: Dictionary in shot.outcomes:
			if outcome.get("converted", false):
				flagged = true
		if not flagged:
			continue
		converted = true
		h.equal("convert.the_target_changes_sides", target.player, 0,
			"+0x45 becomes the shooter's at 0x0046BDCB")
		# `aGetMovePoints` is asked **before** `+0x41` is cleared
		# (`0x0046BDCE` then `0x0046BDE7`), and a stunned unit's allowance
		# is nothing -- so a convert that was stunned keeps no points this
		# turn, and only a later refresh gives it any.
		h.equal("convert.its_points_are_asked_before_the_state_clears",
			target.mp, 0, "stunned when asked, so aGetMovePoints said 0")
		h.equal("convert.its_action_state_is_cleared", target.action_state, 0)
		h.equal("convert.it_looks_around_for_its_new_side", watched.visibility,
			Visibility.FULL, "0x0046BDEB, the writing pass from its own cell")
		h.check("convert.the_target_still_lost_its_hit_points",
			target.hp < 1000, "damage landed before the arm: hp %d" % target.hp)
		break
	h.check("convert.a_seed_below_200_converts", converted,
		"the overheat roll and the hit roll both have to come out right")

	# The absorber's gate: `0x00475590` reads the charges behind equipment
	# slot 18. Charges without the equipment are ignored; with it, one is
	# spent, the damage is zeroed **and still rolled** -- the same draws as a
	# landed hit, which is what the native seed showed.
	var stale: Scene = _scene()
	var _gunner: UnitState = _place(stale, 0, 0, 1, 1, 0)
	var unflagged: UnitState = _place(stale, 1, UnitState.PLAYER_ALIEN, 3, 1, 0)
	unflagged.absorber = 5
	var stale_rng: IncRandom = IncRandom.new()
	stale_rng.randomize_seed(1.0)
	var _ignored: AttackResult = Combat.attack(stale.state, stale.units,
		stale.types, stale.weapons, 1, 1, 3, 1, 0, 1, 1, _turn(), stale_rng)
	h.check("absorber.charges_without_the_equipment_are_ignored",
		unflagged.hp < 1000 and unflagged.absorber == 5,
		"hp %d, charges %d: _C_119's six stale records absorb nothing"
			% [unflagged.hp, unflagged.absorber])

	var carried: Scene = _scene()
	var _shooter2: UnitState = _place(carried, 0, 0, 1, 1, 0)
	var flagged_unit: UnitState = _place(carried, 1, UnitState.PLAYER_ALIEN, 3, 1, 0)
	flagged_unit.absorber = 5
	flagged_unit.equipment = PackedInt32Array([Combat.EQUIP_DAMAGE_ABSORBER])
	var carried_rng: IncRandom = IncRandom.new()
	carried_rng.randomize_seed(1.0)
	var _spent: AttackResult = Combat.attack(carried.state, carried.units,
		carried.types, carried.weapons, 1, 1, 3, 1, 0, 1, 1, _turn(),
		carried_rng)
	h.check("absorber.a_carried_charge_is_spent_and_nullifies",
		flagged_unit.hp == 1000 and flagged_unit.absorber == 4,
		"hp %d, charges %d" % [flagged_unit.hp, flagged_unit.absorber])
	h.check("absorber.a_spent_charge_still_rolls_the_damage",
		absf(carried_rng.seed - stale_rng.seed) < 0.5,
		"xor ebp, ebp at 0x0046BD83 and applyDamage at 0x0046BD9D: the same "
		+ "draws as the landed hit, %f against %f"
			% [carried_rng.seed, stale_rng.seed])

	# The bomb never asks: `aExecuteBomb` reaches `applyDamage` straight from
	# its roll, with the heading 0xFF no arc holds.
	var minefield: Scene = _scene()
	var victim: UnitState = _place(minefield, 0, UnitState.PLAYER_ALIEN, 3, 3, 0)
	victim.absorber = 5
	victim.equipment = PackedInt32Array([Combat.EQUIP_DAMAGE_ABSORBER])
	var mine_rng: IncRandom = IncRandom.new()
	mine_rng.randomize_seed(1.0)
	var _blast2: AttackResult = Interact.execute_bomb(minefield.state,
		minefield.units, minefield.types, minefield.weapons, 3, 3, 0, 1, 1,
		_turn(), mine_rng)
	h.check("absorber.a_mine_ignores_the_absorber",
		victim.hp < 1000 and victim.absorber == 5,
		"hp %d, charges %d: no 0x00475590 call in 0x004702C0"
			% [victim.hp, victim.absorber])

	# The contact promotion is the per-unit pass's own (0x00479786..0x00479861
	# inside 0x004794B0): one observer's pass promotes a hidden neutral it
	# cannot see, with no whole-map rebuild involved.
	var walled: Scene = _scene()
	var observer: UnitState = _place(walled, 0, 0, 1, 1, 0)
	var behind: UnitState = _place(walled, 1, UnitState.PLAYER_ALIEN, 6, 1, 0)
	behind.visibility = Visibility.HIDDEN
	walled.state.set_height(walled.state.index_of(3, 1), 20000)
	var saw: bool = Visibility.look_from(walled.state, walled.units,
		walled.types, observer, 1, 1, 1, 1)
	h.check("promotion.is_inside_the_per_unit_pass",
		not saw and behind.visibility == Visibility.CONTACT,
		"hidden behind the wall, promoted to a lone contact by one pass")


## docs/97 section 34 -- the per-command fog probe: it restores what it saw
## and leaves the groups it woke woken, unless the flag asks for the quiet
## probe this remake used to have.
func _fog_probe(h: TestHarness) -> void:
	# The wake is the computer's own: `unit.player == PLAYER_ALIEN` guards it.
	var alien: Dictionary = TestFixtures.unit(1, 4, 2, 0,
		UnitState.PLAYER_ALIEN)
	alien["order"] = Visibility.ALERTING_ORDERS[0]
	alien["order2"] = 9
	alien["order2_param"] = 7
	alien["group"] = 3
	var world: World = World.create(TestFixtures.map_document(7, 7,
		[TestFixtures.unit(0, 2, 2), alien]), TestFixtures.balance(), 1.0)
	var seen: Dictionary[int, int] = world.display_visibility()
	h.check("probe.the_query_sees_the_alien",
		DictRead.as_int(seen.get(1, Visibility.HIDDEN)) != Visibility.HIDDEN,
		"an alien two fields away on flat ground")
	var woken: int = world.probe_fog()
	h.check("probe.wakes_the_group", woken >= 1
		and DictRead.as_int(world.unit_view(1)["order"]) == 9,
		"%d unit(s) promoted" % woken)
	h.equal("probe.restores_the_visibility_byte",
		DictRead.as_int(world.unit_view(1)["visibility"]), 0,
		"the byte the fixture placed it with, put back by the probe")
	# A blip is not a sight: an alien the observer only scans keeps its
	# order, because the wake is the pass's own line-of-sight arm and not a
	# rule about the byte the pass left behind.
	var scanner: Dictionary = TestFixtures.unit(0, 2, 2, 0, 0, 4, 0,
		[Visibility.EQUIP_SCAN_MODULE])
	var far: Dictionary = TestFixtures.unit(1, 2, 6, 0, UnitState.PLAYER_ALIEN)
	far["order"] = Visibility.ALERTING_ORDERS[0]
	far["order2"] = 9
	far["group"] = 3
	var blip_world: World = World.create(TestFixtures.map_document(7, 7,
		[scanner, far]), TestFixtures.balance(), 1.0)
	var wall: int = blip_world.state.index_of(2, 4)
	blip_world.state.set_field_type(wall, Interact.FIELD_TYPE_WALL)
	blip_world.state.set_height(wall, 32000)
	var blip_seen: Dictionary[int, int] = blip_world.display_visibility()
	var _woke: int = blip_world.probe_fog()
	h.check("probe.a_blip_is_not_a_sight",
		DictRead.as_int(blip_seen.get(1, Visibility.HIDDEN))
			== Visibility.HIDDEN
		or DictRead.as_int(blip_world.unit_view(1)["order"])
			== Visibility.ALERTING_ORDERS[0],
		"a unit the pass marks without a line of sight wakes nobody")

	var flagged: World = World.create(TestFixtures.map_document(7, 7,
		[TestFixtures.unit(0, 2, 2), alien]), TestFixtures.balance(), 1.0)
	flagged.compat_flags = PackedStringArray([World.COMPAT_FOG_PROBE_QUIET])
	h.equal("probe.the_flag_makes_it_quiet", flagged.probe_fog(), 0)
	h.equal("probe.the_flag_leaves_the_order",
		DictRead.as_int(flagged.unit_view(1)["order"]),
		Visibility.ALERTING_ORDERS[0])
