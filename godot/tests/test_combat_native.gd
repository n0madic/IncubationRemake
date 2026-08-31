extends TestSuite

## Oracle boundary: **native runtime**. `aGetHitProbability`, `aCheckLineOfSightEx`,
## `aBuildVisibleMap`, `aCheckWeaponDamage`, `aAttackUnit` and `aExecuteUse`
## called inside a running `Incubation.exe` on `_C_141`, re-expressed by
## `tools/turn_gold.py --emit-cases`.
##
## The third side of the diff, again: `test_combat.gd` checks `core/` against
## the rules, `tools/turn_gold.py --check` checks `inclib/combat.py` and
## `inclib/interact.py` against the engine, and this checks `core/` against the
## same engine bytes.
##
## Two sequencing rules are copied from the capture and must stay copied:
##
## * **the attack probes do not reload**, so each carries its own unit array and
##   is replayed from it;
## * **the use probes do not reload either**, so they are replayed in order
##   through one world -- the crowbar the class-39 probe grants is still there
##   for the ones after it.

const DEV_CASES: String = "res://generated/turn/turn.json"
const USER_CASES: String = "user://turn/turn.json"
const SCHEMA: String = "incubation.turn-cases/1"

## docs/22 section 7 -- how many mismatches a list-valued check prints before it
## stops. A failure that dumped 86 lines is a failure nobody reads.
const REPORT_LIMIT: int = 6


static func _path() -> String:
	if FileAccess.file_exists(DEV_CASES):
		return DEV_CASES
	return USER_CASES


## The resolver's [TurnState] argument. The capture compares markers, action
## points and the generator's seed; nothing in it reads the hero counter
## `aRemoveUnitElement` keeps, so only the two fields the resolver itself uses
## are set.
func _turn(mode: int) -> TurnState:
	var out: TurnState = TurnState.create()
	out.mode = mode
	out.turn = 1
	return out


func run(h: TestHarness) -> void:
	h.begin("combat_native", TestHarness.ORACLE_NATIVE)
	var path: String = _path()
	if not FileAccess.file_exists(path):
		h.check("fixture", false,
			"run tools/turn_gold.py --emit-cases tests/fixtures/turn/cases_turn.json")
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		h.check("fixture.parses", false, "not a JSON object")
		return
	var doc: Dictionary = parsed
	if DictRead.as_string(doc["schema"]) != SCHEMA:
		h.check("fixture.schema", false, DictRead.as_string(doc["schema"]))
		return
	var combat: Dictionary = DictRead.as_dict(doc["combat"])
	if combat.is_empty():
		h.check("combat.captured", false,
			"the capture holds no line-of-sight phase; re-run --game-copy")
		return
	var types: Dictionary = DictRead.as_dict(doc["types"])
	var ai_level: int = DictRead.as_int(doc["ai_level"])

	_hit_cases(h, combat, types)
	_fog_cases(h, combat, types)
	_overheat_cases(h, combat, types)
	_attack_cases(h, combat, types, ai_level)
	_use_cases(h, combat, types, ai_level)


