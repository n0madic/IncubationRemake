class_name Visibility
extends RefCounted

## `aBuildVisibleMap` (`0x004798C0`) and its per-unit pass, from docs/22
## section 9.
##
## **Everything is hidden first and then revealed**, so visibility is recomputed
## from scratch on every call: there is no incremental fog state to persist,
## which is why a save carries only `+0x4F` and not a fog map.
##
## **Vision and fire are different tests.**  Vision measures from the *full*
## height at both ends and accepts 254 -- a unit standing in the way blocks a
## shot but not the sight of it.  Getting this wrong makes an enemy behind a
## crate invisible instead of merely unshootable.

## docs/22 section 9.1 -- `+0x4F`.
const FULL: int = 0
const CONTACT: int = 1
const HIDDEN: int = 3

## docs/22 section 9.2 -- permanently visible whatever the fog says.
const ALWAYS_VISIBLE_TYPES: Array[int] = [0x3D, 0x3E, 0x3F]
## The two of those three the per-unit pass also reveals to *everyone*.
const BEACON_TYPES: Array[int] = [0x3D, 0x3E]
const SPECIES_OBJECT: int = 2

## docs/22 section 9.3 -- equipment 0 and 1, and their ranges.
const EQUIP_SCAN_MODULE: int = 0
const EQUIP_LONG_RANGE_SCAN: int = 1
const SCAN_RANGE: int = 6
const LONG_SCAN_RANGE: int = 8

## docs/22 section 9.3 -- seeing a neutral unit on one of these orders wakes its
## whole AI group.
const ALERTING_ORDERS: Array[int] = [5, 6, 8]


## `aSetVisibleStateForUnit` -- the only writer of `+0x4F`.
##
## State 2 is accepted and ignored; there is no fourth state.
static func set_state(unit: UnitState, state: int) -> bool:
	if not unit.is_alive():
		return false
	if state == FULL or state == CONTACT or state == HIDDEN:
		unit.visibility = state
		return true
	return false


## `0x0047A810` -- promote the secondary order for a whole AI group.
##
## Copies `+0x49`/`+0x4A` over `+0x47`/`+0x48`, which is what the secondary
## order in docs/10 section 5.6 is *for*.  Returns how many units woke.
static func alert_group(units: Dictionary, group: int) -> int:
	var woken: int = 0
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		if unit.is_alive() and unit.group == group:
			unit.order = unit.order2
			unit.order_param = unit.order2_param
			woken += 1
	return woken


