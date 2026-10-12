// The remake's material for every face the engine draws -- docs/92 section
// 7.29. One body, included by one file per draw-kind class; the class is
// fixed by the `render_mode` line and the defines in front of the include,
// because Godot fixes blending, culling and depth writing at compile time.
//
// The original bakes its light into the pages and the face colours, so no
// variant takes Godot's light as light. The blended ones are unshaded; the LIT
// ones go through the lit pipeline only to read the sun's shadow map
// (SunShadow), with ambient and specular off. With no sun up
// (`shadow_strength` 0) the colour is EMISSION and the picture is the unshaded
// one to the bit. With one up the colour is drawn by the sun's own pass
// instead -- see light() for why it cannot be split between the two.
//
// TEXTURED     the face samples its page; otherwise it paints COLOR.
// MASKED       the RGB565 colour key: alpha 0 is a hole (a scissor).
// TRANSLUCENT  the face is blended, its alpha from the page or from COLOR.
// LIT          the face takes the effects' light (EffectLights) and the sun's
//              shadow (SunShadow): the opaque, colour-keyed and flat kinds;
//              the blended ones are the light.

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

#ifdef LIT
// EffectLights' table: texel (i, 0) is light i's position in metres and its
// radius, texel (i, 1) its colour. `fx_light_count` is 0 unless the preset
// asks for effect light, and multiplying by exactly one leaves every other
// preset's picture as it was.
global uniform sampler2D fx_lights;
global uniform int fx_light_count;
const int FX_LIGHT_LIMIT = 16;
varying vec3 world_position;
// How much of a face's colour the sun's shadow takes away: 0 is none, and 0
// whenever no SunShadow is up.
global uniform float shadow_strength;
// The share falls with the colour's own brightness (the page's, as stored):
// SHADOW_FLOOR of it up to SHADOW_RAMP_FROM, all of it from SHADOW_RAMP_TO. A
// dark level is already in its painted shadow, and the full share on top of
// it read as gloom (2026-10-12). The mission levels' median is about 0.09,
// the campaign city's lit faces 0.3. Fitted to the darkening play settled
// on -- about a sixth on dark and mid tones, half on bright ones -- once
// the share was found to have been read off linear light (see light()).
const float SHADOW_FLOOR = 0.3;
const float SHADOW_RAMP_FROM = 0.25;
const float SHADOW_RAMP_TO = 0.8;
// Rec. 601 luma, the weights the share's brightness is read with.
const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);
// A scene face takes the shadow in full once it turns this far to the sun
// (`N.L`), and none below SUN_FACING_FROM: the fade keeps grazing faces, where
// the map's self-shadowing would show as acne, clean.
const float SUN_FACING_FROM = 0.05;
const float SUN_FACING_FULL = 0.25;
// The smallest linear value light() divides by.
const float LINEAR_FLOOR = 1e-6;
// The vertex alpha, which no lit variant reads as alpha: 1 on the scene's
// faces, which take the sun's shadow only where they turn to the sun; 0 on a
// Charisma body's (MeshBuilder.SUN_ALL_FACES), which take it on every face --
// SunShadow lights bodies with a light of their own whose map holds no body,
// so nothing there is the body's own shadow. An `instance uniform` would have
// been the natural switch, but the Compatibility renderer gives every
// instance of the shader a slot of a 4096-entry buffer, and a mission's
// scenery overflows it.
varying float sun_facing_only;

// The share of `colour` the shadow takes, at most `shadow_strength`.
float shadow_share(vec3 colour) {
	float luma = dot(colour, LUMA_WEIGHTS);
	return shadow_strength * mix(SHADOW_FLOOR, 1.0,
		smoothstep(SHADOW_RAMP_FROM, SHADOW_RAMP_TO, luma));
}
#endif

void vertex() {
	face_rect = CUSTOM0;
#ifdef LIT
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	sun_facing_only = COLOR.a;
#endif
}

#ifdef LIT
// The effects' light at this point: each source adds its colour with a
// quadratic fall-off to nothing at its radius. Through walls, as a point
// light without shadows is -- the radii are kept to a few fields for that.
vec3 effect_light() {
	vec3 sum = vec3(0.0);
	for (int i = 0; i < FX_LIGHT_LIMIT; i++) {
		if (i >= fx_light_count) {
			break;
		}
		vec4 where = texelFetch(fx_lights, ivec2(i, 0), 0);
		vec3 colour = texelFetch(fx_lights, ivec2(i, 1), 0).rgb;
		float near = max(1.0 - distance(world_position, where.xyz) / where.w, 0.0);
		sum += colour * near * near;
	}
	return sum;
}
#endif

