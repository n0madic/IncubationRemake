extends TestSuite

## The battle interface -- docs/43.
##
## Oracle boundary: **specification**, against a fixture that is a second
## reading of the same binary. `tools/hud_tables.py --emit-cases` writes the
## dispatch tables, immediates and plate measurements it pinned out of
## `Incubation.exe` and `plate_5.bmp` into `cases_hud.json`, and this suite
## holds [HudTables] to them -- two transcriptions of one executable that
## share no code (docs/92 section 5.1). The rest is the remake's own layout
## and its rules: the plate cut for any canvas, the overlay's translation of
## `core`'s results into the engine's cell states, the ring, the radar's
## arithmetic, the selection rules the click handler has, and the state-byte
## correction to the end-of-turn facing.
##
## **The fixture is required.** A run without `generated/hud/hud.json` fails
## here rather than shrinking, the way every other suite does.

const FIXTURE: String = "res://generated/hud/hud.json"
## The four canvases the layout is laid out on: 4:3, 16:9, 5:4 and wider
## than any display, in the plate's units.
const CANVASES: Array[Vector2] = [Vector2(640, 480), Vector2(853, 480),
	Vector2(640, 512), Vector2(1120, 480)]

var _cases: Dictionary = {}


func run(h: TestHarness) -> void:
	h.begin("hud", TestHarness.ORACLE_SPEC)
	_cases = CacheFixture.read_json(FIXTURE)
	h.check("fixture.present", not _cases.is_empty(),
		"tools/hud_tables.py --emit-cases tests/fixtures/hud/cases_hud.json "
		+ "--root gog_incubation, then run_tests.sh copies it")
	if _cases.is_empty():
		return
	_overlay_tables(h)
	_ring_tables(h)
	_pad_tables(h)
	_column_tables(h)
	_radar_tables(h)
	_frame_tables(h)
	_progress_tables(h)
	_plate_segments(h)
	_layouts(h)
	_anchor_sign(h)
	_libraries(h)
	_cell_states(h)
	_overlay_live(h)
	_ring_geometry(h)
	_radar_arithmetic(h)
	_selection_rules(h)
	_facing_state_byte(h)
	_ray_round_trip(h)
	_hud_live(h)
	_progress_arithmetic(h)


# --- the tables against the binary -------------------------------------------

func _overlay_tables(h: TestHarness) -> void:
	var overlay: Dictionary = DictRead.as_dict(_cases["overlay"])
	var states: Dictionary = DictRead.as_dict(overlay["states"])
	for key: String in states:
		var state: int = key.to_int()
		var want: Dictionary = DictRead.as_dict(states[key])
		var element: Variant = want["element"]
		var sprite: Array = HudTables.sprite_for_state(state, 7)
		var want_element: int = 7 if element is String else DictRead.as_int(element)
		h.check("overlay.state_%d" % state,
			sprite.size() == 2 and DictRead.as_string(sprite[0])
			== DictRead.as_string(want["lib"])
			and DictRead.as_int(sprite[1]) == want_element,
			"%s -> %s" % [str(sprite), str(want)])
		h.equal("overlay.state_%d.hover_gated" % state,
			HudTables.HOVER_GATED_STATES.has(state),
			DictRead.as_bool(want["hover_gated"]))
	var state_map: Array = DictRead.as_array(overlay["state_map"])
	# Every state the map sends to an arm that draws is one this table has,
	# and every state this table has draws in the binary.
	var drawn_states: Array[int] = []
	for i: int in range(state_map.size()):
		var arm: int = DictRead.as_int(state_map[i])
		if arm != 15 and arm != 0:
			drawn_states.append(i + 1)
	var table_states: Array[int] = []
	for key: Variant in HudTables.STATE_SPRITES:
		table_states.append(DictRead.as_int(key))
	table_states.sort()
	h.equal("overlay.state_map_matches_table", drawn_states, table_states)
	var markers: Dictionary = DictRead.as_dict(overlay["unit_markers"])
	h.equal("overlay.hp_digit_max", HudTables.HP_DIGIT_MAX,
		DictRead.as_int(markers["hp_digit_max"]))
	h.equal("overlay.defending", HudTables.MARKER_DEFENDING,
		DictRead.as_int(markers["defending"]))
	h.equal("overlay.malfunction", HudTables.MARKER_MALFUNCTION,
		DictRead.as_int(markers["malfunction"]))
	h.equal("overlay.panic", HudTables.MARKER_PANIC, DictRead.as_int(markers["panic"]))
	h.equal("overlay.path_frames", [HudTables.PATH_FRAME, HudTables.PATH_FRAME_ALT],
		[DictRead.as_int(markers["path_frame"]),
		DictRead.as_int(markers["path_frame_alt"])])
	h.equal("overlay.hover_frame", HudTables.HOVER_FRAME,
		DictRead.as_int(markers["hover_frame"]))
	h.equal("overlay.vp_letters", [HudTables.vp_letter(80), HudTables.vp_letter(89),
		HudTables.vp_letter(79), HudTables.vp_letter(90)],
		[DictRead.as_int(markers["vp_letter_base"]),
		DictRead.as_int(markers["vp_letter_base"]) + 9, -1, -1])
	h.equal("overlay.zoom_gate", HudTables.ZOOM_GATE, DictRead.as_int(overlay["zoom_gate"]))
	h.check("overlay.blink_period",
		is_equal_approx(HudTables.BLINK_PERIOD_SECONDS,
			DictRead.as_int(overlay["blink_period_ms"]) / 1000.0),
		"100 ms")
	var far: Dictionary = DictRead.as_dict(overlay["far_markers"])
	h.equal("overlay.far_flags", [HudTables.far_flag(0), HudTables.far_flag(3),
		HudTables.far_flag(255), HudTables.FAR_FLAG_HIDDEN, HudTables.FAR_FLAG_BLINK],
		[0, 3, DictRead.as_int(far["neutral_flag"]), DictRead.as_int(far["hidden_flag"]),
		DictRead.as_int(far["blink_flag"])])


func _ring_tables(h: TestHarness) -> void:
	var ring: Dictionary = DictRead.as_dict(_cases["ring"])
	h.equal("ring.letters", Array(HudTables.RING_LETTERS),
		DictRead.as_array(ring["letters"]).map(func(v: Variant) -> int:
			return DictRead.as_int(v)))
	h.equal("ring.cancel", HudTables.RING_CANCEL, DictRead.as_int(ring["cancel_element"]))
	h.equal("ring.tiers", [HudTables.RING_TIER_HOVER, HudTables.RING_TIER_BLOCKED],
		[DictRead.as_int(ring["tier_hover"]), DictRead.as_int(ring["tier_blocked"])])
	h.equal("ring.hit_radius", int(HudTables.RING_HIT_RADIUS),
		DictRead.as_int(ring["hit_radius"]))
	h.equal("ring.hover_distance", int(HudTables.RING_HOVER_DISTANCE),
		DictRead.as_int(ring["hover_distance_max"]))
	var clamp: Dictionary = DictRead.as_dict(ring["clamp"])
	h.equal("ring.clamp", [HudTables.RING_CLAMP_LOW, HudTables.RING_CLAMP_HIGH],
		[DictRead.as_int(clamp["low"]), DictRead.as_int(clamp["high"])])
	var offsets: Array = DictRead.as_array(ring["offsets"])
	var same: bool = offsets.size() == HudTables.RING_OFFSETS.size()
	for i: int in range(mini(offsets.size(), HudTables.RING_OFFSETS.size())):
		var pair: Array = DictRead.as_array(offsets[i])
		same = same and HudTables.RING_OFFSETS[i] == Vector2i(
			DictRead.as_int(pair[0]), DictRead.as_int(pair[1]))
	h.check("ring.offsets", same, "nine records, 0xDDE straight and 0x93E diagonal")
	var deltas: Array = DictRead.as_array(ring["facing_deltas"])
	var deltas_same: bool = deltas.size() == Interact.FACING_DX.size()
	for i: int in range(mini(deltas.size(), Interact.FACING_DX.size())):
		var pair: Array = DictRead.as_array(deltas[i])
		deltas_same = deltas_same and Interact.FACING_DX[i] == DictRead.as_int(pair[0]) \
			and Interact.FACING_DY[i] == DictRead.as_int(pair[1])
	h.check("ring.facing_deltas_are_interacts", deltas_same,
		"fcn.004308C0's table is Interact.FACING_DX/DY")
	h.equal("ring.angles", Array(HudTables.FACING_ANGLES),
		DictRead.as_array(ring["facing_angles"]).map(func(v: Variant) -> int:
			return DictRead.as_int(v)))
	var modes: Dictionary = DictRead.as_dict(ring["modes"])
	h.equal("ring.modes", [HudTables.RING_MODE_MOVE, HudTables.RING_MODE_TURN,
		HudTables.RING_MODE_WARP], [DictRead.as_int(modes["move"]),
		DictRead.as_int(modes["turn"]), DictRead.as_int(modes["warp"])])


