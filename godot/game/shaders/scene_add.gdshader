// Kind 0x1c: the saturating additive texture -- see scene.gdshaderinc.
shader_type spatial;
render_mode unshaded, cull_back, blend_add, depth_draw_never;
#define TEXTURED
#define TRANSLUCENT
#include "res://game/shaders/scene.gdshaderinc"
