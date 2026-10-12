// Kind 0x14 seen from both sides: the A_BLUT splats -- see scene.gdshaderinc.
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, cull_disabled, depth_draw_never;
#define TEXTURED
#define MASKED
#define LIT
#include "res://game/shaders/scene.gdshaderinc"
