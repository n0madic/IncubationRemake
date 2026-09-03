class_name CampaignMap
extends RefCounted

## The location graph -- docs/27 section 2.
##
## Baked by the converter into `tables/campaign.json`, as **lists of records**
## with integer ids (D12): a JSON object's key is a string, and the cache has
## to carry integers. So the tables are indexed here, once, at the loading
## boundary, and nothing downstream parses a key back out of a string.
##
## What a remake does **not** need is the campaign map as a 3D `.lev`
## (docs/27 section 8): `_C_XXX` and `_C_YYY` carry the location cells and
## their world positions, and a remake is free to draw its own map as long as
## the ids match. This slice draws theirs, through the existing renderer (D3).

## docs/27 section 2.2 -- `location = missionId + 50`, at `0x004541D5` and
## `0x00455486`.
const LOCATION_BIAS: int = 50

const KIND_NONE: String = "none"
const KIND_BATTLE: String = "battle"
const KIND_UPGRADE: String = "upgrade"
const KIND_DIALOGUE: String = "dialogue"

## location -> mission basename (`aMapName` `0x0045C200`).
var _map_names: Dictionary = {}
## mission id -> the location ids `aCreateLocationMap` opens.
var _unlock_graph: Dictionary = {}
## location -> the dialogue number its arm passes.
var _dialogue: Dictionary = {}
## location -> the `upgrade_N.lev` it loads.
var _upgrade: Dictionary = {}
## mission basename -> its header's next map.
var _chain: Dictionary = {}
## mission basename -> its mission id.
var _mission_ids: Dictionary = {}
## mission basename -> its deployment cells, as `Vector2i`.
var _deployment: Dictionary = {}
## Locations naming a mission the release does not ship (85, 86, 87).
var _cut: PackedInt32Array = PackedInt32Array()
## `_C_XXX`'s two leftovers, which no arm ever opens.
var _unreachable: PackedInt32Array = PackedInt32Array()


static func from_document(document: Dictionary) -> CampaignMap:
	var out: CampaignMap = CampaignMap.new()
	for row: Variant in DictRead.as_array(document["map_names"]):
		var entry: Dictionary = row
		out._map_names[DictRead.as_int(entry["location"])] = \
			DictRead.as_string(entry["mission"])
	for row: Variant in DictRead.as_array(document["unlock_graph"]):
		var entry: Dictionary = row
		out._unlock_graph[DictRead.as_int(entry["mission"])] = \
			DictRead.to_int32(entry["opens"])
	for row: Variant in DictRead.as_array(document["dialogue"]):
		var entry: Dictionary = row
		out._dialogue[DictRead.as_int(entry["location"])] = \
			DictRead.as_int(entry["sequence"])
	for row: Variant in DictRead.as_array(document["upgrade"]):
		var entry: Dictionary = row
		out._upgrade[DictRead.as_int(entry["location"])] = \
			DictRead.as_int(entry["map"])
	for row: Variant in DictRead.as_array(document["missions"]):
		var entry: Dictionary = row
		var name: String = DictRead.as_string(entry["name"])
		out._chain[name] = DictRead.as_string(entry["next_map"])
		out._mission_ids[name] = DictRead.as_int(entry["mission_id"])
		var cells: Array[Vector2i] = []
		for pair: Variant in DictRead.as_array(entry["deployment_cells"]):
			var xy: Array = pair
			cells.append(Vector2i(DictRead.as_int(xy[0]),
				DictRead.as_int(xy[1])))
		out._deployment[name] = cells
	for row: Variant in DictRead.as_array(document["cut_locations"]):
		var entry: Dictionary = row
		out._cut.append(DictRead.as_int(entry["location"]))
	out._unreachable = DictRead.to_int32(document["unreachable_locations"])
	return out


# -- the graph -----------------------------------------------------------------

## docs/27 section 2.2. The forward direction is one addition.
func location_of(mission_id: int) -> int:
	return mission_id + LOCATION_BIAS


## `aMapName` `0x0045C200`. The inverse is a **table**, not a subtraction:
## `_C_104` and `_C_105` are crossed, and so are their mission ids.
func mission_of(location: int) -> String:
	return DictRead.as_string(_map_names.get(location, ""))


## `aCreateLocationMap` `0x00431420` -- the map as it looks when *mission_id* is
## the one to play next. Every arm passes 1; nothing ever closes a location.
func open_locations(mission_id: int) -> PackedInt32Array:
	if not _unlock_graph.has(mission_id):
		return PackedInt32Array()
	var out: PackedInt32Array = DictRead.to_int32(_unlock_graph[mission_id])
	out.sort()
	return out


## Which of `aLocationHandling`'s three kinds of arm a location reaches.
func kind_of(location: int) -> String:
	if _upgrade.has(location):
		return KIND_UPGRADE
	if _dialogue.has(location):
		return KIND_DIALOGUE
	if _map_names.has(location):
		return KIND_BATTLE
	return KIND_NONE


## docs/27 section 2.4 -- upgrade location *N* loads `Missions/upgrade_M.lev`.
##
## **Locations 3 and 6 load each other's map.** Location 3 (*Fight Position*)
## passes 6 and location 6 (*Assembly Camp*) passes 3; the other thirteen are
## 1:1. Nothing in the data corrects it, so it is the shipped behaviour and it
## is reproduced as it is (D6).
func upgrade_map(location: int) -> String:
	if not _upgrade.has(location):
		return ""
	return "upgrade_%d" % DictRead.as_int(_upgrade[location])


## The dialogue number the arm passes. The sequence player is a later slice, so
## a dialogue location opens and is named and plays nothing (D5).
func dialogue_number(location: int) -> int:
	return DictRead.as_int(_dialogue.get(location, 0))


# -- the chain -----------------------------------------------------------------

## docs/27 section 6.6 -- the `.lev` header's next-map field.
##
## `EnterNameOfNextMap` overrides it at run time, which is why the caller
## passes the world's own value when it has one.
func next_map(mission: String) -> String:
	return DictRead.as_string(_chain.get(mission, ""))


func mission_id(mission: String) -> int:
	return DictRead.as_int(_mission_ids.get(mission, 0))


func has_mission(mission: String) -> bool:
	return _mission_ids.has(mission)


## docs/29 section 1.2 -- the cells a squad deploys onto, baked from the `.lev`.
##
## This is the converter's copy of `action_point == player + 1`. [World] reads
## the same rule off its own [MapResource] at run time; this one exists so the
## campaign screens can say how many a mission takes before loading it.
func deployment_cells(mission: String) -> Array[Vector2i]:
	if not _deployment.has(mission):
		return []
	var stored: Array[Vector2i] = _deployment[mission]
	return stored.duplicate()


## Locations naming `_C_134`, `_C_135` and `_C_136` -- three missions were cut
## and the table was not.
func cut_locations() -> PackedInt32Array:
	return _cut.duplicate()


## `_C_XXX`'s *TEST EXTRO* and *<<Invalid Location>>*: cells no arm opens.
func unreachable_locations() -> PackedInt32Array:
	return _unreachable.duplicate()
