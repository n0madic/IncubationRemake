class_name Roster
extends RefCounted

## The unit pool and its two rows -- docs/27 section 3.
##
## The storage is `aUnit[5][31]` at `0x0051F2A0`: 91-byte records, 31 slots per
## row, 30 addressable. The 31st is not spare -- it is the scratch
## `aRemoveUnitFromUnitPool` compacts into, which is why the array is `[5][31]`
## with 30 usable (docs/11 section 5.7).
##
## **A record here is a [UnitState].** The engine's pool record and its map
## record are the same 91 bytes, and the cache already carries every roster
## column in `map.json`'s `units[]`, so a separate representation would be a
## second decoder of one struct. Occupancy is [method UnitState.is_placed] --
## a zero HP byte *is* the free-slot marker, the same convention an unplaced
## unit in a `.lev` uses.
##
## **Row 0 is the live roster and row 1 is the mission-entry snapshot.**
## docs/27 section 3.5 named row 1 "the mission's working copy" from the two
## `aCopyUnitPool` call sites alone; the four fixture saves that carry a pool
## settle it the other way. Inside a mission row 0 is *empty*, because
## deployment removed the records from it, and row 1 still holds the squad.
## The working copy is the map.

const ROWS: int = 5
const ROW_SLOTS: int = 31
const USABLE_SLOTS: int = 30

## The live roster, and the snapshot taken on entering a mission.
const ROW_LIVE: int = 0
const ROW_SNAPSHOT: int = 1

## docs/10 section 5.11 -- rank is EP over this, and `aEnlargeUnitPool` scales
## a starting rank by it.
const EP_PER_RANK: int = 12
## `aEnlargeUnitPool`'s floor: a recruit below rank 3 still gets 3 FP.
const FP_FLOOR: int = 3
## `0x00478A47`.
const RECRUIT_NAME_FORMAT: String = "Soldier %d"
## `+0x5A` is stored in tens.
##
## **Derived here rather than stored.** The engine caches the resale value in
## the record and recomputes it at every point that could invalidate it --
## `aEnlargeUnitPool` writes it and the Upgrade screen rewrites it after every
## weapon purchase (docs/27 section 5.3) -- so it is a cache of
## `(weapon[unit.weapon].cost + 50) / 10` and never independently true. Adding
## it to [UnitState] would put a derived number into the canonical hash and
## into a save, and `map.json` does not carry the column to load it from.
const RESALE_SCALE: int = 10
## `0x0045B821` -- the markup over weapon 0's cost, in both the recruit price
## and the resale formula, which is why dismissing a fresh recruit is free.
const RECRUIT_MARKUP: int = 50
## docs/27 section 3.4 -- 0 dropped at mission end, 1 pool candidate, 2 hero.
const POOL_CANDIDATE: int = 1

## Returned by [method add] and [method enlarge] when the row is full.
const NO_SLOT: int = -1

var _rows: Array[Array] = []


static func create() -> Roster:
	var roster: Roster = Roster.new()
	for row: int in range(ROWS):
		var records: Array[UnitState] = []
		for slot: int in range(ROW_SLOTS):
			records.append(UnitState.new())
		roster._rows.append(records)
	return roster


# -- queries ------------------------------------------------------------------

## The records of one row, **by value**: mutating what comes back does not
## write through, which is the rule every `core` accessor follows.
func records(row: int = ROW_LIVE) -> Array[UnitState]:
	var out: Array[UnitState] = []
	for record: UnitState in _row(row):
		out.append(_clone(record))
	return out


## The record in one slot, or `null` when the slot is free.
func record(slot: int, row: int = ROW_LIVE) -> UnitState:
	if slot < 0 or slot >= ROW_SLOTS:
		return null
	var stored: UnitState = _row(row)[slot]
	return _clone(stored) if stored.is_placed() else null


## The used slots of a row, in slot order.
func occupied_slots(row: int = ROW_LIVE) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var records_of: Array[UnitState] = _row(row)
	for slot: int in range(USABLE_SLOTS):
		if records_of[slot].is_placed():
			out.append(slot)
	return out


## `0x004788C0`.
func free_slots(row: int = ROW_LIVE) -> int:
	return USABLE_SLOTS - used_slots(row)


## `0x00478960`.
func used_slots(row: int = ROW_LIVE) -> int:
	return occupied_slots(row).size()


