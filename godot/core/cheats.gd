class_name Cheats
extends RefCounted

## The level tester's switches -- a rule modifier, and deliberately not
## simulation state.
##
## Nothing in the shipped engine answers to this: it is the remake's own, added
## so a mission can be walked end to end without playing it properly. It
## follows [member World.ai_may_fire] literally, which is the pattern already
## established for a switch that changes what the rules do without being part
## of the state they act on:
##
## * **outside [CanonicalHash]** -- two worlds that differ only in which cheats
##   are on are the same simulation state, and a save taken with one on has to
##   restore to a world whose hash matches;
## * **outside [SaveCodec]** -- cheats never reach disk, so a save cannot carry
##   them into a session that did not ask for them;
## * **carried by [method World.clone]** -- as the same object rather than a
##   copy, because the picture's mirror must equal the truth on every toggle
##   and not only at the moment it was cloned.
##
## They live for the length of the process and travel from mission to mission
## ([member SliceMain] holds one and hands it to every world it builds).
##
## **What a shield does not cover.** [member god] answers weapons and
## explosions -- everything that reaches [method Combat.apply_damage]. It does
## **not** block the mission script's own `KillUnit` ([method
## LclContext.kill_unit]) or a walk into a hole ([method ExecuteMove.execute]):
## a level being tested has to let its own scripted deaths happen, or the thing
## under test is not the level.

## Every switch, in the order the entry screen and the agent report them. The
## one source of truth for what a name means: [method enabled], [method
## set_enabled] and [method to_dict] all read it, so a switch added here needs
## no second table.
const NAMES: Array[String] = ["god", "ammo", "kill", "moves"]

## A one-off action rather than a switch, so it is **not** in [constant NAMES]:
## it has no state to be in. [method World.cheat_kill_enemies] runs it.
const ACTION_NUKE: String = "nuke"

## No damage from a weapon or an explosion, and no stun, for a unit a human
## player controls.
var god: bool = false
## No ammunition spent, no heat gained, no overheat roll and no jam, for a shot
## fired by a unit a human player controls.
var ammo: bool = false
## A shot by a unit a human player controls always connects and always kills.
var kill: bool = false
## Movement points are put back after a move, a shot, a use or a warp.
var moves: bool = false


## Whether *name* is one of [constant NAMES].
static func known(name: String) -> bool:
	return NAMES.has(name)


## `god,ammo` -- a comma-separated list as `--cheats=` and the agent take it.
##
## Returns `{"names": PackedStringArray, "unknown": PackedStringArray}`, both
## in the order they were written and neither containing a duplicate. Static
## and pure so the command line's half is checked by a suite: a name that
## stopped being recognised would otherwise be a launch flag that silently
## did nothing.
static func parse_list(text: String) -> Dictionary:
	var names: PackedStringArray = PackedStringArray()
	var unknown: PackedStringArray = PackedStringArray()
	for piece: String in text.split(",", false):
		var word: String = piece.strip_edges().to_lower()
		if word == "":
			continue
		if not known(word):
			if not unknown.has(word):
				unknown.append(word)
		elif not names.has(word):
			names.append(word)
	return {"names": names, "unknown": unknown}


func enabled(name: String) -> bool:
	match name:
		"god": return god
		"ammo": return ammo
		"kill": return kill
		"moves": return moves
	return false


## Returns false when *name* is not a switch, so a caller can report the typo
## rather than silently doing nothing.
func set_enabled(name: String, on: bool) -> bool:
	match name:
		"god": god = on
		"ammo": ammo = on
		"kill": kill = on
		"moves": moves = on
		_: return false
	return true


## Flips one switch and answers its new value; false for an unknown name, which
## the caller separates from a switch turned off with [method known].
func toggle(name: String) -> bool:
	if not known(name):
		return false
	var now: bool = not enabled(name)
	var _set: bool = set_enabled(name, now)
	return now


func any() -> bool:
	for name: String in NAMES:
		if enabled(name):
			return true
	return false


## Every switch that is on, in [constant NAMES] order.
func active() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for name: String in NAMES:
		if enabled(name):
			out.append(name)
	return out


func clear() -> void:
	for name: String in NAMES:
		var _off: bool = set_enabled(name, false)


func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for name: String in NAMES:
		out[name] = enabled(name)
	return out


func copy_from(other: Cheats) -> void:
	if other == null:
		clear()
		return
	for name: String in NAMES:
		var _set: bool = set_enabled(name, other.enabled(name))


func duplicate() -> Cheats:
	var copy: Cheats = Cheats.new()
	copy.copy_from(self)
	return copy


# --- what the rules ask ------------------------------------------------------
#
# Static and null-tolerant, so a call site reads as one condition rather than
# as a null test and a member access. Every one of them is false when no
# `Cheats` was passed, which is what keeps a default argument of `null` from
# changing a single existing caller.

## The unit belongs to a player a human is holding -- [method
## TurnState.is_human], which is where the bound and the kind test live. The
## aliens' player 255 is outside the slots and is therefore never protected.
static func controlled(unit: UnitState, turn: TurnState) -> bool:
	if unit == null or turn == null:
		return false
	return turn.is_human(unit.player)


## *unit* takes no damage and cannot be stunned.
static func shielded(cheats: Cheats, unit: UnitState, turn: TurnState) -> bool:
	return cheats != null and cheats.god and controlled(unit, turn)


## *unit*'s weapon spends nothing and cannot jam.
static func armed(cheats: Cheats, unit: UnitState, turn: TurnState) -> bool:
	return cheats != null and cheats.ammo and controlled(unit, turn)


## *unit*'s shot connects and kills.
static func lethal(cheats: Cheats, unit: UnitState, turn: TurnState) -> bool:
	return cheats != null and cheats.kill and controlled(unit, turn)


## *unit* keeps its movement points.
static func tireless(cheats: Cheats, unit: UnitState, turn: TurnState) -> bool:
	return cheats != null and cheats.moves and controlled(unit, turn)
