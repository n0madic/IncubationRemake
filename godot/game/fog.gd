class_name Fog
extends RefCounted

## What the player may see -- docs/22 section 9, as a **rendering** rule.
##
## **There is no cell fog in the original, and this does not invent one.**
## `aBuildVisibleMap` writes one byte per *unit* (`+0x4F`) and nothing per cell;
## a save carries `+0x4F` and no fog map, and the pass recomputes from scratch
## on every hand-over. So "cells outside vision are darkened" -- which an
## earlier plan for this stage asked for -- is not a rule this game has, and
## drawing one would be a remake decision dressed up as fidelity. What the
## engine has is three unit states, and that is what is drawn.
##
## | `+0x4F` | Drawn as |
## |---|---|
## | 0 full | the unit, as [UnitsView] builds it |
## | 1 contact | a marker at the cell, with no body and no facing |
## | 3 hidden | nothing at all |
##
## The **contact** state is the interesting one: docs/22 section 9.3's second
## pass promotes a lone hidden alien to a contact unless one of its eight
## neighbours already is, which shows one blip per cluster instead of one per
## alien. A remake that drew hidden units faintly instead would give away
## exactly what that pass exists to hide.

## docs/22 section 9.1.
const FULL: int = 0
const CONTACT: int = 1
const HIDDEN: int = 3

## The engine's own blip, by name: `a3DObjects.cpp` line 3838 resolves
## `A_BLIB.3DI` through `aGetNumberOfPrototype` (`0x00407056`), and the
## geometry is a beam -- 28 vertices spanning z 730..6337 in a 1550-wide
## footprint, about 3.5 m tall. The converter emits it for every world set
## (`inclib.convert.CONTACT_MARKER_MODEL`).
const CONTACT_MODEL: String = "A_BLIB.3DI"

## The fallback blip, for a cache built before the converter emitted the beam:
## a flat disc at the cell, no body. Not what the engine draws.
const CONTACT_RADIUS: float = 0.45
const CONTACT_COLOUR: Color = Color8(230, 90, 90, 180)


## Should this unit be drawn at all?
static func is_drawn(view: Dictionary) -> bool:
	return DictRead.as_int(view["visibility"]) != HIDDEN


## Is it drawn as a blip rather than as a unit?
static func is_contact(view: Dictionary) -> bool:
	return DictRead.as_int(view["visibility"]) == CONTACT


## The blip, for a unit the player has only detected: the engine's own
## `A_BLIB.3DI` when the cache carries it, and the disc when it does not.
##
## The disc was this remake's invention and it was wrong twice over -- the
## original marks a contact with a tall beam, and a flat disc at a cell reads
## as a decal rather than as something standing there. The prototype is four
## lines of lookup away, so there is no reason to draw a guess.
static func contact_marker(prototypes: Dictionary,
		textures: Dictionary) -> MeshInstance3D:
	if prototypes.has(CONTACT_MODEL):
		var beam: MeshInstance3D = MeshInstance3D.new()
		beam.name = "contact"
		beam.mesh = MeshBuilder.build(
			DictRead.as_dict(prototypes[CONTACT_MODEL]), textures)
		return beam
	return fallback_marker()


## The disc, kept only for a cache built before the beam was emitted.
static func fallback_marker() -> MeshInstance3D:
	var disc: CylinderMesh = CylinderMesh.new()
	disc.top_radius = CONTACT_RADIUS
	disc.bottom_radius = CONTACT_RADIUS
	disc.height = 0.08
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = CONTACT_COLOUR
	disc.material = material
	var node: MeshInstance3D = MeshInstance3D.new()
	node.name = "contact"
	node.mesh = disc
	node.position = Vector3(0.0, 0.05, 0.0)
	return node
