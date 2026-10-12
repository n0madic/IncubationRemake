// The remake's material for every face the engine draws -- docs/92 section
// 7.29. One body, included by one file per draw-kind class; the class is
// fixed by the `render_mode` line and the defines in front of the include,
// because Godot fixes blending, culling and depth writing at compile time.
//
// Unshaded throughout: the original bakes its light into the pages and the
// face colours, so nothing here reads Godot's lights.
//
// TEXTURED     the face samples its page; otherwise it paints COLOR.
// MASKED       the RGB565 colour key: alpha 0 is a hole (a scissor).
// TRANSLUCENT  the face is blended, its alpha from the page or from COLOR.

// The page. Filtered reads go through its sampler, clamped; the texel-by-texel
// read the shipped renderers make is `texelFetch`, which no sampler state
// touches. **One sampler, not two**: the Compatibility renderer keeps the
// filter on the texture object itself, so one page bound to a nearest and a
// filtered uniform is filtered in both -- a nearest read that blended across
// every texel edge. White when a face names a page the bank lacks, as an
// untextured material is.
uniform sampler2D page : hint_default_white, filter_linear_mipmap_anisotropic, repeat_disable;
// [constant GraphicsMode.SAMPLING_NEAREST], LINEAR or MIPMAPPED.
uniform int sampling = 0;
// The coarsest mip level a face may read: 3 is 32-texel tiles. The pages are
// atlases, and a coarser level averages a tile with its neighbours.
uniform float max_lod = 3.0;

// The face's own (u0, v0, u1, v1) on its page, from CUSTOM0.
varying vec4 face_rect;

void vertex() {
	face_rect = CUSTOM0;
}

#ifdef TEXTURED
// The mipmapped read, kept inside the face's own rectangle of the atlas.
//
// The level is the one the screen footprint asks for, capped at `max_lod` by
// shrinking the gradients; the sample point is held one texel of that level
// inside the rectangle, so neither the filter nor the mip chain's own
// averaging reaches the neighbouring tile. A rectangle narrower than that
// collapses to its centre.
vec4 mipmapped(vec2 uv) {
	vec2 size = vec2(textureSize(page, 0));
	vec2 gx = dFdx(uv);
	vec2 gy = dFdy(uv);
	float major = max(length(gx * size), length(gy * size));
	float cap = exp2(max_lod);
	float shrink = major > cap ? cap / major : 1.0;
	vec2 inset = vec2(max(major * shrink, 1.0)) / size;
	vec2 lo = face_rect.xy + inset;
	vec2 hi = face_rect.zw - inset;
	vec2 middle = (face_rect.xy + face_rect.zw) * 0.5;
	vec2 held = vec2(
		lo.x <= hi.x ? clamp(uv.x, lo.x, hi.x) : middle.x,
		lo.y <= hi.y ? clamp(uv.y, lo.y, hi.y) : middle.y);
	return textureGrad(page, held, gx * shrink, gy * shrink);
}

// The engine's own read: the texel `floor(uv * 256)`, both indices wrapping
// mod 256 (docs/31 section 4.6).
vec4 nearest(vec2 uv) {
	ivec2 size = textureSize(page, 0);
	ivec2 at = ivec2(floor(uv * vec2(size)));
	return texelFetch(page, ivec2(
		at.x - size.x * int(floor(float(at.x) / float(size.x))),
		at.y - size.y * int(floor(float(at.y) / float(size.y)))), 0);
}

vec4 sample_page(vec2 uv) {
	if (sampling == 1) {
		return textureLod(page, uv, 0.0);
	}
	if (sampling == 2) {
		vec4 filtered = mipmapped(uv);
#ifdef MASKED
		// The key from the full-size page: averaged down, a grille's bars
		// fall under the threshold and thin away into the distance.
		filtered.a = textureLod(page, uv, 0.0).a;
#endif
		return filtered;
	}
	return nearest(uv);
}
#endif

void fragment() {
#ifdef TEXTURED
	vec4 texel = sample_page(UV);
	ALBEDO = texel.rgb;
#ifdef MASKED
	ALPHA = texel.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
#endif
#ifdef TRANSLUCENT
	ALPHA = texel.a;
#endif
#else
	ALBEDO = COLOR.rgb;
#ifdef TRANSLUCENT
	ALPHA = COLOR.a;
#endif
#endif
}
