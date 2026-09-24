class_name Scenery
extends Node3D

## The mission's placed geometry: the scene's `.3DW` clones, the special
## objects, and the ground lattice.
##
## One node per object -- [method MeshBuilder.assemble]'s tree, a body and
## a pivot per part -- sharing one [ArrayMesh] per prototype scope.  For the
## slice's lead mission that is 53 prototypes and about 84 instances, so a
## [MultiMeshInstance3D] would buy nothing.
##
## **Every placed object is assembled with its parts**, since 2026-09-06.  A
## root-scope mesh alone was empty for a prototype whose vertices all belong
## to parts, and `L100EX00.3DI` -- the door of 45 missions -- is exactly that:
## two leaves under `joint_place` 6 and 12 and nothing else. Every doorway was
## an empty frame, and the door test passed on the lattice marker standing on
## the same cell.
##
## The lattice is instanced too, and deliberately -- but **hidden by default**.
## `S003_00X.3DI` is an octagon 320 world units across: an editor marker for the
## cell centre, not a terrain tile, and the original never draws it.  Building
## it is how "the rendered scenery agrees with the inspection tools" is
## checkable; *showing* it is not fidelity, it is a grid of white dots on every
## surface.  It lives under its own child node so that `G` can turn it on.
##
## `CLS.3DI` is parked at z = -1600000 by the `.lev` and is simply not built.

## docs/10 -- where the marker prototype is parked.
const MARKER_PARK_Z: int = -1600000

## docs/26 section 3.4 -- `aDoorOpenSequence` `0x00410A20` turns a door's two
## **leaves**; it never moves the panel. Its ten frames add `mov ebx, ±100`
## (`0x00410B8B` opening, `0x00410BAE` closing) to the object's joint words
## `+0x2A` and `+0x30` (`0x00410D05`, `0x00410D09`) -- the **z angle** of
## parts 6 and 12 in docs/28 section 7.2's record layout -- so an open door's
## leaves stand at -1000 and +1000 of 4096, 88 degrees about the hinges at the
## frame's outer edges, and a closed door's at 0. All 302 door objects in the
## corpus carry exactly that pair for their cell's parity
## (`interaction_tables.py`, `door.corpus_joints`). The `landObject->z` the
## toggle writes is the **land marker** reached through the cell's `+0x05`
## link, whose z is the cell's height in every shipped record; the panel is
## the object `0x00406F20` finds beside it.
##
## **The door is one of a family** (2026-09-06, docs/42 section 8.3). Nine
## more routines write the same words of the object beside the cell's
## marker, and all of them go through [method paint_joint] and
## [method paint_pose] here: the supply box's lid and the lever's handle
## (part 6 about x), the three tubes (part 6, or parts 6 and 12), the
## bridge's two halves, the barrier's emitter (part 6 about z, half a turn
## when off), and the crush wall and the footbridge, which turn the
## **object's own** rotation words `+0x20..+0x24` while they drop and are
## then freed (`aDeleteLand` `0x00406C30`, [method remove_objects]).
## Only the door's and the lever's pose is a function of the cell's state
## and derived in [method apply_state]; the rest live here alone, and
## travel with a save as [method pose_record] -- the joint words that
## differ from the `.lev`'s and the cells whose objects were freed -- which
## [method restore_poses] puts back after a load (docs/42 section 8.3).
const DOOR_LEAF_STEP: int = 100
const DOOR_LEAF_SWING: int = 1000
## The `joint_place` offsets a door's leaves are authored under, and the sign
## each takes: `+0x2A` (part 6) turns by `-swing`, `+0x30` (part 12) by
## `+swing`.
const LEAF_FIRST: int = 6
const LEAF_SECOND: int = 12
## `aPlayUseLeverSequence` `0x00416AD0`: ten frames of `mov ebp, 0x50` /
## `mov ebx, -0x50` on the handle's `+0x26` -- part 6 about **x** -- with
## direction 0 (the lever was *up*, action point 36) taking the negative
## step, so a thrown lever stands at -800 of 4096 and every shipped record
## on a cell with action point 37 carries exactly `(-800, 0, 0)`
## (`interaction_tables.py`, `corpus.lever_joints`).
const LEVER_PART: int = 6
const LEVER_THROW: int = 800

