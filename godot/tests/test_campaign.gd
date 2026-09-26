extends TestSuite

## Oracle boundary: **executable Python** -- `tools/inclib/campaign.py`, run
## over the corpus by `tools/campaign_runtime.py`, which is in turn diffed
## against the immediates `campaign_tables.py` reads out of `Incubation.exe`,
## against `Info.lcl`'s prices, against the cells of `_C_XXX`/`_C_YYY` and
## against the six real saves. This suite compares `core/campaign/` with that
## model, so what it prints is `executable-Python` and not `native-runtime`.
##
## The fixture carries **whole inputs**, the same discipline the move-map cases
## follow: a scoring case names its difficulty, result, kills and losses, so
## the two implementations receive identical inputs by construction rather than
## by agreement.

## `res://generated` first, `user://` second -- the order that keeps a stale
## copy from shadowing a fresh one (see [MoveMapCaseRunner]).
const DEV_CASES_DIR: String = "res://generated/campaign"
const USER_CASES_DIR: String = "user://campaign"
const SCHEMA: String = "incubation.campaign-cases/1"

## D7: the campaign layer must not move [World]'s canonical hash. These three
## were measured on the commit **before** this slice and are unchanged by it;
## a suite that only compared a hash with itself would not notice a drift, and
## `test_cache.gd` and `test_mission.gd` both do exactly that.
##
## **They are pre-sweep, deliberately.** [method World.load_sweep] rewrites
## seven bytes of every unit record (docs/25 section 5.1) and a played mission
## therefore never has these hashes -- `game`'s mission entry runs the sweep
## right after [method World.create], and this pins what the loader alone
## produces. Keeping the pins on the loader is what lets a converter change and
## a sweep change stay apart: one moves these, the other does not.
##
## **Moved once, deliberately** (2026-09-24, save schema 12): the special-object
## table `[0x004FA80C]` joined [MapState] and the digest, because
## `GrowingLand`, `FallingSpores` and `Spores` read and write it (docs/42
## section 8.2). The loader's grid is unchanged; the table is the difference.
const PINNED_HASHES: Dictionary = {
	"_C_140": "586251e3ab0036924a2137cd9aa4e25b0717b674f984b3dd8f9b30bfb0ed0396",
	"_C_141": "72554f1d3a2f9b4361dca1acf294f08e460e43db0e0c150ad5ce1f6836911982",
	"_C_115": "a3ea0d8d619be4bf9e43b667b243db335502c12be12c024dd7d5361a98de664c",
}


static func cases_path() -> String:
	var in_dev: String = DEV_CASES_DIR + "/campaign.json"
	if FileAccess.file_exists(in_dev):
		return in_dev
	return USER_CASES_DIR + "/campaign.json"


func run(h: TestHarness) -> void:
	h.begin("campaign", TestHarness.ORACLE_PYTHON)
	var path: String = cases_path()
	if not FileAccess.file_exists(path):
		# **Not a skip.** A missing fixture is the gap being reported, which is
		# what keeps a run from silently shrinking.
		h.check("cases.present", false,
			"%s is absent -- run campaign_runtime.py --emit-cases" % path)
		_pinned_hashes(h)
		_mission_opening(h)
		_endings(h)
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		h.check("cases.parse", false, path)
		_pinned_hashes(h)
		_mission_opening(h)
		_endings(h)
		return
	var cases: Dictionary = parsed
	h.equal("cases.schema", DictRead.as_string(cases["schema"]), SCHEMA)
	h.equal("cases.oracle", DictRead.as_string(cases["oracle"]),
		TestHarness.ORACLE_PYTHON)
	_fixture_is_current(h, cases)

	_seed(h, cases)
	_economy(h, cases)
	_sort(h, cases)
	_banks(h, cases)
	_abandon(h, cases)
	_survival(h, cases)
	_score(h, cases)
	_payouts(h, cases)
	_tables(h, cases)
	_deployment(h, cases)
	_codec(h, cases)
	_decorations_survive(h, cases)
	_presets(h)
	_pinned_hashes(h)
	_mission_opening(h)
	_endings(h)


## The Recruit window's presets -- `0x00476260` as `tables/campaign.json`
## carries it (docs/27 section 3.2), hired through [method
## CampaignHost.recruit_preset]. The binary side is `campaign_tables.py`'s
## `preset.*` checks; this is the model side, hand-computed from the same
## balance rows the purchase reads.
func _presets(h: TestHarness) -> void:
	var host: CampaignHost = CampaignHost.create(CacheFixture.cache_dir(),
		CacheFixture.balance(), Localization.from_cache(CacheFixture.paths()))
	var ids: PackedInt32Array = host.tables.recruit_ids()
	h.equal("preset.count", ids.size(), 23,
		"the twenty-three arms of 0x00476260")
	h.check("preset.ids_are_the_listed_rows",
		ids == PackedInt32Array([0, 1, 2, 3, 10, 11, 12, 13, 14, 20, 21, 22,
			23, 30, 31, 32, 33, 35, 40, 41, 42, 43, 44]),
		"every row of RecruitScreen.CATEGORY_TYPES and nothing else")
	var state: CampaignState = host.start_instant_action("_S_004",
		{"tech_level": 10, "skill_level": 12, "equip_points": [1500, 0, 0, 0]})

	# Preset 0, *Squad Leader*: weapon 2 and items 8, 10, 14, 5, EP 120,
	# FP 10, markup 170.
	var squad_leader: Dictionary = host.preset(0)
	var expected_cost: int = DictRead.as_int(
		host.row_for(CampaignHost.KIND_WEAPONS, 2).get("cost", 0)) + 170
	for item: int in [8, 10, 14, 5]:
		expected_cost += DictRead.as_int(
			host.row_for(CampaignHost.KIND_EQUIPMENT, item).get("cost", 0))
	var price: int = expected_cost / 10 * 10
	h.equal("preset.price", host.preset_price(0), price,
		"items' costs plus the markup, to the ten below")
	var hired: Dictionary = host.recruit_preset(0)
	h.equal("preset.hired", DictRead.as_string(hired["result"]), Upgrade.OK)
	h.equal("preset.charged", state.points(0), 1500 - price)
	var unit: UnitState = state.roster.record(DictRead.as_int(hired["slot"]))
	h.check("preset.record",
		unit != null and unit.type_id == CampaignState.PRESET_UNIT_TYPE
		and unit.weapon == 2 and unit.ep == 120 and unit.fp == 10
		and unit.player == 0 and unit.pool_flag == Roster.POOL_CANDIDATE,
		"type 0 for the hiring player, EP and FP by literal")
	h.check("preset.equipment",
		unit != null and unit.has_equipment(8) and unit.has_equipment(10)
		and unit.has_equipment(14) and unit.has_equipment(5),
		"every item the arm buys is carried")
	var hp_max: int = DictRead.as_int(host.row_for("units", 0).get("hp_max", 0))
	h.equal("preset.hit_points", unit.hp if unit != null else -1,
		mini(Interact.MAX_HIT_POINTS_CAP,
			hp_max + 120 / Interact.EXPERIENCE_PER_HIT_POINT),
		"0x00475240's ceiling at the preset's EP")
	# TP is the **largest** purchase's skill charge, not the sum: the tail's
	# `mov [ebp+0x18], bl` overwrites the running subtraction.
	var fresh: UnitState = UnitState.new()
	var largest: int = Upgrade.weapon_skill_cost(
		host.row_for(CampaignHost.KIND_WEAPONS, 2), fresh)
	var _w: int = Upgrade.apply_weapon(fresh, 2,
		host.row_for(CampaignHost.KIND_WEAPONS, 2))
	for item: int in [8, 10, 14, 5]:
		var row: Dictionary = host.row_for(CampaignHost.KIND_EQUIPMENT, item)
		largest = maxi(largest, Upgrade.equipment_skill_cost(row, fresh))
		var _e: int = Upgrade.apply_equipment(fresh, item, row)
	h.equal("preset.skill_points", unit.tp if unit != null else -1,
		largest * Upgrade.TP_PER_SKILL_POINT)
	h.check("preset.skills_raised",
		unit != null and unit.skills == fresh.skills,
		"the same raises the two buy routines make")
	h.equal("preset.name", unit.name if unit != null else "",
		host.preset_name(0))
	h.check("preset.name_is_the_bank_line",
		host.preset_name(0) != "0" and host.preset_name(0) != "",
		"Txtmod_h 140 through the shipped bank: " + host.preset_name(0))

	# Preset 44, *Jump Trooper*, buys the Jet Pack (7), which grants the
	# scan (1) -- `0x00475601` -- the same way the Upgrade Menu's purchase does.
	var trooper: Dictionary = host.recruit_preset(44)
	var jumper: UnitState = state.roster.record(DictRead.as_int(trooper["slot"]))
	h.check("preset.jet_pack_grants_scan",
		DictRead.as_string(trooper["result"]) == Upgrade.OK
		and jumper != null and jumper.has_equipment(Upgrade.JET_PACK_ID)
		and jumper.has_equipment(Upgrade.JET_PACK_GRANTS))

	# `0x0045BB86`: the hire caches `cost / 10` in `+0x5A`, so dismissing
	# the preset refunds its price -- and `0x0045ABAB` rewrites the cache
	# with `0x004776E0`'s value of the whole kit after a weapon purchase, so
	# a dismissal after that refunds the kit, not the weapon alone.
	var before: int = state.points(0)
	h.equal("preset.dismissal_refunds_the_price",
		state.dismiss(0, DictRead.as_int(trooper["slot"]), host.weapon_costs()),
		host.preset_price(44))
	h.equal("preset.refund_lands", state.points(0),
		before + host.preset_price(44))
	var costs: Dictionary = host.weapon_costs()
	var items: Dictionary = host.equipment_costs()
	var slot: int = DictRead.as_int(hired["slot"])
	var swapped: Dictionary = state.buy_weapon(0, slot, 1, costs,
		host.row_for(CampaignHost.KIND_WEAPONS, 1), items)
	var kit: int = Roster.kit_value(DictRead.as_int(costs.get(1, 0)),
		state.roster.record(slot).equipment, items)
	h.check("preset.weapon_purchase_caches_the_kit",
		DictRead.as_string(swapped["result"]) == Upgrade.OK
		and state.roster.record(slot).resale == kit
		and kit != Roster.resale_of(DictRead.as_int(costs.get(1, 0))),
		"0x004776E0 counts the carried items, not the weapon alone")
	h.equal("preset.dismissal_after_swap_refunds_the_kit",
		state.dismiss(0, slot, costs), kit * Roster.RESALE_SCALE)
	# The Jet Pack's granted scan is not charged for: `+0x28` set takes item
	# 1's cost back off.
	h.equal("preset.kit_value_ignores_the_granted_scan",
		Roster.kit_value(10, PackedInt32Array([7, 1]), {7: 40, 1: 25}),
		(10 + 40 + 25 - 25 + 50) / 10)

	# The refusals: the row painter's own gate (`0x00455EDF`), spoken, and an
	# id the window never lists.
	state.set_points(0, 10)
	var broke: Dictionary = host.recruit_preset(0)
	h.equal("preset.refused_when_poor", DictRead.as_string(broke["result"]),
		Upgrade.NO_POINTS)
	h.equal("preset.poor_purse_unchanged", state.points(0), 10)
	h.equal("preset.unlisted_id", DictRead.as_string(
		host.recruit_preset(34)["result"]), Upgrade.BAD_ID,
		"34 has a Txtmod_h name and no arm")
	# A seat not in the game is refused at the gate, not hired and then
	# left unpaid by a spend that refuses it.
	var absent: int = state.player_kind.find(0)
	if absent >= 0:
		state.set_points(absent, 5000)
		var free_hire: Dictionary = state.recruit_preset(absent, 1,
			{"weapon": 0, "markup": 10}, "nobody", costs, {}, {}, 10)
		h.equal("preset.refused_for_a_seat_not_in_the_game",
			[DictRead.as_string(free_hire["result"]), state.points(absent)],
			[Upgrade.NO_POINTS, 5000])


