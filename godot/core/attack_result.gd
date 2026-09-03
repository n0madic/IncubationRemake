class_name AttackResult
extends RefCounted

## What one `aAttackUnit` did -- a value, not a mutation reported by side
## effect.  Same shape as `inclib.combat.AttackResult.to_dict()`, so a
## disagreement between the two implementations is a document diff.

var fired: bool = false
var reason: String = ""
## One of [Combat]'s five overheat outcome names.  The default is spelled out
## rather than taken from [Combat], because [Combat] returns *this* class and a
## reference back would be a cyclic dependency -- which GDScript reports as
## "could not resolve external class member" in whatever file loads third.
var overheat: String = "none"
var facing: int = 0
## `[x, y, marker]` for every cell the weapon covers.
var marked: Array[PackedInt32Array] = []
## One entry per marked cell that held a unit.
var outcomes: Array[Dictionary] = []
## `aAttackUnit`'s own return value: the experience the shot earned, summed
## over its kills (`0x0046BFB8`), which `aPlayFightAnimation` takes as its
## sixth argument and puts in the caption (docs/42 section 4.2).
var xp: int = 0
## How many skill levels the attacker's pool rose by -- the argument of the
## skill orbit `0x00410190` (docs/42 section 7.5), zero when the orbit does
## not play: the level compare at `0x0046C252` and the species test at
## `0x0046C269` both gate it.
var skill_raised: int = 0
## What `aExecuteFight` drained after the shot. The *caller* of `aAttackUnit`
## runs it -- both the UI at `0x004731F5` and the computer's fire routine at
## `0x0040A5AB` -- so it is filled in by [method World.submit_attack] and left
## empty by [method Combat.attack] itself.
var reactions: Array[Dictionary] = []


func to_dict() -> Dictionary:
	var cells: Array = []
	for m: PackedInt32Array in marked:
		cells.append(Array(m))
	return {"fired": fired, "reason": reason, "overheat": overheat,
		"facing": facing, "marked": cells, "outcomes": outcomes.duplicate(),
		"xp": xp, "skill_raised": skill_raised}


## The same document read back, for a caller that only has the dictionary.
##
## The computer's turn is decided in one call and replayed afterwards, so an
## `AIEvent`'s shot reaches `game` as [method to_dict]'s document and not as
## this object. Presenting it needs the outcomes and the overheat name, which
## is exactly what a round trip through here recovers.
##
## [member reactions] is **not** part of the document and is not read: the
## shape is pinned to `inclib.combat.AttackResult.to_dict()`, and the
## computer emits what it drained as its own `reactions` event.
static func from_dict(document: Dictionary) -> AttackResult:
	var result: AttackResult = AttackResult.new()
	result.fired = DictRead.as_bool(document.get("fired", false))
	result.reason = DictRead.as_string(document.get("reason", ""))
	result.overheat = DictRead.as_string(document.get("overheat", "none"))
	result.facing = DictRead.as_int(document.get("facing", 0))
	for cell: Variant in DictRead.as_array(document.get("marked", [])):
		result.marked.append(DictRead.to_int32(cell))
	for entry: Variant in DictRead.as_array(document.get("outcomes", [])):
		result.outcomes.append(DictRead.as_dict(entry))
	# `.get`, like every field above: a case file emitted before the
	# experience model existed carries neither key, and a hard index turns
	# that into a run-ending error rather than a shot with no experience.
	result.xp = DictRead.as_int(document.get("xp", 0))
	result.skill_raised = DictRead.as_int(document.get("skill_raised", 0))
	return result
