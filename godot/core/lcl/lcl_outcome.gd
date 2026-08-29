class_name LclOutcome
extends RefCounted

## What one invocation of a mission program did -- docs/20 section 2.
##
## All three kinds are ordinary outcomes of the original: it has no notion of
## "the program crashed". The same shape as `inclib.lcl_runtime.Outcome`, so a
## disagreement between the two implementations is a document diff.

## `[END]` was reached -- the normal stop.
const END: String = "end"
## The cursor ran past the last instruction. docs/20 section 2: the loop simply
## runs out of buffer, so a script with no `[END]` ends this way.
const FELL_OFF: String = "fell_off"
## docs/20 section 2.2 -- report, then return 0. The host gets a zero and
## carries on; the reporter is an empty stub in the release build, so it is
## silent. This is the outcome the hand-over checks (`if (!runProgram())`).
const ABORT: String = "abort"

var kind: String = ABORT
var reason: String = ""
var line: int = 0
var steps: int = 0
## Commands actually dispatched -- i.e. reached with the flag true.
var dispatched: int = 0
## What the model applied but does not simulate: camera moves, sounds and the
## set pieces' animations. Recorded rather than dropped, so `game/` can play
## them and a diff can compare them.
var events: Array[Dictionary] = []


func ok() -> bool:
	return kind != ABORT


func to_dict() -> Dictionary:
	return {"kind": kind, "reason": reason, "line": line, "steps": steps,
		"dispatched": dispatched, "events": events.duplicate(true)}
