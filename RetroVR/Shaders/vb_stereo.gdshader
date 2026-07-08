// Virtual Boy stereo eyepiece — per-eye sampling of a side-by-side frame.
//
// mednafen_vb with vb_3dmode = "side-by-side" outputs one framebuffer with
// the LEFT eye's image in the left half and the RIGHT eye's in the right
// half. In VR, Godot renders this material once per eye with VIEW_INDEX
// telling us which: each eye samples ITS half of the texture, so the quad
// shows genuinely different images to each eye — real stereoscopic depth,
// the thing the original hardware faked with a parallax barrier.
//
// Desktop / mono rendering: VIEW_INDEX is VIEW_MONO_LEFT, so a flat screen
// simply shows the left eye's image.
shader_type spatial;
render_mode unshaded;

uniform sampler2D source_tex: source_color, filter_nearest;
// 1.0 while the core runs; 0.0 shows the powered-off black eyepiece.
uniform float powered: hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = vec2(UV.x * 0.5 + (VIEW_INDEX == VIEW_RIGHT ? 0.5 : 0.0), UV.y);
	ALBEDO = vec3(0.0);
	EMISSION = texture(source_tex, uv).rgb * powered;
}