func first_free(row: int = ROW_LIVE) -> int:
	var records_of: Array[UnitState] = _row(row)
	for slot: int in range(USABLE_SLOTS):
		if not records_of[slot].is_placed():
			return slot
	return NO_SLOT


# -- mutation -----------------------------------------------------------------

## `aEnlargeUnitPool` `0x004789B0` -- seed the first free slot.
##
## Returns the slot, or [constant NO_SLOT] when the row is full. *speech* is
## the caller's draw: the engine calls `aRandom(1, 6)` here and which stream
## that is belongs to the caller -- the campaign uses its own deterministic one
## so a save reproduces (D8).
##
## *hit_points* and *ammo* are what the closing `recomputeUnitStats`
## (`0x004759E0`, at `0x00478B4A`) leaves: the unit type's `hp_max` and weapon
## 0's magazine. They are arguments rather than constants because `core`'s
## campaign half holds no balance tables -- and because a zero HP byte **is**
## the free-slot marker, so a recruit left at zero would be seeded into its own
## slot again by the next call. The rest of that recompute writes zeroes into a
## record that is already zeroed here.
func enlarge(player: int, mode: int, skill_level: int,
		speech: int, hit_points: int, ammo: int,
		row: int = ROW_LIVE) -> int:
	var slot: int = first_free(row)
	if slot == NO_SLOT:
		return NO_SLOT
	if hit_points <= 0:
		return NO_SLOT
	var rank: int = 0 if mode == TurnState.MODE_CAMPAIGN else skill_level
	var unit: UnitState = UnitState.new()
	unit.slot = slot
	unit.name = RECRUIT_NAME_FORMAT % (slot + 1)
	# docs/27 section 3.2: `unitType = player` is deliberate. `Info.lcl` names
	# types 0..3 `Human Soldier (1)` .. `(4)`, one per player slot, so a
	# recruit gets the soldier model of the side that hired them.
	unit.type_id = player
	unit.player = player
	unit.ep = rank * EP_PER_RANK
	unit.tp = rank * EP_PER_RANK
	unit.fp = FP_FLOOR if rank < FP_FLOOR else rank
	unit.weapon = 0
	unit.pool_flag = POOL_CANDIDATE
	unit.speech = speech
	unit.hp = hit_points
	unit.ammo = ammo
	_row(row)[slot] = unit
	return slot


## `aRemoveUnitFromUnitPool` `0x00478B70` -- shift records `slot+1 .. 30` down
## one and clear the scratch the compaction shifts into.
##
## Returns the record that was removed, or `null` when the slot was free, so
## the caller can price the refund. The engine reads `+0x5A` off the record
## before the shift; here the value is derived from the same record, which is
## the same number (see [constant RESALE_SCALE]).
func dismiss(slot: int, row: int = ROW_LIVE) -> UnitState:
	if slot < 0 or slot >= USABLE_SLOTS:
		return null
	var records_of: Array[UnitState] = _row(row)
	var removed: UnitState = records_of[slot]
	if not removed.is_placed():
		return null
	var out: UnitState = _clone(removed)
	for i: int in range(slot, ROW_SLOTS - 1):
		records_of[i] = records_of[i + 1]
	records_of[ROW_SLOTS - 1] = UnitState.new()
	_renumber(row)
	return out


## `aAddUnitToUnitPool` `0x00478C10` -- verbatim into the first free slot.
##
## The re-randomisation of `+0x55` fires only with more than one human player
## or in a net session, so in a campaign a soldier keeps their voice and this
## copy is exact.
func add(unit: UnitState, row: int = ROW_LIVE) -> int:
	var slot: int = first_free(row)
	if slot == NO_SLOT:
		return NO_SLOT
	var stored: UnitState = _clone(unit)
	stored.slot = slot
	_row(row)[slot] = stored
	return slot


## `0x00478630` -- a bubble sort, descending by `+0x17` (EP).
##
## Pairs where **either** record has a zero HP byte are skipped, so a free slot
## is a wall: the records after it never meet the records before it. That is
## why this is the engine's own pass and not a `sort_custom` -- the skip makes
## the result depend on the traversal, and the two disagree on any row with a
## gap in it.
func sort_by_ep(row: int = ROW_LIVE) -> void:
	var records_of: Array[UnitState] = _row(row)
	for _pass: int in range(USABLE_SLOTS):
		for i: int in range(USABLE_SLOTS - 1):
			var a: UnitState = records_of[i]
			var b: UnitState = records_of[i + 1]
			if not a.is_placed() or not b.is_placed():
				continue
			if a.ep < b.ep:
				records_of[i] = b
				records_of[i + 1] = a
	_renumber(row)