func _pad_tables(h: TestHarness) -> void:
	var pad: Dictionary = DictRead.as_dict(_cases["pad"])
	var rect: Dictionary = DictRead.as_dict(pad["rect"])
	var xs: Array = DictRead.as_array(rect["x"])
	var ys: Array = DictRead.as_array(rect["y"])
	var stride: Array = DictRead.as_array(rect["stride"])
	h.equal("pad.origin", HudTables.PAD_ORIGIN,
		Vector2i(DictRead.as_int(xs[0]), DictRead.as_int(ys[0])))
	h.equal("pad.stride", HudTables.PAD_STRIDE,
		Vector2i(DictRead.as_int(stride[0]), DictRead.as_int(stride[1])))
	h.equal("pad.extent", HudTables.PAD_ORIGIN + Vector2i(
		HudTables.PAD_STRIDE.x * HudTables.PAD_COLUMNS,
		HudTables.PAD_STRIDE.y * HudTables.PAD_ROWS),
		Vector2i(DictRead.as_int(xs[1]), DictRead.as_int(ys[1])))
	for row: Variant in DictRead.as_array(pad["commands"]):
		var triple: Array = DictRead.as_array(row)
		h.equal("pad.command_%d_%d" % [DictRead.as_int(triple[0]),
			DictRead.as_int(triple[1])],
			HudTables.pad_command(DictRead.as_int(triple[0]), DictRead.as_int(triple[1])),
			DictRead.as_int(triple[2]))
	var sprites: Dictionary = DictRead.as_dict(pad["sprites"])
	for key: String in sprites:
		h.equal("pad.sprite_%s" % key,
			DictRead.as_int(HudTables.PAD_SPRITES.get(key.to_int(), -1)),
			DictRead.as_int(sprites[key]))
	h.equal("pad.sprite_count", HudTables.PAD_SPRITES.size(), sprites.size())


func _column_tables(h: TestHarness) -> void:
	var columns: Dictionary = DictRead.as_dict(_cases["columns"])
	var rect: Dictionary = DictRead.as_dict(columns["rect"])
	var xs: Array = DictRead.as_array(rect["x"])
	var ys: Array = DictRead.as_array(rect["y"])
	h.equal("columns.x", Array(HudTables.COLUMN_X),
		[DictRead.as_int(DictRead.as_array(xs[0])[0]),
		DictRead.as_int(DictRead.as_array(xs[1])[0])])
	h.equal("columns.width", HudTables.COLUMN_WIDTH,
		DictRead.as_int(DictRead.as_array(xs[0])[1])
		- DictRead.as_int(DictRead.as_array(xs[0])[0]))
	h.equal("columns.top", HudTables.COLUMN_TOP, DictRead.as_int(ys[0]))
	h.equal("columns.row_height", HudTables.COLUMN_ROW_HEIGHT,
		DictRead.as_int(rect["row_height"]))
	h.equal("columns.rows", HudTables.COLUMN_ROWS,
		(DictRead.as_int(ys[1]) - DictRead.as_int(ys[0])) / HudTables.COLUMN_ROW_HEIGHT)
	h.equal("columns.right_shift", HudTables.COLUMN_X[1] - HudTables.COLUMN_X[0],
		DictRead.as_int(columns["right_shift"]))
	var events: Array = DictRead.as_array(columns["events"])
	for column: int in range(events.size()):
		var rows: Array = DictRead.as_array(events[column])
		for row: int in range(rows.size()):
			h.equal("columns.event_%d_%d" % [column, row],
				HudTables.column_event(column, row), DictRead.as_int(rows[row]))
	var sprites: Dictionary = DictRead.as_dict(columns["sprites"])
	for key: String in sprites:
		h.equal("columns.sprite_%s" % key,
			DictRead.as_int(HudTables.COLUMN_SPRITES.get(key.to_int(), -1)),
			DictRead.as_int(sprites[key]))
	h.equal("columns.empty_sprite", HudTables.COLUMN_EMPTY,
		DictRead.as_int(columns["empty_sprite"]))
	var captions: Dictionary = DictRead.as_dict(columns["captions"])
	for key: String in captions:
		var ids: Array = DictRead.as_array(captions[key])
		var mine: Array[int] = [DictRead.as_int(HudTables.COLUMN_CAPTIONS.get(key.to_int(), 0))]
		if key.to_int() == HudTables.EVENT_MAGNIFIER:
			mine.append(HudTables.CAPTION_MAGNIFIER_OFF)
		h.equal("columns.caption_%s" % key, mine,
			ids.map(func(v: Variant) -> int: return DictRead.as_int(v)))
	var at: Array = DictRead.as_array(columns["caption_pos"])
	h.equal("columns.caption_at", HudTables.CAPTION_AT,
		Vector2i(DictRead.as_int(at[0]), DictRead.as_int(at[1])))


func _radar_tables(h: TestHarness) -> void:
	var radar: Dictionary = DictRead.as_dict(_cases["radar"])
	var clip: Array = DictRead.as_array(radar["clip"])
	h.equal("radar.clip", HudTables.RADAR_CLIP, Rect2i(DictRead.as_int(clip[0]),
		DictRead.as_int(clip[1]), DictRead.as_int(clip[2]), DictRead.as_int(clip[3])))
	var centre: Array = DictRead.as_array(radar["centre"])
	h.equal("radar.centre", HudTables.RADAR_CENTRE,
		Vector2i(DictRead.as_int(centre[0]), DictRead.as_int(centre[1])))
	h.equal("radar.scale", [HudTables.RADAR_SCALE_DEFAULT, HudTables.RADAR_SCALE_STEP,
		HudTables.RADAR_SCALE_MIN, HudTables.RADAR_SCALE_MAX, HudTables.RADAR_SPLIT_X],
		[DictRead.as_int(radar["scale_default"]), DictRead.as_int(radar["scale_step"]),
		DictRead.as_int(DictRead.as_array(radar["scale_range"])[0]),
		DictRead.as_int(DictRead.as_array(radar["scale_range"])[1]),
		DictRead.as_int(radar["scale_split"])])
	var click: Array = DictRead.as_array(radar["click_rect"])
	h.equal("radar.click_rect", [HudTables.RADAR_CLICK.position.x,
		HudTables.RADAR_CLICK.position.x + HudTables.RADAR_CLICK.size.x,
		HudTables.RADAR_CLICK.position.y,
		HudTables.RADAR_CLICK.position.y + HudTables.RADAR_CLICK.size.y],
		click.map(func(v: Variant) -> int: return DictRead.as_int(v)))
	var compass: Dictionary = DictRead.as_dict(radar["compass"])
	var letters: Array[String] = ["N", "S", "W", "E"]
	for i: int in range(letters.size()):
		var at: Array = DictRead.as_array(compass[letters[i]])
		h.equal("radar.compass_%s" % letters[i], HudTables.RADAR_COMPASS[i],
			Vector2i(DictRead.as_int(at[0]), DictRead.as_int(at[1])))
		h.equal("radar.compass_sprite_%s" % letters[i], HudTables.RADAR_COMPASS_SPRITES[i],
			DictRead.as_int(DictRead.as_dict(radar["compass_sprites"])[letters[i]]))
	var units: Dictionary = DictRead.as_dict(radar["unit_sprites"])
	h.equal("radar.unit_sprites", [HudTables.RADAR_OWN, HudTables.RADAR_OWN_NO_MP,
		HudTables.RADAR_OWN_SELECTED, HudTables.RADAR_OTHER_PLAIN,
		HudTables.RADAR_OTHER_MARKED, HudTables.RADAR_DETECTED],
		[DictRead.as_int(units["own"]), DictRead.as_int(units["own_no_mp"]),
		DictRead.as_int(units["own_selected"]), DictRead.as_int(units["other_seen"]),
		DictRead.as_int(units["other"]), DictRead.as_int(units["hidden"])])
	var lamp: Array = DictRead.as_array(radar["lamp"])
	h.equal("radar.lamp", HudTables.RADAR_LAMP_AT,
		Vector2i(DictRead.as_int(lamp[0]), DictRead.as_int(lamp[1])))
	var lamps: Dictionary = DictRead.as_dict(radar["lamp_sprites"])
	h.equal("radar.lamp_sprites", [HudTables.RADAR_LAMP_VISIBLE, HudTables.RADAR_LAMP_DETECTED],
		[DictRead.as_int(lamps["enemy_visible"]), DictRead.as_int(lamps["enemy_detected"])])


## docs/43 section 7 -- the watched player's bar, against the binary.
func _progress_tables(h: TestHarness) -> void:
	var bar: Dictionary = DictRead.as_dict(_cases["progress"])
	var origin: Array = DictRead.as_array(bar["origin"])
	h.equal("progress.origin", HudTables.PROGRESS_ORIGIN,
		Vector2i(DictRead.as_int(origin[0]), DictRead.as_int(origin[1])))
	h.equal("progress.segments", HudTables.PROGRESS_SEGMENTS,
		DictRead.as_int(bar["segments"]))
	h.equal("progress.steps", HudTables.PROGRESS_STEPS,
		DictRead.as_int(bar["steps"]))
	h.equal("progress.elements",
		[HudTables.PROGRESS_LIT, HudTables.PROGRESS_DARK],
		[DictRead.as_int(bar["lit_element"]),
			DictRead.as_int(bar["dark_element"])])
	h.equal("progress.library", HudTables.LIB_PROGRESS,
		DictRead.as_string(bar["library"]))
	h.equal("progress.wave", HudTables.PROGRESS_WAVE,
		DictRead.as_string(bar["wave"]))
	# The capsules are one element width apart, and the fixture carries both
	# elements of the library the engine steps through.
	var vp: Array = DictRead.as_array(
		DictRead.as_dict(_cases["libs"])["vp"])
	h.equal("progress.capsule_count", vp.size(), 2)
	h.equal("progress.capsule_size",
		[DictRead.as_int(DictRead.as_dict(vp[0])["w"]),
			DictRead.as_int(DictRead.as_dict(vp[1])["w"])], [15, 15])
	h.check("progress.bar_fits_the_panel",
		HudTables.PROGRESS_ORIGIN.x
		+ HudTables.PROGRESS_SEGMENTS * DictRead.as_int(
			DictRead.as_dict(vp[0])["w"]) <= HudTables.PLATE_SIZE.x,
		"twenty-two capsules of fifteen from x 59 stay on the plate")