## `"<name>/<scope>"` -> the mesh built for it, once per mission.
var _meshes: Dictionary[String, ArrayMesh] = {}
var _built: int = 0
var _removed: int = 0
var _missing: PackedStringArray = PackedStringArray()
var _lattice: Node3D = null
## Map cell index -> the instances standing on it, and each instance's
## **authored** transform. A lift's rider moves by the difference between the
## live cell height and the one the `.lev` recorded; a door's panel does not
## move at all.
var _by_cell: Dictionary[int, Array] = {}
## Which of those are `.3DW` **scene clones** rather than special objects.
##
## The engine's object search `0x00406F20` walks the special-object table at
## `[0x4FA80C]` and nothing else, so a clone is not a thing any set piece can
## find, turn or free -- and clones are placed **first**, so a cell carrying
## one used to answer with it. On `_C_142` the door's flight aimed at
## `LEVEL01D.004` instead of the panel; on `_C_163` the second footbridge's
## camera aimed 13 760 units below its block and `aDeleteLand` took the
## level's own geometry with it -- into the save's `removed` list, where the
## load would take it again.
var _clones: Dictionary[Node3D, bool] = {}
var _authored: Dictionary[Node3D, Transform3D] = {}
## Each placed object's engine-unit position -- `+0x10/+0x14/+0x18` of the
## record a set piece flies to.
var _origin: Dictionary[Node3D, Vector3i] = {}
## Each placed object's part pivots, by the `joint_place` offset each is
## authored under: `{anim: pivot}`.
var _pivots: Dictionary[Node3D, Dictionary] = {}
## Each placed object's **current** joint triples, `{anim: Vector3i}` -- the
## live `+0x26..+0x30` words, which a routine that toggles on the pose it
## finds (the bridge) has to read back.
var _joints: Dictionary[Node3D, Dictionary] = {}
## The same triples as the `.lev` authored them, kept so [method pose_record]
## can say which parts have moved.
var _authored_joints: Dictionary[Node3D, Dictionary] = {}
## The cells [method remove_objects] has emptied, in the order it did.
var _removed_cells: PackedInt32Array = PackedInt32Array()
## Each placed object's authored yaw, the `+0x24` word the crush wall and
## the footbridge add their own turn to.
var _yaw: Dictionary[Node3D, int] = {}
## Authored cell height, from the `.lev`'s own lattice records. **Not** the
## height the world happens to have at build time: a save loaded with a door
## already open has to place that marker where the open door is, and comparing
## the live state against itself would place it where the closed one was.
var _authored_height: Dictionary[int, int] = {}
## Instance -> the cell it was **built** on. [method move_objects] re-keys
## an object under another cell; the difference between the two is what
## [method pose_record] carries as a move, so a loaded save can put a
## platform's deck back where the ride left it.
var _home: Dictionary[Node3D, int] = {}
## Objects inserted after the `.lev` was built, mapped to their prototype.
## They are part of the original's mutable special-object table, so unlike
## authored objects they must be named explicitly in the picture save record.
var _inserted: Dictionary[Node3D, String] = {}
## [MapState]'s special-object table id -> the node standing for that record.
## The `.lev`'s own objects are ids `0..n-1` in the order [method build]
## places them, which is the order the table starts in; a record inserted
## later is registered the first time [method sync_land] meets it.
var _land_ids: Dictionary[int, Node3D] = {}
## Table ids whose model this world set cannot build, so a sync does not try
## again every time it runs.
var _land_unbuildable: Dictionary[int, bool] = {}
var _prototypes: Dictionary = {}
var _textures: Dictionary = {}
var _width: int = 0
var _moved: int = 0
var _turned: int = 0


func build(map_document: Dictionary, geometry: Dictionary,
		textures: Dictionary) -> void:
	_width = DictRead.as_int(map_document["width"])
	_prototypes = DictRead.as_dict(geometry["prototypes"])
	_textures = textures
	# Freed synchronously, not queued: a rebuild has to leave the node list in
	# its final state before anything reads it back, and `queue_free` defers to
	# the end of the frame.
	for child: Node in get_children():
		remove_child(child)
		child.free()
	_meshes.clear()
	_built = 0
	_removed = 0
	_moved = 0
	_turned = 0
	_missing = PackedStringArray()
	_by_cell.clear()
	_authored.clear()
	_origin.clear()
	_pivots.clear()
	_joints.clear()
	_authored_joints.clear()
	_removed_cells = PackedInt32Array()
	_clones.clear()
	_yaw.clear()
	_authored_height.clear()
	_home.clear()
	_inserted.clear()
	_land_ids.clear()
	_land_unbuildable.clear()
	_lattice = Node3D.new()
	_lattice.name = "Lattice"
	# The editor's cell markers are an inspection aid, not scenery: off until
	# asked for.
	_lattice.visible = false
	add_child(_lattice)
	var prototypes: Dictionary = _prototypes

	var clones: Array = DictRead.as_array(map_document["scene_clones"])
	for entry: Variant in clones:
		var clone: Dictionary = DictRead.as_dict(entry)
		_place(prototypes, textures, DictRead.as_string(clone["prototype"]),
			DictRead.as_int(clone["x"]), DictRead.as_int(clone["y"]),
			DictRead.as_int(clone["z"]), DictRead.as_int(clone["yaw"]), [],
			null, true)

	var specials: Array = DictRead.as_array(map_document["special_objects"])
	for index: int in range(specials.size()):
		var obj: Dictionary = DictRead.as_dict(specials[index])
		var placed: Node3D = _place(prototypes, textures,
			DictRead.as_string(obj["prototype"]),
			DictRead.as_int(obj["x"]), DictRead.as_int(obj["y"]),
			DictRead.as_int(obj["z"]), DictRead.as_int(obj["yaw"]),
			DictRead.as_array(obj.get("joints", [])))
		if placed != null:
			_land_ids[index] = placed
		else:
			_land_unbuildable[index] = true

	var land: Dictionary = DictRead.as_dict(map_document["land"])
	var name: String = DictRead.as_string(land["prototype"])
	var xs: Array = DictRead.as_array(land["x"])
	var ys: Array = DictRead.as_array(land["y"])
	var zs: Array = DictRead.as_array(land["z"])
	var yaws: Array = DictRead.as_array(land["yaw"])
	# The lattice records carry the authored cell **index** as well as the world
	# position, so the baseline height is read rather than divided back out.
	var grid_x: Array = DictRead.as_array(land["grid_x"])
	var grid_y: Array = DictRead.as_array(land["grid_y"])
	for i: int in range(xs.size()):
		_authored_height[DictRead.as_int(grid_y[i]) * _width
			+ DictRead.as_int(grid_x[i])] = DictRead.as_int(zs[i])
	for i: int in range(xs.size()):
		_place(prototypes, textures, name, DictRead.as_int(xs[i]),
			DictRead.as_int(ys[i]), DictRead.as_int(zs[i]),
			DictRead.as_int(yaws[i]), [], _lattice)