## `aGetHitProbability` and `aCheckLineOfSightEx` over 86 ordered enemy pairs.
##
## The line-of-sight outcome compared is the routine's **out-parameter**, not
## its return value: EAX is a success flag that is 1 for a clear ray and 1 for
## a blocked one alike (docs/22 section 6.2).
func _hit_cases(h: TestHarness, combat: Dictionary,
		types: Dictionary) -> void:
	var built: Dictionary = MoveMapCaseRunner.build_combat_world(combat, types,
		DictRead.as_array(combat["units"]))
	var state: MapState = built["state"]
	var units: Dictionary = built["units"]
	var utab: UnitTypeTable = built["unit_types"]
	var wtab: WeaponTable = built["weapons"]
	var players: int = DictRead.as_int(combat["human_players"])
	var mode: int = DictRead.as_int(combat["game_mode"])
	var los_mode: int = DictRead.as_int(combat["los_mode"])
	var eye: Dictionary = DictRead.as_dict(combat["eye_heights"])
	var full: Dictionary = DictRead.as_dict(combat["full_heights"])

	var pairs: Array = DictRead.as_array(combat["hit"])
	h.check("hit.pairs", not pairs.is_empty(), "%d pair(s)" % pairs.size())
	var distance_bad: Array[String] = []
	var gate_bad: Array[String] = []
	var percent_bad: Array[String] = []
	var los_bad: Array[String] = []
	var height_bad: Array[String] = []
	var codes: Dictionary = {}
	for entry: Variant in pairs:
		var case: Dictionary = DictRead.as_dict(entry)
		var a: int = DictRead.as_int(case["a"])
		var b: int = DictRead.as_int(case["b"])
		var att: UnitState = units[a]
		var dfn: UnitState = units[b]
		var weapon: int = DictRead.as_int(case["weapon"])
		var got: HitChance = HitChance.compute(state, units, utab, wtab, att,
			dfn, weapon, true, players, mode)
		if got.distance != DictRead.as_int(case["distance"]):
			distance_bad.append("%d->%d: %d != %d"
				% [a, b, got.distance, DictRead.as_int(case["distance"])])
		if (1 if got.in_range else 0) != DictRead.as_int(case["in_range"]):
			gate_bad.append("%d->%d: %s" % [a, b, got.in_range])
		if got.percent != DictRead.as_int(case["percent"]):
			percent_bad.append("%d->%d: %d != %d"
				% [a, b, got.percent, DictRead.as_int(case["percent"])])

		# The two height helpers, against the engine's own answers.  They are
		# what the ray's endpoints are, so a wrong one moves every outcome
		# below by a whole body.
		var eye_want: int = DictRead.as_int(eye[str(a)])
		var full_want: int = DictRead.as_int(full[str(b)])
		if HitChance.eye_height(utab, att.type_id) != eye_want:
			height_bad.append("eye %d: %d != %d"
				% [a, HitChance.eye_height(utab, att.type_id), eye_want])
		if HitChance.full_height(utab, dfn.type_id) != full_want:
			height_bad.append("full %d: %d != %d"
				% [b, HitChance.full_height(utab, dfn.type_id), full_want])

		if case.has("los"):
			var ray: int = LineOfSight.check(state, units, utab, att.x, att.y,
				eye_want, dfn.x, dfn.y, full_want, los_mode, players, mode)
			codes[ray] = true
			if ray != DictRead.as_int(case["los"]):
				los_bad.append("%d->%d: %d != %d"
					% [a, b, ray, DictRead.as_int(case["los"])])
	h.check("hit.distance_matches_native", distance_bad.is_empty(),
		", ".join(distance_bad.slice(0, REPORT_LIMIT)))
	h.check("hit.range_gate_matches_native", gate_bad.is_empty(),
		", ".join(gate_bad.slice(0, REPORT_LIMIT)))
	h.check("hit.percent_matches_native", percent_bad.is_empty(),
		", ".join(percent_bad.slice(0, REPORT_LIMIT)))
	h.check("hit.heights_match_native", height_bad.is_empty(),
		", ".join(height_bad.slice(0, REPORT_LIMIT)))
	h.check("los.matches_native", los_bad.is_empty(),
		", ".join(los_bad.slice(0, REPORT_LIMIT)))
	# A capture in which every ray came back clear would agree with a model
	# that never blocked anything.
	h.check("los.more_than_one_code_occurs", codes.size() > 1,
		"codes seen: %s" % [codes.keys()])


## `aBuildVisibleMap` -- the whole fog pass, per player, against `+0x4F`.
func _fog_cases(h: TestHarness, combat: Dictionary,
		types: Dictionary) -> void:
	var passes: Array = DictRead.as_array(combat["fog"])
	h.check("fog.passes", not passes.is_empty(),
		"%d player pass(es)" % passes.size())
	var players: int = DictRead.as_int(combat["human_players"])
	var mode: int = DictRead.as_int(combat["game_mode"])
	for entry: Variant in passes:
		var case: Dictionary = DictRead.as_dict(entry)
		var player: int = DictRead.as_int(case["player"])
		var built: Dictionary = MoveMapCaseRunner.build_combat_world(combat,
			types, DictRead.as_array(case["units"]))
		var units: Dictionary = built["units"]
		var fog_state: MapState = built["state"]
		var fog_types: UnitTypeTable = built["unit_types"]
		Visibility.build(fog_state, units, fog_types, player, players, mode)
		var bad: Array[String] = []
		var seen: Dictionary = {}
		for want: Variant in DictRead.as_array(case["expect"]):
			var pair: Array = DictRead.as_array(want)
			var slot: int = DictRead.as_int(pair[0])
			var wanted: int = DictRead.as_int(pair[1])
			var unit: UnitState = units[slot]
			seen[wanted] = true
			if unit.visibility != wanted:
				bad.append("slot %d: %d != %d" % [slot, unit.visibility,
					wanted])
		h.check("fog.p%d.matches_native" % player, bad.is_empty(),
		", ".join(bad.slice(0, REPORT_LIMIT)))
		# One player's pass hides nothing and the other's hides plenty; both
		# are asserted, and the count says which this was.
		h.check("fog.p%d.states_present" % player, seen.size() >= 1,
			"states in the engine's answer: %s" % [seen.keys()])


