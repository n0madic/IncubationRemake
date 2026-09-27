class_name PictureFog
extends RefCounted

## What the player may see, computed over the picture's own world.
##
## Three things used to answer this question separately and disagree: the
## bodies drew from a fresh pass over the truth, the radar and the ground
## overlay read the stored `+0x4F`, and the replay overrode both with a
## snapshot taken before the computer's turn began. The snapshot is what made
## an alien that walked into the squad's sight stay a **contact beam** for the
## rest of the turn -- and, since the beam is a marker with no body, a beam
## that swung its claws and fired with no fight clip to play on.
##
## The engine's own answer is stranger than either. The fog the *rules* read is
## rebuilt at the hand-over and at nothing in between (docs/22 section 9.4), so
## in the original the alien is a contact for the whole of its walk too; what
## the player *sees* follows the per-command probe, whose restore covers the
## unit byte and not the 3D object's draw flag, so the picture runs ahead of
## the rules by exactly one probe (docs/92 section 7.5.5).
##
## **This remake goes one step further, deliberately.** The probe is per
## command, and the computer's turn is one command: reproducing it faithfully
## means the beam stands until the turn changes, which reads as a bug and not
## as a period detail. So the pass is recomputed per event over the lagging
## mirror, for the seat that is watching, with each walker answered at the cell
## its **body** is drawn on rather than the one its state still names. An alien
## comes out of the fog in the frame it comes out of the fog.
## [member beams_until_hand_over] restores the original's timing; it is a
## picture flag and not a `World.compat_flags` entry, because it moves nothing
## the canonical hash covers.

## The seat the picture is drawn for: the human player whose turn it is, or
## whose turn it was when the computer took over. `-1` before a mission.
##
## **Not `turn.current_player`.** That is 255 while the computer holds the
## turn, and a fog pass for 255 is the aliens' own view of the map -- every
## alien fully visible and every marine a contact.
var viewer: int = -1

## Reproduce the original's timing: the stored `+0x4F` of the mirror, which
## the hand-over is the only thing that moves.
var beams_until_hand_over: bool = false

## Slots the engine's own writes reveal for the rest of the replay.
var _reveals: Dictionary[int, bool] = {}
## Slot -> the state a take-back left standing ([method hold]).
var _held: Dictionary[int, int] = {}


## Note what an event revealed, and clear the set where the engine's fog pass
## would have run.
func note_event(kind: String, slot: int, payload: Dictionary) -> void:
	# A hand-over rebuilds the fog outright, so nothing carries past it; a
	# door and a jump rebuild it too (docs/22 section 9.4's permanent sites).
	if kind == "hand_over" or kind == "use" or kind == "warp":
		_reveals.clear()
		_held.clear()
		return
	for revealed: int in reveals_of(kind, slot, payload):
		_reveals[revealed] = true


func clear() -> void:
	_reveals.clear()
	_held.clear()
	viewer = -1


## A take-back on the place interface: *states* is what the picture showed
## before it, and it stands until [method release] or a hand-over.
##
## `aTransferUnitFromMapToPool` rebuilds no fog -- `aKillUnit`'s closure
## reaches no visibility builder, and in the running original an alien only
## the recalled soldier saw keeps its `+0x4F` (docs/43 section 5.5,
## `hud_probe.py` phase `recall`) -- so what was spotted stays on screen
## until the next placement (`0x00478DE4`) or the hand-over passes again.
func hold(states: Dictionary[int, int]) -> void:
	for slot: int in states:
		if not _held.has(slot):
			_held[slot] = states[slot]


## The placement's own fog pass (`0x00478DE4`): the take-back's hold is over.
func release() -> void:
	_held.clear()


func revealed() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for slot: int in _reveals:
		out.append(slot)
	return out


## The answer the whole picture reads -- bodies, radar, ground overlay and the
## click pick, so an alien appears in all four in the same frame.
##
## `at` is where a body is **drawn** for a unit the picture is still walking,
## slot to cell; see `Visibility.states_for`.
func states(shown: World, at: Dictionary[int, Vector2i] = {}) -> Dictionary[int, int]:
	if shown == null:
		return {}
	if beams_until_hand_over:
		var stored: Dictionary[int, int] = {}
		for slot: int in shown.unit_slots():
			stored[slot] = DictRead.as_int(
				shown.unit_view(slot)["visibility"])
		return stored
	var seat: int = viewer
	if seat < 0 or seat == UnitState.PLAYER_ALIEN:
		seat = shown.turn.current_player
	var seen: Dictionary[int, int] = shown.display_visibility(seat, at)
	# **Forced, not merely left alone.** `aExecuteMove`'s mode-3 self reveal
	# (`0x0046E4BB`) and `aAttackUnit`'s two (`0x0046B643`, `0x0046BA22`) are
	# permanent writes the next hand-over undoes, so a unit that showed itself
	# and then stepped back into cover is visible for the rest of the turn.
	for slot: int in _reveals:
		if seen.has(slot):
			seen[slot] = Visibility.FULL
	for slot: int in _held:
		if seen.has(slot):
			seen[slot] = _held[slot]
	return seen


## The engine's own reveals, read off an event rather than off the byte.
##
## Three writes, and all three are behind a test the record does not keep:
##
## * `0x0046E4BB` -- a computer mover seen where it starts is marked visible
##   before it moves (`aExecuteMove`'s animation mode 3, docs/42 section 3.2),
##   which the walk reports as `seen_source`;
## * `0x0046B643` -- the shooter, the moment the weapon is cleared to fire
##   (docs/22 section 7.1). A shot that jammed reveals nobody, which is why
##   the test is the attack's own `fired`;
## * the same reveal for a reaction: `Reaction.drain` fires through
##   `Combat.attack`, so a unit in overwatch that pulls the trigger runs
##   `0x0046B643` too.
static func reveals_of(kind: String, slot: int,
		payload: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if kind == "move" or kind == "move_begin":
		if DictRead.as_bool(payload.get("seen_source", false)) and slot >= 0:
			out.append(slot)
		return out
	if kind == "fire":
		if DictRead.as_bool(payload.get("fired", false)) and slot >= 0:
			out.append(slot)
		return out
	if kind == "reaction":
		# One event per shot since the journal: the reactor is the event's own
		# slot, and the attack under it says whether the trigger was pulled.
		var attack: Dictionary = DictRead.as_dict(payload.get("attack", {}))
		if slot >= 0 and DictRead.as_bool(attack.get("fired", false)):
			out.append(slot)
		return out
	if kind == "reactions":
		# The planner's own list, which the case fixture still carries.
		for item: Variant in DictRead.as_array(payload.get("reactions", [])):
			var entry: Dictionary = DictRead.as_dict(item)
			var reactor: int = DictRead.as_int(entry.get("reactor", -1))
			var shot: Dictionary = DictRead.as_dict(entry.get("attack", {}))
			if reactor >= 0 and DictRead.as_bool(shot.get("fired", false)) \
					and not out.has(reactor):
				out.append(reactor)
	return out