func built_count() -> int:
	return _built


## The special objects still standing, over the whole map: what
## `0x00406F20`'s table would still find.
##
## **Not** [method built_count], which counts the lattice's cell markers and
## the scene's own `.3DW` clones as well -- neither is in that table, and
## neither is what a set piece takes away. The distinction is invisible in a
## suite, which holds the [Scenery] and can ask it anything, and is the whole
## of it from outside: a driven session watching a wall fall needs a number
## that *moves*, and `built_count` never does.
func object_count() -> int:
	var live: int = 0
	for child: Node in get_children():
		var node: Node3D = child as Node3D
		if node == null or node == _lattice or _clones.has(node):
			continue
		live += 1
	return live


## Whether the editor's cell markers are shown.  They are built either way, so
## `built_count()` counts them and the inspection-tool comparison still holds.
func lattice_visible() -> bool:
	return _lattice != null and _lattice.visible


func toggle_lattice() -> void:
	if _lattice != null:
		_lattice.visible = not _lattice.visible


func missing_prototypes() -> PackedStringArray:
	return _missing.duplicate()


## Place one object: the prototype's node tree at `(x, y, z, yaw)`, its parts
## posed by `joints` -- the two triples of docs/28 section 7.2's `+0x26` and
## `+0x2C`, which the `.lev` authors for a special object and a `.3DW` clone
## does not carry.
func _place(prototypes: Dictionary, textures: Dictionary, name: String,
		x: int, y: int, z: int, yaw: int, joints: Array,
		parent: Node3D = null, clone: bool = false) -> Node3D:
	if z <= MARKER_PARK_Z:
		return null
	if not prototypes.has(name):
		if not _missing.has(name):
			_missing.append(name)
		return null
	var prototype: Dictionary = DictRead.as_dict(prototypes[name])
	var node: Node3D = MeshBuilder.assemble(name, prototype, textures, _meshes)
	if node == null:
		return null
	node.name = "%s@%d_%d" % [name.get_basename(), x, y]
	node.transform = Transform3D(WorldSpace.yaw_basis(yaw),
		WorldSpace.to_godot(x, y, z))
	var pivots: Dictionary = {}
	var poses: Dictionary = {}
	var anims: Array = MeshBuilder.part_anims(prototype)
	for index: int in range(anims.size()):
		if anims[index] == null:
			continue
		var pivot: Node3D = node.get_node_or_null(
			NodePath(MeshBuilder.PART_NODE % index)) as Node3D
		if pivot == null:
			continue
		var anim: int = DictRead.as_int(anims[index])
		pivots[anim] = pivot
		var triple: Array = _joint_triple(joints, anim)
		var pose: Vector3i = Vector3i.ZERO
		if not triple.is_empty():
			pose = Vector3i(DictRead.as_int(triple[0]),
				DictRead.as_int(triple[1]), DictRead.as_int(triple[2]))
			pivot.basis = WorldSpace.joint_basis(pose.x, pose.y, pose.z)
		poses[anim] = pose
	if parent == null:
		add_child(node)
	else:
		parent.add_child(node)
	var cell: int = _cell_of(x, y)
	if not _by_cell.has(cell):
		_by_cell[cell] = []
	_by_cell[cell].append(node)
	if clone:
		_clones[node] = true
	_authored[node] = node.transform
	_origin[node] = Vector3i(x, y, z)
	_pivots[node] = pivots
	_joints[node] = poses
	_authored_joints[node] = poses.duplicate()
	_yaw[node] = yaw
	_home[node] = cell
	_built += 1
	return node


