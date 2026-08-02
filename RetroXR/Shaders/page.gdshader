shader_type spatial;
render_mode cull_disabled;

// Double-sided page shader: shows front_texture on front face,
// back_texture on back face. Paper-like appearance.

uniform sampler2D front_texture : source_color, filter_linear_mipmap;
uniform sampler2D back_texture : source_color, filter_linear_mipmap;
uniform vec4 paper_tint : source_color = vec4(0.98, 0.96, 0.92, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.85;

void fragment() {
	vec4 color;
	if (FRONT_FACING) {
		color = texture(front_texture, UV) * paper_tint;
	} else {
		// Mirror UV horizontally for back face so text reads correctly
		vec2 back_uv = vec2(1.0 - UV.x, UV.y);
		color = texture(back_texture, back_uv) * paper_tint;
	}
	ALBEDO = color.rgb;
	ALPHA = color.a;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
}
