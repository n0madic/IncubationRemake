class_name ScoreRecord
extends RefCounted

## One player's 40-byte scoreboard record -- docs/11 section 5.5.
##
## The layout is measured, not inferred: `resetScoreboard` `0x0043B990` zeroes
## `+0x00`..`+0x1C` and writes `+0x20 = 1`, and the scorer `0x0043BA10` reads
## `+0x00` as the kills it multiplies and `+0x08` as the losses it doubles,
## then writes `+0x18` and adds into `+0x1C`.
##
## `+0x04`, `+0x0C`, `+0x14` and `+0x24` are carried and **not interpreted**.
## The scorer reads none of them and the six fixture saves disagree on their
## values; naming them would be a guess, and this project's rule is to say so.

## `0x00509F48`, one record per player slot.
const STRIDE: int = 40

## `resetScoreboard`'s value for `+0x20`: "nothing happened", and the reason an
## abandoned mission scores nothing.
const RESULT_NOTHING: int = 1
const RESULT_WON: int = 2
const RESULT_WON_OUTSTANDING: int = 3
const RESULT_WON_GLORIOUS: int = 4
const RESULT_DEFEAT: int = 5

var kills: int = 0          # +0x00
var unknown_04: int = 0     # +0x04
var losses: int = 0         # +0x08
var unknown_0c: int = 0     # +0x0C
var unknown_10: int = 0     # +0x10
var unknown_14: int = 0     # +0x14
var score: int = 0          # +0x18 -- this mission
var total: int = 0          # +0x1C -- the campaign
var result: int = RESULT_NOTHING   # +0x20
var unknown_24: int = 0     # +0x24


## `resetScoreboard` `0x0043B990`.
func reset() -> void:
	kills = 0
	unknown_04 = 0
	losses = 0
	unknown_0c = 0
	unknown_10 = 0
	unknown_14 = 0
	score = 0
	total = 0
	result = RESULT_NOTHING
	unknown_24 = 0


func view() -> Dictionary:
	return {
		"kills": kills,
		"unknown_04": unknown_04,
		"losses": losses,
		"unknown_0c": unknown_0c,
		"unknown_10": unknown_10,
		"unknown_14": unknown_14,
		"score": score,
		"total": total,
		"result": result,
		"unknown_24": unknown_24,
	}


static func from_view(record: Variant) -> ScoreRecord:
	var entry: Dictionary = DictRead.as_dict(record)
	var out: ScoreRecord = ScoreRecord.new()
	out.kills = DictRead.as_int(entry["kills"])
	out.unknown_04 = DictRead.as_int(entry["unknown_04"])
	out.losses = DictRead.as_int(entry["losses"])
	out.unknown_0c = DictRead.as_int(entry["unknown_0c"])
	out.unknown_10 = DictRead.as_int(entry["unknown_10"])
	out.unknown_14 = DictRead.as_int(entry["unknown_14"])
	out.score = DictRead.as_int(entry["score"])
	out.total = DictRead.as_int(entry["total"])
	out.result = DictRead.as_int(entry["result"])
	out.unknown_24 = DictRead.as_int(entry["unknown_24"])
	return out


func hash_into(ctx: HashingContext) -> void:
	ctx.update(PackedInt32Array([kills, unknown_04, losses, unknown_0c,
		unknown_10, unknown_14, score, total, result,
		unknown_24]).to_byte_array())
