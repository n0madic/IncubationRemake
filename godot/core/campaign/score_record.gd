class_name ScoreRecord
extends RefCounted

## One player's 40-byte scoreboard record -- docs/11 section 5.5.
##
## The layout is measured, not inferred: `resetScoreboard` `0x0043B990` zeroes
## `+0x00`..`+0x1C` and writes `+0x20 = 1`, and the scorer `0x0043BA10` reads
## `+0x00` as the kills it multiplies and `+0x08` as the losses it doubles,
## then writes `+0x18` and adds into `+0x1C`.
##
## The record is **four pairs**, each "this mission" beside "the campaign" --
## which is what the debriefing's two reading passes show: `0x0045DF24`..
## `0x0045E44B` read `+0x1C/+0x14/+0x0C/+0x04` and then
## `+0x18/+0x10/+0x08/+0x00`.
##
## | Pair | Mission | Campaign | Written by |
## | --- | --- | --- | --- |
## | kills | `+0x00` | `+0x04` | `0x0043B810` -- the shooter's, on a kill whose players differ |
## | lost | `+0x08` | `+0x0C` | `0x0043B8D0` -- the victim's, from all **eleven** death paths |
## | lost to an enemy | `+0x10` | `+0x14` | `0x0043B860` -- the victim's, beside `0x0043B810` |
## | score | `+0x18` | `+0x1C` | the scorer `0x0043BA10` |
##
## `+0x24` is the hero counter `aRemoveUnitElement` keeps and the LCL predicate
## `HeroKilled` reads (`0x004409E0`). The six fixture saves agree: `+0x04 = 25`
## kills, `+0x0C = 3` lost, `+0x14 = 3` of them to an enemy, `+0x1C = 119`.

## `0x00509F48`, one record per player slot.
const STRIDE: int = 40

## `resetScoreboard`'s value for `+0x20`: "nothing happened", and the reason an
## abandoned mission scores nothing.
const RESULT_NOTHING: int = 1
const RESULT_WON: int = 2
const RESULT_WON_OUTSTANDING: int = 3
const RESULT_WON_GLORIOUS: int = 4
const RESULT_DEFEAT: int = 5

## +0x00 / +0x04 -- kills this mission, and over the campaign.
var kills: int = 0
var campaign_kills: int = 0
## +0x08 / +0x0C -- units lost, from every death path. The scorer doubles the
## mission half.
var losses: int = 0
var campaign_losses: int = 0
## +0x10 / +0x14 -- of those, the ones an enemy killed.
var lost_to_enemy: int = 0
var campaign_lost_to_enemy: int = 0
## +0x18 / +0x1C -- the score.
var score: int = 0
var total: int = 0
## +0x20 -- the mission result.
var result: int = RESULT_NOTHING
## +0x24 -- heroes lost, which `HeroKilled` reads.
var heroes_lost: int = 0


## `resetScoreboard` `0x0043B990`.
func reset() -> void:
	kills = 0
	campaign_kills = 0
	losses = 0
	campaign_losses = 0
	lost_to_enemy = 0
	campaign_lost_to_enemy = 0
	score = 0
	total = 0
	result = RESULT_NOTHING
	heroes_lost = 0


func view() -> Dictionary:
	return {
		"kills": kills,
		"campaign_kills": campaign_kills,
		"losses": losses,
		"campaign_losses": campaign_losses,
		"lost_to_enemy": lost_to_enemy,
		"campaign_lost_to_enemy": campaign_lost_to_enemy,
		"score": score,
		"total": total,
		"result": result,
		"heroes_lost": heroes_lost,
	}


static func from_view(record: Variant) -> ScoreRecord:
	var entry: Dictionary = DictRead.as_dict(record)
	var out: ScoreRecord = ScoreRecord.new()
	out.kills = DictRead.as_int(entry["kills"])
	out.campaign_kills = DictRead.as_int(entry["campaign_kills"])
	out.losses = DictRead.as_int(entry["losses"])
	out.campaign_losses = DictRead.as_int(entry["campaign_losses"])
	out.lost_to_enemy = DictRead.as_int(entry["lost_to_enemy"])
	out.campaign_lost_to_enemy = DictRead.as_int(
		entry["campaign_lost_to_enemy"])
	out.score = DictRead.as_int(entry["score"])
	out.total = DictRead.as_int(entry["total"])
	out.result = DictRead.as_int(entry["result"])
	out.heroes_lost = DictRead.as_int(entry["heroes_lost"])
	return out


func hash_into(ctx: HashingContext) -> void:
	ctx.update(PackedInt32Array([kills, campaign_kills, losses,
		campaign_losses, lost_to_enemy, campaign_lost_to_enemy, score, total,
		result, heroes_lost]).to_byte_array())
