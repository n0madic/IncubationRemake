extends TestSuite

## Oracle boundary: specification-only, against the converted data.
##
## The visual half of docs/92 section 10.4's "the rendered map, scenery and
## initial units agree with the existing inspection tools" is done by eye
## against `lev_parse.py --png` and `prototyp_parse.py --obj`.  What can be
## mechanised is the part that is really a claim about *counts and positions*:
## every clone, special object and lattice marker in the document becomes an
## instance, every unit node sits on its unit's own map field, and the overlay
## has exactly one quad per cell.
##
## It also states the property docs/92 section 10.2 item 4 puts last: **scene
## nodes are never authoritative**.  Every position here is derived from
## `World.unit_view`, so moving a node and rebuilding puts it back.

const CORNERS_PER_QUAD: int = 4
const MARKER_PARK_Z: int = -1600000


func run(h: TestHarness) -> void:
	h.begin("render", TestHarness.ORACLE_SPEC)
	var loaded: Dictionary = CacheFixture.load_slice_world()
	if loaded.is_empty():
		h.check("fixture", false,
			CacheFixture.missing_hint())
		return
	var world: World = loaded["world"]
	var document: Dictionary = loaded["document"]
	var header: Dictionary = DictRead.as_dict(document["header"])
	var world_set: String = DictRead.as_string(header["world_set"])
	var geometry: Dictionary = CacheFixture.geometry(world_set)
	h.check("geometry.present", not geometry.is_empty(),
		"geometry/%s.json" % world_set)
	if geometry.is_empty():
		return

	_check_hues(h)
	_check_defaults_hidden(h, document, geometry, world)
	_check_scenery(h, document, geometry)
	# The slice world's authored units are all the computer's -- the squad is
	# the campaign's -- and the fog is the engine's: a player with no living
	# unit rebuilds to "all hidden" with no blips, because the contact
	# promotion lives inside the per-unit pass (docs/22 section 9.3). So the
	# bodies are looked at as their own player, which draws every one.
	world.turn.current_player = UnitState.PLAYER_ALIEN
	_check_units(h, world, geometry)
	_check_overlay(h, world)


## The overlay ramp must be `lev_parse.py`'s, entry for entry, because being
## comparable by eye against `lev_parse.py --png` is the whole point of the
## overlay.  It was once copied from `type_hue[4:]`, which painted every cell
## as the type four along and wrapped at seven -- and since the converted
## missions hold only types 0, 1 and 2, every cell on every one of them.
const LEV_PARSE_TYPE_HUE: Array = [
	[70, 90, 110], [60, 120, 70], [120, 100, 60], [90, 90, 140],
	[110, 110, 110], [140, 80, 60], [60, 130, 130], [130, 60, 130],
	[150, 150, 90], [80, 160, 200], [200, 120, 200],
]


## Two debug layers exist and **neither is on by default**.
##
## The terrain overlay tints every cell of the map and the ground lattice puts
## a white octagon in the middle of every one of them; together they made the
## default view a grid of dots under a coloured film, on top of geometry that
## is the whole point of rendering the mission at all.  They are built either
## way -- `built_count()` still counts the lattice, so the inspection-tool
## comparison is unaffected -- and `T` and `G` show them.
func _check_defaults_hidden(h: TestHarness, document: Dictionary,
		geometry: Dictionary, world: World) -> void:
	var overlay: TerrainOverlay = TerrainOverlay.new()
	overlay.build(world.terrain_snapshot())
	h.check("overlay.hidden_by_default", not overlay.visible,
		"the field-type overlay is an inspection view, not the render")
	overlay.toggle()
	h.check("overlay.toggles", overlay.visible)
	overlay.free()

	var scenery: Scenery = Scenery.new()
	scenery.build(document, geometry, {})
	h.check("lattice.hidden_by_default", not scenery.lattice_visible(),
		"S003_00X.3DI is an editor cell marker; the original never draws it")
	scenery.toggle_lattice()
	h.check("lattice.toggles", scenery.lattice_visible())
	scenery.free()


func _check_hues(h: TestHarness) -> void:
	h.equal("overlay.hue_count", TerrainOverlay.TYPE_HUE.size(),
		LEV_PARSE_TYPE_HUE.size(), "one entry per field type")
	var mismatch: int = 0
	for i: int in range(mini(TerrainOverlay.TYPE_HUE.size(),
			LEV_PARSE_TYPE_HUE.size())):
		var want: Array = LEV_PARSE_TYPE_HUE[i]
		var got: Color = TerrainOverlay.TYPE_HUE[i]
		if got.r8 != DictRead.as_int(want[0]) \
				or got.g8 != DictRead.as_int(want[1]) \
				or got.b8 != DictRead.as_int(want[2]):
			mismatch += 1
	h.equal("overlay.hues_match_lev_parse", mismatch, 0,
		"the ramp is tools/lev_parse.py:179, entry for entry")


func _check_scenery(h: TestHarness, document: Dictionary,
		geometry: Dictionary) -> void:
	var scenery: Scenery = Scenery.new()
	scenery.build(document, geometry, {})
	var clones: Array = DictRead.as_array(document["scene_clones"])
	var specials: Array = DictRead.as_array(document["special_objects"])
	var land: Dictionary = DictRead.as_dict(document["land"])
	var lattice: Array = DictRead.as_array(land["x"])
	var expected: int = clones.size() + specials.size() + lattice.size()
	h.equal("scenery.instances", scenery.built_count(), expected,
		"every clone, special object and lattice marker becomes an instance")
	h.equal("scenery.no_missing_prototypes",
		", ".join(scenery.missing_prototypes()), "",
		"the transitive closure the converter emitted is complete")
	# The header's clone count and the .3DW disagree on four D00 missions; the
	# .3DW is what the engine parses, so the converter warns rather than fails.
	var diagnostics: Dictionary = DictRead.as_dict(document["diagnostics"])
	h.equal("scenery.clone_count_source",
		DictRead.as_int(diagnostics["clone_count_parsed"]), clones.size(),
		"placement follows the parsed .3DW, not the header count")
	scenery.free()


