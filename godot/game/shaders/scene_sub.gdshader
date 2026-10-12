// Kind 0x20: the saturating subtractive texture -- see scene.gdshaderinc.
shader_type spatial;
render_mode unshaded, cull_back, blend_sub, depth_draw_never;
#define TEXTURED
#define TRANSLUCENT
#include "res://game/shaders/scene.gdshaderinc"