## Add a special object the running engine inserted rather than the `.lev`
## authored.  The exact model and position are retained by [method pose_record]
## so a save/reload does not heal a GroundUnit hole back into bare floor.
## Repeating the same insertion is idempotent for restore retries.
func insert_object(name: String, at: Vector3i, yaw: int = 0) -> bool:
	for key: Variant in _inserted:
		var existing: Node3D = key
		if is_instance_valid(existing) and _inserted[existing] == name \
				and _origin.get(existing, Vector3i.ZERO) == at \
				and _yaw.get(existing, 0) == yaw:
			return false
	return _insert(name, at, yaw) != null


func _insert(name: String, at: Vector3i, yaw: int) -> Node3D:
	var node: Node3D = _place(_prototypes, _textures, name,
		at.x, at.y, at.z, yaw, [])
	if node != null:
		_inserted[node] = name
	return node


## Bring the special objects in line with the table the picture's mirror
## holds ([method MapState.land_objects]): free the node of every record the
## table no longer has, and stand up a node for every record it has that the
## picture never drew.
##
## Events draw these objects as they happen -- a spore falling, a patch
## growing, a hole opening -- but an event the player skipped is landed
## without being drawn ([method EventPlayback.skip]), and cells and heights
## are redrawn from the state while objects were not: `_C_176`'s growth,
## skipped, stood in the table as walls nobody could see. A node an event
## already inserted, or [method restore_poses] brought back, is **adopted**
## by model and position, so its heading survives; only a record with no node
## at all is inserted fresh, unturned. Answers how many nodes changed.
func sync_land(records: Array[Dictionary]) -> int:
	var changed: int = 0
	for id: int in _land_ids.keys():
		if not is_instance_valid(_land_ids[id]):
			var _dropped: bool = _land_ids.erase(id)
	var wanted: Dictionary[int, Dictionary] = {}
	for record: Dictionary in records:
		wanted[DictRead.as_int(record["id"])] = record
	for id: int in _land_ids.keys():
		if wanted.has(id):
			continue
		changed += _free_node(_land_ids[id])
		var _gone: bool = _land_ids.erase(id)
	var claimed: Dictionary[Node3D, bool] = {}
	for node: Node3D in _land_ids.values():
		claimed[node] = true
	for id: int in wanted:
		if _land_ids.has(id) or _land_unbuildable.has(id):
			continue
		var record: Dictionary = wanted[id]
		var model: String = DictRead.as_string(record["model"])
		var at: Vector3i = Vector3i(DictRead.as_int(record["x"]),
			DictRead.as_int(record["y"]), DictRead.as_int(record["z"]))
		var found: Node3D = null
		for key: Variant in _inserted:
			var node: Node3D = key
			if is_instance_valid(node) and not claimed.has(node) \
					and _inserted[node] == model \
					and _origin.get(node, Vector3i.ZERO) == at:
				found = node
				break
		if found == null:
			found = _insert(model, at, 0)
			if found == null:
				_land_unbuildable[id] = true
				continue
			changed += 1
		_land_ids[id] = found
		claimed[found] = true
	return changed


## Free one placed object and forget it everywhere.
func _free_node(instance: Node3D) -> int:
	if not is_instance_valid(instance):
		return 0
	for key: int in _by_cell:
		_by_cell[key].erase(instance)
	_authored.erase(instance)
	_origin.erase(instance)
	_pivots.erase(instance)
	_joints.erase(instance)
	_authored_joints.erase(instance)
	_yaw.erase(instance)
	_home.erase(instance)
	_inserted.erase(instance)
	instance.get_parent().remove_child(instance)
	instance.free()
	_removed += 1
	return 1


## Draw an inserted object `height` world units above where it was inserted,
## its recorded position untouched -- `FallingSpores`' drop, whose record is
## inserted high and lowered frame by frame onto the marker (`0x00414720`).
## The object is found by its model and position, as [method insert_object]
## keys it. Answers whether one was moved.
func lift_inserted(name: String, at: Vector3i, height: int) -> bool:
	for key: Variant in _inserted:
		var node: Node3D = key
		if not is_instance_valid(node) or _inserted[node] != name \
				or _origin.get(node, Vector3i.ZERO) != at:
			continue
		var authored: Transform3D = _authored[node]
		node.transform = Transform3D(authored.basis,
			authored.origin + WorldSpace.to_godot(0, 0, height))
		return true
	return false


## The authored joint triple a `joint_place` offset names: `joints[0]` for
## offset 6, `joints[1]` for 12, nothing for either when the record carries
## none or the offset is neither.
static func _joint_triple(joints: Array, anim: int) -> Array:
	var index: int = -1
	if anim == LEAF_FIRST:
		index = 0
	elif anim == LEAF_SECOND:
		index = 1
	if index < 0 or index >= joints.size():
		return []
	var triple: Array = DictRead.as_array(joints[index])
	return triple if triple.size() >= 3 else []


