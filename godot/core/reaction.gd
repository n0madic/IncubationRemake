class_name Reaction
extends RefCounted

## The reaction-fire queue -- docs/25 section 6.
##
## **Nothing here clears `+0x41`.**  A sweep for every store into that offset
## over the whole of `0x0046CCA0` finds none: a unit stays on overwatch, firing
## at each enemy that moves past, until the hand-over clears it or it runs out
## of ammunition or overheats.  docs/25 calls this "the single most
## remake-relevant rule in this document, and the one an implementation is most
## likely to get wrong by clearing the flag after the first shot".
##
## The other two rules that are easy to lose: the reactor's facing is saved
## before the shot and restored after it, so a unit on overwatch does not end up
## staring at whatever it last shot at; and if the mover dies the drain returns
## immediately, leaving the reactors behind it in the queue with their tickets.

## docs/21 section 4 -- `0x004753E0` requires two movement points, and
## `0x00478500` stamps `+0x39`.
const MIN_MP: int = 2
const ACTED: int = 3
## `+0x41 == 1` -- a reaction is pending.
const WAITING: int = 1
## The one value the two Def gates disagree about.  `0x004753E0` returns
## `def_mode & 1` and so refuses it; `0x0040A710` tests `== 1 || == 4` and so
## accepts it.  The shipped table never uses it, which is why the disagreement
## can only be seen on a constructed weapon.
const DEF_MODE_AUTOMATIC: Array[int] = [1, 4]


## `0x004753E0` -- the **Def** button's own eligibility test.
static func may_enter_defence(wtab: WeaponTable, unit: UnitState) -> bool:
	if unit.mp < MIN_MP:
		return false
	if unit.malfunction != 0:
		return false
	if unit.ammo == 0:
		return false
	if unit.action_state == WAITING:
		return false
	return (wtab.def_mode(unit.weapon) & 1) != 0


## `0x0040A710` -- the AI's end-of-turn pass, as a predicate.
static func auto_enter_defence(wtab: WeaponTable, unit: UnitState) -> bool:
	if unit.mp < MIN_MP:
		return false
	return wtab.has(unit.weapon) \
		and DEF_MODE_AUTOMATIC.has(wtab.def_mode(unit.weapon))


## `0x00478500` -- put a unit on overwatch and hand it a ticket.
##
## Returns the ticket.  A unit that was **already** waiting loses its remaining
## movement points, which is what makes pressing Def twice an act rather than a
## no-op -- so the old state is read before the new one is written.
static func enter_defence(state: TurnState, unit: UnitState) -> int:
	var was_waiting: bool = unit.action_state == WAITING
	unit.action_state = WAITING
	unit.acted = ACTED
	var slot: int = unit.player & 3
	state.reaction_counter[slot] += 1
	unit.ticket = state.reaction_counter[slot]
	if was_waiting:
		unit.mp = 0
	return unit.ticket


## `0x004790F0` -- is the mover inside the reactor's 135 degree front?
##
## The heading from the reactor to the mover and its two neighbouring octants;
## true when the reactor's own facing is one of the three.  The same shape
## docs/22 section 7.4 uses for rear armour, read from the other end.
static func in_front_arc(reactor: UnitState, mover: UnitState) -> bool:
	var heading: int = Combat.direction(reactor.x, reactor.y, mover.x, mover.y)
	return Combat.in_arc(heading, reactor.facing)


## `0x0046CCA0`'s six conditions, in the order docs/25 section 6 lists them.
##
## The chance test is the expensive one and stays last, exactly as the engine
## orders it: a reactor that is dead, unwaiting, empty or overheated never
## reaches the line-of-sight walk.
static func candidates(state: MapState, units: Dictionary,
		utab: UnitTypeTable, wtab: WeaponTable, mover: UnitState,
		human_players: int, game_mode: int) -> Array[UnitState]:
	var out: Array[UnitState] = []
	for slot: Variant in units:
		var reactor: UnitState = units[slot]
		if not reactor.is_alive() or reactor.player == mover.player:
			continue
		if reactor.action_state != WAITING:
			continue
		if reactor.ammo == 0:
			continue
		var cap: int = Combat.max_heat(wtab, reactor)
		if cap != Combat.HEAT_NONE and reactor.heat >= cap:
			continue
		var chance: HitChance = HitChance.compute(state, units, utab, wtab,
			reactor, mover, reactor.weapon, true, human_players, game_mode)
		if not chance.in_range or chance.percent <= 0:
			continue
		if not (Combat.banner_nearby(reactor, units)
				or in_front_arc(reactor, mover)):
			continue
		out.append(reactor)
	return out


