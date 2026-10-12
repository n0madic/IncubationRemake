class_name SunShadow
extends DirectionalLight3D

## The sun's shadow, for the *enhanced* graphics preset -- docs/92 section
## 7.29. The remake's own: the original draws no shadow at run time, and its
## light is baked into the pages and the face colours.
##
## **A shadow, not a light.** While a sun is up the scene shader's lit
## variants draw their whole colour through this light's pass (`light()` in
## `scene.gdshaderinc`): the page exactly where the shadow map sees the sun,
## less up to [constant STRENGTH] of it in shadow -- less on dark colours, and
## none on a face turned away from the sun, which keeps its painted detail.
## Lit ground keeps its colour, so the baked light is never doubled.
##
## **The strength is global, and 0 unless a sun is up.** Every lit material
## reads `shadow_strength`, and while it is not 0 their EMISSION is 0 -- so one
## in a world with no light is black. A cutscene hides the roots the suns
## stand in, so each sun publishes it on every change of its own visibility:
## [constant STRENGTH] while any sun in the tree is visible, 0 otherwise.
##
## **The sun stands high.** Nothing records where the artists' baked light
## comes from, so a low sun would cast shadows that argue with the painted
## ones. [constant ELEVATION_DEGREES] from the horizon keeps every shadow short
## and under the thing that casts it -- closer to contact shadow than to an
## evening sun -- and the azimuth is fixed in the world, so turning the camera
## quadrant does not move it.
##
## Presentation only: nothing here enters a save or the canonical hash.

const GLOBAL_STRENGTH: StringName = &"shadow_strength"
const GROUP: StringName = &"sun_shadow"
## How much of a bright face's colour full shadow takes away; the shader takes
## less of a dark one (`shadow_share`).
const STRENGTH: float = 0.55
const ELEVATION_DEGREES: float = 65.0
const AZIMUTH_DEGREES: float = 35.0
## Metres from the camera the shadow map covers. A mission is at most 40
## fields (80 m) on a side and the camera sees a corner of it, so this holds
## the whole view.
const MAX_DISTANCE: float = 60.0
## The body light's map reaches less far: it exists only to darken a body in
## a wall's shadow, which past this is a few pixels tall, and a shorter map
## draws fewer casters into its share of the directional shadow atlas.
const BODY_MAX_DISTANCE: float = 40.0
const BIAS: float = 0.1
const NORMAL_BIAS: float = 2.0
## Soften the edge a little: a hard-edged map at this distance stair-steps.
const BLUR: float = 1.5
## The visual layer a Charisma body's parts are drawn on ([CharismaBody]), so
## the sun can treat bodies apart. Every other mesh stays on layer 1.
const BODY_LAYER: int = 1 << 1
const ALL_LAYERS: int = (1 << 20) - 1
const SCENE_LAYERS: int = ALL_LAYERS & ~BODY_LAYER
## The root's meta the published strength is recorded under, for the agent to
## report what the shader reads rather than what it should read.
const PUBLISHED_META: StringName = &"sun_shadow_strength"

## **Two lights, one sun.** This one lights the scene, and everything casts
## into its map, bodies included -- a soldier's shadow on the floor. Bodies
## are lit by [member _on_bodies] instead, whose map holds the scene only: a
## body in a wall's shadow darkens, and is never shaded by its own arm or
## chest, which over a few dozen flat faces read as a patchwork. The cost is
## a second shadow pass.
var _on_bodies: DirectionalLight3D = null


func _init() -> void:
	name = "SunShadow"
	_aim(self)
	_dress(self)
	light_cull_mask = SCENE_LAYERS
	# A child, so it turns and hides with this one.
	_on_bodies = DirectionalLight3D.new()
	_on_bodies.name = "SunOnBodies"
	_dress(_on_bodies)
	_on_bodies.light_cull_mask = BODY_LAYER
	_on_bodies.shadow_caster_mask = SCENE_LAYERS
	_on_bodies.directional_shadow_max_distance = BODY_MAX_DISTANCE
	add_child(_on_bodies)
	visible = false


## The sun's direction: fixed in the world, high in the sky.
static func _aim(light: DirectionalLight3D) -> void:
	light.rotation_degrees = Vector3(-ELEVATION_DEGREES, AZIMUTH_DEGREES, 0.0)


static func _dress(light: DirectionalLight3D) -> void:
	light.light_color = Color.WHITE
	light.light_energy = 1.0
	light.light_specular = 0.0
	light.shadow_enabled = true
	light.shadow_bias = BIAS
	light.shadow_normal_bias = NORMAL_BIAS
	light.shadow_blur = BLUR
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	light.directional_shadow_max_distance = MAX_DISTANCE


## The light a [World3D] of its own needs while a sun is up elsewhere: the
## same direction, no shadow map. Without it the lit materials there would be
## black -- the soldier in the upgrade screen's window, on the enhanced
## preset. With the strength at 0 the shader ignores it, and the picture is
## the unshaded one.
static func fill() -> DirectionalLight3D:
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.name = "SunFill"
	_aim(light)
	_dress(light)
	light.shadow_enabled = false
	return light


func _enter_tree() -> void:
	add_to_group(GROUP)
	_publish(null)


func _exit_tree() -> void:
	_publish(self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_inside_tree():
		_publish(null)


## Switch the shadow on or off. Off is the light hidden.
func set_enabled(enabled: bool) -> void:
	visible = enabled
	_publish(null)


## What the global strength should be now, with `leaving` already gone.
func strength(leaving: SunShadow = null) -> float:
	if not is_inside_tree():
		return 0.0
	return strength_among(get_tree().get_nodes_in_group(GROUP), leaving)


## [constant STRENGTH] while any of `suns` but `leaving` is drawn, 0 otherwise.
static func strength_among(suns: Array[Node], leaving: SunShadow) -> float:
	return STRENGTH if drawn_among(suns, leaving) > 0 else 0.0


## How many of `suns` but `leaving` are drawn.
static func drawn_among(suns: Array[Node], leaving: SunShadow) -> int:
	var drawn: int = 0
	for node: Variant in suns:
		var sun: SunShadow = node
		if sun != leaving and sun.is_visible_in_tree():
			drawn += 1
	return drawn


## The strength the shader was last given, or 0 before any sun published.
static func published(tree: SceneTree) -> float:
	if tree == null or not tree.root.has_meta(PUBLISHED_META):
		return 0.0
	var value: Variant = tree.root.get_meta(PUBLISHED_META)
	return value if value is float else 0.0


func _publish(leaving: SunShadow) -> void:
	if not is_inside_tree():
		return
	var suns: Array[Node] = get_tree().get_nodes_in_group(GROUP)
	# **One sun per picture.** The mission and the campaign map each keep one,
	# and the two are never up together; if they were, both would light the
	# same world and light() would add the colour twice.
	if drawn_among(suns, leaving) > 1:
		push_warning("SunShadow: more than one sun is drawn; lit faces " +
			"would be drawn twice over")
	var value: float = strength_among(suns, leaving)
	RenderingServer.global_shader_parameter_set(GLOBAL_STRENGTH, value)
	get_tree().root.set_meta(PUBLISHED_META, value)
