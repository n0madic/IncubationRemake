class_name TurnState
extends RefCounted

## The turn half of the block `aSaveGameControl` writes -- docs/25 section 3.
##
## Only what a turn reads is here, on the same rule [UnitState] follows: the
## 720-byte block carries more, and carrying fields nothing reads would invite
## treating them as validated.
##
## The rotation this drives is pinned natively: `tools/turn_gold.py` phase 5
## steps `0x0043B320` twelve times inside the live engine and diffs the current
## player, the previous player, the any-player-left predicate and the return
## code at every step.

## docs/25 section 3 -- the counter wraps at 200 (`0x0043B2A0`).
const TURN_WRAP: int = 200
## docs/10 section 5.7 -- the alien side, a full member of the rotation.
const PLAYER_COMPUTER: int = 255
## docs/25 section 7 -- the neutral-prop owner. **Never** stored in the
## current-player byte: the setter rejects it and nothing passes it, which is
## why `advance_player` can never produce it.
const PLAYER_PROPS: int = 252
## docs/25 section 3 -- `5` takes a slot out of the rotation.
const END_STATE_OUT: int = 5
const PLAYER_SLOTS: int = 4

## `0x0043B1F0` reads the session kind. The compiler wrote three successive
## `sub eax, n; je`, so the four values are consecutive from 1.
const MODE_CAMPAIGN: int = 1
const MODE_NET: int = 2
const MODE_LOCAL: int = 3
const MODE_PBM: int = 4

## `0x00509E1D`. Zero means no hand-over has happened yet, and that is the test
## the hand-over itself uses to recognise the first one -- at zero the whole
## skip rule is disabled (docs/25 section 3.1).
var turn: int = 0
var current_player: int = 0
var previous_player: int = 0
## `0x0043B310` -- the rotation's upper bound; 1 in the campaign.
var player_count: int = 1
## `0x0043B6E0` -- 0 means the slot is not in the game, 1 means a human.
## Written down as a constant because two readers now ask the same question:
## [method human_count] and [method Cheats.controlled].
const KIND_HUMAN: int = 1
var player_kind: PackedInt32Array = PackedInt32Array([1, 0, 0, 0])
## `0x0043B930`.
var end_state: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
## `0x00509F08` -- "the computer side plays". Always set in a campaign.
var solo_flag: bool = true
## `0x00460450`. docs/93 section 11 left this to the campaign layer; this slice
## chooses **1, normal**, and carries it here so it enters the canonical hash
## rather than sitting in a constant.
var ai_level: int = 1
## Which session kind this is. It gates the "no units left" skip and nothing
## else here, and a campaign fails that gate -- see [method skips_empty_players].
var mode: int = MODE_CAMPAIGN
## `0x00517F50` -- zeroed by the refresh, so ticket numbering restarts every
## hand-over (docs/25 section 6).
var reaction_counter: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
## The player record's `+0x24` (`0x00509F48` + 40*p), one per slot -- what
## `HeroKilled` (docs/20 section 7.4) reads and what
## [method UnitState.remove] writes. A `.lev` carries no player records, so an
## authored mission starts with all four clear; from there it is the removal
## of a **hero** on a turn that has started that moves one (docs/22 section
## 9.5). Each is one byte in the engine, so it wraps at 256.
var hero_killed: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
## The rest of the campaign scoreboard's per-mission halves -- `0x00509F48`,
## stride 40, four records. The engine's record is **four pairs**, each "this
## mission" beside "the campaign", which is what the debriefing's two reading
## passes show (`0x0045DF24`..`0x0045E44B` read `+0x1C/+0x14/+0x0C/+0x04` and
## `+0x18/+0x10/+0x08/+0x00`):
##
## | Pair | Mission | Campaign | Written by |
## | --- | --- | --- | --- |
## | kills | `+0x00` | `+0x04` | `0x0043B810`, the shooter's, on a kill whose players differ |
## | lost | `+0x08` | `+0x0C` | `0x0043B8D0`, the victim's, from **every** death path -- 11 callers |
## | lost to an enemy | `+0x10` | `+0x14` | `0x0043B860`, the victim's, only where `0x0043B810` also fires |
## | score | `+0x18` | `+0x1C` | the scorer `0x0043BA10` |
##
## `+0x08` is the one the scorer doubles, and `+0x24` is [member hero_killed].
##
## **Outside the canonical hash, and deliberately** (docs/98, D7): the
## scoreboard is `GameControl`-block state rather than the mission's, the
## campaign carries the totals, and folding these in would move every hash the
## first five slices pinned. They are in [method view] because a mid-mission
## save has to bring them back.
var mission_kills: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
var mission_lost: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
var mission_lost_to_enemy: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
## `0x004418B0` writes its one argument into `0x0043BE00`. **UNVERIFIED**: what
## reads it has not been traced. Carried so a later capture has something to
## compare, and so a script that sets it round-trips through a save.
var turn_control: int = 0


static func create() -> TurnState:
	return TurnState.new()


func human_count() -> int:
	var n: int = 0
	for i: int in range(mini(player_count, PLAYER_SLOTS)):
		if player_kind[i] == KIND_HUMAN:
			n += 1
	return n


## `0x0043B1F0` -- the gate in front of the "no units left" skip.
##
## True **only** in a net or pbm session, or a local session with more than one
## human. A shipped single-player campaign fails it, so it never skips a
## player: the human keeps being handed its turn even with nothing left alive,
## and the mission ends through the game-control slots rather than through the
## rotation running out.
func skips_empty_players() -> bool:
	if not solo_flag:
		return false
	if mode == MODE_NET or mode == MODE_PBM:
		return true
	return mode == MODE_LOCAL and human_count() > 1