## `aBuildVisibleMapForUnit(observer, x, y, &saw)` `0x004794B0` -- one
## observer's pass, **standing on `(x, y)`**.
##
## The cell is an argument, not the observer's record: `aExecuteMove` asks
## it from the walk's destination before the first step (`0x0046E330`), and
## the line of sight starts at that cell's height plus the observer's full
## height. Every call **writes** -- each unit of another player in sight goes
## to [constant FULL], and a computer unit on one of [constant ALERTING_ORDERS]
## wakes its group -- and the return value is only whether anything was seen.
## All six call sites in `Incubation.exe` are this writing pass; the engine
## has no query form of it. The scanner arm measures its distance from the
## asked cell too (`0x0047969C`).
##
## `wake` is called with an AI group id; pass an empty [Callable] to run the
## pass without waking anybody, which only [method states_for] wants -- see
## there for why.
static func for_unit(state: MapState, units: Dictionary, utab: UnitTypeTable,
		observer: UnitState, x: int, y: int, human_players: int,
		game_mode: int, wake: Callable) -> bool:
	var scan: int = 0
	if observer.has_equipment(EQUIP_SCAN_MODULE):
		scan = 1
	if observer.has_equipment(EQUIP_LONG_RANGE_SCAN):
		scan = 2

	var saw: bool = false
	var oz: int = HitChance.full_height(utab, observer.type_id) \
		+ state.height_at(state.index_of(x, y))
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		if not unit.is_alive():
			continue
		if BEACON_TYPES.has(unit.type_id):
			set_state(unit, FULL)
			continue
		if unit.player == observer.player:
			continue
		if utab.species(unit.type_id) == SPECIES_OBJECT:
			continue

		var uz: int = HitChance.full_height(utab, unit.type_id) \
			+ state.height_at(state.index_of(unit.x, unit.y))
		var block: int = LineOfSight.check(state, units, utab, x, y, oz,
			unit.x, unit.y, uz, 1, human_players, game_mode)
		if block < LineOfSight.TERRAIN:
			saw = true
			set_state(unit, FULL)
			if (unit.player == UnitState.PLAYER_ALIEN
					and ALERTING_ORDERS.has(unit.order) and wake.is_valid()):
				wake.call(unit.group)
		elif unit.visibility != FULL:
			var d: int = MoveMap.distance(x, y, unit.x, unit.y)
			if scan >= 1 and d < SCAN_RANGE:
				set_state(unit, FULL if scan == 2 else CONTACT)
			elif scan == 2 and d < LONG_SCAN_RANGE:
				set_state(unit, CONTACT)

	# The second pass, and it is **this routine's**, not the whole fog pass's
	# (`0x00479786`..`0x00479861`, before the `ret` at `0x0047989A`): a
	# still-hidden neutral unit is promoted to a contact unless one of its
	# eight neighbours already is one -- one blip per cluster. So every
	# per-unit pass runs it, `aExecuteMove`'s three included, which is how a
	# computer mover that walks unseen with the *Enemy Move* option off comes
	# out of its own arrival pass as a contact (`turn_gold.py`, `mode3_off`).
	#
	# **Order-dependent, and deliberately so.**  A promotion made earlier in
	# this loop is visible to the neighbour test of a later one, so the
	# iteration order is part of the answer.  `units` is walked in insertion
	# order, which is slot order, exactly as the engine's 200-slot scan is.
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		if (not unit.is_alive() or unit.visibility != HIDDEN
				or unit.player != UnitState.PLAYER_ALIEN):
			continue
		var neighbour_contact: bool = false
		for dy: int in [-1, 0, 1]:
			for dx: int in [-1, 0, 1]:
				if dx == 0 and dy == 0:
					continue
				var nx: int = unit.x + dx
				var ny: int = unit.y + dy
				if not state.in_bounds(nx, ny):
					continue
				var other_slot: int = state.unit_at(state.index_of(nx, ny))
				if other_slot < 0 or not units.has(other_slot):
					continue
				var other: UnitState = units[other_slot]
				if other.is_alive() and other.visibility == CONTACT:
					neighbour_contact = true
		if not neighbour_contact:
			set_state(unit, CONTACT)
	return saw


## [method for_unit] as the engine calls it outside the whole fog pass: the
## writes, **and** the groups it alerts woken on the spot (`0x0047A810` is
## unconditional inside `0x004794B0`). This is the pass `aExecuteMove` runs
## three times per walk ([method ExecuteMove.execute]).
static func look_from(state: MapState, units: Dictionary, utab: UnitTypeTable,
		observer: UnitState, x: int, y: int, human_players: int,
		game_mode: int) -> bool:
	# A local lambda for the reason [method build] gives.
	var wake: Callable = func(group: int) -> void:
		alert_group(units, group)
	return for_unit(state, units, utab, observer, x, y, human_players,
		game_mode, wake)


## `aBuildVisibleMap` `0x004798C0` -- the whole fog pass for one player.
##
## Writes `+0x4F` on every unit and wakes the AI groups the pass alerts. For
## the answer *without* either, see [method states_for].
static func build(state: MapState, units: Dictionary, utab: UnitTypeTable,
		player: int, human_players: int, game_mode: int) -> void:
	# **A local lambda, never a stored one.**  A [Callable] that captured
	# `units` and was then stored anywhere reachable from `units` is a
	# RefCounted cycle, which Godot reports only as "resources still in use at
	# exit".  This one dies with the call.
	var wake: Callable = func(group: int) -> void:
		alert_group(units, group)
	_pass(state, units, utab, player, human_players, game_mode, wake)


