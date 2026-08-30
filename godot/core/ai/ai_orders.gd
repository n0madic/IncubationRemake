class_name AIOrders
extends RefCounted

## The eleven order handlers -- docs/23 section 3, jump table `0x0040A37C`.
##
## Six of the eleven begin with a second jump table indexed by the level
## counter; orders 5, 6, 8 and 9 branch on the level directly. Values above 10
## land on order 8's arm, which is the common epilogue and does nothing.
##
## Throughout, `fire(u)` is `0x0040A440(u, 8, 0)` in a `while` loop -- *shoot
## until you cannot* -- and `plan(u, kind, param, level)` is `0x0040A750`.

const ORDER_BERSERK: int = 0
const ORDER_MOVE_ACTPT: int = 1
const ORDER_ATTACK_ACTPT: int = 2
const ORDER_MOVE_GROUP: int = 3
const ORDER_ATTACK_GROUP: int = 4
const ORDER_TURN_WAIT: int = 5
const ORDER_RANGE_WAIT: int = 6
const ORDER_DEFEND: int = 7
const ORDER_VISIBILITY_WAIT: int = 8
const ORDER_CLEVER: int = 9
const ORDER_DISTURB: int = 10
const ORDER_COUNT: int = 11

## docs/10 section 5.6 -- the editor's own names, in its own order.
const ORDER_NAMES: Array[String] = ["Berserk", "Move (ActPt)",
	"Attack (ActPt)", "Move (Group)", "Attack (Group)", "Turn (Wait)",
	"Range (Wait)", "Defend", "Visibility (Wait)", "Clever small units",
	"Disturb"]

## docs/23 section 3.3 -- the three tails a handler can reach.
## `ACTED_END` is the shared copy at `0x0040A364` -- and order 4's own at
## `0x0040A274`, which differs only in which epilogue label the *not acted* arm
## jumps to. `ACTED_ZERO_MP` is order 7's at `0x0040A164`, which writes the
## byte rather than calling `endUnitTurn`, so **a defender never turns**.
const TAIL_EPILOGUE: String = "epilogue"
const TAIL_ACTED_END: String = "acted_end_unit_turn"
const TAIL_ACTED_ZERO_MP: String = "acted_zero_mp"

## `0x00409A1B` -- what order 9 lends every enemy while it stamps the threat
## map, and takes back afterwards. Reading the ten as "as if they had another
## turn" is interpretation; the arithmetic is literal.
const THREAT_MP_BONUS: int = 10
## The order-9 coin flip, `aRandom(0, 20) > 10`.
const COIN_MAX: int = 20
const COIN_THRESHOLD: int = 10
## The hit points below which order 9 runs for cover instead of shooting first.
const CLEVER_LOW_HP: int = 3
## The movement points order 9 lends itself and takes back.
const CLEVER_MP: int = 2


static func dispatch(ctx: AIContext, unit: UnitState, level: int) -> void:
	var order: int = unit.order
	var param: int = unit.order_param
	ctx.result.saw_order(order)

	var tail: String = TAIL_EPILOGUE
	if order == ORDER_BERSERK:
		tail = _berserk(ctx, unit, level)
	elif order == ORDER_MOVE_ACTPT or order == ORDER_ATTACK_ACTPT:
		tail = _action_point(ctx, unit, param, level)
	elif order == ORDER_MOVE_GROUP:
		tail = _move_group(ctx, unit, param, level)
	elif order == ORDER_ATTACK_GROUP:
		tail = _attack_group(ctx, unit, param, level)
	elif order == ORDER_TURN_WAIT:
		tail = _turn_wait(ctx, unit, param, level)
	elif order == ORDER_RANGE_WAIT:
		tail = _range_wait(ctx, unit, param, level)
	elif order == ORDER_DEFEND:
		tail = _defend(ctx, unit, level)
	elif order == ORDER_CLEVER:
		tail = _clever(ctx, unit, level)
	elif order == ORDER_DISTURB:
		tail = _disturb(ctx, unit, level)
	# Order 8 `Visibility (Wait)` and every byte above 10 fall through with
	# TAIL_EPILOGUE: the handler *is* the epilogue.

	if tail == TAIL_ACTED_END and unit.acted != 0:
		AIUnitTurn.end_unit_turn(ctx, unit)
	elif tail == TAIL_ACTED_ZERO_MP and unit.acted != 0:
		unit.mp = 0