#ifdef TEXTURED
// The mipmapped read, kept inside the face's own rectangle of the atlas.
//
// The level is the one the screen footprint asks for, capped at `max_lod` by
// shrinking the gradients; the sample point is held one texel of that level
// inside the rectangle, so neither the filter nor the mip chain's own
// averaging reaches the neighbouring tile. A rectangle narrower than that
// collapses to its centre.
//
// **Close up, the texels stay square** (2026-10-12, after play): a plain
// bilinear blend across a magnified texel turned a rocket pod's painted
// shading -- a few texels of light and dark -- into a flat smear that only
// the nearest read kept. So the blend between two texels is narrowed to
// SHARP_EDGE of a texel around their edge, never under one screen pixel
// ("sharp bilinear"): magnified, the inside of a texel holds its own colour
// and the step to the next is a short ramp rather than a stair or a smear.
// Where a texel covers a screen pixel or less, the ramp is the whole texel --
// the plain read -- and the mip chain does the work.
const float SHARP_EDGE = 0.35;

vec2 sharpened(vec2 uv, vec2 size) {
	vec2 at = uv * size;
	vec2 seam = floor(at + 0.5);
	vec2 offset = at - seam;
	vec2 ramp = max(fwidth(at), vec2(SHARP_EDGE));
	vec2 sharp = clamp(offset / ramp, -0.5, 0.5);
	return (seam + mix(sharp, offset, step(1.0, ramp))) / size;
}

// `uv` is the face's own coordinate, which the level is chosen from; `sharp`
// is sharpened(uv), which is where the read is made.
vec4 mipmapped(vec2 uv, vec2 sharp) {
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
		lo.x <= hi.x ? clamp(sharp.x, lo.x, hi.x) : middle.x,
		lo.y <= hi.y ? clamp(sharp.y, lo.y, hi.y) : middle.y);
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
		vec2 sharp = sharpened(uv, vec2(textureSize(page, 0)));
		vec4 filtered = mipmapped(uv, sharp);
#ifdef MASKED
		// The key from the full-size page: averaged down, a grille's bars
		// fall under the threshold and thin away into the distance.
		filtered.a = textureLod(page, sharp, 0.0).a;
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
#ifdef LIT
	// The page already holds the original's light; the effects' is laid on
	// it as a gain, so a black texel stays black.
	ALBEDO *= vec3(1.0) + effect_light();
	EMISSION = shadow_strength > 0.0 ? vec3(0.0) : ALBEDO;
#endif
}

#ifdef LIT
// The sRGB decode and encode, for light().
vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)),
		step(vec3(0.04045), c));
}

vec3 linear_to_srgb(vec3 c) {
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055,
		step(vec3(0.0031308), c));
}

// Called only while a light is in the scene -- SunShadow's, or the fill a
// world of its own carries -- and then the whole colour comes from here.
//
// **The Compatibility renderer lights in linear light and stores sRGB.**
// light() sees ALBEDO decoded -- the page's `c` arrives as dec(c) -- and what
// the sun's pass adds is stored as enc(dec(c) * diffuse); a diffuse of 1.0
// gives the page back exactly (measured on `_C_141`, 2026-10-12: a diffuse
// of 0.5 alone turns a stored 80 into 56 and 40 into 26). So a share held
// back in EMISSION does not come back -- EMISSION * 0.55 plus a diffuse of
// 0.45 drew mid-tones brighter than the page -- and the factor `f` the shadow
// leaves is turned into the diffuse that stores `c * f`: dec(c * f) / dec(c),
// with `c` re-encoded from ALBEDO. An earlier cut divided by dec(ALBEDO),
// decoding twice; measured with `f` forced to 0.5 it stored about 0.68 of
// the page instead of half, and its share was read off linear light.
//
// **Only a face turned to the sun takes a shadow.** A face turned away is not
// darkened at all: the first cut shaded it as its own shadow, and a whole wall
// facing the camera and not the sun went dark and lost its painted detail
// (`_C_166`, 2026-10-12). What stays is the shadow cast on floors, roofs and
// ledges; `receive` fades it out towards grazing angles, where the map's own
// self-shadowing would otherwise show as acne.
//
// **Nothing while no sun is up.** fragment() then paints the colour as
// EMISSION, and a light that still reaches the face -- the upgrade screen's
// SunFill, which its own world keeps for the enhanced preset -- must not add
// it a second time: it drew that soldier a fifth brighter under the original
// preset.
//
// No `return` here: Godot refuses one in the light processor, and the
// variant then fails to compile -- which the headless suites never see.
void light() {
	if (shadow_strength > 0.0) {
		float receive = mix(1.0,
			smoothstep(SUN_FACING_FROM, SUN_FACING_FULL, dot(NORMAL, LIGHT)),
			sun_facing_only);
		vec3 stored = linear_to_srgb(ALBEDO);
		float f = 1.0 - shadow_share(stored) * receive * (1.0 - ATTENUATION);
		// Lit -- most of the picture: the diffuse that stores the colour
		// itself, with no conversion to pay for.
		if (f >= 1.0) {
			DIFFUSE_LIGHT += vec3(1.0);
		} else {
			DIFFUSE_LIGHT += srgb_to_linear(stored * f)
				/ max(ALBEDO, vec3(LINEAR_FLOOR));
		}
	}
}
#endif
