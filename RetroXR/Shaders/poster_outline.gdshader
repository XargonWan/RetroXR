// Poster hover rim — the poster's own silhouette, one size up, in a flat colour.
//
// A poster is a die-cut sheet as often as a rectangle, so a plain quad behind it
// lights up the whole rectangle and the transparent part of the art reads as a
// solid slab. This samples the poster's ALPHA and paints only what the art
// actually covers, so a star gets a star-shaped rim.
//
// DISCARD, never ALPHA. Writing ALPHA at all moves the material into the
// transparent pipeline, where it stops writing depth and sorts per-triangle
// against the sheet 1 mm in front of it — the trap paper.gdshader documents. A
// discard keeps this in the opaque pass, which is also what lets the rim sit
// behind the art without fighting it.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, shadows_disabled;

uniform sampler2D poster_tex : source_color, filter_linear_mipmap;
uniform vec4 rim_color : source_color = vec4(1.0, 0.85, 0.3, 1.0);
// Matched to the sheet's own alpha_scissor_threshold, or the rim and the art
// disagree about where the edge is.
uniform float cutoff : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	if (texture(poster_tex, UV).a < cutoff) {
		discard;
	}
	ALBEDO = rim_color.rgb;
	EMISSION = rim_color.rgb;
}