func _frame_tables(h: TestHarness) -> void:
	var frame: Dictionary = DictRead.as_dict(_cases["frame"])
	var window: Array = DictRead.as_array(frame["window"])
	h.equal("frame.window", HudTables.WINDOW, Rect2i(DictRead.as_int(window[0]),
		DictRead.as_int(window[1]), DictRead.as_int(window[2]), DictRead.as_int(window[3])))
	h.equal("frame.window_is_the_deploy_screens", Rect2(HudTables.WINDOW),
		SelectUnitsScreen.DEPLOY_WINDOW)
	var turn: Array = DictRead.as_array(frame["turn_text"])
	h.equal("frame.turn_text", HudTables.TURN_TEXT_AT,
		Vector2i(DictRead.as_int(turn[0]), DictRead.as_int(turn[1])))
	h.equal("frame.turn_red_within", HudTables.TURN_RED_WITHIN,
		DictRead.as_int(frame["turn_red_within"]))
	var panel: Dictionary = DictRead.as_dict(_cases["panel"])
	var origin: Array = DictRead.as_array(panel["origin"])
	h.equal("panel.origin", HudTables.PANEL_ORIGIN,
		Vector2i(DictRead.as_int(origin[0]), DictRead.as_int(origin[1])))
	h.equal("panel.name_y", HudTables.PANEL_NAME_Y, DictRead.as_int(panel["name_y"]))
	var blocks: Dictionary = DictRead.as_dict(panel["blocks"])
	var mine: Dictionary = {"hp": HudTables.PANEL_BLOCK_HP,
		"experience": HudTables.PANEL_BLOCK_EXPERIENCE,
		"weapon": HudTables.PANEL_BLOCK_WEAPON,
		"movement": HudTables.PANEL_BLOCK_MOVEMENT,
		"skills": HudTables.PANEL_BLOCK_SKILLS}
	for key: String in blocks:
		var pair: Array = DictRead.as_array(blocks[key])
		h.equal("panel.block_%s" % key, mine[key],
			Vector2i(DictRead.as_int(pair[0]), DictRead.as_int(pair[1])))
	var icons: Dictionary = DictRead.as_dict(panel["icons"])
	h.equal("panel.icons", [HudTables.ICON_HP_FRAME, HudTables.ICON_CLASS_MARINE,
		HudTables.ICON_CLASS_ALIEN, HudTables.ICON_CLASS_ROBOT, HudTables.ICON_ARMOUR_RUNG,
		HudTables.ICON_WOUND_DOT, HudTables.ICON_EXPERIENCE_FRAME, HudTables.ICON_TIER_DISC,
		HudTables.ICON_DECORATION_FIRST, HudTables.ICON_WEAPON_FRAME, HudTables.ICON_LAMP_A,
		HudTables.ICON_LAMP_B, HudTables.ICON_MALFUNCTION_FIRST, HudTables.ICON_MOVEMENT_DISC],
		[DictRead.as_int(icons["hp_frame"]), DictRead.as_int(icons["class_marine"]),
		DictRead.as_int(icons["class_alien"]), DictRead.as_int(icons["class_robot"]),
		DictRead.as_int(icons["armour_rung"]), DictRead.as_int(icons["wound_dot"]),
		DictRead.as_int(icons["experience_frame"]), DictRead.as_int(icons["tier_disc"]),
		DictRead.as_int(icons["decoration_first"]), DictRead.as_int(icons["weapon_frame"]),
		DictRead.as_int(icons["lamp_a"]), DictRead.as_int(icons["lamp_b"]),
		DictRead.as_int(icons["malfunction_first"]),
		DictRead.as_int(icons["movement_disc"])])
	var status: Dictionary = DictRead.as_dict(panel["status_text"])
	h.equal("panel.status_text", [HudTables.TEXT_PANIC, HudTables.TEXT_LIGHT_PANIC,
		HudTables.TEXT_HOT, HudTables.TEXT_NO_AMMO],
		[DictRead.as_int(status["panic"]), DictRead.as_int(status["light_panic"]),
		DictRead.as_int(status["hot"]), DictRead.as_int(status["no_ammo"])])


# --- the plate ---------------------------------------------------------------

func _plate_segments(h: TestHarness) -> void:
	var plate: Dictionary = DictRead.as_dict(_cases["plate"])
	var size: Array = DictRead.as_array(plate["size"])
	h.equal("plate.size", HudTables.PLATE_SIZE,
		Vector2i(DictRead.as_int(size[0]), DictRead.as_int(size[1])))
	var segments: Array = DictRead.as_array(plate["segments"])
	h.equal("plate.segment_count", HudTables.PLATE_SEGMENTS.size(), segments.size())
	for i: int in range(mini(segments.size(), HudTables.PLATE_SEGMENTS.size())):
		var want: Dictionary = DictRead.as_dict(segments[i])
		var mine: Dictionary = HudTables.PLATE_SEGMENTS[i]
		var region: Array = DictRead.as_array(want["region"])
		var mine_region: Rect2i = mine["region"]
		h.check("plate.segment_%s" % DictRead.as_string(want["name"]),
			DictRead.as_string(mine["name"]) == DictRead.as_string(want["name"])
			and mine_region == Rect2i(DictRead.as_int(region[0]), DictRead.as_int(region[1]),
				DictRead.as_int(region[2]), DictRead.as_int(region[3]))
			and DictRead.as_string(mine["anchor"]) == DictRead.as_string(want["anchor"])
			and DictRead.as_string(mine["kind"]) == DictRead.as_string(want["kind"]),
			str(mine))
	# **A filler is one row.** It repeats down whatever height a taller canvas
	# has, so a slice with any pattern in it shows as a stripe every time the
	# pattern comes round -- which is what a 12-row slice of the column's rim
	# did on a portrait screen.
	var one_row: bool = true
	for piece: Dictionary in HudTables.PLATE_SEGMENTS:
		if DictRead.as_string(piece["kind"]) != "filler":
			continue
		var slice: Rect2i = piece["region"]
		if slice.size.y != 1:
			one_row = false
	h.check("plate.fillers_are_one_row", one_row,
		"a vertical filler extrudes; it must not repeat a pattern")
	# The measured features lie on the pieces that carry them: the radar
	# screen and the pad sockets on the bottom-right piece, the turn window on
	# the top-right one, the panel inset starting on the bottom-left one.
	var features: Dictionary = DictRead.as_dict(plate["features"])
	var radar: Array = DictRead.as_array(features["radar_screen"])
	var bottom_right: Rect2i = HudTables.PLATE_SEGMENTS[9]["region"]
	h.check("plate.radar_on_bottom_right",
		bottom_right.encloses(Rect2i(DictRead.as_int(radar[0]), DictRead.as_int(radar[1]),
			DictRead.as_int(radar[2]), DictRead.as_int(radar[3]))), str(radar))
	var sockets: Array = DictRead.as_array(features["pad_socket_columns"])
	h.check("plate.pad_on_bottom_right",
		DictRead.as_int(DictRead.as_array(sockets[0])[0]) >= bottom_right.position.x
		and DictRead.as_int(DictRead.as_array(sockets[2])[1])
		< bottom_right.position.x + bottom_right.size.x, str(sockets))
	var turn_x: Array = DictRead.as_array(features["turn_window_x"])
	var top_right: Rect2i = HudTables.PLATE_SEGMENTS[2]["region"]
	h.check("plate.turn_window_on_top_right",
		DictRead.as_int(turn_x[0]) >= top_right.position.x
		and HudTables.TURN_TEXT_AT.x > top_right.position.x, str(turn_x))
	var inset_x: Array = DictRead.as_array(features["inset_x"])
	var bottom_left: Rect2i = HudTables.PLATE_SEGMENTS[7]["region"]
	h.check("plate.panel_starts_on_bottom_left",
		DictRead.as_int(inset_x[0]) >= bottom_left.position.x
		and HudTables.PANEL_ORIGIN.x >= DictRead.as_int(inset_x[0])
		and HudTables.PANEL_ORIGIN.x < bottom_left.position.x + bottom_left.size.x,
		str(inset_x))