## `aCopyUnitPool` `0x00478910` -- 2730 bytes, one whole usable row.
func copy_row(source: int, destination: int) -> void:
	var src: Array[UnitState] = _row(source)
	var dst: Array[UnitState] = _row(destination)
	for slot: int in range(USABLE_SLOTS):
		dst[slot] = _clone(src[slot])


## Entering a mission: `aCopyUnitPool(0, 1)` at `0x0045A914`.
func snapshot() -> void:
	copy_row(ROW_LIVE, ROW_SNAPSHOT)


## The debriefing's *back to the map* button: `aCopyUnitPool(1, 0)` at
## `0x0045E9D9`. It puts the **pre-mission** roster back, so it is a replay.
func restore() -> void:
	copy_row(ROW_SNAPSHOT, ROW_LIVE)


## What the campaign map's state says has happened by the time it is drawn.
##
## `_5_.sav` is on the map screen with row 1 **empty**, though neither
## debriefing button clears it. What clears it is not traced; that the snapshot
## does not outlive the debriefing is what the save shows, and it is why
## *replay* is a debriefing button rather than a map one.
func clear_snapshot() -> void:
	var records_of: Array[UnitState] = _row(ROW_SNAPSHOT)
	for slot: int in range(ROW_SLOTS):
		records_of[slot] = UnitState.new()


## Put one record into a slot, replacing whatever is there.
func put(slot: int, unit: UnitState, row: int = ROW_LIVE) -> void:
	if slot < 0 or slot >= ROW_SLOTS:
		return
	var stored: UnitState = _clone(unit)
	stored.slot = slot
	_row(row)[slot] = stored


## Empty one slot -- what deployment does to the live row.
func clear(slot: int, row: int = ROW_LIVE) -> void:
	if slot < 0 or slot >= ROW_SLOTS:
		return
	_row(row)[slot] = UnitState.new()


# -- derived ------------------------------------------------------------------

## `+0x5A`, the cached resale value, in tens of equipment points -- derived.
static func resale_of(weapon_cost: int) -> int:
	return (weapon_cost + RECRUIT_MARKUP) / RESALE_SCALE


## What dismissing a soldier carrying a weapon of *weapon_cost* refunds.
static func refund_for(weapon_cost: int) -> int:
	return resale_of(weapon_cost) * RESALE_SCALE


# -- internals ----------------------------------------------------------------

func _row(index: int) -> Array[UnitState]:
	var clamped: int = clampi(index, 0, ROWS - 1)
	var out: Array[UnitState] = _rows[clamped]
	return out


## After a shift or a sort a record's `slot` no longer matches where it sits,
## and the roster screen addresses a record rather than a table row
## (docs/29 section 1.4). Keeping the field true to the position is what makes
## either addressing work.
func _renumber(row: int) -> void:
	var records_of: Array[UnitState] = _row(row)
	for slot: int in range(ROW_SLOTS):
		records_of[slot].slot = slot


static func _clone(unit: UnitState) -> UnitState:
	return UnitState.from_view(unit.view())


func hash_into(ctx: HashingContext) -> void:
	for row: int in range(ROWS):
		for slot: int in range(ROW_SLOTS):
			var unit: UnitState = _rows[row][slot]
			if not unit.is_placed():
				continue
			ctx.update(PackedInt32Array([row, slot]).to_byte_array())
			unit.hash_into(ctx)


## The serialisable form: every occupied slot of the two rows the campaign uses.
func view() -> Dictionary:
	var out: Dictionary = {}
	for row: int in [ROW_LIVE, ROW_SNAPSHOT]:
		var rows: Array = []
		for slot: int in occupied_slots(row):
			var entry: Dictionary = _row(row)[slot].view()
			entry["slot"] = slot
			rows.append(entry)
		out[str(row)] = rows
	return out


static func from_view(record: Dictionary) -> Roster:
	var roster: Roster = Roster.create()
	for row: int in [ROW_LIVE, ROW_SNAPSHOT]:
		var key: String = str(row)
		if not record.has(key):
			continue
		for entry: Variant in DictRead.as_array(record[key]):
			var view_of: Dictionary = entry
			var unit: UnitState = UnitState.from_view(view_of)
			roster.put(DictRead.as_int(view_of["slot"]), unit, row)
	return roster