## The map cell an object standing at engine `(x, y)` belongs to.
##
## Integer division of the world coordinate by the field size, which is where
## the `.lev` put it: an object is authored at its cell's own origin, and the
## few that sit off-centre still round into the cell they decorate.
func _cell_of(x: int, y: int) -> int:
	var cx: int = x / WorldSpace.WORLD_UNITS_PER_FIELD
	var cy: int = y / WorldSpace.WORLD_UNITS_PER_FIELD
	return cy * _width + cx


## Move the objects on `cells` to where the live state says their cell is.
##
## This is the second half of "the picture is a function of the state": the
## first half is that the offset is computed from the **authored** transform
## every time, never accumulated, so applying it twice is the same as applying
## it once and a reload lands in the same place as a live change.
##
## A cell whose action point is a door's is the one exception, and it is the
## engine's own: `aDoorOpenSequence` writes the cell's height into the **land
## marker's** z and turns the **panel's leaves** ([method paint_door]), so on
## a door cell the lattice takes the height delta and everything else stays
## where the `.lev` put it. Before 2026-09-06 the panel took the delta too,
## on docs/97 section 7's reading that it "rises out of the floor"; the
## listing says otherwise (docs/26 section 3.4).
func apply_state(snapshot: Dictionary, cells: PackedInt32Array) -> int:
	if snapshot.is_empty():
		return 0
	var heights: PackedInt32Array = snapshot["height_map"]
	var points: PackedByteArray = snapshot.get("action_point",
		PackedByteArray())
	_moved = 0
	for cell: int in cells:
		if cell < 0 or cell >= heights.size() or not _by_cell.has(cell):
			continue
		var delta: int = heights[cell] - _authored_height.get(cell, heights[cell])
		var offset: Vector3 = WorldSpace.to_godot(0, 0, delta)
		var door: bool = cell < points.size() \
			and Interact.DOOR_IDS.has(points[cell])
		for node: Variant in _by_cell[cell]:
			var instance: Node3D = node
			if not is_instance_valid(instance):
				continue
			var authored: Transform3D = _authored[instance]
			if door and instance.get_parent() != _lattice:
				instance.transform = authored
			else:
				instance.transform = Transform3D(authored.basis,
					authored.origin + offset)
			_moved += 1
		if door:
			var _leaves: int = paint_door(cell,
				0 if (points[cell] & 1) == 1 else DOOR_LEAF_SWING)
		elif cell < points.size() and (points[cell] == Interact.LEVER_UP
				or points[cell] == Interact.LEVER_DOWN):
			# The lever's handle is a function of its action point the way
			# the door's leaves are of its parity: 36 is *up* and the
			# authored zero, 37 is *down* and the thrown -800 -- one shipped
			# lever ships thrown and its record carries exactly that.
			var _handle: int = paint_joint(cell, LEVER_PART, Vector3i(
				-LEVER_THROW if points[cell] == Interact.LEVER_DOWN else 0,
				0, 0))
	return _moved


## The platform ride's picture, one frame of it: every object on `cells` --
## the land marker `aGetSymbolObjectPtr` `0x00412BA7` finds through the
## cell's link and the special objects `0x00406F20` `0x00412BF7` finds beside
## it -- drawn `offset` engine units from where it was authored. The level's
## own `.3DW` clones are in neither table and stay. Nothing is re-keyed:
## the objects still belong to their source cells until [method
## move_objects] lands them. Answers how many moved.
func shift_objects(cells: PackedInt32Array, offset: Vector3i) -> int:
	var moved: int = 0
	var by: Vector3 = WorldSpace.to_godot(offset.x, offset.y, offset.z)
	for cell: int in cells:
		for node: Variant in instances_on(cell):
			var instance: Node3D = node
			if not is_instance_valid(instance) or _clones.has(instance):
				continue
			var authored: Transform3D = _authored[instance]
			instance.transform = Transform3D(authored.basis,
				authored.origin + by)
			moved += 1
	return moved