## The layout on four canvases: the pieces tile the frame around the window
## with no overlap, the fixed ones keep their size, the window is the rest.
func _layouts(h: TestHarness) -> void:
	for canvas: Vector2 in CANVASES:
		var label: String = "%dx%d" % [int(canvas.x), int(canvas.y)]
		var rects: Array[Rect2] = PlateLayout.rects_for(canvas)
		var window: Rect2 = HudTables.window_for(canvas)
		h.equal("layout.%s.window" % label, window,
			Rect2(60.0, 34.0, canvas.x - 120.0, canvas.y - 140.0))
		var area: float = 0.0
		var overlap: bool = false
		var inside: bool = true
		var placed: Array[Rect2] = []
		for i: int in range(rects.size()):
			var kind: String = DictRead.as_string(HudTables.PLATE_SEGMENTS[i]["kind"])
			var rect: Rect2 = rects[i]
			if kind == "fixed":
				var region: Rect2i = HudTables.PLATE_SEGMENTS[i]["region"]
				if rect.size != Vector2(region.size):
					inside = false
			if rect.size.x <= 0.0 or rect.size.y <= 0.0:
				continue
			for other: Rect2 in placed:
				if other.intersects(rect):
					overlap = true
			placed.append(rect)
			area += rect.get_area()
			if not Rect2(Vector2.ZERO, canvas).encloses(rect):
				inside = false
			if rect.intersects(window):
				overlap = true
		h.check("layout.%s.no_overlap" % label, not overlap,
			"pieces neither overlap each other nor the window")
		h.check("layout.%s.fixed_keep_size_and_fit" % label, inside,
			"every fixed piece its own pixels, everything on the canvas")
		h.check("layout.%s.tiles_the_frame" % label,
			is_equal_approx(area + window.get_area(), canvas.x * canvas.y),
			"pieces + window = canvas: %.0f + %.0f vs %.0f" % [area,
				window.get_area(), canvas.x * canvas.y])
		# The widgets stay on their pieces and on the canvas.
		var pad_far: Vector2 = PlateLayout.anchored(Vector2(HudTables.pad_socket_at(2, 1)
			+ HudTables.PAD_STRIDE), canvas, "bottom_right")
		var radar_far: Vector2 = PlateLayout.anchored(Vector2(HudTables.RADAR_CLIP.end),
			canvas, "bottom_right")
		var right_column: Vector2 = PlateLayout.anchored(
			Vector2(HudTables.column_slot_at(1, 8)), canvas, "top_right")
		h.check("layout.%s.widgets_on_canvas" % label,
			pad_far.x <= canvas.x and pad_far.y <= canvas.y
			and radar_far.x <= canvas.x and radar_far.y <= canvas.y
			and right_column.x + HudTables.COLUMN_WIDTH <= canvas.x
			and right_column.y + HudTables.COLUMN_ROW_HEIGHT <= window.end.y,
			"pad %s radar %s column %s" % [str(pad_far), str(radar_far), str(right_column)])
	# On 4:3 the layout is the original's plate to the pixel.
	var plain: Array[Rect2] = PlateLayout.rects_for(Vector2(640, 480))
	var exact: bool = true
	for i: int in range(plain.size()):
		var kind: String = DictRead.as_string(HudTables.PLATE_SEGMENTS[i]["kind"])
		var cut: Rect2i = HudTables.PLATE_SEGMENTS[i]["region"]
		var region: Rect2 = Rect2(cut)
		if kind == "filler":
			exact = exact and plain[i].size.y == 0.0
		else:
			exact = exact and plain[i] == region
	h.check("layout.640x480_is_the_plate", exact, "every piece where it was cut from")
	h.equal("layout.anchored_moves_with_the_corner",
		PlateLayout.anchored(Vector2(600, 400), Vector2(853, 512), "bottom_right"),
		Vector2(813, 432))


## [Sprite3D] grows a non-centred texture right and **up** from its origin,
## which is what the anchor arithmetic has to invert. Measured with the
## generated mesh's bounds (a 13x15 texture, `offset (0, 7)`, bounds from
## y 7 to 22), and pinned here as the function the overlay uses.
func _anchor_sign(h: TestHarness) -> void:
	h.equal("anchor.dir_letter", GroundSprites.anchor_offset(Vector2i(6, 7), 15),
		Vector2(-6.0, -8.0), "texel (6, 7) of a 13x15 letter on the origin")
	h.equal("anchor.digit", GroundSprites.anchor_offset(Vector2i(4, 4), 9),
		Vector2(-4.0, -5.0))
	h.equal("anchor.top_left", GroundSprites.anchor_offset(Vector2i.ZERO, 10),
		Vector2(0.0, -10.0), "no anchor: the top-left texel on the origin")
	h.check("anchor.pixel_size_is_the_windows_focal",
		is_equal_approx(GroundSprites.pixel_size(), 1.0 / 400.0),
		"one texel = one unit of 640x480 at focal 400")


## The interface libraries the fixture measured are what the cache carries.
func _libraries(h: TestHarness) -> void:
	var art: Art = Art.open(CacheFixture.cache_dir())
	var libs: Dictionary = DictRead.as_dict(_cases["libs"])
	for name: String in libs:
		var elements: Array = DictRead.as_array(libs[name])
		h.equal("lib.%s.count" % name, art.sprite_count(name), elements.size())
		var anchors_agree: bool = true
		for i: int in range(elements.size()):
			var want: Dictionary = DictRead.as_dict(elements[i])
			var offset: Vector2i = art.sprite_offset(name, i)
			if offset != Vector2i(DictRead.as_int(want["dx"]), DictRead.as_int(want["dy"])):
				anchors_agree = false
			var texture: Texture2D = art.sprite(name, i)
			if texture != null and (texture.get_width() != DictRead.as_int(want["w"])
					or texture.get_height() != DictRead.as_int(want["h"])):
				anchors_agree = false
		h.check("lib.%s.anchors_and_sizes" % name, anchors_agree,
			"every element's +0x1C/+0x20 and size as the LIB has them")


# --- the overlay --------------------------------------------------------------

