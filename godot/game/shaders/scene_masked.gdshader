// Kind 0x14: the colour-keyed texture, drawn after the opaque ones -- see scene.gdshaderinc.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never;
#define TEXTURED
#define MASKED
#define LIT
#include "res://game/shaders/scene.gdshaderinc"
