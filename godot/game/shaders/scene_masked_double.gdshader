// Kind 0x14 seen from both sides: the A_BLUT splats -- see scene.gdshaderinc.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
#define TEXTURED
#define MASKED
#include "res://game/shaders/scene.gdshaderinc"