## The fixture must have been emitted from **this** corpus and **this** model.
##
## A schema check is not enough: the file is regenerated by hand and went stale
## twice while this slice was being written, and a stale one passes every other
## check in here because both sides read it. So three numbers the Python side
## took from `Info.lcl` are compared against what `CampaignHost` reads from
## `tables/balance.json` -- the same shape of guard `LEAST_CHECKS` is.
func _fixture_is_current(h: TestHarness, cases: Dictionary) -> void:
	var host: CampaignHost = CampaignHost.create(CacheFixture.cache_dir(),
		CacheFixture.balance(), null)
	var state: CampaignState = host.start_new(2)
	h.equal("cases.weapon_zero_cost", state.weapon_zero_cost,
		DictRead.as_int(cases["weapon_zero_cost"]),
		"the fixture and the cache read one Info.lcl")
	h.equal("cases.recruit_hit_points", state.recruit_hit_points,
		DictRead.as_int(cases["recruit_hit_points"]))
	h.equal("cases.recruit_ammo", state.recruit_ammo,
		DictRead.as_int(cases["recruit_ammo"]),
		"weapon 0's mun, which the seed's closing recompute puts in +0x3D")
	h.equal("cases.recruit_cost", state.recruit_cost(),
		DictRead.as_int(cases["recruit_cost"]))
	h.equal("cases.mission_count",
		DictRead.as_dict(cases["chain"]).size(), 75,
		"every shipped campaign mission is in the fixture")


func _state(cases: Dictionary, number: int) -> CampaignState:
	return CampaignState.begin(number,
		DictRead.as_int(cases["weapon_zero_cost"]),
		DictRead.as_int(cases["recruit_hit_points"]),
		DictRead.as_int(cases["recruit_ammo"]),
		_seed_names(cases))


