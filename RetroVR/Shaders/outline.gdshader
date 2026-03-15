// Outline shader — pass 2 of the stencil-based silhouette technique.
//
// WHY THIS WORKS:
//
//   pass 1 (outline_depth_prepass.gdshader, set as the overlay's material_override):
//     Renders the mesh's front faces invisibly and writes stencil=1 for every
//     pixel the original mesh covers on screen.
//
//   pass 2 (this shader, set as pass 1's next_pass):
//     Renders the expanded (cull_front) hull with depth_test_disabled so the
//     outline is always visible even when the object is behind other geometry.
//     Only renders where stencil != 1 — i.e. outside the original silhouette.
//     Interior pixels are discarded by the stencil test. Depth test disabled
//     also eliminates flickering at inside edges caused by depth precision.
//
//   Expansion is center-to-vertex in NDC screen space (not normal-based).
//   This works correctly for flat QuadMesh geometry (book cover, back cover, stacks)
//   where every vertex shares the same normal and normal-based expansion produces zero.
//
shader_type spatial;
render_mode cull_front, unshaded, blend_mix, depth_draw_never, depth_test_disabled;
stencil_mode read, write, compare_not_equal, 1;

uniform vec4  outline_color  : source_color = vec4(0.25, 0.6, 1.0, 1.0);
uniform float outline_width  : hint_range(0.0, 3.0) = 1.0;
uniform float glow_strength  : hint_range(0.0, 8.0) = 2.0;
uniform float fade_start     : hint_range(0.0, 10.0) = 0.0;
uniform float fade_end       : hint_range(0.1, 50.0) = 10.0;

varying float v_view_dist;

void vertex() {
	vec4 clip_pos    = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 clip_center = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);

	v_view_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);

	vec2 ndc_pos    = clip_pos.xy / clip_pos.w;
	vec2 ndc_center = clip_center.xy / clip_center.w;
	vec2 expand_dir = ndc_pos - ndc_center;
	float dir_len   = length(expand_dir);

	if (dir_len > 1e-4) {
		clip_pos.xy += (expand_dir / dir_len) * outline_width * 0.01 * clip_pos.w;
	}

	POSITION = clip_pos;
}

void fragment() {
	float dist_fade = 1.0 - smoothstep(fade_start, fade_end, v_view_dist);
	ALBEDO   = outline_color.rgb;
	EMISSION = outline_color.rgb * glow_strength;
	ALPHA    = outline_color.a * dist_fade;
}
