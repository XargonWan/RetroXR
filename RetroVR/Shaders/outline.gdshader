// Outline shader — stencil-masked inverted hull (pass 2 of 2).
//
// Pass 1 (outline_mask.gdshader) stamps the object's screen footprint into the
// stencil buffer (ref 2), ignoring depth. This pass renders the hull inflated
// along view-space normals with depth testing disabled and stencil
// compare_not_equal: only the ring OUTSIDE the object's own footprint survives.
//
// Because neither pass depth-tests, the outline:
//   - is never eaten by nearby geometry (table under the object, shelf behind
//     it) that sits closer than the object's back faces, and
//   - stays visible when the object is fully occluded (x-ray).
//
// Multi-mesh objects compose correctly: all mask passes (priority 1) stamp the
// union footprint before any outline pass (priority 2) draws.
//
// Requires Godot 4.4+ stencil support (experimental). Stencil reads only work
// in the transparent pass — writing ALPHA puts both passes there.
//
// Note: flat geometry (normals parallel to view) gets no outline — view_normal.xy ≈ 0
// means no expansion, which is correct for interior label planes etc.
shader_type spatial;
render_mode cull_front, unshaded, depth_draw_never, depth_test_disabled;
stencil_mode read, compare_not_equal, 2;

uniform vec4  outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float outline_width : hint_range(0.0, 8.0) = 1.0;
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
		// outline_width is in pixels: NDC spans 2 units, scaled per-axis so the
		// outline is equally thick on horizontal and vertical edges.
		clip_pos.xy += (view_normal.xy / n_len) * outline_width * 2.0 * clip_pos.w / VIEWPORT_SIZE;
	}

	POSITION = clip_pos;
}

void fragment() {
	float dist_fade = 1.0 - smoothstep(fade_start, fade_end, v_view_dist);
	// unshaded skips EMISSION, so push the HDR glow through ALBEDO instead.
	ALBEDO = outline_color.rgb * (1.0 + glow_strength);
	ALPHA  = outline_color.a * dist_fade;
}