func _seed_names(cases: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var seeded: Dictionary = DictRead.as_dict(cases["seed"])
	for entry: Variant in DictRead.as_array(
			DictRead.as_dict(seeded["1"])["roster"]):
		out.append(DictRead.as_string(DictRead.as_dict(entry)["name"]))
	return out


## docs/27 section 3.1 -- and the campaign arm `0x0043AE76` behind it.
func _seed(h: TestHarness, cases: Dictionary) -> void:
	var seeded: Dictionary = DictRead.as_dict(cases["seed"])
	for number: int in [1, 2]:
		var want: Dictionary = DictRead.as_dict(seeded[str(number)])
		var state: CampaignState = _state(cases, number)
		h.equal("seed.%d.mission" % number, state.mission,
			DictRead.as_string(want["mission"]))
		h.equal("seed.%d.tech" % number, state.tech_level,
			DictRead.as_int(want["tech_level"]))
		h.equal("seed.%d.skill" % number, state.skill_level,
			DictRead.as_int(want["skill_level"]))
		h.equal("seed.%d.players" % number, state.player_count,
			DictRead.as_int(want["player_count"]))
		h.equal_ints("seed.%d.points" % number, state.equipment_points,
			DictRead.to_int32(want["equipment_points"]))
		var roster: Array = DictRead.as_array(want["roster"])
		h.equal("seed.%d.pool_size" % number, state.roster.used_slots(),
			roster.size())
		for entry: Variant in roster:
			var record: Dictionary = entry
			var slot: int = DictRead.as_int(record["slot"])
			var unit: UnitState = state.roster.record(slot)
			if unit == null:
				h.check("seed.%d.slot_%d" % [number, slot], false, "empty")
				continue
			h.equal("seed.%d.slot_%d.name" % [number, slot], unit.name,
				DictRead.as_string(record["name"]))
			h.equal("seed.%d.slot_%d.ep" % [number, slot], unit.ep,
				DictRead.as_int(record["ep"]))
			h.equal("seed.%d.slot_%d.tp" % [number, slot], unit.tp,
				DictRead.as_int(record["tp"]))
			h.equal("seed.%d.slot_%d.rank" % [number, slot],
				unit.ep / Roster.EP_PER_RANK, DictRead.as_int(record["rank"]))
			h.equal("seed.%d.slot_%d.type" % [number, slot], unit.type_id,
				DictRead.as_int(record["unit_type"]))
			h.equal("seed.%d.slot_%d.pool_flag" % [number, slot],
				unit.pool_flag, DictRead.as_int(record["pool_flag"]))
			h.equal("seed.%d.slot_%d.speech" % [number, slot], unit.speech,
				DictRead.as_int(record["speech"]))
			h.equal_ints("seed.%d.slot_%d.skills" % [number, slot],
				unit.skills, DictRead.to_int32(record["skills"]))
			h.equal_ints("seed.%d.slot_%d.equipment" % [number, slot],
				unit.equipment, DictRead.to_int32(record["equipment"]))
			# `0x00478B4A` -- `aEnlargeUnitPool` closes with the full
			# recompute, so a seeded record already carries weapon 0's
			# magazine.
			h.equal("seed.%d.slot_%d.ammo" % [number, slot], unit.ammo,
				DictRead.as_int(record["ammo"]))

	# The sixteen field writes, against the block campaign_tables decodes out of
	# `0x0047883B`..`0x004788A5`. The mapping from offset to field is this
	# suite's; the values are the executable's.
	var state_one: CampaignState = _state(cases, 1)
	for entry: Variant in DictRead.as_array(cases["squad_fields"]):
		var row: Dictionary = entry
		var record_index: int = DictRead.as_int(row["record"])
		var offset: int = DictRead.as_int(row["offset"])
		var unit: UnitState = state_one.roster.record(record_index)
		if unit == null:
			continue
		var got: int = _field_at(unit, offset)
		if got < 0:
			continue
		h.equal("seed.field.%d.%d" % [record_index, offset], got,
			DictRead.as_int(row["value"]))


## The record offsets the seed writes, as this remake's fields. `-1` means the
## offset is one the suite does not map, which is reported by not checking it
## rather than by a false pass.
func _field_at(unit: UnitState, offset: int) -> int:
	match offset:
		0x17: return unit.ep
		0x18: return unit.tp
		0x4C: return unit.type_id
		0x4D: return unit.pool_flag
		0x55: return unit.speech
	if offset >= 0x1A and offset <= 0x1F:
		return unit.skills[offset - 0x1A]
	if offset >= 0x21 and offset <= 0x35:
		return 1 if unit.has_equipment(offset - 0x21) else 0
	return -1


func _economy(h: TestHarness, cases: Dictionary) -> void:
	var state: CampaignState = _state(cases, 2)
	h.equal("economy.recruit_cost", state.recruit_cost(),
		DictRead.as_int(cases["recruit_cost"]))
	var steps: Array = DictRead.as_array(cases["economy"])
	for entry: Variant in steps:
		var step: Dictionary = entry
		var name: String = DictRead.as_string(step["step"])
		match name:
			"start":
				pass
			"recruit":
				state.recruit(0, 1)
			"dismiss":
				state.dismiss(0, 0, {0: DictRead.as_int(
					cases["weapon_zero_cost"])})
			"cap":
				state.set_points(0, 9990)
				state.add_points(0, 100)
			"kit":
				state.set_points(0, 200)
				state.recruit(0, 1)
				var _item: Dictionary = state.buy_equipment(0, 0, 3,
					{"cost": 25})
				var _rifle: Dictionary = state.buy_weapon(0, 0, 5,
					{0: DictRead.as_int(cases["weapon_zero_cost"]), 5: 30},
					{}, {3: 25})
				var _gone: int = state.dismiss(0, 0, {})
		h.equal("economy.%s.purse" % name, state.points(0),
			DictRead.as_int(step["purse"]))
		h.equal("economy.%s.used" % name, state.roster.used_slots(),
			DictRead.as_int(step["used"]))

	# The two refusals, which the fixture's happy path does not reach.
	var poor: CampaignState = _state(cases, 2)
	poor.set_points(0, 10)
	h.equal("economy.recruit_refused_when_poor", poor.recruit(0, 1),
		Roster.NO_SLOT)
	h.equal("economy.poor_purse_unchanged", poor.points(0), 10)
	h.equal("economy.spend_refuses", poor.spend_points(0, 20000), false)
	h.equal("economy.empty_slot_holds_nothing", poor.add_points(3, 100), false)

	# A weapon swap costs the difference and refunds first.
	var swap: CampaignState = _state(cases, 2)
	swap.recruit(0, 1)
	var costs: Dictionary = {0: 10, 5: 30}
	h.equal("economy.buy_weapon",
		DictRead.as_string(swap.buy_weapon(0, 0, 5, costs)["result"]),
		Upgrade.OK)
	h.equal("economy.swap_costs_difference", swap.points(0), 100 - 60 + 10 - 30)
	var upgraded: UnitState = swap.roster.record(0)
	h.equal("economy.weapon_changed", upgraded.weapon, 5)
	h.equal("economy.resale_after_swap", Roster.refund_for(30), 80)
	_upgrade_rules(h)


## docs/27 section 5.3 -- what `aBuyWeapon` and `aBuyEquipment` do beyond the
## purse, hand-computed from `Info.lcl`'s own lines.
func _upgrade_rules(h: TestHarness) -> void:
	# `SetEquipInfo (14, "Servo System", 30, 2,0,0,2,1,0, 1, "N", 13)` -- CON 2,
	# TS 2, MS 1 -- against a soldier who has MS 2 and nothing else, which is
	# `West`'s seeded row. The shortfall is 2 + 2 + 0 = 4.
	var servo: Dictionary = {"id": 14, "cost": 30,
		"skills": {"CON": 2, "LW": 0, "HW": 0, "TS": 2, "MS": 1, "LS": 0}}
	var west: UnitState = UnitState.new()
	west.hp = 5
	west.skills = PackedInt32Array([0, 0, 0, 0, 2, 0])
	h.equal("upgrade.shortfall_is_per_soldier",
		Upgrade.equipment_skill_cost(servo, west), 4,
		"CON 2 and TS 2 are missing; MS 1 is already met by MS 2")
	var raised: PackedInt32Array = Upgrade.raise_skills(
		Upgrade.skills_of(servo), west.skills, Upgrade.EQUIPMENT_SKILL_ORDER)
	h.equal("upgrade.purchase_raises_to_the_requirement",
		[raised[UnitState.SKILL_CON], raised[UnitState.SKILL_TS],
		raised[UnitState.SKILL_MS]], [2, 2, 2],
		"and never lowers the one already above it")
	h.equal("upgrade.raise_leaves_the_source_alone", west.skills,
		PackedInt32Array([0, 0, 0, 0, 2, 0]),
		"a rule module must not write through a record's own vector")
	# `SetWeaponInfo (2, "Standard Assault Rifle", ..., 3,0,0,0, ...)` -- LW 3.
	var rifle: Dictionary = {"id": 2, "cost": 30,
		"skills": {"LW": 3, "HW": 0, "TS": 0, "CON": 0}}
	h.equal("upgrade.weapon_shortfall",
		Upgrade.weapon_skill_cost(rifle, west), 3)

	# The mutual-exclusion groups of `aBuyEquipment`.
	h.equal("upgrade.armour_group", Upgrade.cleared_by(12),
		PackedInt32Array([10, 11, 13]), "one armour at a time")
	h.equal("upgrade.medic_group", Upgrade.cleared_by(15),
		PackedInt32Array([16]))
	h.equal("upgrade.jet_pack_is_in_no_group",
		Upgrade.cleared_by(Upgrade.JET_PACK_ID), PackedInt32Array())

	# The decoration allowance and the three gates on *Commend Unit*.
	h.equal("upgrade.decoration_allowance",
		[Upgrade.decoration_allowance(39), Upgrade.decoration_allowance(40),
		Upgrade.decoration_allowance(60), Upgrade.decoration_allowance(100)],
		[0, 1, 2, 3], "`0x00475550`, derived from EP alone")
	var veteran: UnitState = UnitState.new()
	veteran.hp = 5
	veteran.ep = 100
	h.check("upgrade.commend_is_offered", Upgrade.may_commend(veteran, 1))
	h.check("upgrade.commend_needs_a_medal",
		not Upgrade.may_commend(veteran, 0))
	veteran.decorations = 3
	h.check("upgrade.commend_stops_at_the_allowance",
		not Upgrade.may_commend(veteran, 1))
	veteran.decorations = 0
	veteran.tp = Upgrade.TP_CAP
	h.check("upgrade.commend_stops_at_ten_skill_points",
		not Upgrade.may_commend(veteran, 1),
		"`0x00458416` greys the button at 120")
	# `0x00458449` greys gadget **3**, the name field, for a hero -- not
	# gadget 5, which is what docs/10 section 5.11 read it as.
	var hero: UnitState = UnitState.new()
	hero.hp = 5
	hero.ep = 100
	hero.pool_flag = UnitState.HERO_POOL_FLAG
	h.check("upgrade.a_hero_may_still_be_commended",
		Upgrade.may_commend(hero, 1))
	h.check("upgrade.a_hero_may_not_be_renamed", not Upgrade.may_rename(hero))

	# And the whole purchase, through the state: the Jet Pack grants Long
	# Range Scan, and with it carried the Scan Module is refused before the
	# purse is touched (`0x0045A9B6`).
	var buyer: CampaignState = CampaignState.create()
	buyer.player_kind[0] = 1
	buyer.set_points(0, 500)
	var slot: int = buyer.roster.enlarge(0, TurnState.MODE_CAMPAIGN, 0, 1, 5, 7)
	var jetted: UnitState = buyer.roster.record(slot)
	jetted.tp = 120
	buyer.roster.put(slot, jetted)
	var jet: Dictionary = {"id": Upgrade.JET_PACK_ID, "cost": 190,
		"skills": {"CON": 4, "TS": 3}}
	h.equal("upgrade.jet_pack_bought",
		DictRead.as_string(buyer.buy_equipment(0, slot, Upgrade.JET_PACK_ID,
			jet)["result"]), Upgrade.OK)
	var carrier: UnitState = buyer.roster.record(slot)
	h.check("upgrade.jet_pack_grants_long_range_scan",
		carrier.has_equipment(Upgrade.JET_PACK_GRANTS),
		"`Info.lcl` annotates the line itself `* warp & scan`")
	h.equal("upgrade.jet_pack_costs_seven_skill_points",
		carrier.tp, 120 - 7 * Upgrade.TP_PER_SKILL_POINT,
		"CON 4 and TS 3 from nothing")
	var purse: int = buyer.points(0)
	h.equal("upgrade.scan_module_refused_under_a_jet_pack",
		DictRead.as_string(buyer.buy_equipment(0, slot,
			Upgrade.SCAN_MODULE_ID, {"id": 0, "cost": 50})["result"]),
		Upgrade.BLOCKED_BY_JET_PACK)
	h.equal("upgrade.refusal_is_free", buyer.points(0), purse,
		"the guard sits in front of the purse")
	h.equal("upgrade.already_carried_is_refused",
		DictRead.as_string(buyer.buy_equipment(0, slot, Upgrade.JET_PACK_ID,
			jet)["result"]), Upgrade.ALREADY_CARRIED,
		"the engine toggles it off and charges for it; Undo is the way back")


## `0x00478630` -- and the case that makes it more than a `sort_custom`.
func _sort(h: TestHarness, cases: Dictionary) -> void:
	var index: int = 0
	for entry: Variant in DictRead.as_array(cases["sorts"]):
		var case: Dictionary = entry
		var roster: Roster = Roster.create()
		for pair: Variant in DictRead.as_array(case["before"]):
			var xy: Array = pair
			var unit: UnitState = UnitState.new()
			unit.hp = 5
			unit.ep = DictRead.as_int(xy[1])
			unit.name = "u%d" % DictRead.as_int(xy[0])
			roster.put(DictRead.as_int(xy[0]), unit)
		roster.sort_by_ep()
		var got: Array = []
		for slot: int in roster.occupied_slots():
			got.append([slot, roster.record(slot).ep])
		var want: Array = []
		for pair: Variant in DictRead.as_array(case["after"]):
			var xy: Array = pair
			want.append([DictRead.as_int(xy[0]), DictRead.as_int(xy[1])])
		h.equal("sort.%d" % index, got, want)
		index += 1


## docs/27 section 3.5 as corrected: row 0 live, row 1 the entry snapshot.
func _banks(h: TestHarness, cases: Dictionary) -> void:
	var state: CampaignState = _state(cases, 1)
	var roster: Roster = state.roster
	for entry: Variant in DictRead.as_array(cases["banks"]):
		var step: Dictionary = entry
		var name: String = DictRead.as_string(step["step"])
		match name:
			"start":
				pass
			"snapshot":
				roster.snapshot()
			"deployed":
				for slot: int in [0, 1, 2]:
					roster.clear(slot)
			"restore":
				roster.restore()
			"debriefing_over":
				roster.clear_snapshot()
		h.equal("banks.%s.live" % name, roster.used_slots(Roster.ROW_LIVE),
			DictRead.as_int(step["live"]))
		h.equal("banks.%s.snapshot" % name,
			roster.used_slots(Roster.ROW_SNAPSHOT),
			DictRead.as_int(step["snapshot"]))


## A mission left without finishing it gives the squad back -- from the
## deployment screen and from the mission itself.
##
## The second half is what `B` over a running mission used to cost: the
## briefing's *Back* raised the location map, `abandon_mission` restored
## nothing because the screen was not the deployment one, and the marines
## standing on the map -- taken out of the live row to get there -- were gone
## for good.
func _abandon(h: TestHarness, cases: Dictionary) -> void:
	for screen: String in [CampaignHost.SCREEN_MISSION]:
		var host: CampaignHost = CampaignHost.create(CacheFixture.cache_dir(),
			CacheFixture.read_json(CacheFixture.cache_dir()
				+ "/tables/balance.json"), null)
		host.state = _state(cases, 1)
		var roster: Roster = host.state.roster
		var before: int = roster.used_slots(Roster.ROW_LIVE)
		roster.snapshot()
		for slot: int in [0, 1]:
			roster.clear(slot)
		host.screen = screen
		host.abandon_mission()
		h.equal("abandon.%s.squad_comes_back" % screen,
			roster.used_slots(Roster.ROW_LIVE), before,
			"everyone deployed is put back in the live row")
		h.equal("abandon.%s.lands_on_the_map" % screen, host.screen,
			CampaignHost.SCREEN_MAP)

	# **The briefing's *Continue* over a deployment already made.** It rebuilds
	# the mission, so `begin_mission` runs a second time -- and the snapshot it
	# takes must not be the row deployment emptied. Without the restore in
	# front of it the squad was lost for good: everyone on the map went with
	# the rebuilt scene and the pre-mission row had been overwritten.
	var again: CampaignHost = CampaignHost.create(CacheFixture.cache_dir(),
		CacheFixture.read_json(CacheFixture.cache_dir()
			+ "/tables/balance.json"), null)
	again.state = _state(cases, 1)
	var pool: Roster = again.state.roster
	var whole: int = pool.used_slots(Roster.ROW_LIVE)
	again.begin_mission(null)
	for slot: int in [0, 1]:
		pool.clear(slot)
	again.begin_mission(null)
	h.equal("begin_mission.re_entry_keeps_the_squad",
		pool.used_slots(Roster.ROW_LIVE), whole,
		"a second entry puts the deployed soldiers back first")
	again.screen = CampaignHost.SCREEN_MISSION
	again.abandon_mission()
	h.equal("begin_mission.re_entry_restores_whole",
		pool.used_slots(Roster.ROW_LIVE), whole)


## docs/27 section 3.4 -- `+0x4D` and the full-pool refusal, both of which the
## engine performs in silence and this remake names (docs/92 section 7.4).
func _survival(h: TestHarness, cases: Dictionary) -> void:
	var index: int = 0
	for entry: Variant in DictRead.as_array(cases["survival"]):
		var case: Dictionary = entry
		var state: CampaignState = _state(cases, 2)
		var full: bool = DictRead.as_bool(case.get("full", false))
		if full:
			for slot: int in range(Roster.USABLE_SLOTS):
				var filler: UnitState = UnitState.new()
				filler.hp = 7
				filler.pool_flag = Roster.POOL_CANDIDATE
				filler.name = "u%d" % slot
				state.roster.put(slot, filler)
		var unit: UnitState = UnitState.new()
		unit.hp = 7
		unit.name = "late" if full else "u"
		unit.pool_flag = DictRead.as_int(case["pool_flag"])
		unit.player = 0
		var survivors: Array[UnitState] = [unit]
		var report: Dictionary = MissionEnd.recover(state, survivors, 0)
		var recovered: Array = report["recovered"]
		var lost: Array = report["lost"]
		h.equal("survival.%d.kept" % index, recovered.size(),
			DictRead.as_int(case["kept"]))
		var reason: Variant = case["reason"]
		if reason == null:
			h.equal("survival.%d.nothing_lost" % index, lost.size(), 0)
		else:
			h.equal("survival.%d.reason" % index,
				DictRead.as_string(DictRead.as_dict(lost[0])["reason"]),
				DictRead.as_string(reason))
		index += 1

	# **Both refusals have words, and only one of them is an alarm.** The
	# screen writes the reason's own identifier for anything it has not been
	# given a sentence for, which is what a new refusal would look like.
	h.equal("survival.the_guest_has_words",
		DebriefingScreen.reason_key(MissionEnd.DROP_NOT_CANDIDATE),
		DebriefingScreen.KEY_GUEST)
	h.equal("survival.a_full_squad_has_words",
		DebriefingScreen.reason_key(MissionEnd.DROP_POOL_FULL),
		DebriefingScreen.KEY_SQUAD_FULL)
	h.equal("survival.an_unknown_refusal_keeps_its_id",
		DebriefingScreen.reason_key("something_new"), "")

	# A unit of another player is not this player's to recover.
	var other: CampaignState = _state(cases, 2)
	var theirs: UnitState = UnitState.new()
	theirs.hp = 7
	theirs.player = 1
	theirs.pool_flag = Roster.POOL_CANDIDATE
	theirs.name = "theirs"
	var ignored: Array[UnitState] = [theirs]
	var out: Dictionary = MissionEnd.recover(other, ignored, 0)
	var out_recovered: Array = DictRead.as_array(out["recovered"])
	var out_lost: Array = DictRead.as_array(out["lost"])
	h.equal("survival.other_players_ignored",
		out_recovered.size() + out_lost.size(), 0)


## docs/27 section 6.2 -- five results by three difficulties by three shapes.
func _score(h: TestHarness, cases: Dictionary) -> void:
	var index: int = 0
	for entry: Variant in DictRead.as_array(cases["scores"]):
		var case: Dictionary = entry
		var state: CampaignState = _state(cases, 2)
		state.difficulty = DictRead.as_int(case["difficulty"])
		var board: ScoreRecord = state.scoreboard[0]
		board.kills = DictRead.as_int(case["kills"])
		board.losses = DictRead.as_int(case["losses"])
		board.result = DictRead.as_int(case["result"])
		var reports: Array[Dictionary] = MissionEnd.score(state)
		h.equal("score.%d.one_report" % index, reports.size(), 1)
		h.equal("score.%d.value" % index,
			DictRead.as_int(reports[0]["score"]),
			DictRead.as_int(case["score"]))
		h.equal("score.%d.total" % index, state.scoreboard[0].total,
			DictRead.as_int(case["total"]))
		index += 1

	# The two resets, which are not the same routine and were once confused.
	# `reset()` is `resetScoreboard` and wipes the campaign halves too; a
	# replay or a step to the next mission must use `reset_mission()`, or
	# pressing *Try Again* costs the player their whole campaign score.
	var carried: ScoreRecord = ScoreRecord.new()
	carried.kills = 4
	carried.losses = 1
	carried.lost_to_enemy = 1
	carried.heroes_lost = 1
	carried.score = 140
	carried.campaign_kills = 29
	carried.campaign_losses = 4
	carried.campaign_lost_to_enemy = 4
	carried.total = 259
	carried.result = ScoreRecord.RESULT_WON
	carried.reset_mission()
	h.equal("score.reset_mission.keeps_the_campaign",
		[carried.campaign_kills, carried.campaign_losses,
		carried.campaign_lost_to_enemy, carried.total], [29, 4, 4, 259])
	h.equal("score.reset_mission.clears_the_mission",
		[carried.kills, carried.losses, carried.lost_to_enemy,
		carried.heroes_lost, carried.score, carried.result],
		[0, 0, 0, 0, 0, ScoreRecord.RESULT_NOTHING],
		"every mission half, not only kills and losses")
	carried.reset()
	h.equal("score.reset.clears_everything",
		[carried.campaign_kills, carried.total], [0, 0],
		"resetScoreboard runs at campaign start and nowhere else")

	var reset: ScoreRecord = ScoreRecord.new()
	reset.kills = 9
	reset.score = 5
	reset.total = 77
	reset.result = 4
	reset.reset()
	h.equal("score.reset.kills", reset.kills, 0)
	h.equal("score.reset.total", reset.total, 0)
	h.equal("score.reset.result", reset.result, ScoreRecord.RESULT_NOTHING)


func _payouts(h: TestHarness, cases: Dictionary) -> void:
	var index: int = 0
	for entry: Variant in DictRead.as_array(cases["payouts"]):
		var case: Dictionary = entry
		var state: CampaignState = _state(cases, 2)
		state.mode = DictRead.as_int(case["mode"])
		state.equipment_points[0] = DictRead.as_int(case["purse_before"])
		state.game_control[MissionEnd.SLOT_EQUIPMENT_POINTS] = 250
		state.game_control[MissionEnd.SLOT_COMMENDATIONS] = 2
		state.scoreboard[0].result = DictRead.as_int(case["result"])
		state.scoreboard[0].lost_to_enemy = DictRead.as_int(case["lost_to_enemy"])
		var medals_before: int = state.commendations[0]
		var reports: Array[Dictionary] = MissionEnd.score(state)
		h.equal("payout.%d.points" % index,
			DictRead.as_int(reports[0]["equipment_points"]),
			DictRead.as_int(case["equipment_points"]),
			"what landed in a capped purse, not what the slot said")
		h.equal("payout.%d.commendations" % index,
			DictRead.as_int(reports[0]["commendations"]),
			DictRead.as_int(case["commendations"]))
		# `0x0043B860`'s third increment -- a unit lost to an enemy is a
		# commendation, in every mode and whatever the result.
		h.equal("payout.%d.death_medals" % index,
			[DictRead.as_int(reports[0]["death_medals"]),
				state.commendations[0] - medals_before],
			[DictRead.as_int(case["death_medals"]),
				DictRead.as_int(case["medals"])])
		h.equal("payout.%d.purse" % index, state.points(0),
			DictRead.as_int(case["purse"]))
		index += 1


## docs/27 section 2 -- the location graph, off the baked cache.
func _tables(h: TestHarness, cases: Dictionary) -> void:
	var document: Dictionary = CacheFixture.read_json(
		CacheFixture.cache_dir() + "/tables/campaign.json")
	if document.is_empty():
		h.check("tables.present", false, "tables/campaign.json is absent")
		return
	var map: CampaignMap = CampaignMap.from_document(document)
	var want: Dictionary = DictRead.as_dict(cases["tables"])

	h.equal("tables.location_bias", CampaignMap.LOCATION_BIAS,
		DictRead.as_int(want["location_bias"]))
	var names: Array = DictRead.as_array(want["map_names"])
	var matched: int = 0
	for entry: Variant in names:
		var row: Dictionary = entry
		if map.mission_of(DictRead.as_int(row["location"])) \
				== DictRead.as_string(row["mission"]):
			matched += 1
	h.equal("tables.map_names", matched, names.size())

	var graph: Array = DictRead.as_array(want["unlock_graph"])
	var graph_matched: int = 0
	for entry: Variant in graph:
		var row: Dictionary = entry
		if map.open_locations(DictRead.as_int(row["mission"])) \
				== DictRead.to_int32(row["opens"]):
			graph_matched += 1
	h.equal("tables.unlock_graph", graph_matched, graph.size())

	# `location = missionId + 50`, and `aMapName` is its exact inverse -- which
	# is a table and not a subtraction, because `_C_104` and `_C_105` cross.
	h.equal("tables.location_of", map.location_of(1), 51)
	h.equal("tables.crossed_pair",
		[map.mission_of(55), map.mission_of(58)], ["_C_105", "_C_104"])
	h.equal("tables.campaign1_start", map.open_locations(1),
		PackedInt32Array([1, 10, 51]))
	h.equal("tables.campaign2_start", map.open_locations(40),
		PackedInt32Array([90]))
	h.equal("tables.kinds",
		[map.kind_of(1), map.kind_of(10), map.kind_of(90), map.kind_of(999)],
		[CampaignMap.KIND_UPGRADE, CampaignMap.KIND_DIALOGUE,
		CampaignMap.KIND_BATTLE, CampaignMap.KIND_NONE])
	# docs/27 section 2.4 -- locations 3 and 6 load each other's map (D6).
	h.equal("tables.upgrade_3_6_crossed",
		[map.upgrade_map(3), map.upgrade_map(6)], ["upgrade_6", "upgrade_3"])
	h.equal("tables.cut_locations", map.cut_locations(),
		PackedInt32Array([85, 86, 87]))
	h.equal("tables.unreachable", map.unreachable_locations(),
		PackedInt32Array([21, 50]))

	# The chain, against every shipped header.
	var chain: Dictionary = DictRead.as_dict(cases["chain"])
	var chain_matched: int = 0
	for name: Variant in chain:
		var mission: String = name
		if map.next_map(mission) == DictRead.as_string(chain[mission]):
			chain_matched += 1
	h.equal("tables.chain", chain_matched, chain.size())
	h.equal("tables.epilogue_ends", map.next_map("_C_180"), "")
	h.equal("tables.campaign1_hands_over", map.next_map("_C_133"), "_C_YYY")
	h.equal("tables.map_of_campaign",
		[DictRead.as_string(CampaignState.CAMPAIGN_MAP[1]),
		DictRead.as_string(CampaignState.CAMPAIGN_MAP[2])],
		["_C_XXX", "_C_YYY"])


## docs/29 section 1.2 -- deployment is `action_point == player + 1`, read from
## [MapState] and not from a second list (D4).
func _deployment(h: TestHarness, cases: Dictionary) -> void:
	var wanted: Dictionary = DictRead.as_dict(cases["deployment_cells"])
	var balance: Dictionary = CacheFixture.balance()
	var checked: int = 0
	for name: String in ["_C_141", "_C_115"]:
		var document: Dictionary = CacheFixture.mission(name)
		if document.is_empty() or not wanted.has(name):
			continue
		var world: World = World.create(document, balance, 0.0)
		var got: Array[Vector2i] = world.deployment_cells(0)
		var want: Array[Vector2i] = []
		for pair: Variant in DictRead.as_array(wanted[name]):
			var xy: Array = pair
			want.append(Vector2i(DictRead.as_int(xy[0]),
				DictRead.as_int(xy[1])))
		want.sort()
		got.sort()
		h.equal("deploy.%s.cells" % name, got, want)
		checked += 1

		# One record out of a roster, onto the first cell, and the four ways it
		# is refused.
		var unit: UnitState = UnitState.new()
		unit.hp = 9
		unit.name = "Deployed"
		unit.pool_flag = Roster.POOL_CANDIDATE
		unit.type_id = 0
		var before: int = world.unit_slots().size()
		var cell: Vector2i = want[0]
		var placed: Dictionary = world.deploy_from_pool(0, unit, cell.x, cell.y)
		h.equal("deploy.%s.result" % name,
			DictRead.as_string(placed["result"]), World.DEPLOY_OK)
		h.equal("deploy.%s.added_a_unit" % name,
			world.unit_slots().size(), before + 1)
		var slot: int = DictRead.as_int(placed["slot"])
		var view: Dictionary = world.unit_view(slot)
		h.equal("deploy.%s.at_the_cell" % name,
			[DictRead.as_int(view["x"]), DictRead.as_int(view["y"])],
			[cell.x, cell.y])
		h.equal("deploy.%s.is_ours" % name, DictRead.as_int(view["player"]), 0)
		# `0x00478DD1` -- the full recompute deployment runs. A roster record
		# carries no magazine of its own, so without it the whole squad lands
		# with an empty weapon and `_C_100` cannot be played at all.
		var wtab: WeaponTable = world.weapons()
		h.equal("deploy.%s.magazine" % name, DictRead.as_int(view["ammo"]),
			wtab.magazine_for(DictRead.as_int(view["weapon"]), false),
			"weapon %d's mun" % DictRead.as_int(view["weapon"]))
		h.check("deploy.%s.magazine_is_not_zero" % name,
			DictRead.as_int(view["ammo"]) > 0,
			"%d rounds" % DictRead.as_int(view["ammo"]))
		h.equal("deploy.%s.healed" % name, DictRead.as_int(view["hp"]),
			world.max_hit_points(slot),
			"the recompute fills the hit points to the ceiling")
		# The fifth argument, `aUI_SetUnit(x, y, record, facing)` at
		# `0x00478D6B`: the place interface's quadrant facing lands on the
		# record; a caller with none to give keeps the record's own.
		h.equal("deploy.%s.keeps_the_records_facing" % name,
			DictRead.as_int(view["facing"]), unit.facing)
		if want.size() >= 2:
			var faced: Dictionary = world.deploy_from_pool(0, unit,
				want[1].x, want[1].y, 5)
			h.equal("deploy.%s.faced_result" % name,
				DictRead.as_string(faced["result"]), World.DEPLOY_OK)
			h.equal("deploy.%s.faced" % name, DictRead.as_int(
				world.unit_view(DictRead.as_int(faced["slot"]))["facing"]), 5)
			# `aTransferUnitFromMapToPool` `0x00478F20`, minus the pool
			# insertion: the record comes back and the cell is free again.
			var taken: Dictionary = world.recall_from_map(0, want[1].x,
				want[1].y)
			h.equal("deploy.%s.recalled" % name,
				DictRead.as_string(taken["result"]), World.RECALL_OK)
			var back_record: UnitState = taken["record"]
			h.check("deploy.%s.recalled_record" % name,
				back_record != null and back_record.name == "Deployed"
				and back_record.facing == 5,
				"the record as it stood on the map")
			h.equal("deploy.%s.recall_freed_the_cell" % name,
				DictRead.as_int(world.cell_view(want[1].x, want[1].y)["unit"]),
				MapState.NO_UNIT)
			h.equal("deploy.%s.recall_nobody" % name,
				DictRead.as_string(world.recall_from_map(0, want[1].x,
					want[1].y)["result"]), World.RECALL_NO_UNIT)
		# `0x00463485`: only a pool candidate comes back; a mission's own
		# soldier stays where the `.lev` put him.
		var kept: UnitState = UnitState.new()
		kept.hp = 9
		kept.name = "Kept"
		kept.pool_flag = 0
		kept.type_id = 0
		var kept_cell: Vector2i = want[want.size() - 1]
		var kept_placed: Dictionary = world.deploy_from_pool(0, kept,
			kept_cell.x, kept_cell.y)
		if DictRead.as_string(kept_placed["result"]) == World.DEPLOY_OK:
			h.equal("deploy.%s.recall_refuses_a_non_candidate" % name,
				DictRead.as_string(world.recall_from_map(0, kept_cell.x,
					kept_cell.y)["result"]), World.RECALL_NOT_A_CANDIDATE)
			h.check("deploy.%s.non_candidate_stays" % name,
				DictRead.as_int(world.cell_view(kept_cell.x,
					kept_cell.y)["unit"]) != MapState.NO_UNIT)
			h.equal("deploy.%s.recall_refuses_another_player" % name,
				DictRead.as_string(world.recall_from_map(1, kept_cell.x,
					kept_cell.y)["result"]), World.RECALL_NOT_YOURS)

		h.equal("deploy.%s.cell_taken" % name,
			DictRead.as_string(world.deploy_from_pool(
				0, unit, cell.x, cell.y)["result"]), World.DEPLOY_CELL_TAKEN)
		h.equal("deploy.%s.not_a_cell" % name,
			DictRead.as_string(world.deploy_from_pool(
				0, unit, 0, 0)["result"]), World.DEPLOY_NOT_A_CELL)
		h.equal("deploy.%s.empty_record" % name,
			DictRead.as_string(world.deploy_from_pool(
				0, UnitState.new(), cell.x, cell.y)["result"]),
			World.DEPLOY_EMPTY_RECORD)

		# And back out: the survivors the debriefing judges.
		var survivors: Array[UnitState] = world.survivors_of(0)
		h.check("deploy.%s.survivors" % name, survivors.size() >= 1,
			"%d unit(s) of player 0" % survivors.size())
		# `0x00478EA1` -- recovery runs the same full recompute, so a survivor
		# reaches the pool healed to the ceiling and reloaded. That is what the
		# fixture saves show: `_31_.sav` holds Sgt. Bratt at `hp 11` (his
		# exact ceiling) with `ammo 10`, weapon 2's magazine.
		if survivors.size() >= 1:
			var back: UnitState = survivors[0]
			h.equal("deploy.%s.recovered_ammo" % name, back.ammo,
				wtab.magazine_for(back.weapon, false))
			h.equal("deploy.%s.recovered_hp" % name, back.hp,
				Interact.max_hit_points(world.unit_types(), back),
				"the recompute heals a survivor on the way out")
		var removed: int = world.clear_units_of(0)
		h.check("deploy.%s.cleared" % name, removed >= 1,
			"%d taken off the map" % removed)
	h.check("deploy.missions_checked", checked == 2,
		"%d of 2 slice missions read from the cache" % checked)


func _codec(h: TestHarness, cases: Dictionary) -> void:
	var state: CampaignState = _state(cases, 1)
	state.roster.snapshot()
	state.difficulty = 2
	state.mission = "_C_105"
	state.scoreboard[0].total = 119
	var digest: String = state.digest_hex()

	var blob: PackedByteArray = CampaignCodec.encode(state)
	var decoded: Dictionary = CampaignCodec.decode(blob)
	h.equal("codec.round_trip", DictRead.as_int(decoded["result"]),
		CampaignCodec.Result.OK)
	var back: CampaignState = decoded["state"]
	h.equal("codec.digest", back.digest_hex(), digest)
	h.equal("codec.mission", back.mission, "_C_105")
	h.equal("codec.roster", back.roster.used_slots(), 3)
	h.equal("codec.snapshot", back.roster.used_slots(Roster.ROW_SNAPSHOT), 3)
	var empty_blob: PackedByteArray = DictRead.to_bytes(decoded["mission"])
	h.equal("codec.no_mission_blob", empty_blob.size(), 0)

	# A mission save rides inside, opaque: `SaveCodec` refuses a blob whose map
	# name is not the world's, which is right for a mission and wrong for a
	# campaign, so the container never opens it (D10).
	var payload: PackedByteArray = PackedByteArray([1, 2, 3, 4, 5])
	var nested: Dictionary = CampaignCodec.decode(
		CampaignCodec.encode(state, payload))
	h.equal("codec.nested_blob", nested["mission"], payload)

	# The four refusals, each a different answer.
	h.equal("codec.truncated",
		DictRead.as_int(CampaignCodec.decode(
			PackedByteArray([1, 2, 3]))["result"]),
		CampaignCodec.Result.TRUNCATED)
	var wrong_magic: PackedByteArray = blob.duplicate()
	wrong_magic[0] = 0x58
	h.equal("codec.bad_magic",
		DictRead.as_int(CampaignCodec.decode(wrong_magic)["result"]),
		CampaignCodec.Result.BAD_MAGIC)
	var corrupted: PackedByteArray = blob.duplicate()
	corrupted[blob.size() - 1] ^= 0xFF
	h.equal("codec.bad_digest",
		DictRead.as_int(CampaignCodec.decode(corrupted)["result"]),
		CampaignCodec.Result.BAD_DIGEST)
	var bad_schema: PackedByteArray = blob.duplicate()
	bad_schema[4] = 0x7F
	h.equal("codec.bad_schema",
		DictRead.as_int(CampaignCodec.decode(bad_schema)["result"]),
		CampaignCodec.Result.BAD_DIGEST,
		"a schema byte is inside the digest, so corruption is reported first")


## `+0x38` is a new field, and a new field is a field every copy can drop.
##
## It is appended to [method UnitState.hash_into] only when it is non-zero, so
## a mission's pinned hash cannot move -- but the moment a commended soldier
## stands on a map, the hash *does* carry it, and every path that copies a
## record field by field instead of through [method UnitState.view] would make
## the mirror disagree with the world and a save refuse its own digest.
func _decorations_survive(h: TestHarness, cases: Dictionary) -> void:
	var state: CampaignState = _state(cases, 1)
	var slots: PackedInt32Array = state.roster.occupied_slots()
	if slots.is_empty():
		h.check("decor.roster", false, "the seed roster is empty")
		return
	state.commendations[0] = 1
	var decorated: UnitState = state.roster.record(slots[0])
	decorated.ep = Upgrade.DECORATION_TIERS[0]
	decorated.tp = 0
	decorated.pool_flag = 1
	state.roster.put(slots[0], decorated)
	h.check("decor.commend", state.commend(0, slots[0]), "the award is allowed")
	h.equal("decor.awarded", state.roster.record(slots[0]).decorations, 1)

	var digest: String = state.digest_hex()
	var decoded: Dictionary = CampaignCodec.decode(CampaignCodec.encode(state))
	h.equal("decor.codec_ok", DictRead.as_int(decoded["result"]),
		CampaignCodec.Result.OK)
	var back: CampaignState = decoded["state"]
	h.equal("decor.codec_digest", back.digest_hex(), digest)
	h.equal("decor.codec_field", back.roster.record(slots[0]).decorations, 1)

	# And the same record on a map: the clone, the delta mirror and the save.
	var document: Dictionary = CacheFixture.mission("_C_140")
	if document.is_empty():
		h.check("decor.mission", false,
			"no _C_140: " + CacheFixture.missing_hint())
		return
	var world: World = World.create(document, CacheFixture.balance(), 0.0)
	var live: Dictionary = world.units_for_ai()
	var placed: int = -1
	for slot: int in world.unit_slots():
		var unit: UnitState = live[slot]
		if unit.player == 0 and unit.is_alive():
			placed = slot
			break
	if placed < 0:
		h.check("decor.placed", false, "_C_140 places no live player-0 unit")
		return
	var plain: String = world.canonical_hash_hex()
	var plain_blob: PackedByteArray = world.save({})
	var marine: UnitState = live[placed]
	marine.decorations = 2
	var carried: String = world.canonical_hash_hex()
	h.check("decor.hashed", carried != plain,
		"a non-zero decoration count is inside the canonical hash")
	h.equal("decor.clone", world.clone().canonical_hash_hex(), carried,
		"World.clone copies through view(), so the mirror agrees")

	# **Two reloads and not one measured value.** `load_save` ends with a
	# visibility pass (`0x004490A9`), so a save reloaded into a world that has
	# never had one does not come back at the saving world's own hash -- which
	# is true of every mission and has nothing to do with this field. The A/B
	# is what isolates it: the same route twice, once with the decoration.
	var control: World = World.create(document, CacheFixture.balance(), 0.0)
	h.equal("decor.save_control_ok",
		SaveCodec.result_name(control.load_save(plain_blob)), "OK")
	var reloaded: World = World.create(document, CacheFixture.balance(), 0.0)
	h.equal("decor.save_ok",
		SaveCodec.result_name(reloaded.load_save(world.save({}))), "OK")
	h.equal("decor.save_field",
		DictRead.as_int(reloaded.unit_view(placed)["decorations"]), 2,
		"SaveCodec stores the whole view, so the field comes back")
	h.check("decor.save_hash",
		reloaded.canonical_hash_hex() != control.canonical_hash_hex(),
		"and the reloaded world hashes as the decorated one")


## D7 -- the campaign layer must not move [World]'s canonical hash.
func _pinned_hashes(h: TestHarness) -> void:
	var balance: Dictionary = CacheFixture.balance()
	for name: String in PINNED_HASHES:
		var document: Dictionary = CacheFixture.mission(name)
		if document.is_empty():
			h.check("hash.%s.present" % name, false, "not in the cache")
			continue
		var world: World = World.create(document, balance, 0.0)
		h.equal("hash.%s" % name, world.canonical_hash_hex(),
			DictRead.as_string(PINNED_HASHES[name]),
			"measured before this slice; D7 says it does not move")


## The two openings of a mission -- docs/98 section 12.
##
## Neither is reachable from `core` alone in the game: `SliceMain._build`
## chooses the arm and the deployment screen's *Continue* takes the other. But
## both are `World`'s own methods, and what they decide -- the turn a mission
## is played from, and whether `NEXT TURN` runs before the player's first
## command -- is exactly the kind of claim that would otherwise be verified by
## hand once and quietly broken. `_C_106` is the mission that shows it: its
## `NEXT TURN` is `Platform (19,2,2,11)`, gated on an action point the `.lev`
## arrives with, so the whole difference between the two arms is visible in
## three cells.
const OPENING_MISSION: String = "_C_106"
## The platform's centre before the ride and after it -- `Platform (19,2,2,11)`
## is direction 2 (south) by eleven tiles.
const PLATFORM_FROM: Vector2i = Vector2i(19, 2)
const PLATFORM_TO: Vector2i = Vector2i(19, 13)
## docs/10 section 4.2 -- what the ride leaves behind, and what it lands on.
const CTRL_FREE_PLACE: int = 1
const CTRL_DEEP_HOLE: int = 4


func _mission_opening(h: TestHarness) -> void:
	var balance: Dictionary = CacheFixture.balance()
	var document: Dictionary = CacheFixture.mission(OPENING_MISSION)
	if document.is_empty() or balance.is_empty():
		h.check("opening.present", false,
			"no %s: %s" % [OPENING_MISSION, CacheFixture.missing_hint()])
		return

	# **The loader leaves turn 0**, which is the deployment phase and not a
	# turn anybody takes.
	var silent: World = World.create(document, balance, 0.0)
	h.equal("opening.loader_turn", silent.turn.turn, 0)

	# The arm a mission with nobody to place takes: turn 1, no script. The
	# hand-over comes **first**, as [SliceMain] runs them and as the engine
	# does -- its one-shot zeroes the counter, so a 1 written ahead of it
	# would not survive.
	var attached_silent: bool = silent.attach_script(
		CacheFixture.script_document(OPENING_MISSION))
	h.check("opening.script_attached", attached_silent,
		"%s carries a program" % OPENING_MISSION)
	var opened: TurnResult = silent.open_mission()
	silent.skip_deployment_turn()
	h.equal("opening.silent_turn", silent.turn.turn, TurnState.FIRST_TURN)
	silent.skip_deployment_turn()
	h.equal("opening.silent_is_idempotent", silent.turn.turn,
		TurnState.FIRST_TURN,
		"the engine's guard is `turnCounter() == 0`, so the second entry to "
		+ "aInitBattleGround does nothing")
	# **The hand-over does not undo the counter**, which is the whole reason
	# the order is what it is: a world that took the two the other way round
	# comes out on turn 0, because `_first_hand_over` mirrors
	# `resetGameControl`.
	var reversed: World = World.create(document, balance, 0.0)
	reversed.skip_deployment_turn()
	var _reversed_opened: TurnResult = reversed.open_mission()
	h.equal("opening.reset_zeroes_the_counter", reversed.turn.turn, 0,
		"0x0043B770's `mov byte [0x509E1D], bl`, which is why "
		+ "aInitBattleGround's setTurn(1) runs after the view player's init")
	h.equal("opening.silent_code", opened.code, TurnResult.OK)
	h.equal("opening.silent_player", silent.turn.current_player, 0)
	h.equal("opening.silent_turn_after", silent.turn.turn,
		TurnState.FIRST_TURN)
	h.check("opening.silent_ran_no_script",
		not opened.ran_turn_script and not opened.ran_player_script,
		"handOver(1) raises neither event")
	h.equal("opening.silent_platform_stayed",
		silent.state.field_type_at(
			silent.state.index_of(PLATFORM_FROM.x, PLATFORM_FROM.y)),
		CTRL_FREE_PLACE,
		"no NEXT TURN, so the platform is where the .lev left it")

	# The other arm: a squad deployed, then the hand-over that leaving the
	# deployment screen makes.
	var played: World = World.create(document, balance, 0.0)
	var _swept: int = played.load_sweep()
	var attached: bool = played.attach_script(
		CacheFixture.script_document(OPENING_MISSION))
	h.check("opening.deployed_script_attached", attached)
	var cells: Array[Vector2i] = played.deployment_cells(0)
	h.check("opening.deployment_cells", cells.size() == 5,
		"%s has five landing cells, all on the platform" % OPENING_MISSION)
	if cells.is_empty():
		return
	var record: UnitState = UnitState.new()
	record.hp = 9
	record.name = "Deployed"
	record.pool_flag = Roster.POOL_CANDIDATE
	record.type_id = 0
	var placed: Dictionary = played.deploy_from_pool(0, record,
		cells[0].x, cells[0].y)
	h.equal("opening.deployed", DictRead.as_string(placed["result"]),
		World.DEPLOY_OK)
	var rider: int = DictRead.as_int(placed["slot"])
	var _first: TurnResult = played.open_mission()
	h.equal("opening.deployed_stays_at_zero", played.turn.turn, 0,
		"handOver(1) does not advance the counter")
	h.check("opening.deploying_at_zero", played.deploying(),
		"fcn.00463380's gate is the counter alone")

	var handed: TurnResult = played.submit_end_turn(EndTurnCommand.create())
	h.equal("opening.handed_code", handed.code, TurnResult.OK)
	h.equal("opening.handed_turn", played.turn.turn, TurnState.FIRST_TURN,
		"the rotation passes through the computer's seat and comes back")
	h.equal("opening.handed_player", played.turn.current_player, 0)
	h.check("opening.not_deploying_at_one", not played.deploying())
	h.check("opening.handed_ran_turn_script", handed.ran_turn_script,
		"which is the NEXT TURN the platform rides on")
	h.check("opening.handed_no_ai", handed.ai_result == null,
		"0x0047D600 runs aAISystemControl only when the counter is not 0")
	h.equal("opening.platform_left",
		played.state.field_type_at(
			played.state.index_of(PLATFORM_FROM.x, PLATFORM_FROM.y)),
		CTRL_DEEP_HOLE, "the vacated cells are deep holes")
	h.equal("opening.platform_arrived",
		played.state.field_type_at(
			played.state.index_of(PLATFORM_TO.x, PLATFORM_TO.y)),
		CTRL_FREE_PLACE)
	var carried: Dictionary = played.unit_view(rider)
	h.equal("opening.rider_carried",
		[DictRead.as_int(carried["x"]), DictRead.as_int(carried["y"])],
		[cells[0].x, cells[0].y + (PLATFORM_TO.y - PLATFORM_FROM.y)],
		"the ride relocates its riders before it copies the cells")


## docs/27 section 6.6, corrected 2026-09-08: `_C_133` hands over to `_C_YYY`,
## whose header carries mission id **255** -- the animated extro, not campaign
## 2 -- and `_C_179` to `_C_180`, id 180, the static one. Both are mission
## rows, so [method CampaignHost.advance] lands on them and the gate at the
## map's entry plays the ending instead of a map (docs/92 section 7.19).
func _endings(h: TestHarness) -> void:
	var host: CampaignHost = CampaignHost.create(CacheFixture.cache_dir(),
		CacheFixture.balance())
	var defeated: CampaignState = host.start_new(2)
	var defeated_world: World = World.create(
		CacheFixture.mission("_C_140"), CacheFixture.balance(), 0.0)
	var squad_before_defeat: int = 0
	for slot: int in defeated_world.unit_slots():
		var view: Dictionary = defeated_world.unit_view(slot)
		if DictRead.as_int(view["player"]) == 0 \
				and DictRead.as_int(view["hp"]) > 0:
			squad_before_defeat += 1
	defeated_world.game_control.set_slot(4, 1)
	host.begin_mission(defeated_world)
	var defeat_report: Dictionary = host.finish_mission(defeated_world)
	h.equal("endings.defeat_reaches_the_report",
		DictRead.as_int(defeat_report["result"]), ScoreRecord.RESULT_DEFEAT)
	h.equal("endings.forfeit_keeps_the_squad",
		[DictRead.as_int(defeat_report["losses"]),
			DictRead.as_array(defeat_report["recovered"]).size(),
			DictRead.as_array(defeat_report["lost"]).size(),
			defeated.roster.used_slots()],
		[0, squad_before_defeat, 0, squad_before_defeat],
		"the ordinary defeat lifecycle recovers every surviving unit")
	var refused: String = host.advance()
	h.equal("endings.defeat_does_not_advance",
		[refused, defeated.mission, host.screen],
		["", "_C_140", CampaignHost.SCREEN_DEBRIEFING],
		"a loss may be retried, but it cannot unlock the next mission")

	var won: CampaignState = host.start_new(2)
	var won_world: World = World.create(
		CacheFixture.mission("_C_140"), CacheFixture.balance(), 0.0)
	won_world.game_control.set_slot(0, 1)
	host.begin_mission(won_world)
	var win_report: Dictionary = host.finish_mission(won_world)
	h.equal("endings.victory_reaches_the_report",
		DictRead.as_int(win_report["result"]), ScoreRecord.RESULT_WON)
	var advanced: String = host.advance()
	h.equal("endings.victory_still_advances",
		[advanced, won.mission, host.screen],
		["_C_141", "_C_141", CampaignHost.SCREEN_MAP])

	# *Try Again* after a win undoes the debriefing's payout as well as its
	# score (docs/92 section 7.13, D13): a replayed win used to be paid twice.
	var again: CampaignState = host.start_new(2)
	var paid_world: World = World.create(
		CacheFixture.mission("_C_140"), CacheFixture.balance(), 0.0)
	paid_world.game_control.set_slot(0, 1)
	paid_world.game_control.set_slot(MissionEnd.SLOT_EQUIPMENT_POINTS, 120)
	paid_world.game_control.set_slot(MissionEnd.SLOT_COMMENDATIONS, 2)
	var purse_before: int = again.equipment_points[0]
	var medals_before: int = again.commendations[0]
	var total_before: int = again.scoreboard[0].total
	host.begin_mission(paid_world)
	# Two soldiers lost to the enemy: `0x0043B860` pays a commendation for
	# each at the death, beside the slot-11 medals the debriefing pays.
	paid_world.turn.mission_lost_to_enemy[0] = 2
	paid_world.turn.mission_lost[0] = 2
	var paid_report: Dictionary = host.finish_mission(paid_world)
	h.equal("endings.the_debriefing_pays",
		[DictRead.as_int(paid_report["equipment_points"]),
			DictRead.as_int(paid_report["death_medals"]),
			again.equipment_points[0] - purse_before,
			again.commendations[0] - medals_before,
			again.scoreboard[0].campaign_lost_to_enemy],
		[120, 2, 120, 4, 2])
	var replayed: String = host.replay()
	h.equal("endings.replay_takes_the_payout_back",
		[replayed, again.equipment_points[0], again.commendations[0],
			again.scoreboard[0].total,
			again.scoreboard[0].campaign_lost_to_enemy, host.screen],
		["_C_140", purse_before, medals_before, total_before, 0,
			CampaignHost.SCREEN_MAP],
		"`0x0043BBD0` takes the score, the pairs and the death medals off; "
		+ "the remake's D13 takes the payout too; the roster restore is "
		+ "`aCopyUnitPool(1, 0)`'s")
	h.equal("endings.no_world_outlives_the_replay",
		host.deployment_cells().size(), 0)
	# **Abandoning is the same do-over.** The engine has no way to leave a
	# mission short of its debriefing (the pause menu's *Main Map* is the
	# remake's, docs/92 section 7.15), so what its bookkeeping says about a
	# sortie that does not count is `0x0045E9CB`: the roster back and the
	# mission's pairs and death medals off. Folding the mission's counters
	# only at the debriefing gives an abandoned sortie exactly that net --
	# the campaign state after *Try Again* and after *Main Map* is one state.
	# (The LCL slots are the one field apart: the debriefing copies the
	# mission's script slots into the campaign, an abandoned sortie never
	# gets that far, and neither the scoreboard nor the purse reads them.)
	var replayed_view: Dictionary = again.view()
	var _slots: bool = replayed_view.erase("game_control")
	var dropped: CampaignState = host.start_new(2)
	var dropped_world: World = World.create(
		CacheFixture.mission("_C_140"), CacheFixture.balance(), 0.0)
	dropped_world.game_control.set_slot(0, 1)
	dropped_world.game_control.set_slot(MissionEnd.SLOT_EQUIPMENT_POINTS, 120)
	dropped_world.game_control.set_slot(MissionEnd.SLOT_COMMENDATIONS, 2)
	host.begin_mission(dropped_world)
	dropped_world.turn.mission_lost_to_enemy[0] = 2
	dropped_world.turn.mission_lost[0] = 2
	dropped_world.turn.mission_kills[0] = 5
	host.abandon_mission()
	var dropped_view: Dictionary = dropped.view()
	var _dropped_slots: bool = dropped_view.erase("game_control")
	h.equal("endings.abandon_is_the_replays_net",
		[dropped_view == replayed_view, dropped.commendations[0],
			dropped.scoreboard[0].campaign_kills, host.screen],
		[true, medals_before, 0, CampaignHost.SCREEN_MAP],
		"no medal, kill or loss of a dropped sortie reaches the campaign, "
		+ "which is what `0x0043BBD0` leaves after a replay")
	# ...nor an *End game*, nor a new campaign: the HQ printed the last
	# mission's landing-cell count off a world nobody had dropped.
	host.begin_mission(paid_world)
	h.check("endings.a_begun_mission_answers_cells",
		host.deployment_cells().size() > 0)
	host.end()
	h.equal("endings.end_drops_the_world",
		[host.state == null, host.deployment_cells().size(), host.location],
		[true, 0, 0])
	var _fresh: CampaignState = host.start_new(2)
	host.begin_mission(paid_world)
	var _next: CampaignState = host.start_new(2)
	h.equal("endings.a_new_campaign_drops_the_world",
		host.deployment_cells().size(), 0)

	var state: CampaignState = host.start_new(1)
	state.mission = "_C_133"
	host.last_report = {"result": ScoreRecord.RESULT_WON}
	var target: String = host.advance()
	h.equal("endings.chain_1_ends_at_yyy", [target, state.mission,
		host.tables.mission_id(target), host.at_an_ending()],
		["_C_YYY", "_C_YYY", 255, true])
	h.equal("endings.yyy_opens_the_animated_extro",
		DictRead.as_string(host.opening_sequence()["kind"]),
		CampaignHost.OPENING_EXTRO)
	var second: CampaignState = host.start_new(2)
	second.mission = "_C_179"
	host.last_report = {"result": ScoreRecord.RESULT_WON}
	var last: String = host.advance()
	h.equal("endings.chain_2_ends_at_180", [last, host.tables.mission_id(last),
		host.at_an_ending()], ["_C_180", 180, true])
	h.equal("endings.180_opens_the_static_extro",
		DictRead.as_string(host.opening_sequence()["kind"]),
		CampaignHost.OPENING_STATIC_EXTRO)
	h.check("endings.no_next_map_past_an_ending",
		host.tables.next_map("_C_YYY") == "" and host.tables.next_map("_C_180") == "")
