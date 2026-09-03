class_name MoveResult
extends RefCounted

## What one walk did, as a value -- the sibling of [MoveMapResult].
##
## The shape matches `inclib.movemap.ExecuteResult.to_dict`, so the two
## implementations are diffed document against document rather than field by
## field at each call site.

## `aExecuteMove`'s own return value. **FALSE does not mean nothing happened**:
## a mine ends the walk with the unit moved, its distance accumulated and its
## facing turned, and the routine still answers FALSE. [member steps] is what
## says how far it got.
var ok: bool = false
var x: int = 0
var y: int = 0
## What argument 5 receives -- **0** on the mine arm, which is not the cost of
## the steps that were taken.
var cost: int = 0
var steps: int = 0
## The increment to `unit[+0x50]`, in tenths of a field.
var walked: int = 0
## `unit[+0x46]` after the walk: the facing of the last step taken.
var facing: int = 0
## `[cell index, new action point]` for every VictoryPoint claimed.
var action_point_writes: Array[Vector2i] = []
## `{"kind": String, "x": int, "y": int, "detail": int}` per event.
var events: Array[Dictionary] = []
## Set when a mine stopped the walk. The engine zeroes `+0x15` itself on that
## arm, so the caller must not also subtract [member cost].
var movement_zeroed: bool = false
## Whether the walk ended on a mine. `0x0046EC0F` gates the whole detonation
## block on it, and the arm it then picks is [method ExecuteMove._detonate]'s.
var stopped_on_mine: bool = false
## Whether the walk ended on a teleporter entry. `0x0046EA73` breaks the walk
## there and `0x0046EDEB` gates the epilogue's `aExecuteTeleporter` call on the
## same flag; [method ExecuteMove._teleport] is what resolves it, so
## [member x] and [member y] are the **exit** cell afterwards. Kept out of
## [method to_dict] for the same reason as [member route].
var teleporter: bool = false
## The cells an **authored** mine went off on, as `[x0, y0, x1, y1, ...]` and
## empty when none did -- a mover of size 1 can set off more than one, because
## its arm sweeps the eight neighbours rather than the cell it stopped on.  The walk
## clears `+0x10`, `+0x0E` and the object slot itself, as `aExecuteMove` does;
## firing the weapon-36 shot is the caller's, because the engine's own
## `aExecuteBomb` call is the last thing on that arm and the caller is what
## owns the units (docs/26 section 6.2).
var detonate: PackedInt32Array = PackedInt32Array()
## What that mine did, empty when none went off. The same document
## [AttackResult.to_dict] makes, and the same one the `mine_detonated` event
## carries -- the caller needs it for the picture and nothing else.
var blast: Dictionary = {}
var reason: String = ""
## What the `MoveUnit` event returned, or an empty dictionary when the walk
## never got far enough to fire it. docs/20 section 5: the event fires **after**
## the walk, so a refusal here cannot un-walk it.
var script_result: Dictionary = {}

## The cells the walk actually entered, **source first**, in travel order --
## `[start, first step, ..., where the unit stopped]`. Not the reconstructed
## path: a walk can stop short of it on the budget or on a mine, and this is
## what happened rather than what was planned.
##
## Deliberately **not** in [method to_dict]. That document is diffed against
## `inclib.movemap.ExecuteResult.to_dict` and pinned by the native capture in
## `tests/fixtures/movemap/cases_native.json`, which the engine emitted and
## which cannot grow a field the engine never had. This is presentation data
## for [AIPlayback], carried in the move event's payload instead.
var route: PackedInt32Array = PackedInt32Array()

## Every reaction shot the walk drew -- docs/25 section 6. Empty when nobody was
## on overwatch, which is every walk on a mission the player has not used the
## **Def** button on. The drain runs in the *caller* (docs/23 section 5.3's
## tail calls `aExecuteFight` after `aExecuteMove`), so this is filled in by
## [method World.submit_move] and not by [ExecuteMove].
var reactions: Array[Dictionary] = []

## `aExecuteMove`'s two locals from the passes it runs before the first step
## (docs/42 section 3.2), as they stand after the `+0x0C > 6` discard: would
## the mover see an enemy from the destination, and -- asked for a computer
## mover only -- from the source. Filled in by [method ExecuteMove.execute],
## not by [method ExecuteMove.run], and kept out of [method to_dict] for the
## same reason as [member route].
var seen_destination: bool = false
var seen_source: bool = false


static func failed(fx: int, fy: int, why: String) -> MoveResult:
	var result: MoveResult = MoveResult.new()
	result.x = fx
	result.y = fy
	result.reason = why
	return result


func to_dict() -> Dictionary:
	var writes: Array = []
	for write: Vector2i in action_point_writes:
		writes.append([write.x, write.y])
	return {
		"ok": ok,
		"x": x,
		"y": y,
		"cost": cost,
		"steps": steps,
		"walked": walked,
		"facing": facing,
		"action_point_writes": writes,
		"events": events.duplicate(true),
		"movement_zeroed": movement_zeroed,
		"reactions": reactions.duplicate(true),
	}