## `0x0046CCA0` -- every enemy on overwatch shoots the unit that moved.
##
## Two branches, and the difference is the **order**, never the membership.  In
## `campaign` mode the queue is drained by ticket from 1 upward -- so the unit
## that went on overwatch first shoots first -- and in every other mode the 200
## slots are walked in index order.  The tickets are written either way.
##
## The ticket loop starting at **1** is why a waiting unit whose ticket is 0 is
## never found by it.  No shipped path produces one -- [method enter_defence]
## always stamps at least 1 -- but a save or a script can, and the two branches
## disagree about it.
static func drain(state: MapState, units: Dictionary, utab: UnitTypeTable,
		wtab: WeaponTable, mover: UnitState, ai_level: int,
		human_players: int, game_mode: int, turn: TurnState,
		rng: IncRandom,
		journal: EventJournal = null,
		cheats: Cheats = null,
		overlay_for: Callable = Callable(),
		ctrlmap: CtrlMapTable = null) -> Array[Dictionary]:
	var fired: Array[Dictionary] = []
	if not mover.is_alive():
		return fired
	var by_slot: Array[UnitState] = candidates(state, units, utab, wtab, mover,
		human_players, game_mode)
	by_slot.sort_custom(func(a: UnitState, b: UnitState) -> bool:
		return a.slot < b.slot)

	var order: Array[UnitState] = []
	if game_mode == TurnState.MODE_CAMPAIGN:
		var highest: int = 0
		for u: UnitState in by_slot:
			highest = maxi(highest, u.ticket)
		for ticket: int in range(1, highest + 1):
			for u: UnitState in by_slot:
				if u.ticket == ticket:
					order.append(u)
	else:
		order = by_slot

	for reactor: UnitState in order:
		var facing: int = reactor.facing
		# **The fifth argument is 1 here**, which is what marks the shot a
		# reaction -- and the close-combat swap of docs/21 section 6 is
		# behind it: `0x0046B592` and `0x0046C319` both jump past the
		# dispatcher when it is set, so a unit on overwatch never reaches for
		# its bayonet, however close the mover walks.
		# An overlay for the one weapon whose pattern reads one ([constant
		# Combat.SPECIAL_OBJECTS]); `overlay_for` is [method World._overlay_for]
		# and answers an empty array otherwise. **UNVERIFIED which overlay a
		# reaction reads in the engine**: `cell[+0x00]` is one shared byte,
		# and at reaction time it holds what the mover's side last wrote,
		# not the reactor's own. No capture fires a weapon-11 reaction and no
		# shipped alien carries the weapon, so this builds the reactor's; a
		# human on overwatch with the Multi-target Destroyer is where the two
		# would differ.
		var states: PackedByteArray = PackedByteArray()
		if overlay_for.is_valid():
			states = overlay_for.call(reactor)
		var result: AttackResult = Combat.attack(state, units, utab, wtab,
			reactor.x, reactor.y, mover.x, mover.y, ai_level, human_players,
			game_mode, turn, rng, true, cheats, states, ctrlmap)
		reactor.facing = facing
		var shot: Dictionary = {"reactor": reactor.slot,
			"ticket": reactor.ticket, "attack": result.to_dict(),
			"jammed": false}
		# `0x0046CE06` / `0x0046D088` -- in **both** loops: a shot that fired
		# and left the magazine empty, or the heat counter at `0x00475340`'s
		# cap, plays the jam orbit (docs/42 section 7.4) and takes the
		# reactor out of the queue with `mov byte [esi + 0x59], 0`. The
		# ticket in `shot` is the one it fired with.
		if result.fired and (reactor.ammo == 0
				or reactor.heat == Combat.max_heat(wtab, reactor)):
			shot["jammed"] = true
			reactor.ticket = 0
		fired.append(shot)
		# **One boundary per shot.** The engine's drain calls `aAttackUnit`
		# per reactor and each carries its own blocking fight animation, so
		# the picture shows them one at a time rather than as a list -- and
		# a reactor killed by an earlier shot in the same drain never fires.
		if journal != null:
			var _shot: Dictionary = journal.mark("reaction", reactor.slot,
				reactor.x, reactor.y, mover.x, mover.y,
				DictRead.as_int(shot["ticket"]), str(reactor.weapon),
				{"reactor": reactor.slot, "ticket": shot["ticket"],
					"attack": shot["attack"], "jammed": shot["jammed"],
					"mover": mover.slot})
		if not mover.is_alive():
			break
	return fired