## The ride's end: the objects on each of `cells` now stand `dx, dy` fields
## away and are keyed there, as the engine's are once its loop has added
## `dist * 10` steps to their positions. `core` has already copied the
## cells' height and type (`0x00412FFB`), so `snapshot` is read for the
## height delta the destination cell will apply from now on -- the moved
## object's authored transform is set so that [method apply_state] lands it
## where the ride left it. A destination off the map leaves the object
## where it was, as a source it cannot reach. Answers how many moved.
func move_objects(snapshot: Dictionary, cells: PackedInt32Array, dx: int,
		dy: int) -> int:
	var heights: PackedInt32Array = snapshot.get("height_map",
		PackedInt32Array())
	var by: Vector3 = WorldSpace.to_godot(dx * WorldSpace.WORLD_UNITS_PER_FIELD,
		dy * WorldSpace.WORLD_UNITS_PER_FIELD, 0)
	var moved: int = 0
	for cell: int in cells:
		var x: int = cell % _width + dx
		var y: int = cell / _width + dy
		if x < 0 or y < 0 or x >= _width or _width <= 0:
			continue
		var target: int = y * _width + x
		if target >= heights.size() and not heights.is_empty():
			continue
		var delta: int = 0
		if target < heights.size():
			delta = heights[target] - _authored_height.get(target, heights[target])
		var lift: Vector3 = WorldSpace.to_godot(0, 0, delta)
		for node: Variant in instances_on(cell):
			var instance: Node3D = node
			if not is_instance_valid(instance) or _clones.has(instance):
				continue
			var authored: Transform3D = _authored[instance]
			var landed: Vector3 = authored.origin + by
			_authored[instance] = Transform3D(authored.basis, landed - lift)
			instance.transform = Transform3D(authored.basis, landed)
			var origin: Vector3i = _origin.get(instance, Vector3i.ZERO)
			_origin[instance] = origin + Vector3i(
				dx * WorldSpace.WORLD_UNITS_PER_FIELD,
				dy * WorldSpace.WORLD_UNITS_PER_FIELD, 0)
			(_by_cell[cell] as Array).erase(instance)
			if not _by_cell.has(target):
				_by_cell[target] = []
			(_by_cell[target] as Array).append(instance)
			moved += 1
	return moved


## The same, for every cell -- what a fresh build or a loaded save needs.
func apply_all(snapshot: Dictionary) -> int:
	var every: PackedInt32Array = PackedInt32Array()
	for cell: int in _by_cell:
		every.append(cell)
	return apply_state(snapshot, every)


## Turn the leaves of the door on `cell` to `swing` -- `0` shut,
## [constant DOOR_LEAF_SWING] open, and `frame * `[constant DOOR_LEAF_STEP]
## on the way. Part 6 takes `-swing`, part 12 `+swing`, about the z axis,
## which is what the ten frames of `0x00410D01` write. Every object on the
## cell that carries those two parts is a door here, as it is in the
## engine, which finds *the object beside the marker* and asks no more.
## Answers how many leaves turned.
func paint_door(cell: int, swing: int) -> int:
	var first: int = paint_joint(cell, LEAF_FIRST, Vector3i(0, 0, -swing))
	var second: int = paint_joint(cell, LEAF_SECOND, Vector3i(0, 0, swing))
	# **Accumulated, not assigned.** [method turned_count] is a tally over the
	# life of the build, the way [member _moved] and [member _removed] are;
	# assigning here made it "the last door's leaves" instead.
	_turned += first + second
	return first + second


## Write one joint triple -- the three words at `+0x26` (part 6) or `+0x2C`
## (part 12) of docs/28 section 7.2's record -- into every **special** object
## on `cell` that carries that part ([method objects_on]), the way each `aPlay*Sequence` writes the object
## `0x00406F20` finds beside the cell's marker. The pose is **absolute**, so
## painting a frame twice paints it once; a routine that steps a word each
## frame is `start + step * frame` at the caller, with `start` read back
## through [method joint_of]. Answers how many parts turned.
func paint_joint(cell: int, anim: int, triple: Vector3i) -> int:
	var turned: int = 0
	for node: Variant in objects_on(cell):
		var instance: Node3D = node
		var pivots: Dictionary = _pivots.get(instance, {})
		if not pivots.has(anim):
			continue
		var pivot: Node3D = pivots[anim]
		pivot.basis = WorldSpace.joint_basis(triple.x, triple.y, triple.z)
		var poses: Dictionary = _joints.get(instance, {})
		poses[anim] = triple
		_joints[instance] = poses
		turned += 1
	return turned


## The current joint triple of part `anim` on the first object of `cell`
## that carries it, or zero when none does -- what `Bridge` reads at
## `0x00410EA2` (`mov di, [esi+0x26]`) to decide which way to turn.
func joint_of(cell: int, anim: int) -> Vector3i:
	for node: Variant in objects_on(cell):
		var instance: Node3D = node
		var poses: Dictionary = _joints.get(instance, {})
		if poses.has(anim):
			var pose: Vector3i = poses[anim]
			return pose
	return Vector3i.ZERO


## Whether any object on `cell` carries part `anim`.
func has_joint(cell: int, anim: int) -> bool:
	for node: Variant in objects_on(cell):
		var instance: Node3D = node
		var pivots: Dictionary = _pivots.get(instance, {})
		if pivots.has(anim):
			return true
	return false