## `aCheckWeaponDamage` at and below the cap, with the seed read either side.
##
## Probe 1 is one *below* the cap: it must draw nothing and write nothing, and
## that is the gate. The rest are at the cap and reach the arms.
func _overheat_cases(h: TestHarness, combat: Dictionary,
		types: Dictionary) -> void:
	var block: Dictionary = DictRead.as_dict(combat["overheat"])
	if block.is_empty():
		h.check("overheat.captured", false, "no overheat phase in the capture")
		return
	var slot: int = DictRead.as_int(block["slot"])
	var cap: int = DictRead.as_int(block["cap"])
	var probes: Array = DictRead.as_array(block["probes"])
	h.check("overheat.probes", probes.size() > 1,
		"%d probe(s), cap %d" % [probes.size(), cap])
	var wtab: WeaponTable = WeaponTable.from_rows(
		DictRead.as_array(types["weapons"]))
	var bad: Array[String] = []
	var arms: Dictionary = {}
	for entry: Variant in probes:
		var case: Dictionary = DictRead.as_dict(entry)
		var built: Dictionary = MoveMapCaseRunner.build_combat_world(combat,
			types, DictRead.as_array(combat["units"]))
		var over_units: Dictionary = built["units"]
		var unit: UnitState = over_units[slot]
		unit.heat = cap if DictRead.as_bool(case["at_the_cap"]) else cap - 1
		unit.malfunction = DictRead.as_int(case["malfunction_before"])
		var rng: IncRandom = IncRandom.new()
		rng.randomize_seed(DictRead.as_float(case["seed_before"]))
		arms[Combat.check_weapon_damage(wtab, unit, rng)] = true
		if unit.malfunction != DictRead.as_int(case["malfunction_after"]):
			bad.append("%d != %d" % [unit.malfunction,
				DictRead.as_int(case["malfunction_after"])])
		# The seed is the sharp part: it says whether the roll happened at all,
		# which is the whole of the gate.
		if absf(rng.seed - DictRead.as_float(case["seed_after"])) > 0.5:
			bad.append("seed %f != %f" % [rng.seed,
				DictRead.as_float(case["seed_after"])])
	h.check("overheat.matches_native", bad.is_empty(),
		", ".join(bad.slice(0, REPORT_LIMIT)))
	h.check("overheat.more_than_one_arm", arms.size() > 1,
		"arms reached: %s" % [arms.keys()])


## `aAttackUnit`, probe by probe, each from the world the one before it left.
func _attack_cases(h: TestHarness, combat: Dictionary, types: Dictionary,
		ai_level: int) -> void:
	var block: Dictionary = DictRead.as_dict(combat["attack"])
	if block.is_empty():
		h.check("attack.captured", false, "no attack phase in the capture")
		return
	var probes: Array = DictRead.as_array(block["probes"])
	h.check("attack.probes", not probes.is_empty(),
		"%d shot(s)" % probes.size())
	var players: int = DictRead.as_int(combat["human_players"])
	var mode: int = DictRead.as_int(combat["game_mode"])
	var hp_bad: Array[String] = []
	var seed_bad: Array[String] = []
	var kills: int = 0
	var markers: Dictionary = {}
	for i: int in range(probes.size()):
		var case: Dictionary = DictRead.as_dict(probes[i])
		var built: Dictionary = MoveMapCaseRunner.build_combat_world(combat,
			types, DictRead.as_array(case["units"]))
		var units: Dictionary = built["units"]
		var rng: IncRandom = IncRandom.new()
		rng.randomize_seed(DictRead.as_float(case["seed_before"]))
		var shot_state: MapState = built["state"]
		var shot_types: UnitTypeTable = built["unit_types"]
		var shot_weapons: WeaponTable = built["weapons"]
		var result: AttackResult = Combat.attack(shot_state, units,
			shot_types, shot_weapons,
			DictRead.as_int(case["ax"]), DictRead.as_int(case["ay"]),
			DictRead.as_int(case["tx"]), DictRead.as_int(case["ty"]),
			ai_level, players, mode, _turn(mode), rng)
		for outcome: Dictionary in result.outcomes:
			markers[DictRead.as_int(outcome["marker"])] = true
		if absf(rng.seed - DictRead.as_float(case["seed_after"])) > 0.5:
			seed_bad.append("probe %d: %f != %f" % [i, rng.seed,
				DictRead.as_float(case["seed_after"])])
		for want: Variant in DictRead.as_array(case["hp_after"]):
			var pair: Array = DictRead.as_array(want)
			var slot: int = DictRead.as_int(pair[0])
			var wanted: int = DictRead.as_int(pair[1])
			var mine: int = 0
			if units.has(slot):
				var unit: UnitState = units[slot]
				mine = unit.hp
			if mine != wanted:
				hp_bad.append("probe %d slot %d: %d != %d"
					% [i, slot, mine, wanted])
			if wanted == 0:
				kills += 1
	# The seed is the whole draw order: the hit roll, the damage roll, the two
	# fatigue extras and the armour roll, in that order.  A model that drew the
	# right *values* in the wrong order would fail here and nowhere else.
	h.check("attack.seed_matches_native", seed_bad.is_empty(),
		", ".join(seed_bad.slice(0, REPORT_LIMIT)))
	h.check("attack.hit_points_match_native", hp_bad.is_empty(),
		", ".join(hp_bad.slice(0, REPORT_LIMIT)))
	h.check("attack.something_died", kills > 0,
		"%d zero-hit-point record(s) across the probes" % kills)
	h.check("attack.reached_a_hit_and_a_miss",
		markers.has(Combat.MARKER_MISS) and markers.size() > 1,
		"markers: %s" % [markers.keys()])


