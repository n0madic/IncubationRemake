// Kinds 0x00, 0x04 and 0x18: the face colour -- see scene.gdshaderinc.
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, cull_back, depth_draw_opaque;
#define LIT
#include "res://game/shaders/scene.gdshaderinc"
