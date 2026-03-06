// Blue aura outline — applied as next_pass on mesh surfaces.
// Renders only back-faces (cull_front) of the slightly-expanded mesh,
// producing a clean outline/aura around the object.
shader_type spatial;
render_mode cull_front, unshaded, depth_draw_opaque;

uniform vec4 outline_color : source_color = vec4(0.25, 0.6, 1.0, 1.0);
uniform float outline_width : hint_range(0.0, 0.05) = 0.012;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
