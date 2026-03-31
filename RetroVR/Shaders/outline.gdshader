// Outline shader — single-pass cull_front technique.
//
// The real mesh (source or overlay copy) renders at priority 0 and writes depth.
// This pass renders at priority 1 with cull_front (back faces only):
//   - Vertices are pushed outward along their view-space normal.
//   - Interior back faces are behind the already-written depth → fail depth test → hidden.
//   - Edge back faces are not occluded → pass depth test → visible as outline.
//
// No stencil or prepass needed. Works correctly on complex multi-mesh objects
// because the shared depth buffer handles masking across all overlays naturally.
//
// Note: flat geometry (normals parallel to view) gets no outline — view_normal.xy ≈ 0
// means no expansion, which is correct for interior label planes etc.
shader_type spatial;
render_mode cull_front, unshaded, depth_draw_never;

uniform vec4  outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float outline_width : hint_range(0.0, 3.0) = 1.0;
uniform float glow_strength : hint_range(0.0, 8.0) = 2.0;
uniform float fade_start    : hint_range(0.0, 10.0) = 0.0;
uniform float fade_end      : hint_range(0.1, 50.0) = 10.0;

varying float v_view_dist;

void vertex() {
	vec4 clip_pos    = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 view_normal = normalize(mat3(MODELVIEW_MATRIX) * NORMAL);

	v_view_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);

	float n_len = length(view_normal.xy);
	if (n_len > 1e-4) {
		clip_pos.xy += (view_normal.xy / n_len) * outline_width * clip_pos.w / VIEWPORT_SIZE.x;
	}

	POSITION = clip_pos;
}

void fragment() {
	float dist_fade = 1.0 - smoothstep(fade_start, fade_end, v_view_dist);
	ALBEDO   = outline_color.rgb;
	EMISSION = outline_color.rgb * glow_strength;
	ALPHA    = outline_color.a * dist_fade;
}