func _cell_states(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("states.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var slot: int = _first_of_player(world, 0)
	var query: MoveMapResult = world.submit_move_query(MoveQueryCommand.create(slot))
	var view: Dictionary = world.unit_view(slot)
	var own: Vector2i = Vector2i(DictRead.as_int(view["x"]), DictRead.as_int(view["y"]))
	# The band goes on a **body**: since docs/100 a band over a cell with no
	# live, drawn unit on it is not stamped, because the bands are computed on
	# the truth and the mirror lags it by a command (`test_game_ui`'s
	# `overlay.*` checks pin the filter itself).
	var alien: int = _first_of_player(world, UnitState.PLAYER_ALIEN)
	var _seen: bool = world.apply_unit_record(alien, {"visibility": Visibility.FULL})
	var alien_view: Dictionary = world.unit_view(alien)
	var band_cell: Vector2i = Vector2i(DictRead.as_int(alien_view["x"]),
		DictRead.as_int(alien_view["y"]))
	var bands: Dictionary[Vector2i, int] = {band_cell: 33}
	var states: Dictionary[Vector2i, int] = GroundSprites.cell_states(world, slot,
		query, bands)
	var reachable: int = 0
	var translated: bool = true
	# `aWalkMoveMap`'s own value. Nothing may produce it: the state is written
	# by every move in the game and drawn by none (docs/43 section 3.1), and
	# a marked walk was what the remake used to show.
	var walk_mark: int = 100
	var marked_walk: bool = false
	for cell: Vector2i in states:
		var state: int = states[cell]
		if state == HudTables.STATE_REACHABLE:
			reachable += 1
			translated = translated and query.is_reachable(cell.x, cell.y)
		elif state == HudTables.STATE_WARP:
			translated = translated and query.is_warp_target(cell.x, cell.y)
		elif state == walk_mark:
			marked_walk = true
	h.equal("states.own_cell_is_50", states.get(own, 0), HudTables.STATE_OWN_CELL)
	var overwritten: int = 1
	if query.is_reachable(band_cell.x, band_cell.y):
		overwritten += 1
	h.equal("states.reachable_are_10", reachable, query.reachable_count() - overwritten,
		"every reachable cell but the mover's own and the band's")
	h.check("states.translated_from_the_fill", translated, "10 and 60 from the query")
	h.equal("states.band_stamped", states.get(band_cell, 0), 33)
	h.check("states.no_walk_is_marked", not marked_walk,
		"no cell is left in state 100, whoever walks")


func _overlay_live(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("overlay.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var art: Art = Art.open(CacheFixture.cache_dir())
	var slot: int = _first_of_player(world, 0)
	var query: MoveMapResult = world.submit_move_query(MoveQueryCommand.create(slot))
	var ground: GroundSprites = GroundSprites.new()
	var nowhere: Vector2i = Vector2i(-1, -1)
	ground.refresh(art, world, slot, query, nowhere, {}, 0, false)
	var squad: int = 0
	for other: int in world.unit_slots():
		var view: Dictionary = world.unit_view(other)
		if DictRead.as_int(view["player"]) == 0 and DictRead.as_int(view["hp"]) > 0:
			squad += 1
	# Off a legal cell the digits are not drawn: the own cell's frame is all
	# there is -- no hit-point digit over the squad (docs/43 D12).
	h.check("overlay.squad_present", squad > 0, "%d marine(s)" % squad)
	h.equal("overlay.without_hover", ground.get_child_count(), 1,
		"mp[51] on the mover's cell and nothing over the marines")
	var view: Dictionary = world.unit_view(slot)
	var own: Vector2i = Vector2i(DictRead.as_int(view["x"]), DictRead.as_int(view["y"]))
	h.check("overlay.own_cell_frame", ground.drawn_at(own).has(["mp", HudTables.PATH_FRAME]),
		str(ground.drawn_at(own)))
	# A platform ride carries the marks on its block with the deck (docs/43
	# section 3: a mark is blitted where the cell's ground object projects,
	# and the ride moves that object). One field east, then back.
	var frame_mark: Node3D = ground.get_child(0) as Node3D
	var placed: Vector3 = frame_mark.position if frame_mark != null else Vector3.ZERO
	var one_field: Vector3i = Vector3i(WorldSpace.WORLD_UNITS_PER_FIELD, 0, 0)
	h.equal("overlay.a_ride_shifts_the_cells_marks",
		ground.shift_cells([own] as Array[Vector2i], one_field), 1, "")
	h.check("overlay.the_shifted_mark_moved_a_field", frame_mark != null
		and frame_mark.position.is_equal_approx(
			placed + Vector3(WorldSpace.FIELD_METRES, 0.0, 0.0)),
		str(frame_mark.position if frame_mark != null else Vector3.ZERO))
	h.equal("overlay.a_cell_without_marks_shifts_nothing",
		ground.shift_cells([Vector2i(-1, -1)] as Array[Vector2i], one_field), 0, "")
	var _back: int = ground.shift_cells([own] as Array[Vector2i], Vector3i.ZERO)
	h.check("overlay.zero_puts_the_mark_back", frame_mark != null
		and frame_mark.position.is_equal_approx(placed), "")
	# Over a reachable cell every digit appears, the hovered one framed.
	var hover: Vector2i = Vector2i(-1, -1)
	for y: int in range(query.height):
		for x: int in range(query.width):
			if query.is_reachable(x, y) and Vector2i(x, y) != own and hover.x < 0:
				hover = Vector2i(x, y)
	ground.refresh(art, world, slot, query, hover, {}, 0, false)
	var digits: int = query.reachable_count() - 1 + query.warp_count()
	h.equal("overlay.with_hover", ground.get_child_count(), 1 + digits + 1,
		"the digits, the frame on the hovered cell")
	h.check("overlay.hovered_cell_frame",
		ground.drawn_at(hover).has(["mp", HudTables.HOVER_FRAME]), str(ground.drawn_at(hover)))
	# **No hit-point digit over any unit** (docs/43 D12): the listing's
	# `0x004186AF` block put `mp[min(hp, 15)]` over a current player's unit
	# with points left, and the original shows none over a fresh squad, so
	# the remake draws none -- not over one's own, with or without points,
	# and never over somebody else's.
	var unit_digit: bool = false
	for other: int in world.unit_slots():
		var them: Dictionary = world.unit_view(other)
		if DictRead.as_int(them["hp"]) == 0:
			continue
		var at: Vector2i = Vector2i(DictRead.as_int(them["x"]),
			DictRead.as_int(them["y"]))
		for sprite: Variant in ground.drawn_at(at):
			var pair: Array = DictRead.as_array(sprite)
			if pair.size() == 2 \
					and DictRead.as_string(pair[0]) == HudTables.LIB_MARKERS \
					and DictRead.as_int(pair[1]) <= HudTables.HP_DIGIT_MAX:
				unit_digit = true
	h.check("overlay.no_hp_digit_over_any_unit", not unit_digit,
		"docs/43 D12: the original shows none over a fresh squad")
	var hit_points: int = DictRead.as_int(view["hp"])
	var rested: bool = world.submit_stand_down(StandDownCommand.create(slot))
	ground.refresh(art, world, slot, query, hover, {}, 0, false)
	h.check("overlay.no_digit_after_resting_either", rested
		and not ground.drawn_at(own).has(["mp", mini(hit_points, HudTables.HP_DIGIT_MAX)]),
		"rested: %s, %s" % [str(rested), str(ground.drawn_at(own))])
	var all_overlay: bool = true
	for child: Node in ground.get_children():
		var mark: Sprite3D = child as Sprite3D
		if mark == null or not mark.no_depth_test or not mark.fixed_size \
				or mark.centered or mark.alpha_cut != SpriteBase3D.ALPHA_CUT_DISCARD:
			all_overlay = false
	h.check("overlay.sprites_are_overlay", all_overlay,
		"no depth test, fixed size, anchored, alpha cut: a blit after the frame")
	# The far view: flags for every drawn unit, and no digits.
	ground.refresh(art, world, slot, query, hover, {}, 0, true)
	var flags: int = 0
	for cell: Vector2i in ground.drawn_cells():
		for sprite: Variant in ground.drawn_at(cell):
			if DictRead.as_string(DictRead.as_array(sprite)[0]) == HudTables.LIB_FAR:
				flags += 1
	h.check("overlay.far_view_flags", flags >= squad,
		"%d map.LIB flags for %d marines and whatever else is visible" % [flags, squad])
	ground.free()


func _ring_geometry(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("ring.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var art: Art = Art.open(CacheFixture.cache_dir())
	var ring: DirectionRing = DirectionRing.new()
	var slot: int = _first_of_player(world, 0)
	var view: Dictionary = world.unit_view(slot)
	var cell: Vector2i = Vector2i(DictRead.as_int(view["x"]), DictRead.as_int(view["y"]))
	ring.place(art, world, cell, HudTables.RING_MODE_TURN)
	h.check("ring.up", ring.is_up() and ring.get_child_count() == DirectionRing.RECORDS,
		"nine letters")
	h.equal("ring.mode", ring.mode, HudTables.RING_MODE_TURN)
	h.equal("ring.facing_of_records", [DirectionRing.facing_of(0), DirectionRing.facing_of(7),
		DirectionRing.facing_of(DirectionRing.CANCEL_RECORD)], [0, 7, -1])
	var chosen: Array[int] = []
	ring.record_pressed.connect(func(record: int) -> void: chosen.append(record))
	var north: TextureRect = ring.get_child(0) as TextureRect
	h.equal("ring.visible_letters_take_clicks_over_the_frame", north.mouse_filter,
		Control.MOUSE_FILTER_PASS,
		"the click is accepted, while motion continues to the shared hover path")
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	north.gui_input.emit(press)
	h.equal("ring.visible_letter_emits_its_record", chosen, [0],
		"the visible N chooses N, independent of its unclamped 3D point")
	var release: InputEventMouseButton = InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	north.gui_input.emit(release)
	h.equal("ring.release_does_not_choose_twice", chosen, [0])
	# The draw clamp changes the letter's Control position but not its world
	# record. Hover and the fallback click must follow that visible position.
	for child: Node in ring.get_children():
		(child as TextureRect).visible = false
	north.position = Vector2(180.0, 525.0)
	north.visible = true
	var camera: Camera3D = Camera3D.new()
	var visible_anchor: Vector2 = north.position + Vector2(
		art.sprite_offset(HudTables.LIB_RING, HudTables.RING_LETTERS[0]))
	h.equal("ring.hit_follows_the_clamped_letter",
		ring.hit(camera, visible_anchor), 0,
		"the visible N, not its off-frame 3D projection")
	camera.free()
	ring.take_down()
	h.check("ring.down", not ring.is_up() and ring.get_child_count() == 0, "")
	ring.free()


func _radar_arithmetic(h: TestHarness) -> void:
	var north: Vector2 = Vector2(0.0, -1.0)
	var east: Vector2 = Vector2(1.0, 0.0)
	h.equal("radar.spot_east", Radar.spot(Vector2i(1, 0), north, east, 40),
		Vector2(90.0 / 40.0, 0.0), "one field east = 90/scale pixels")
	h.equal("radar.spot_north", Radar.spot(Vector2i(0, 1), north, east, 40),
		Vector2(0.0, -66.0 / 40.0), "one field north = 66/scale pixels up")
	h.equal("radar.spot_zoomed", Radar.spot(Vector2i(20, 0), north, east, 20),
		Vector2(90.0, 0.0), "at scale 20 twenty fields span the screen")
	var radar: Radar = Radar.new()
	radar.setup(null)
	h.equal("radar.default_scale", radar.fields, HudTables.RADAR_SCALE_DEFAULT)
	var stepped: int = radar.step(1)
	h.equal("radar.step_up", stepped, HudTables.RADAR_SCALE_DEFAULT + HudTables.RADAR_SCALE_STEP)
	for _i: int in range(20):
		stepped = radar.step(1)
	h.equal("radar.step_caps_at_80", stepped, HudTables.RADAR_SCALE_MAX)
	for _i: int in range(20):
		stepped = radar.step(-1)
	h.equal("radar.step_floors_at_20", stepped, HudTables.RADAR_SCALE_MIN)
	radar.free()


# --- the rules ------------------------------------------------------------------

func _selection_rules(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	h.check("select.a_unit_with_points", world.may_select(0), "slot 0 has points")
	var record: Dictionary = world.unit_view(0)
	record["mp"] = 0
	var _applied: bool = world.apply_unit_record(0, record)
	h.check("select.not_without_points", not world.may_select(0) and world.may_command(0),
		"commandable, yet not selectable (0x00471CB6)")
	record["mp"] = 3
	_applied = world.apply_unit_record(0, record)
	h.check("rotate.writes_the_facing",
		world.submit_rotate(RotateCommand.create(0, 3))
		and DictRead.as_int(world.unit_view(0)["facing"]) == 3, "facing 3")
	h.check("rotate.refuses_a_bad_facing",
		not world.submit_rotate(RotateCommand.create(0, 8))
		and DictRead.as_int(world.unit_view(0)["facing"]) == 3, "8 is not a facing")
	h.check("rotate.costs_nothing", DictRead.as_int(world.unit_view(0)["mp"]) == 3,
		"aChangeUnitViewDirection charges no point")
	h.check("weapon_mode.refused_without_a_toggle", not world.may_toggle_weapon(0),
		"the fixture weapon is its own toggle")
	h.check("bands.none_without_a_visible_enemy_in_range",
		world.facing_to_target(0) == Combat.FACING_NONE or world.target_bands(0).size() > 0,
		"either a band or no facing")


## The state-byte correction of 2026-09-05: mode 0 and the ratchet read
## `cell[+0x00]`, so a farther target on a higher band beats a nearer one on
## a lower band, and with no overlay the nearest wins.
func _facing_state_byte(h: TestHarness) -> void:
	var units: Array = [TestFixtures.unit(0, 3, 3), TestFixtures.unit(1, 3, 4, 0, 1),
		TestFixtures.unit(2, 3, 0, 0, 1)]
	var world: World = World.create(TestFixtures.map_document(7, 7, units),
		TestFixtures.balance(), 1.0)
	var states: PackedByteArray = PackedByteArray()
	states.resize(world.state.cell_count())
	states.fill(Combat.FACING_STATE_PLAIN)
	states[world.state.index_of(3, 4)] = 31
	states[world.state.index_of(3, 0)] = 33
	var towards_band: int = Combat.end_turn_facing(world.state, world.units_for_ai(),
		world.unit_types(), 3, 3, Combat.FACING_MODE_TARGET_BAND, false, states)
	h.equal("facing.higher_band_wins", towards_band, 2,
		"south to (3, 0) on band 33 over (3, 4) on 31, though farther")
	var plain: int = Combat.end_turn_facing(world.state, world.units_for_ai(),
		world.unit_types(), 3, 3, Combat.FACING_MODE_ANY_ENEMY, false)
	h.equal("facing.nearest_without_an_overlay", plain, 0, "north to (3, 4)")
	var none: int = Combat.end_turn_facing(world.state, world.units_for_ai(),
		world.unit_types(), 3, 3, Combat.FACING_MODE_TARGET_BAND, false)
	h.equal("facing.mode_0_needs_a_band", none, Combat.FACING_NONE,
		"no cell in 30..34, nobody to turn to")


## The pick's ray meets the point the projection put on the pixel, on the
## offset frustum the mission camera uses. Godot's own `project_ray_*` did
## not -- it ignores the frustum offset -- which is why a unit clicked on its
## own cell could be missed and its neighbour taken (2026-09-05).
func _ray_round_trip(h: TestHarness) -> void:
	var camera: Camera3D = Camera3D.new()
	camera.transform = Transform3D(Basis.from_euler(Vector3(-0.9, 0.4, 0.0)),
		Vector3(10.0, 12.0, 20.0))
	var worst: float = 0.0
	for canvas: Vector2 in CANVASES:
		var window: Rect2 = HudTables.window_for(canvas)
		CameraRig.frame_projection(camera, window, canvas, 0, float(HudTables.WINDOW.size.x))
		var matrix: Projection = CameraRig.projection_of(camera, canvas)
		for target: Vector3 in [Vector3(4.0, 0.0, -6.0), Vector3(20.0, 2.0, -30.0),
				Vector3(-8.0, 1.0, -12.0), Vector3(12.0, 0.5, -2.0)]:
			var local: Vector3 = camera.transform.affine_inverse() * target
			var clip: Vector4 = matrix * Vector4(local.x, local.y, local.z, 1.0)
			if clip.w <= 0.0:
				continue
			var pixel: Vector2 = Vector2((clip.x / clip.w + 1.0) * 0.5 * canvas.x,
				(1.0 - clip.y / clip.w) * 0.5 * canvas.y)
			var ray: PackedVector3Array = CameraRig.ray_through(camera, pixel, canvas)
			if ray.size() != 2:
				worst = INF
				continue
			var to_target: Vector3 = target - ray[0]
			var off: float = (to_target - ray[1] * to_target.dot(ray[1])).length()
			worst = maxf(worst, off)
	h.check("ray.meets_the_projected_point", worst < 0.001,
		"worst miss %.5f Godot units over four canvases" % worst)
	camera.free()


# --- the interface itself -------------------------------------------------------

func _hud_live(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("hud.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var cache: String = CacheFixture.cache_dir()
	var strings: Localization = Localization.from_cache(cache, CacheFixture.manifest())
	var art: Art = Art.open(cache)
	var hud: MissionHud = MissionHud.new()
	hud.setup(art, strings, GameFont.load_from(cache, "font_2"),
		GameFont.load_from(cache, MissionHud.TEXT_FONT),
		GameFont.load_from(cache, MissionHud.SMALL_FONT), cache)
	var all_on: Callable = func(_number: int) -> bool: return true
	var none_on: Callable = func(_number: int) -> bool: return false
	var north: Vector2 = Vector2(0.0, -1.0)
	var east: Vector2 = Vector2(1.0, 0.0)
	hud.refresh(world, -1, all_on, none_on, north, east, {}, false)
	h.equal("hud.turn_text", hud.turn_text(), str(world.turn.turn))
	# The pickup message of docs/24 section 7.2, and the hold it puts on the
	# rest of the plate. `0x0041BB44` returns from the mission's input handler
	# while a box is up and the interface's own mouse hit test `0x00450F10`
	# sits past that return, so a click on a button does nothing either -- in
	# Godot that is a full-rect `Control` in front of every widget, because a
	# `Control` answers a click before `_unhandled_input` does.
	h.check("hud.no_message_before_a_pickup", not hud.info_visible(),
		"nothing has been opened")
	h.equal("hud.no_message_text", hud.info_text(), "")
	var said: Array = InfoText.load_from(cache).spans_for(13)
	h.check("hud.the_message_has_spans", not said.is_empty(),
		"action point 13 is Events.txt E2")
	hud.show_info(said)
	h.check("hud.a_pickup_raises_the_message", hud.info_visible())
	h.check("hud.the_message_is_the_labels_text",
		hud.info_text().contains("Equipment"),
		"{:E2} is `Found Equipment for our stock`: " + hud.info_text())
	var shield: Control = hud.info_shield()
	h.equal("hud.the_message_covers_the_plate",
		shield.anchor_right - shield.anchor_left, 1.0,
		"a full-rect Control, so no widget behind it is picked")
	h.equal("hud.the_message_stops_the_mouse", shield.mouse_filter,
		Control.MOUSE_FILTER_STOP,
		"0x00450F10 sits past the return at 0x0041BB44")
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	shield.gui_input.emit(press)
	h.check("hud.a_click_takes_the_message_down", not hud.info_visible(),
		"0x0043F130 -- the original's own is the right button alone")
	hud.show_info(said)
	var release: InputEventMouseButton = InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	shield.gui_input.emit(release)
	h.check("hud.a_release_leaves_it_up", hud.info_visible(),
		"the press is the dismissal, as `is_pressed` says")
	# The five-second dismissal, which the original has no equivalent of: a
	# crate opened by mistake held the whole mission until it was noticed.
	hud.tick_info(MissionHud.INFO_AUTO_HIDE_SECONDS - 0.1)
	h.check("hud.the_message_waits_out_its_seconds", hud.info_visible(),
		"under INFO_AUTO_HIDE_SECONDS, so nothing has expired")
	hud.tick_info(0.2)
	h.check("hud.the_message_takes_itself_down", not hud.info_visible(),
		"past INFO_AUTO_HIDE_SECONDS")
	# A box that is down must not bank the seconds: the next message would
	# open with most of its time already spent.
	hud.tick_info(60.0)
	hud.show_info(said)
	hud.tick_info(0.1)
	h.check("hud.a_new_message_starts_its_own_clock", hud.info_visible(),
		"tick_info banks nothing while the box is down")
	# ...and a dismissal restarts it too, rather than resuming where the
	# message before it stopped.
	shield.gui_input.emit(press)
	hud.show_info(said)
	hud.tick_info(MissionHud.INFO_AUTO_HIDE_SECONDS - 0.1)
	h.check("hud.the_clock_is_reset_by_a_re_show", hud.info_visible(),
		"show_info clears the clock")
	hud.hide_info()
	h.check("hud.an_empty_message_never_shows", not hud.info_visible())
	hud.show_info([])
	h.check("hud.a_label_with_no_spans_shows_nothing", not hud.info_visible(),
		"an arm whose label the file does not carry raises no box")
	h.check("hud.no_report_before_the_end", not hud.report_visible(), "slots 0..4 clear")
	h.equal("hud.panel_empty_without_a_selection", hud.panel.icon_count(), 0)
	# `0x00451FE3` returns before the marks **and** before both lamps, so a
	# radar with nothing selected is the four compass letters and nothing
	# else. `4 or 5` was what let a lamp burn with no selection through.
	h.equal("hud.radar_shows_the_compass_alone", hud.radar.mark_count(), 4,
		"four letters, no selection to centre on and no lamp")
	var no_missing: bool = true
	for number: int in range(1, 17):
		var caption: String = hud.columns.caption_for(number)
		if caption == "" or caption.contains(Localization.MISSING_PREFIX):
			no_missing = false
	for number: int in HudTables.PAD_SPRITES:
		var caption: String = hud.pad.caption_for(DictRead.as_int(number))
		if caption == "" or caption.contains(Localization.MISSING_PREFIX):
			no_missing = false
	h.check("hud.every_caption_is_shipped", no_missing,
		"sixteen events and six commands out of Txtmod_h")
	# Inventory names are local tooltips like the Upgrade Menu's. Their text is
	# `Info.lcl`'s equipment rows, so none is a caption written here, and the
	# carrier survives the panel's frequent redraws so Godot's hover timer can
	# actually expire.
	var carrier: int = _first_of_player(world, 0)
	hud.refresh(world, carrier, all_on, none_on, north, east, {}, false)
	var rects: Array[Rect2] = hud.panel.item_rects()
	var ids: PackedInt32Array = hud.panel.item_ids()
	h.check("hud.the_inventory_offers_a_hint_target", not rects.is_empty(),
		"%d picture(s) for slot %d" % [rects.size(), carrier])
	if not rects.is_empty():
		var centre: Vector2 = rects[0].get_center()
		h.equal("hud.the_picture_names_its_own_item",
			hud.panel.item_at(centre), ids[0])
		var named: String = hud.panel.equipment_name(ids[0])
		h.check("hud.the_item_hint_is_the_game_s_own_name",
			named != "" and not named.contains(Localization.MISSING_PREFIX),
			"equipment %d is `%s`" % [ids[0], named])
		var item_hint: HintControl = hud.panel.item_hint_at(centre)
		h.check("hud.the_item_has_a_local_tooltip", item_hint != null
			and item_hint.tooltip_text == named,
			"the picture itself carries `%s`" % named)
		var made: Control = item_hint._make_custom_tooltip("x") \
			if item_hint != null else null
		h.check("hud.the_item_uses_the_upgrade_menu_tooltip",
			made is PanelContainer,
			"HintControl supplies the plate-scale backed tooltip")
		if made != null:
			made.free()
		h.equal("hud.the_item_leaves_the_top_hint_line_clear",
			hud.hint_text(), "")
		hud.refresh(world, carrier, all_on, none_on, north, east, {}, false)
		h.check("hud.the_item_tooltip_survives_a_redraw",
			hud.panel.item_hint_at(centre) == item_hint,
			"the hover timer is not reset with the picture")
		# The top line remains the command pad and column buttons' caption.
		hud.set_hint("Overview map")
		h.equal("hud.a_button_caption_uses_the_top_line", hud.hint_text(),
			"Overview map")
		hud.set_hint("")
		h.equal("hud.the_button_hint_line_clears", hud.hint_text(), "")
	# docs/43 sections 5.1 and 5.2's "key (remake)" column, on the hint line
	# rather than as a legend across the playing screen.
	h.equal("hud.a_button_with_no_key_keeps_its_hint",
		HudTables.with_key("Overview map", ""), "Overview map")
	h.equal("hud.a_button_with_a_key_says_so",
		HudTables.with_key("Overview map", "4"), "Overview map  [4]")
	h.check("hud.every_key_names_a_button",
		_keys_name_buttons(), "EVENT_KEYS and COMMAND_KEYS only name real buttons")
	# **One table, and it is the binding.** The hint and the dispatch read the
	# same entry, so the round trip is what says a re-bound key cannot leave
	# the plate telling the player the old one -- and no keycode may stand for
	# two buttons, or the first of them would swallow the other's key.
	var round_trip: bool = true
	var codes: Dictionary[int, int] = {}
	for number: int in HudTables.EVENT_KEYS:
		var code: int = HudTables.EVENT_KEYS[number]
		if HudTables.event_for_key(code) != number or codes.has(code):
			round_trip = false
		codes[code] = number
		if HudTables.event_key(number) != OS.get_keycode_string(code):
			round_trip = false
	for number: int in HudTables.COMMAND_KEYS:
		var code: int = HudTables.COMMAND_KEYS[number]
		if HudTables.command_for_key(code) != number or codes.has(code):
			round_trip = false
		codes[code] = number
		if HudTables.command_key(number) != OS.get_keycode_string(code):
			round_trip = false
	h.check("hud.every_key_presses_its_own_button", round_trip,
		"%d distinct keycodes, each answering for one button and labelled by"
			% codes.size() + " Godot's own name for it")
	h.equal("hud.an_unbound_key_presses_nothing",
		[HudTables.event_for_key(KEY_W), HudTables.command_for_key(KEY_W)],
		[-1, -1], "the pan keys belong to no button")
	# **And the mission host really dispatches through it.** The round trip
	# above pins the table against itself; this pins the *only* other place a
	# key could be decided. Re-adding an `elif key.keycode == KEY_T:` above
	# the lookup would put the two-copy state back with every check still
	# green, so the source is read and required to hold no direct branch on a
	# key either table names. `script_export_mode` is Text for the test
	# preset, so it runs in the exported build too.
	var host: GDScript = load("res://game/main.gd")
	var source: String = host.source_code
	h.check("hud.main_source_is_readable", source.length() > 0,
		"%d characters of game/main.gd" % source.length())
	h.check("hud.main_dispatches_through_the_table",
		source.contains("HudTables.event_for_key(")
			and source.contains("HudTables.command_for_key("),
		"_unhandled_input looks a pressed key up in the binding table")
	var rebranched: Array[String] = []
	for code: int in _bound_keycodes():
		var name: String = "KEY_" + OS.get_keycode_string(code).to_upper()
		if source.contains("keycode == %s:" % name) \
				or source.contains("keycode == %s " % name):
			rebranched.append(name)
	h.equal("hud.no_key_is_branched_on_twice", rebranched, [],
		"no button's key is also tested by hand in _unhandled_input")
	h.check("hud.the_column_hint_carries_the_key",
		hud.columns.caption_for(HudTables.EVENT_FREE_CAMERA).ends_with("[4]")
		and hud.pad.caption_for(HudTables.COMMAND_USE).ends_with("[U]"),
		hud.columns.caption_for(HudTables.EVENT_FREE_CAMERA))
	h.equal("hud.event_13_hint_follows_the_magnifier",
		[hud.columns.caption_for(13) == strings.shipped("Txtmod_h", 32)], [true])
	h.check("hud.slots_carry_their_events",
		hud.columns.event_at(0, 0) == 8 and hud.columns.event_at(1, 8) == 10
		and hud.columns.event_at(0, 7) == 0, "left top is Remind, right bottom Next player")
	h.check("hud.all_events_lit", hud.columns.is_enabled(0, 0) and hud.columns.is_enabled(1, 8)
		and not hud.columns.is_enabled(0, 7), "an empty slot never lights")
	h.check("hud.pad_dark_without_a_selection", not hud.pad.is_enabled(1), "")
	# A selection: the panel names it, the pad lights what the callable says.
	var slot: int = _first_of_player(world, 0)
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false)
	var name: String = DictRead.as_string(world.unit_view(slot)["name"])
	var texts: PackedStringArray = hud.panel.texts()
	var named: bool = false
	var missing: bool = false
	for text: String in texts:
		if text.begins_with(name):
			named = true
		if text.contains(Localization.MISSING_PREFIX):
			missing = true
	h.check("hud.panel_names_the_selection", named, ", ".join(texts))
	h.check("hud.panel_renders_no_missing_string", not missing, ", ".join(texts))
	h.check("hud.panel_draws_the_blocks", hud.panel.icon_count() >= 4,
		"%d icons: the frames, the class, the disc" % hud.panel.icon_count())
	h.check("hud.pad_lit_for_the_selection", hud.pad.is_enabled(1) and hud.pad.is_enabled(8), "")
	h.check("hud.radar_marks_the_squad", hud.radar.mark_count() > 4,
		"%d marks" % hud.radar.mark_count())
	# docs/43 section 7 -- the watched player's screen replaces all of that.
	var watching: Dictionary = {"player": UnitState.PLAYER_ALIEN,
		"acted": 0, "live": 8}
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false, watching)
	h.equal("hud.progress.one_capsule_at_the_opening",
		DictRead.as_int(hud.view()["progress"]), 1)
	h.equal("hud.progress.the_panel_goes", hud.panel.icon_count(), 0)
	h.equal("hud.progress.the_radar_goes",
		DictRead.as_int(hud.view()["radar_marks"]), 0)
	h.check("hud.progress.the_columns_and_the_pad_go",
		not hud.columns.visible and not hud.pad.visible,
		"the bare plate of aViewPlayer.cpp")
	h.equal("hud.progress.the_turn_number_goes", hud.turn_text(), "",
		"the top strip is painted back before anything is written on it")
	# `0x0047DA5F`: an unchanged fill makes no sound, and neither does the
	# opening frame of a turn nobody has moved on yet.
	h.check("hud.progress.the_opening_is_silent", not hud.progress_stepped(),
		"fill 0 against a bar that was reset with the seat")
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false, watching)
	h.check("hud.progress.a_still_bar_is_silent", not hud.progress_stepped(),
		"the same fill twice ticks progress.wav once, not twice")
	watching["acted"] = 4
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false, watching)
	h.equal("hud.progress.half_the_side_moved",
		DictRead.as_int(hud.view()["progress"]), 11)
	h.check("hud.progress.a_step_ticks", hud.progress_stepped(),
		"the fill moved, so the bar ticks")
	watching["acted"] = 8
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false, watching)
	h.equal("hud.progress.the_whole_bar_at_the_end",
		DictRead.as_int(hud.view()["progress"]),
		HudTables.PROGRESS_SEGMENTS)
	# And it comes back when the seat does.
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false)
	h.equal("hud.progress.the_bar_goes_with_the_turn",
		DictRead.as_int(hud.view()["progress"]), 0)
	h.check("hud.progress.the_seat_returning_is_silent",
		not hud.progress_stepped(),
		"putting the bar away is not a step of it")
	h.equal("hud.progress.the_turn_number_returns", hud.turn_text(),
		str(world.turn.turn))
	h.check("hud.progress.the_interface_returns",
		hud.columns.visible and hud.pad.visible and hud.panel.icon_count() > 0,
		"%d icons" % hud.panel.icon_count())
	var pressed: Array[int] = []
	hud.command.connect(func(number: int) -> void: pressed.append(number))
	h.check("hud.pad_press_raises_the_command", hud.pad.press(1) and pressed == [1], str(pressed))
	hud.refresh(world, slot, all_on, none_on, north, east, {}, false)
	h.check("hud.pad_press_refused_when_dark", not hud.pad.press(1) and pressed == [1],
		"the gate runs at the press as well")
	var events: Array[int] = []
	hud.event.connect(func(number: int) -> void: events.append(number))
	h.check("hud.column_press_raises_the_event", hud.columns.press_event(10) and events == [10],
		str(events))
	# The window and the report.
	h.equal("hud.window_for_the_plate", HudTables.window_for(Vector2(640, 480)),
		Rect2(60, 34, 520, 340))
	h.equal("hud.window_for_16_9", HudTables.window_for(Vector2(853, 480)),
		Rect2(60, 34, 733, 340))
	world.game_control.set_slot(0, 1)
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false)
	h.check("hud.the_report_appears_on_a_win", hud.report_visible(), "slot 0 is set")
	var won: String = hud.report_text()
	h.check("hud.the_report_is_the_game_s_own_words",
		won.contains(strings.shipped(Localization.MODULE_MISSION, Localization.ID_COMPLETED))
		and won.contains(strings.shipped(Localization.MODULE_REPORT,
			Localization.ID_REPORT_TITLE)), won.replace("\n", " | "))
	var grades: Array[String] = []
	for value: int in [1, 2, 3]:
		world.game_control.set_slot(0, value)
		hud.refresh(world, slot, all_on, all_on, north, east, {}, false)
		grades.append(hud.report_text())
	h.check("hud.the_three_win_grades_differ",
		grades[0] != grades[1] and grades[1] != grades[2] and grades[0] != grades[2],
		" | ".join(grades).replace("\n", " / "))
	h.check("hud.the_report_renders_no_missing_string",
		not won.contains(Localization.MISSING_PREFIX), won)
	# The report waits for the picture. `core` decides a whole computer turn
	# in one call, so `mission_ended()` is true from the first frame of the
	# replay -- the plate used to drop over the shot that was still killing
	# the last marine.
	world.game_control.set_slot(0, 1)
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false, {}, true)
	h.check("hud.the_report_waits_for_the_picture", not hud.report_visible(),
		"held while the replay or a sequence is still on screen")
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false, {}, false)
	h.check("hud.the_report_comes_back_when_the_hold_lifts",
		hud.report_visible(), "and the frame the hold lifts on shows it")
	# The turn counter with a par: `"%d/%s"`, red inside three turns.
	world.turn.turn_control = world.turn.turn + 2
	hud.refresh(world, slot, all_on, all_on, north, east, {}, false)
	h.equal("hud.turn_with_par", hud.turn_text(),
		"%d/%d" % [world.turn.turn, world.turn.turn + 2])
	var view: Dictionary = hud.view()
	h.check("hud.view_has_the_keys", view.has("window") and view.has("panel_texts")
		and view.has("radar_fields") and view.has("ring_mode"), str(view.keys()))
	hud.free()