## `0x0043B2A0` -- five instructions, and the wrap is the whole of the fifth.
func advance_turn() -> int:
	turn += 1
	if turn == TURN_WRAP:
		turn = 0
	return turn


## A fresh dictionary of scalars, never this object.
func view() -> Dictionary:
	return {
		"turn": turn,
		"current_player": current_player,
		"previous_player": previous_player,
		"player_count": player_count,
		"player_kind": player_kind.duplicate(),
		"end_state": end_state.duplicate(),
		"solo_flag": solo_flag,
		"ai_level": ai_level,
		"mode": mode,
		"reaction_counter": reaction_counter.duplicate(),
		"hero_killed": hero_killed.duplicate(),
		"mission_kills": mission_kills.duplicate(),
		"mission_lost": mission_lost.duplicate(),
		"mission_lost_to_enemy": mission_lost_to_enemy.duplicate(),
		"turn_control": turn_control,
	}


## The inverse of [method view].
##
## Both halves used to live in `SaveCodec`, which was the only reader; the
## picture's mirror is the second, so the pair belongs together. The values
## may arrive as typed arrays (a delta built in memory) or as the `Array` of
## floats `JSON.parse_string` produces (a save), and [method _ints] narrows
## either -- a hash over the parsed form would be stable and wrong.
static func from_view(view: Dictionary) -> TurnState:
	var turn: TurnState = TurnState.create()
	turn.turn = DictRead.as_int(view["turn"])
	turn.current_player = DictRead.as_int(view["current_player"])
	turn.previous_player = DictRead.as_int(view["previous_player"])
	turn.player_count = DictRead.as_int(view["player_count"])
	turn.solo_flag = DictRead.as_bool(view["solo_flag"])
	turn.ai_level = DictRead.as_int(view["ai_level"])
	turn.mode = DictRead.as_int(view["mode"])
	turn.player_kind = _ints(view["player_kind"])
	turn.end_state = _ints(view["end_state"])
	turn.reaction_counter = _ints(view["reaction_counter"])
	turn.hero_killed = _ints(view["hero_killed"])
	turn.mission_kills = _ints(view["mission_kills"])
	turn.mission_lost = _ints(view["mission_lost"])
	turn.mission_lost_to_enemy = _ints(view["mission_lost_to_enemy"])
	turn.turn_control = DictRead.as_int(view["turn_control"])
	return turn


static func _ints(value: Variant) -> PackedInt32Array:
	if value is PackedInt32Array:
		var packed: PackedInt32Array = value
		return packed.duplicate()
	return DictRead.to_int32(value)


## Write another turn's fields over this one, in place.
##
## [method clone] answers with a new object; the mirror keeps one [TurnState]
## for the life of the mission because `World` hands the same reference to
## every rule, so the delta writes through instead of replacing.
func restore(view: Dictionary) -> void:
	var other: TurnState = from_view(view)
	turn = other.turn
	current_player = other.current_player
	previous_player = other.previous_player
	player_count = other.player_count
	player_kind = other.player_kind
	end_state = other.end_state
	solo_flag = other.solo_flag
	ai_level = other.ai_level
	mode = other.mode
	reaction_counter = other.reaction_counter
	hero_killed = other.hero_killed
	mission_kills = other.mission_kills
	mission_lost = other.mission_lost
	mission_lost_to_enemy = other.mission_lost_to_enemy
	turn_control = other.turn_control


func clone() -> TurnState:
	var copy: TurnState = TurnState.new()
	copy.turn = turn
	copy.current_player = current_player
	copy.previous_player = previous_player
	copy.player_count = player_count
	copy.player_kind = player_kind.duplicate()
	copy.end_state = end_state.duplicate()
	copy.solo_flag = solo_flag
	copy.ai_level = ai_level
	copy.mode = mode
	copy.reaction_counter = reaction_counter.duplicate()
	copy.hero_killed = hero_killed.duplicate()
	copy.mission_kills = mission_kills.duplicate()
	copy.mission_lost = mission_lost.duplicate()
	copy.mission_lost_to_enemy = mission_lost_to_enemy.duplicate()
	copy.turn_control = turn_control
	return copy


## `0x0043B8D0`, `0x0043B860` and `0x0043B810` all guard the same way before
## they index the scoreboard: unit type at most 30 and not 24, and a player
## slot inside the four.
##
## **`0x0043B810` does not carry the player guard**, so an alien killer --
## player 255 -- makes the engine write 40 * 255 bytes past the array. That is
## an out-of-bounds write, not a rule, and it is bounded here rather than
## reproduced.
const SCORED_TYPE_MAX: int = 30
const SCORED_TYPE_EXCLUDED: int = 24


static func scores_as_a_loss(type_id: int, player: int) -> bool:
	return type_id <= SCORED_TYPE_MAX and type_id != SCORED_TYPE_EXCLUDED \
		and player >= 0 and player < PLAYER_SLOTS


## `0x0043B8D0` -- every death of a unit that counts, whatever killed it.
func count_unit_lost(type_id: int, player: int) -> void:
	if scores_as_a_loss(type_id, player):
		mission_lost[player] += 1


## `0x0043B810` (the killer) and `0x0043B860` (the victim), which fire together
## and only when the two players differ.
func count_kill_and_loss(killer: int, victim_type: int,
		victim_player: int) -> void:
	if killer == victim_player:
		return
	if killer >= 0 and killer < PLAYER_SLOTS:
		mission_kills[killer] += 1
	if scores_as_a_loss(victim_type, victim_player):
		mission_lost_to_enemy[victim_player] += 1
