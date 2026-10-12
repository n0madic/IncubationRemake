// Kind 0x0c: the face colour at one half over what is drawn -- see scene.gdshaderinc.
shader_type spatial;
render_mode unshaded, cull_back, blend_mix, depth_draw_never;
#define TRANSLUCENT
#include "res://game/shaders/scene.gdshaderinc"
