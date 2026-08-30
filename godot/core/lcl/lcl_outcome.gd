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
	# The events go out as `[name, values]` **pairs**, which is the shape
	# `inclib.lcl_runtime.Outcome.to_dict` produces. They are held as
	# dictionaries because `game/` reads them by name, and the class doc's
	# claim that a disagreement is a document diff is only true if the two
	# documents have the same shape -- it was not, and the replay quietly
	# compared event names and never event values.
	var pairs: Array = []
	for event: Dictionary in events:
		pairs.append([DictRead.as_string(event["name"]),
			DictRead.as_array(event["values"]).duplicate()])
	return {"kind": kind, "reason": reason, "line": line, "steps": steps,
		"dispatched": dispatched, "events": pairs}
