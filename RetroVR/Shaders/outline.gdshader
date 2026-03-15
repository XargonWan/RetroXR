// Outline shader — pass 2 of the fake-stencil silhouette technique.
//
// WHY THIS WORKS (no SubViewport, no depth_test_disabled needed):
//
//   pass 1 (outline_depth_prepass.gdshader, set as the overlay's material_override):
//     Renders the mesh's front faces invisibly but writes depth. This is the stencil mask.
//
//   pass 2 (this shader, set as pass 1's next_pass):
//     Renders expanded geometry. Depth test IS enabled, testing against pass 1's mask:
//       - Pixels INSIDE the object → behind the mask depth → fail → hidden.
//       - Pixels at the SILHOUETTE RING → outside the object's 2D screen footprint →
//         depth buffer is empty/far there → always pass → always visible. ✓
//
//   Expansion is center-to-vertex in NDC screen space (not normal-based).
//   This works correctly for flat QuadMesh geometry (book cover, back cover, stacks)
//   where every vertex shares the same normal and normal-based expansion produces zero.
//
shader_type spatial;
render_mode cull_disabled, unshaded, blend_mix, depth_draw_never;

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

	// Tiny depth nudge toward camera so the outline wins depth ties at the silhouette.
	clip_pos.z -= 0.001 * clip_pos.w;

	POSITION = clip_pos;
}

void fragment() {
	float dist_fade = 1.0 - smoothstep(fade_start, fade_end, v_view_dist);
	float alpha     = outline_color.a * dist_fade;

	ALBEDO   = outline_color.rgb;
	EMISSION = outline_color.rgb * glow_strength;
	ALPHA    = alpha;
}