## 0 -- the aliens' default: close on the best enemy and shoot.
##
## Levels 3 and 5 look for a **friendly alien** instead (kinds 3 and 1), so the
## escalation reads *"if you found nobody to kill, go and join the pack"*.
static func _berserk(ctx: AIContext, unit: UnitState, level: int) -> String:
	AIFire.until_empty(ctx, unit)
	if level <= 2:
		AIPlan.run(ctx, unit, AIPlan.KIND_ENEMY, 0, level)
		AIFire.until_empty(ctx, unit)
	elif level == 3:
		AIPlan.run(ctx, unit, AIPlan.KIND_ALLY_SHORT, 0, 3)
	elif level == 4:
		AIPlan.run(ctx, unit, AIPlan.KIND_ENEMY, 0, 4)
	else:
		# Level 5 carries its own copy of the shared preamble at `0x00409F00`.
		AIPlan.run(ctx, unit, AIPlan.KIND_ALLY, 0, 5)
	return TAIL_ACTED_END


## 1 and 2 -- one block, whatever the editor's two labels say. Kind 6 selects
## the free cell whose action point equals the parameter.
static func _action_point(ctx: AIContext, unit: UnitState, param: int,
		level: int) -> String:
	AIPlan.run(ctx, unit, AIPlan.KIND_ACTION_POINT, param, level)
	AIFire.until_empty(ctx, unit)
	return TAIL_ACTED_END


## 3 -- walk to a unit whose group id is the parameter. Level 5 is the one arm
## with **no** fire loop in front of the plan.
static func _move_group(ctx: AIContext, unit: UnitState, param: int,
		level: int) -> String:
	if level <= 4:
		AIFire.until_empty(ctx, unit)
	AIPlan.run(ctx, unit, AIPlan.KIND_GROUP, param, level)
	return TAIL_ACTED_END


## 4 -- the group orders' aggressive half, with its own promotion.
##
## When no live unit carries the group id the secondary order is promoted on
## the spot and the turn ends here. This is the promotion docs/10 section 5.6
## describes, and the only place a handler rewrites its own order.
static func _attack_group(ctx: AIContext, unit: UnitState, param: int,
		level: int) -> String:
	if not AIUnitTurn.group_alive(ctx, param):
		unit.order = unit.order2
		unit.order_param = unit.order2_param
		ctx.emit(AIEvent.make("promote_order", unit.slot, unit.x, unit.y,
			0, 0, unit.order, "group empty"))
		return TAIL_EPILOGUE
	if level <= 4:
		AIFire.until_empty(ctx, unit, AIFire.FIRE_GROUP, param)
		AIPlan.run(ctx, unit, AIPlan.KIND_GROUP, param, level)
		AIFire.until_empty(ctx, unit, AIFire.FIRE_GROUP, param)
	else:
		AIFire.until_empty(ctx, unit)
		AIPlan.run(ctx, unit, AIPlan.KIND_ALLY, param, 5)
	return TAIL_ACTED_END


## 5 -- one chance to shoot from where it stands, then sit the turn out.
static func _turn_wait(ctx: AIContext, unit: UnitState, param: int,
		level: int) -> String:
	if level == 0:
		AIFire.until_empty(ctx, unit)
		AIPlan.run(ctx, unit, AIPlan.KIND_ENEMY, param, 0)
		AIFire.until_empty(ctx, unit)
	elif level == 1:
		AIUnitTurn.countdown(unit)
	return TAIL_EPILOGUE


## 6 -- order 5 at level 0, a tripwire at level 1.
##
## Unlike order 5 this does **not** zero the movement points, so a woken group
## acts on the next sweep.
static func _range_wait(ctx: AIContext, unit: UnitState, param: int,
		level: int) -> String:
	if level == 0:
		AIFire.until_empty(ctx, unit)
		AIPlan.run(ctx, unit, AIPlan.KIND_ENEMY, param, 0)
		AIFire.until_empty(ctx, unit)
	elif level == 1:
		AIUnitTurn.distance_trigger(ctx, unit)
	return TAIL_EPILOGUE


## 7 -- a defender never moves, and never turns either.
static func _defend(ctx: AIContext, unit: UnitState, level: int) -> String:
	if level <= 4:
		AIFire.until_empty(ctx, unit)
	else:
		AIUnitTurn.defence_mode(ctx, unit)
	return TAIL_ACTED_ZERO_MP


## 10 -- *Berserk* without the friendly-alien fallbacks.
static func _disturb(ctx: AIContext, unit: UnitState, level: int) -> String:
	AIFire.until_empty(ctx, unit)
	AIPlan.run(ctx, unit, AIPlan.KIND_ENEMY, 0, level)
	if level <= 2:
		AIFire.until_empty(ctx, unit)
	return TAIL_ACTED_END