## Every key belongs to a button the interface actually has.
## Every keycode either table binds, as one list.
static func _bound_keycodes() -> Array[int]:
	var out: Array[int] = []
	for number: int in HudTables.EVENT_KEYS:
		out.append(HudTables.EVENT_KEYS[number])
	for number: int in HudTables.COMMAND_KEYS:
		out.append(HudTables.COMMAND_KEYS[number])
	return out


static func _keys_name_buttons() -> bool:
	for number: int in HudTables.EVENT_KEYS:
		if not HudTables.COLUMN_CAPTIONS.has(number):
			return false
	for number: int in HudTables.COMMAND_KEYS:
		if not HudTables.PAD_CAPTIONS.has(number):
			return false
	return true


static func _first_of_player(world: World, player: int) -> int:
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["player"]) == player and DictRead.as_int(view["hp"]) > 0:
			return slot
	return -1


## `0x0047DA38`..`0x0047DA4C` and the two runs after it: the fill, and what the
## replay counts it from.
func _progress_arithmetic(h: TestHarness) -> void:
	h.equal("progress.no_unit_is_no_fill", TurnProgress.fill_for(0, 0), 0)
	h.equal("progress.none_acted_is_zero", TurnProgress.fill_for(0, 8), 0)
	h.equal("progress.one_of_eight", TurnProgress.fill_for(1, 8), 2)
	h.equal("progress.half_of_eight", TurnProgress.fill_for(4, 8), 10)
	h.equal("progress.all_of_eight", TurnProgress.fill_for(8, 8), 21)
	h.equal("progress.rounds_down", TurnProgress.fill_for(1, 22), 0)
	# The lit run is `fill + 1`, so a side that has not moved still burns one.
	var lit: Array[int] = []
	for acted: int in [0, 1, 4, 8]:
		lit.append(TurnProgress.fill_for(acted, 8) + 1)
	h.equal("progress.lit_counts", lit, [1, 3, 11, 22])
	# **The tally reads the mirror.** It used to be handed the slots the
	# replay had already played and the casualties it was still holding,
	# because the truth had spent every point and lost every body before the
	# first frame. The picture's world has not, so the two lists are empty
	# and the count is the ordinary one (docs/100 section 2).
	var counted: Vector2i = TurnProgress.tally(TestFixtures.tiny_world(), 0)
	h.check("progress.the_tally_reads_the_world_it_is_given",
		counted.y > 0, "%d unit(s) in the divisor" % counted.y)
	# docs/43 section 4.5 -- the selection the hand-over gives back. The rule
	# read out of the binary; `test_game_ui.gd` runs the search itself.
	var selection: Dictionary = DictRead.as_dict(_cases["selection"])
	h.check("selection.kept_over_the_hand_over",
		DictRead.as_bool(selection["kept_over_the_hand_over"]),
		"no hand-over routine writes 0x005162F0")
	h.check("selection.empty_takes_the_first_unit",
		DictRead.as_bool(selection["empty_takes_the_first_unit"])
		and DictRead.as_bool(selection["second_pass_ignores_movement"]),
		"and an empty one is refilled by fcn.00477CE0's two passes")
	h.equal("selection.passes", DictRead.as_int(selection["first_unit_passes"]),
		2)
	# docs/43 section 7.3 -- the screen the bar is drawn on. The two facts a
	# remake needs out of it: which state the computer's turn is, and that it
	# is the one arm of the seven that prints nothing.
	var screen: Dictionary = DictRead.as_dict(_cases["view_player"])
	h.check("view_player.watched_turn_is_silent",
		DictRead.as_bool(screen["prints_nothing"]),
		"state %d prints nothing at all" %
		DictRead.as_int(screen["watched_state"]))
	h.equal("view_player.alarm_is_network_only",
		DictRead.as_int(screen["alarm_mode"]), 2,
		"the alert needs the network mode; a mission played alone is mode 1")
	h.check("view_player.the_computer_is_named",
		DictRead.as_string(DictRead.as_dict(screen["captions"])["132"])
		!= "", "txtmod_h 132 names the computer on a multi-player hand-over")
	# And the wave the remake plays is the screen's own, not the alert.
	h.equal("view_player.wave_is_the_bars",
		[HudTables.PROGRESS_WAVE, AudioTables.VIEW_PLAYER_PROGRESS],
		[DictRead.as_string(DictRead.as_dict(_cases["progress"])["wave"]),
			"progress"])
	h.equal("view_player.alarm_wave",
		DictRead.as_string(screen["alarm_wave"]), "alarm.wav",
		"copied into the cache, played by nothing")
