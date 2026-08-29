class_name TestFixtures
extends RefCounted

## Synthetic worlds built in memory, with no cache and no filesystem.
##
## These are the only inputs that can exercise fire, mines, shields, ladders,
## hidden units and the `special` refusals in a *unit* test: none of them occurs
## on any shipped map.  The native capture reaches them too, by writing the same
## fields in the live process, so the two are cross-checks rather than
## substitutes.

## docs/21 section 2 -- the eleven shipped control-map types with their delays.
const CTRLMAP_ROWS: Array[Dictionary] = [
	{"index": 0, "type": 0, "delay": 0, "cover": 0, "name": "Undefined"},
	{"index": 1, "type": 1, "delay": 0, "cover": 0, "name": "Free Place"},
	{"index": 2, "type": 2, "delay": 255, "cover": 255, "name": "Wall"},
	{"index": 3, "type": 3, "delay": 255, "cover": 255, "name": "Hole"},
	{"index": 4, "type": 4, "delay": 255, "cover": 255, "name": "Deep Hole"},
	{"index": 5, "type": 5, "delay": 1, "cover": 0, "name": "Debris"},
	{"index": 6, "type": 6, "delay": 0, "cover": 0, "name": "Poison"},
	{"index": 7, "type": 7, "delay": 255, "cover": 40, "name": "Enormous Obs"},
	{"index": 8, "type": 8, "delay": 0, "cover": 0, "name": "Ladder"},
	{"index": 9, "type": 9, "delay": 0, "cover": 0, "name": "Teleporter Entry"},
	{"index": 10, "type": 10, "delay": 255, "cover": 0, "name": "Teleporter Exit"},
]


static func unit_type(id: int, special: int = 0, unit_size: int = 0,
		mp_max: int = 6) -> Dictionary:
	return {
		"id": id, "mp_max": mp_max, "hp_max": 20, "special": special,
		"size": unit_size, "species": 0, "height": 18,
		"model": "A_MK_0B.3DI", "description": "type %d" % id,
	}


static func balance(extra_types: Array = []) -> Dictionary:
	var types: Array = [
		unit_type(0), unit_type(1, 1), unit_type(14, 14), unit_type(15, 15),
		unit_type(99, 0, 1),
	]
	types.append_array(extra_types)
	return {"ctrlmap": CTRLMAP_ROWS, "units": types}


static func unit(slot: int, x: int, y: int, type_id: int = 0, player: int = 0,
		mp: int = 4, visibility: int = 0,
		equipment: Array = []) -> Dictionary:
	return {
		"slot": slot, "name": "unit %d" % slot, "type_id": type_id,
		"player": player, "x": x, "y": y, "hit_points": 10,
		# 255 is what all but the 70 human-type shipped units carry; 0 and 1
		# are the two values that override the movement allowance, so a
		# fixture defaulting to 0 would silently exercise an override.
		"action_points": mp, "ep": 0, "rank": 0, "fp": 255, "tp": 0,
		"rested": 0, "action_state": 0,
		"skills": {}, "equipment_ids": equipment, "weapon": 0, "facing": 0,
		"order": 0, "order_param": 0, "order2": 0, "order2_param": 0,
		"group": 0, "visibility": visibility, "placed": true,
	}


## A `w` x `h` grid of Free Place at height 0, with the given units on it.
static func map_document(w: int, h: int, units: Array,
		field_types: Array = [], heights: Array = []) -> Dictionary:
	var n: int = w * h
	var ft: Array = field_types
	if ft.is_empty():
		ft = []
		for _i: int in range(n):
			ft.append(1)
	var hs: Array = heights
	if hs.is_empty():
		hs = []
		for _i: int in range(n):
			hs.append(0)
	var zeros: Array = []
	var links: Array = []
	for _i: int in range(n):
		zeros.append(0)
		links.append(-1)
	for record: Variant in units:
		var view: Dictionary = record
		links[DictRead.as_int(view["y"]) * w + DictRead.as_int(view["x"])] = DictRead.as_int(view["slot"])
	return {
		"schema": "incubation.map/1",
		"source": {},
		"header": {
			"name": "SYNTHETIC", "next_map": "", "map_type": 1,
			"mission_id": 0, "world_set": "A00", "world_scene": "Synthetic",
			"camera_height": 32000, "equip_points": [0, 0, 0, 0],
			"skill_level": 0, "tech_level": 0,
		},
		"width": w, "height": h,
		"cells": {
			"height": hs, "field_type": ft, "action_point": zeros.duplicate(),
			"unit": links, "effect0": zeros.duplicate(),
			"effect1": zeros.duplicate(), "effect2": zeros.duplicate(),
			"effect3": zeros.duplicate(), "land": zeros.duplicate(),
			"start_index": links.duplicate(), "decal0": zeros.duplicate(),
			"decal1": zeros.duplicate(),
		},
		"units": units,
		"land": {"prototype": "S003_00X.3DI", "x": [], "y": [], "z": [],
			"yaw": [], "grid_x": [], "grid_y": []},
		"special_objects": [],
		"scene_clones": [],
		"marker": null,
		"diagnostics": {"clone_count_header": 0, "clone_count_parsed": 0,
			"warnings": []},
	}


static func tiny_world() -> World:
	var units: Array = [unit(0, 2, 2), unit(1, 4, 2, 0, 1)]
	return World.create(map_document(7, 7, units), balance(), 1.0)


## A different authored map, so a save from one can be offered to the other.
static func other_world() -> World:
	var units: Array = [unit(0, 1, 1)]
	var doc: Dictionary = map_document(7, 7, units)
	var cells: Dictionary = doc["cells"]
	var heights: Array = cells["height"]
	heights[0] = 6400
	return World.create(doc, balance(), 1.0)
