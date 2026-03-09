// Outline shader — pass 2 of the fake-stencil silhouette technique.
//
// WHY THIS WORKS (no SubViewport, no depth_test_disabled needed):
//
//   pass 1 (outline_depth_prepass.gdshader, set as the overlay's material_override):
//     Renders the mesh's front faces invisibly but writes depth. This is the stencil mask.
//
//   pass 2 (this shader, set as pass 1's next_pass):
//     Renders expanded back faces. Depth test IS enabled, testing against pass 1's mask:
//       - Back faces INSIDE the object → behind the mask depth → fail → hidden.
//       - Back faces at the SILHOUETTE → outside the object's 2D screen footprint →
//         depth buffer is empty/far there → always pass → always visible. ✓
//
//   The expansion is screen-space XY only (POSITION.xy, NOT VERTEX world-space).
//   This preserves the depth value of each vertex, eliminating z-fighting at the
//   silhouette boundary that caused the old VERTEX+=NORMAL approach to flicker as
//   the camera moved.
//
shader_type spatial;
render_mode cull_front, unshaded, blend_mix, depth_draw_never;

uniform vec4 outline_color : source_color = vec4(0.25, 0.6, 1.0, 1.0);

// shell_width: repurposed as a depth bias scale. Slightly nudges the back-face
// depth toward camera to clear any remaining depth-precision edge at the silhouette.
// Kept as a uniform so existing GDScript property assignments still work.
// Visual outline width is controlled entirely by perspective_width.
uniform float shell_width : hint_range(0.0, 0.05) = 0.012;

// Screen-space outline width. 1.0 = ~1% of screen height regardless of distance.
uniform float perspective_width : hint_range(0.0, 2.0) = 0.8;

// Controls the softness / band-width of the outline ring.
// Small (0.05) = thin crisp edge. Large (0.5+) = wide soft glow halo.
uniform float edge_softness : hint_range(0.001, 1.0) = 0.3;

// Emission multiplier — drives Godot's glow post-process (WorldEnvironment → Glow).
uniform float glow_strength : hint_range(0.0, 8.0) = 2.0;

// Distance fade: outline fades from 1 at fade_start to 0 at fade_end (view-space meters).
uniform float fade_start : hint_range(0.0, 10.0) = 0.0;
uniform float fade_end : hint_range(0.1, 50.0) = 10.0;

varying float v_view_dist;
varying vec3 v_view_normal;

void vertex() {
	// View-space position of the (unexpanded) vertex.
	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	v_view_dist   = length(view_pos.xyz);
	v_view_normal = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);

	// Clip-space position.
	vec4 clip_pos = PROJECTION_MATRIX * view_pos;

	// Screen-space XY expansion.
	// Project the surface normal into clip space and push the vertex along it in 2D.
	// Multiplying by clip_pos.w converts the NDC-space offset to clip-space, so the
	// outline stays the same apparent size regardless of how far the object is.
	// Z is NOT modified here — depth stays equal to the unmodified surface depth.
	vec4 clip_norm = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(NORMAL, 0.0));
	float norm_len = length(clip_norm.xy);
	if (norm_len > 1e-4) {
		clip_pos.xy += (clip_norm.xy / norm_len) * perspective_width * 0.01 * clip_pos.w;
	}

	// Tiny depth nudge toward camera.
	// At the exact silhouette pixel the back-face depth equals the prepass mask depth.
	// This sub-millimetre bias (shell_width * 0.05 in NDC) ensures the outline always
	// wins that comparison without affecting any other depth relationship.
	clip_pos.z -= (shell_width * 0.05 + 0.0002) * clip_pos.w;

	POSITION = clip_pos;
}

void fragment() {
	// Distance fade.
	float dist_fade = 1.0 - smoothstep(fade_start, fade_end, v_view_dist);

	// Edge softness — fades the inner boundary of the outline ring.
	// rim ≈ 0  at the silhouette (normal ⊥ view) → full opacity.
	// rim → 1 away from silhouette → transparent.
	// edge_softness sets how wide the visible band is.
	float rim       = abs(dot(normalize(v_view_normal), vec3(0.0, 0.0, 1.0)));
	float edge_fade = 1.0 - smoothstep(0.0, edge_softness, rim);

	float alpha = outline_color.a * dist_fade * edge_fade;

	// Bloom: EMISSION over 1.0 feeds into Godot's WorldEnvironment glow.
	ALBEDO   = outline_color.rgb;
	EMISSION = outline_color.rgb * glow_strength;
	ALPHA    = alpha;
}