func _check_units(h: TestHarness, world: World, geometry: Dictionary) -> void:
	var units: UnitsView = UnitsView.new()
	units.build(world, geometry, {})
	var slots: PackedInt32Array = world.unit_slots()
	h.equal("units.nodes", units.get_child_count(), slots.size())
	var misplaced: PackedStringArray = PackedStringArray()
	for i: int in range(slots.size()):
		var slot: int = slots[i]
		var view: Dictionary = world.unit_view(slot)
		var x: int = DictRead.as_int(view["x"])
		var y: int = DictRead.as_int(view["y"])
		var cell: Dictionary = world.cell_view(x, y)
		var want: Vector3 = WorldSpace.cell_centre(x, y,
			DictRead.as_int(cell["height"]))
		var node: Node3D = units.get_child(i) as Node3D
		if node.position.distance_to(want) > 0.0001:
			misplaced.append("slot %d" % slot)
		# The cell the unit stands on must link back to it.
		if DictRead.as_int(cell["unit"]) != slot:
			misplaced.append("slot %d unlinked" % slot)
	h.equal("units.positions", ", ".join(misplaced), "",
		"every node sits on its unit's own field, taken from unit_view")

	# docs/42 section 6 -- at most four bodies idle at once, and none loops.
	units.library = CharismaLibrary.open(CacheFixture.cache_dir(), {}, "_C_140")
	units.build(world, geometry, {})
	units.presentation_rng = IncRandom.new()
	units.presentation_rng.randomize_seed(7.0)
	var most: int = 0
	for _i: int in range(600):
		units.animate(1.0 / CharismaState.FRAMES_PER_SECOND, world)
		most = maxi(most, units.scheduler.idling().size())
	h.check("units.at_most_four_idle", most <= IdleScheduler.SLOTS.size(),
		"%d idling at the busiest frame" % most)
	h.check("units.some_idle_started", units.scheduler.starts > 0,
		"%d start(s), %d draw(s) in 600 frames"
			% [units.scheduler.starts, units.scheduler.draws])

	# Scene nodes are never authoritative: move one and rebuild.
	if slots.size() > 0:
		var node: Node3D = units.get_child(0) as Node3D
		var moved: Vector3 = node.position + Vector3(10.0, 10.0, 10.0)
		node.position = moved
		units.build(world, geometry, {})
		var rebuilt: Node3D = units.get_child(0) as Node3D
		h.check("units.not_authoritative", rebuilt.position != moved,
			"a moved node does not survive a rebuild")
	units.free()


func _check_overlay(h: TestHarness, world: World) -> void:
	var overlay: TerrainOverlay = TerrainOverlay.new()
	var snapshot: Dictionary = world.terrain_snapshot()
	overlay.build(snapshot)
	var mesh: ArrayMesh = overlay.mesh as ArrayMesh
	h.check("overlay.surface", mesh != null and mesh.get_surface_count() == 1,
		"one surface for the whole grid")
	if mesh == null or mesh.get_surface_count() == 0:
		overlay.free()
		return
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	h.equal("overlay.quads", vertices.size(),
		world.resource.cell_count() * CORNERS_PER_QUAD,
		"one quad per map field")

	# The ground overlay of docs/43 section 3 replaced the depth-tested quads
	# of `highlight.gd` on 2026-09-05: the marks are a blit **after** the
	# frame (`fcn.00417E70` through `fcn.004475D0`), so nothing standing in
	# front of a marked field hides it, and docs/97 section 45.2's reading of
	# the opposite was wrong. What this pins is that reading: overlay sprites,
	# one per marked cell while the pointer is on a legal one, none depth
	# tested.
	var ground: GroundSprites = GroundSprites.new()
	var art: Art = Art.open(CacheFixture.paths())
	var result: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(world.unit_slots()[0], false))
	var view: Dictionary = world.unit_view(world.unit_slots()[0])
	var own: Vector2i = Vector2i(DictRead.as_int(view["x"]), DictRead.as_int(view["y"]))
	var hover: Vector2i = Vector2i(-1, -1)
	for y: int in range(result.height):
		for x: int in range(result.width):
			if result.is_reachable(x, y) and Vector2i(x, y) != own and hover.x < 0:
				hover = Vector2i(x, y)
	ground.refresh(art, world, world.unit_slots()[0], result, hover, {},
		DictRead.as_int(view["player"]), false)
	var marked: int = result.reachable_count() - 1 + result.warp_count()
	var digits: int = 0
	var depth_tested: int = 0
	for child: Node in ground.get_children():
		var mark: Sprite3D = child as Sprite3D
		if mark == null:
			continue
		if not mark.no_depth_test:
			depth_tested += 1
		if mark.texture != null and mark.texture.get_width() == 9 \
				and mark.texture.get_height() == 9 and mark.fixed_size:
			digits += 1
	h.equal("ground.one_digit_per_marked_cell", digits, marked,
		"%d 9x9 marks for %d marked cells" % [digits, marked])
	h.equal("ground.none_depth_tested", depth_tested, 0,
		"a marked cell is never hidden by what stands in front of it")
	h.check("ground.covers_mover",
		result.is_reachable(own.x, own.y) and ground.drawn_at(own).has(["mp", 51]),
		"the unit's own field is part of its move map and wears the path frame")
	ground.free()
	overlay.free()