## 9 -- the largest handler, and the only one with logic of its own.
##
## Four things happen before the level is looked at: a threat map is built by
## running the target overlay from **every enemy's** side with ten extra
## movement points, the unit decides whether it is a melee unit, levels outside
## 0..3 stop, and a melee unit with points to spare closes and shoots. Then the
## branch that matters: *am I standing where an enemy can hit me?*
##
## The cell pointer is taken **before** any of that, so the marker read below
## is the one on the cell the unit started on. It also means that a melee unit
## which took the step above reads an overlay [AIPlan] has already reset: the
## threat map does not survive a plan, and that is the engine's behaviour.
static func _clever(ctx: AIContext, unit: UnitState, level: int) -> String:
	_refresh_threat_map(ctx, unit)
	var melee: bool = ctx.wtab.range_max(unit.weapon) == 1
	if level < 0 or level > 3:
		return TAIL_EPILOGUE

	var here: int = ctx.map.index_of(unit.x, unit.y)
	if melee and unit.mp >= CLEVER_MP:
		unit.mp -= CLEVER_MP
		AIPlan.run(ctx, unit, AIPlan.KIND_ENEMY, 0, 0)
		unit.mp = IncInt.u8(unit.mp + CLEVER_MP)
		AIFire.until_empty(ctx, unit)
		AIUnitTurn.end_unit_turn(ctx, unit)

	var marker: int = ctx.state[here]
	if marker >= AIOverlay.MARKER_MIN and marker <= AIOverlay.MARKER_MAX:
		if unit.hp < CLEVER_LOW_HP:
			AIPlan.run(ctx, unit, AIPlan.KIND_COVER, 0, 2)
			AIFire.until_empty(ctx, unit)
		else:
			AIFire.until_empty(ctx, unit)
			AIPlan.run(ctx, unit, AIPlan.KIND_COVER, 0, 3)
			AIFire.until_empty(ctx, unit)
		return _clever_tail(ctx, unit)
	return _clever_door(ctx, unit, melee)


## `0x00409A1B` -- every enemy's reach, stamped over the same overlay.
##
## Weapons `isArcing` reaches are skipped, and the pass does **not** reset the
## overlay first, so the bands accumulate from all of them.
static func _refresh_threat_map(ctx: AIContext, unit: UnitState) -> void:
	for slot: int in range(AISystem.UNIT_SLOTS):
		var other: UnitState = ctx.unit_or_null(slot)
		if other == null or other.hp == 0:
			continue
		if other.player == unit.player:
			continue
		if HitChance.ARCING_WEAPONS.has(other.weapon):
			continue
		other.mp = IncInt.u8(other.mp + THREAT_MP_BONUS)
		AIOverlay.build(ctx, other, ctx.turn.human_count(), ctx.turn.mode)
		other.mp = IncInt.u8(other.mp - THREAT_MP_BONUS)


## `0x00409DFD` / `0x00409E03` / `0x00409E0C` -- the shared exits.
static func _clever_tail(ctx: AIContext, unit: UnitState) -> String:
	if unit.mp >= CLEVER_MP:
		AIUnitTurn.defence_mode(ctx, unit)
	AIUnitTurn.end_unit_turn(ctx, unit)
	return TAIL_EPILOGUE


## `0x00409CB4` -- nobody has a shot at me, so go and open a door.
##
## Then a coin flip and four combinations of it with `melee`. The **ranged**
## side is the one that lends itself two movement points, which is the opposite
## way round from the melee arm above -- and it gives them back
## unconditionally, so a unit that had fewer than two ends up with two more
## than it started with. That is the engine's arithmetic, not a transcription
## slip.
static func _clever_door(ctx: AIContext, unit: UnitState,
		melee: bool) -> String:
	AIPlan.run(ctx, unit, AIPlan.KIND_DOOR, 0, 0)
	AIUnitTurn.open_door(ctx, unit)
	AIFire.until_empty(ctx, unit)
	AIUnitTurn.open_door(ctx, unit)
	var coin: int = ctx.rng.draw(0, COIN_MAX)
	ctx.emit(AIEvent.make("clever_coin", unit.slot, unit.x, unit.y, 0, 0,
		coin, "melee" if melee else "ranged"))
	if coin > COIN_THRESHOLD:
		if not melee:
			return _clever_tail(ctx, unit)
		AIPlan.run(ctx, unit, AIPlan.KIND_COVER, 0, 2)
		AIFire.until_empty(ctx, unit)
		AIUnitTurn.end_unit_turn(ctx, unit)
		return TAIL_EPILOGUE

	AIFire.run(ctx, unit)
	if not melee:
		if unit.mp >= CLEVER_MP:
			unit.mp -= CLEVER_MP
		AIPlan.run(ctx, unit, AIPlan.KIND_ENEMY, 0, 3)
		unit.mp = IncInt.u8(unit.mp + CLEVER_MP)
	else:
		AIPlan.run(ctx, unit, AIPlan.KIND_COVER, 0, 2)
	AIFire.until_empty(ctx, unit)
	if not melee:
		return _clever_tail(ctx, unit)
	AIPlan.run(ctx, unit, AIPlan.KIND_COVER, 0, 2)
	AIFire.until_empty(ctx, unit)
	AIUnitTurn.end_unit_turn(ctx, unit)
	return TAIL_EPILOGUE