## `aExecuteUse` swept over eight facings for three classes, **in order**.
func _use_cases(h: TestHarness, combat: Dictionary, types: Dictionary,
		ai_level: int) -> void:
	var block: Dictionary = DictRead.as_dict(combat["use"])
	if block.is_empty():
		h.check("use.captured", false, "no interaction phase in the capture")
		return
	var cell: Array = DictRead.as_array(block["cell"])
	var slot: int = DictRead.as_int(block["slot"])
	var probes: Array = DictRead.as_array(block["probes"])
	h.check("use.probes", not probes.is_empty(),
		"%d probe(s)" % probes.size())

	var built: Dictionary = MoveMapCaseRunner.build_combat_world(combat, types,
		DictRead.as_array(combat["units"]))
	var state: MapState = built["state"]
	var units: Dictionary = built["units"]
	var unit: UnitState = units[slot]
	var use_types: UnitTypeTable = built["unit_types"]
	var use_weapons: WeaponTable = built["weapons"]
	var control: GameControl = GameControl.create()
	var rng: IncRandom = IncRandom.new()
	var at: int = state.index_of(DictRead.as_int(cell[0]),
		DictRead.as_int(cell[1]))

	var ap_bad: Array[String] = []
	var ammo_bad: Array[String] = []
	var equip_bad: Array[String] = []
	var kinds: Dictionary = {}
	for entry: Variant in probes:
		var case: Dictionary = DictRead.as_dict(entry)
		var klass: int = DictRead.as_int(case["class"])
		state.set_action_point(at, klass)
		unit.facing = DictRead.as_int(case["facing"])
		var result: UseResult = Interact.execute(state, units,
			use_types, use_weapons, control, unit, ai_level,
			DictRead.as_int(combat["human_players"]),
			DictRead.as_int(combat["game_mode"]),
			_turn(DictRead.as_int(combat["game_mode"])), rng)
		kinds[result.kind] = true
		if state.action_point_at(at) \
				!= DictRead.as_int(case["action_point_after"]):
			ap_bad.append("class %d facing %d: %d != %d"
				% [klass, unit.facing, state.action_point_at(at),
					DictRead.as_int(case["action_point_after"])])
		if unit.ammo != DictRead.as_int(case["ammo_after"]):
			ammo_bad.append("class %d facing %d: %d != %d"
				% [klass, unit.facing, unit.ammo,
					DictRead.as_int(case["ammo_after"])])
		var wanted: PackedInt32Array = DictRead.to_int32(
			case["equipment_after"])
		var mine: PackedInt32Array = unit.equipment.duplicate()
		mine.sort()
		wanted.sort()
		if mine != wanted:
			equip_bad.append("class %d facing %d: %s != %s"
				% [klass, unit.facing, mine, wanted])
	h.check("use.action_point_matches_native", ap_bad.is_empty(),
		", ".join(ap_bad.slice(0, REPORT_LIMIT)))
	h.check("use.ammunition_matches_native", ammo_bad.is_empty(),
		", ".join(ammo_bad.slice(0, REPORT_LIMIT)))
	h.check("use.equipment_matches_native", equip_bad.is_empty(),
		", ".join(equip_bad.slice(0, REPORT_LIMIT)))
	# Seven of every eight probes are refusals, so a model that refused
	# *everything* would agree with 21 of the 24.
	h.check("use.reached_more_than_a_refusal", kinds.size() > 1,
		"kinds: %s" % [kinds.keys()])
	h.check("use.granted_the_crowbar",
		unit.equipment.has(Interact.EQUIP_CROWBAR),
		"class 39 is the third of the three probed classes")
