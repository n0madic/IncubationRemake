// EffectLights' halo: a soft disc added over the scene round each light --
// docs/92 section 7.29. Its own pass rather than the environment's glow, which
// in the Compatibility renderer changes the whole picture it is laid on.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

// A radial fall-off, white at the centre and black at the rim.
uniform sampler2D falloff : filter_linear, repeat_disable;

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = texture(falloff, UV).r;
}