## Turn and lower the **special** objects on `cell` by their own rotation
## words ([method objects_on]) --
## `turn` added to `+0x20/+0x22/+0x24`, the last on top of the authored
## yaw -- and `drop` world units below where the `.lev` put them. This is
## the crush wall (`+0x20 += 0x66`, `z -= 0x1E0` a frame) and the
## footbridge (`+0x22`, `+0x24` by the tilt, `z -= 0xD20`), whose object
## moves by its own loop and **not** by the cell's height: `0x0042F410`
## zeroes the marker's z, the wall's own z walks down 480 at a time. Like
## [method paint_joint] it is absolute in `turn` and `drop`, computed from
## the authored transform every frame. Answers how many objects moved.
func paint_pose(cell: int, turn: Vector3i, drop: int) -> int:
	var posed: int = 0
	for node: Variant in objects_on(cell):
		var instance: Node3D = node
		var authored: Transform3D = _authored[instance]
		var yaw: int = _yaw.get(instance, 0)
		instance.transform = Transform3D(
			WorldSpace.joint_basis(turn.x, turn.y, yaw + turn.z),
			authored.origin + WorldSpace.to_godot(0, 0, -drop))
		posed += 1
	return posed


## Free the special objects on `cell` -- not the marker and not a `.3DW`
## clone ([method objects_on]) -- the way `aDeleteLand` `0x00406C30` frees a
## crushed wall or a fallen footbridge at the end of its loop. The engine
## frees the **one** its search found; this frees every special standing
## there, which on the shipped maps is the same object. They leave every index first, so nothing keyed on a freed node
## is left behind; [method built_count] keeps counting what was built and
## [method removed_count] what went. Answers how many were freed.
func remove_objects(cell: int) -> int:
	var gone: int = 0
	for node: Variant in objects_on(cell):
		var instance: Node3D = node
		_by_cell[cell].erase(instance)
		_authored.erase(instance)
		_origin.erase(instance)
		_pivots.erase(instance)
		_joints.erase(instance)
		_authored_joints.erase(instance)
		_yaw.erase(instance)
		_home.erase(instance)
		_inserted.erase(instance)
		instance.get_parent().remove_child(instance)
		instance.free()
		gone += 1
	_removed += gone
	if gone > 0 and not _removed_cells.has(cell):
		_removed_cells.append(cell)
	return gone


func removed_count() -> int:
	return _removed


## What the picture holds that the `.lev` did not put there: every joint
## triple that differs from the authored one, as `[cell, part, x, y, z]`
## rows in cell order, and the cells whose objects were freed -- an opened
## hatch, a lowered bridge, an emitter facing away, a crushed wall. This is
## what the original's `.sav` keeps by embedding the special-object records
## with their `+0x26..+0x30` words (docs/11), and what the remake's save
## carries beside the simulation so a loaded mission shows them (docs/42
## section 8.3). A pose written by [method paint_pose] is not in it: the
## crush wall and the footbridge end by freeing their object, and the
## removal is what is kept.
func pose_record() -> Dictionary:
	var joints: Array = []
	var cells: Array = _by_cell.keys()
	cells.sort()
	for key: Variant in cells:
		var cell: int = key
		# The special objects alone, as everywhere else: a clone carries no
		# authored triple and so contributes no row either way, but the
		# record is a list of what a set piece moved and a clone is not
		# something a set piece can reach ([method objects_on]).
		for node: Variant in objects_on(cell):
			var instance: Node3D = node
			var poses: Dictionary = _joints.get(instance, {})
			var authored: Dictionary = _authored_joints.get(instance, {})
			var anims: Array = poses.keys()
			anims.sort()
			for anim: Variant in anims:
				var pose: Vector3i = poses[anim]
				var was: Vector3i = authored.get(anim, Vector3i.ZERO)
				if pose != was:
					joints.append([cell, anim, pose.x, pose.y, pose.z])
	var removed: Array = []
	for cell: int in _removed_cells:
		removed.append(cell)
	# The moves: one row per cell whose objects a platform carried away,
	# `[home, dx, dy]` in fields. A ride moves everything on a cell by the
	# same distance, so the row is per home cell and not per object; a
	# marker and a deck that had somehow parted would be two rows.
	var moves: Array = []
	for key: Variant in cells:
		var cell: int = key
		for node: Variant in instances_on(cell):
			var instance: Node3D = node
			if not is_instance_valid(instance) or _clones.has(instance) \
					or not _home.has(instance):
				continue
			var home: int = _home[instance]
			if home == cell:
				continue
			var row: Array = [home, cell % _width - home % _width,
				cell / _width - home / _width]
			if not moves.has(row):
				moves.append(row)
	var record: Dictionary = {"joints": joints, "removed": removed,
		"moves": moves}
	var inserted: Array = []
	for key: Variant in cells:
		var cell: int = key
		for node: Variant in instances_on(cell):
			var instance: Node3D = node
			if not is_instance_valid(instance) or not _inserted.has(instance):
				continue
			var at: Vector3i = _origin.get(instance, Vector3i.ZERO)
			inserted.append([cell, _inserted[instance], at.x, at.y, at.z,
				_yaw.get(instance, 0)])
	if not inserted.is_empty():
		record["inserted"] = inserted
	return record


