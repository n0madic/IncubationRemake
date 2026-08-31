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


## `aBuildVisibleMapForUnit` `0x00479370` -- one observer's pass.
##
## Returns true when it saw anything.  `wake` is called with an AI group id;
## pass an empty [Callable] to run the pass without waking anybody, which is
## what a "what would this unit see" query wants.
static func for_unit(state: MapState, units: Dictionary, utab: UnitTypeTable,
		observer: UnitState, human_players: int, game_mode: int,
		wake: Callable) -> bool:
	var scan: int = 0
	if observer.has_equipment(EQUIP_SCAN_MODULE):
		scan = 1
	if observer.has_equipment(EQUIP_LONG_RANGE_SCAN):
		scan = 2

	var saw: bool = false
	var oz: int = HitChance.full_height(utab, observer.type_id) \
		+ state.height_at(state.index_of(observer.x, observer.y))
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
		var block: int = LineOfSight.check(state, units, utab, observer.x,
			observer.y, oz, unit.x, unit.y, uz, 1, human_players, game_mode)
		if block < LineOfSight.TERRAIN:
			saw = true
			set_state(unit, FULL)
			if (unit.player == UnitState.PLAYER_ALIEN
					and ALERTING_ORDERS.has(unit.order) and wake.is_valid()):
				wake.call(unit.group)
		elif unit.visibility != FULL:
			var d: int = MoveMap.distance(observer.x, observer.y, unit.x,
				unit.y)
			if scan >= 1 and d < SCAN_RANGE:
				set_state(unit, FULL if scan == 2 else CONTACT)
			elif scan == 2 and d < LONG_SCAN_RANGE:
				set_state(unit, CONTACT)
	return saw


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
## **No group is woken.** The engine's probe can wake one -- the orders it
## promotes are not in the buffer it restores -- and that is a bug rather than
## a rule, so [method for_unit]'s documented "run the pass without waking
## anybody" arm is used instead.
##
## Returns slot -> `+0x4F`, and leaves `units` exactly as it found it.
static func states_for(state: MapState, units: Dictionary,
		utab: UnitTypeTable, player: int, human_players: int,
		game_mode: int) -> Dictionary[int, int]:
	var saved: Dictionary[int, int] = {}
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		saved[unit.slot] = unit.visibility
	_pass(state, units, utab, player, human_players, game_mode, Callable())
	var seen: Dictionary[int, int] = {}
	for slot: Variant in units:
		var unit: UnitState = units[slot]
		seen[unit.slot] = unit.visibility
		unit.visibility = saved[unit.slot]
	return seen


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

	for slot: Variant in units:
		var unit: UnitState = units[slot]
		if unit.is_alive() and unit.player == player:
			for_unit(state, units, utab, unit, human_players, game_mode, wake)

	# The second pass: a still-hidden neutral unit is promoted to a contact
	# unless one of its eight neighbours is already one -- which shows one blip
	# per cluster instead of one per alien.
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