## What the pass *would* say, without the pass having happened.
##
## `0x00481F00` -- `lNetwork.cpp:1461`, the routine `aViewPlayer.cpp`'s command
## dispatcher calls before every player command -- does exactly this: it saves
## all 200 units' `+0x4F` (`0x00479AA0`, into the 200-byte buffer at
## `0x51F1D8`), calls `aBuildVisibleMap` for the current player, reads the cell
## it was asked about, and then puts every `+0x4F` back (`0x00479AC0`). The fog
## the *rules* see is therefore still the one the last hand-over left; the fog
## the *player* sees is recomputed on every command.
##
## That asymmetry is not an accident of this remake, it is the engine's:
## `aSetVisibleStateForUnit` writes both `+0x4F` **and** the 3D object's
## `+0x40` (1 solid / 3 blip / 2 absent, docs/22 section 9.1), and the save and
## restore cover only the first. So what is drawn follows the probe and what
## the AI and the rules read does not.
##
## **No group is woken here.** This is a query and stays one; the wake the
## engine's probe leaves behind is [method World.probe_fog]'s, run once per
## player command where `aViewPlayer.cpp` runs it (docs/97 section 34).
##
## Returns slot -> `+0x4F`, and leaves every `+0x4F` exactly as it found it.
## `at` answers the pass for units standing **where the picture draws them**
## rather than where the state has them, slot to cell.
##
## The picture is a lagging mirror: a body crossing a field is between the
## cell its walk started on and the one its delta will put it on, and asking
## the fog about the stale cell is what made an alien that stepped into the
## squad's sight stay a contact beam until the turn changed -- attacking as a
## beam, because the fight clip had no body to play on (docs/100 section 4).
## Only the **observed** position moves: an override never changes who is
## looking, and it is put back before this returns, so this stays a query.
static func states_for(state: MapState, units: Dictionary,
		utab: UnitTypeTable, player: int, human_players: int,
		game_mode: int,
		at: Dictionary[int, Vector2i] = {}) -> Dictionary[int, int]:
	var saved: Dictionary[int, int] = {}
	var placed: Dictionary[int, Vector2i] = {}
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		saved[unit.slot] = unit.visibility
		if at.has(unit.slot) and state.in_bounds(at[unit.slot].x,
				at[unit.slot].y):
			placed[unit.slot] = Vector2i(unit.x, unit.y)
			unit.x = at[unit.slot].x
			unit.y = at[unit.slot].y
	_pass(state, units, utab, player, human_players, game_mode, Callable())
	var seen: Dictionary[int, int] = {}
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		seen[unit.slot] = unit.visibility
		unit.visibility = saved[unit.slot]
		if placed.has(unit.slot):
			unit.x = placed[unit.slot].x
			unit.y = placed[unit.slot].y
	return seen


## `0x00481F00` -- the engine's per-command probe, wake and all.
##
## It saves every `+0x4F`, runs the pass **with** the wake, and restores the
## bytes: the restore covers `+0x4F` and nothing else, so the orders
## `alert_group` promotes survive it. Waking is therefore the pass's own
## arm -- an observer that *sees* a unit on an alerting order -- and not a
## second rule derived from what the pass left behind, which would wake on
## a scan blip and on the beacons the pass marks without a line of sight.
##
## Answers how many units were promoted. [method states_for] is the query
## half and does not wake; [method World.probe_fog] is the caller.
static func probe(state: MapState, units: Dictionary, utab: UnitTypeTable,
		player: int, human_players: int, game_mode: int) -> int:
	var saved: Dictionary[int, int] = {}
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		saved[unit.slot] = unit.visibility
	var promoted: Array[int] = [0]
	var wake: Callable = func(group: int) -> void:
		promoted[0] += alert_group(units, group)
	_pass(state, units, utab, player, human_players, game_mode, wake)
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		unit.visibility = saved[unit.slot]
	return promoted[0]


static func _pass(state: MapState, units: Dictionary, utab: UnitTypeTable,
		player: int, human_players: int, game_mode: int,
		wake: Callable) -> void:
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		if not unit.is_alive():
			continue
		var always: bool = (unit.player == player
			or utab.species(unit.type_id) == SPECIES_OBJECT
			or ALWAYS_VISIBLE_TYPES.has(unit.type_id))
		set_state(unit, FULL if always else HIDDEN)

	# The contact promotion runs inside each per-unit pass (see [method
	# for_unit]), so a player with no living unit rebuilds to "all hidden" with
	# no blips.
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		if unit.is_alive() and unit.player == player:
			for_unit(state, units, utab, unit, unit.x, unit.y, human_players,
				game_mode, wake)