## Put a [method pose_record] back: [method move_objects] per move row
## **first**, since the joint rows and the removed cells name where things
## stand now; then [method paint_joint] per row and [method remove_objects]
## per cell. All three are idempotent, so restoring twice is restoring
## once -- a move's home cell has nothing left to carry the second time.
## `snapshot` is the terrain the objects land on; without it a move lands at
## the authored height and a later terrain diff may lift it. Every number is
## narrowed here because the record rides in the save's JSON header and
## comes back as floats. Answers how many objects moved, parts turned and
## cells emptied.
func restore_poses(record: Dictionary, snapshot: Dictionary = {}) -> int:
	var done: int = 0
	# Insert first: a later move/removal row may address an object which did
	# not exist in the authored map.
	for entry: Variant in DictRead.as_array(record.get("inserted", [])):
		var row: Array = DictRead.as_array(entry)
		if row.size() < 6:
			continue
		if insert_object(DictRead.as_string(row[1]), Vector3i(
				DictRead.as_int(row[2]), DictRead.as_int(row[3]),
				DictRead.as_int(row[4])), DictRead.as_int(row[5])):
			done += 1
	for entry: Variant in DictRead.as_array(record.get("moves", [])):
		var row: Array = DictRead.as_array(entry)
		if row.size() < 3:
			continue
		done += move_objects(snapshot,
			PackedInt32Array([DictRead.as_int(row[0])]),
			DictRead.as_int(row[1]), DictRead.as_int(row[2]))
	for entry: Variant in DictRead.as_array(record.get("joints", [])):
		var row: Array = DictRead.as_array(entry)
		if row.size() < 5:
			continue
		done += paint_joint(DictRead.as_int(row[0]), DictRead.as_int(row[1]),
			Vector3i(DictRead.as_int(row[2]), DictRead.as_int(row[3]),
				DictRead.as_int(row[4])))
	for entry: Variant in DictRead.as_array(record.get("removed", [])):
		done += remove_objects(DictRead.as_int(entry))
	return done


## The cells whose objects include one built from a prototype named
## `prefix` -- `"L040EA00"` for a crush wall -- in cell order. For the
## suites, which find a mechanism by what stands there rather than by a
## hard-coded cell.
func cells_with_prototype(prefix: String) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var cells: Array = _by_cell.keys()
	cells.sort()
	for key: Variant in cells:
		var cell: int = key
		for node: Variant in objects_on(cell):
			var instance: Node3D = node
			if instance.name.begins_with(prefix):
				out.append(cell)
				break
	return out


func moved_count() -> int:
	return _moved


func turned_count() -> int:
	return _turned


## The instances standing on a cell, for the suite and for the set-piece
## driver. A copy: the array this returns must not be a handle into the index.
func instances_on(cell: int) -> Array:
	return (_by_cell[cell] as Array).duplicate() if _by_cell.has(cell) else []


## The scene's own `.3DW` clones standing on a cell, in placement order. A
## copy.
##
## Read straight off [member _clones], which [method build] fills as it places
## them and no later call touches. That independence is the point: this is what
## a suite asks to establish that a cell **is** a shared field before it checks
## what [method objects_on] answers there, so the fixture's precondition does
## not run through the code the checks are about.
func clones_on(cell: int) -> Array:
	var out: Array = []
	for node: Variant in instances_on(cell):
		var instance: Node3D = node
		if is_instance_valid(instance) and _clones.has(instance):
			out.append(instance)
	return out


## The objects standing on a cell that `0x00406F20` **can find** -- the
## special objects -- in placement order. A copy.
##
## Neither the lattice marker nor a `.3DW` scene clone is one of them: the
## search walks the special-object table alone ([member _clones]), and every
## caller here is asking the search's question -- what a set piece flies to,
## turns, reads a joint off or frees. [method instances_on] is the wider
## answer, for a suite that wants to see what is drawn.
func objects_on(cell: int) -> Array:
	var out: Array = []
	for node: Variant in instances_on(cell):
		var instance: Node3D = node
		if is_instance_valid(instance) and instance.get_parent() != _lattice \
				and not _clones.has(instance):
			out.append(instance)
	return out


## Where the special objects on a cell were authored, in engine units, in
## placement order -- what a set piece flies to. Empty when nothing but the
## marker and the level's own clones stand there.
func object_origins(cell: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for node: Variant in objects_on(cell):
		var instance: Node3D = node
		out.append(_origin.get(instance, Vector3i.ZERO))
	return out


## The pivot of one object's part, by the `joint_place` offset it is authored
## under, or `null`.
func pivot_of(instance: Node3D, anim: int) -> Node3D:
	var pivots: Dictionary = _pivots.get(instance, {})
	if not pivots.has(anim):
		return null
	var pivot: Node3D = pivots[anim]
	return pivot


func authored_height(cell: int) -> int:
	return _authored_height.get(cell, 0)
