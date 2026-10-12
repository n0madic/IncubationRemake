// Kinds 0x08, 0x10 and 0x24: an opaque textured decal -- see scene.gdshaderinc.
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, cull_back, depth_draw_opaque;
#define TEXTURED
#define LIT
#include "res://game/shaders/scene.gdshaderinc"
