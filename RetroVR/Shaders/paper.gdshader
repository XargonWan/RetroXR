shader_type spatial;
render_mode cull_disabled;

// Paper page: a double-sided sheet that bows off its stack, dives into the
// gutter, and can be folded around a hand-driven fold line.
//
// All geometry is derived from two normalised page coordinates:
//   u = 0 at the gutter (spine) edge, 1 at the fore edge
//   v = 0 at the bottom edge, 1 at the top edge
// u is built from VERTEX.x rather than UV so the maths is independent of how
// the quad happens to be UV-mapped, and spine_sign flips it for the left page
// (and for the covers, which the book rotates 180 degrees about Y).

uniform sampler2D front_texture : source_color, hint_default_white, filter_linear_mipmap;
uniform sampler2D back_texture : source_color, hint_default_white, filter_linear_mipmap;
uniform vec4 paper_tint : source_color = vec4(0.98, 0.96, 0.92, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.82;
// How much the fibre texture breaks up the roughness. Coated stock is smooth
// and even, so gloss finishes want almost none of this.
uniform float roughness_variation : hint_range(0.0, 0.4) = 0.06;

// Page frame.
uniform vec2 page_size = vec2(0.18, 0.25);   // metres
uniform float spine_sign = 1.0;              // +1: gutter at local -X, -1: gutter at +X

// Rest shape.
uniform float gutter_dive : hint_range(0.0, 0.02) = 0.004;
uniform float gutter_falloff : hint_range(1.0, 40.0) = 12.0;
uniform float bow_amount : hint_range(0.0, 0.02) = 0.0025;
uniform float fore_droop : hint_range(0.0, 0.02) = 0.0015;
uniform float edge_curl : hint_range(0.0, 0.02) = 0.002;

// Fold-line cylinder wrap. fold_normal points from the fold line toward the
// part of the sheet that curls over; fold_strength 0 disables the whole branch.
uniform float fold_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec2 fold_origin = vec2(0.0);        // page-local metres
uniform vec2 fold_normal = vec2(1.0, 0.0);   // unit
uniform float curl_radius = 0.01;
uniform float curl_taper : hint_range(0.0, 4.0) = 1.2;

// Surface.
uniform float gutter_ao : hint_range(0.0, 1.0) = 0.55;
uniform float gutter_ao_falloff : hint_range(1.0, 40.0) = 9.0;
uniform sampler2D grain_texture : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec2 grain_tile = vec2(6.0, 8.0);
uniform float fibre_strength : hint_range(0.0, 1.0) = 0.25;
uniform float backlight_amount : hint_range(0.0, 1.0) = 0.22;
uniform float sheen : hint_range(0.0, 1.0) = 0.18;

varying float v_u;

const float PI_ = 3.14159265;
const float PAPER_PI = 3.14159265;

#include "res://Shaders/paper_rest.gdshaderinc"

void vertex() {
	float w = max(page_size.x, 1e-5);
	float h = max(page_size.y, 1e-5);
	float u = clamp(0.5 + spine_sign * VERTEX.x / w, 0.0, 1.0);
	float v = clamp(0.5 + VERTEX.y / h, 0.0, 1.0);
	v_u = u;

	float gutter;
	float sag;
	float bow;
	paper_rest_parts(u, v, gutter_dive, gutter_falloff, bow_amount, fore_droop, edge_curl,
		gutter, sag, bow);
	float dzdu;
	float dzdv;
	paper_rest_slope(u, v, gutter_dive, gutter_falloff, bow_amount, fore_droop, edge_curl,
		dzdu, dzdv);

	VERTEX.z += gutter + sag + bow;

	// Arc-length conservation: the sheet dipping into the gutter is longer than
	// the flat span it covers, so a material point sits nearer the spine than
	// its flat position. Doing this in geometry (rather than squeezing UVs)
	// keeps the texture attached to the paper.
	VERTEX.x -= spine_sign * gutter_dive * exp(-u * gutter_falloff) * 0.5;

	// dz/dx and dz/dy from du/dx = spine_sign/w, dv/dy = 1/h.
	vec3 n = normalize(vec3(-dzdu * spine_sign / w, -dzdv / h, 1.0));

	if (fold_strength > 0.0) {
		vec2 fn = normalize(fold_normal);
		vec2 ft = vec2(-fn.y, fn.x);
		float d = dot(VERTEX.xy - fold_origin, fn);
		if (d > 0.0) {
			// Looser curl toward the spine, where the binding stiffens the sheet.
			float r = max(curl_radius * (1.0 + curl_taper * (1.0 - u)), 1e-4);
			vec2 fold_pt = VERTEX.xy - fn * d;
			float arc = d / r;
			if (arc < PI_) {
				VERTEX.xy = fold_pt + fn * (r * sin(arc));
				VERTEX.z += r * (1.0 - cos(arc));
			} else {
				// Past the half-cylinder the sheet is flat again, upside down.
				VERTEX.xy = fold_pt - fn * (d - PI_ * r);
				VERTEX.z += 2.0 * r;
			}
			// Rotate the rest normal about the fold axis by the same angle.
			float a = clamp(arc, 0.0, PI_);
			float ca = cos(a);
			float sa = sin(a);
			float nn = dot(n.xy, fn);
			float nt = dot(n.xy, ft);
			float nz = n.z;
			float nn2 = nn * ca - nz * sa;
			float nz2 = nn * sa + nz * ca;
			n = normalize(vec3(fn * nn2 + ft * nt, nz2));
		}
	}

	NORMAL = n;
}

void fragment() {
	vec4 color;
	if (FRONT_FACING) {
		color = texture(front_texture, UV) * paper_tint;
	} else {
		// Mirror UV horizontally for back face so text reads correctly
		vec2 back_uv = vec2(1.0 - UV.x, UV.y);
		color = texture(back_texture, back_uv) * paper_tint;
	}

	// Gutter shadow — the single cheapest cue that this is a bound book.
	float shade = 1.0 - gutter_ao * exp(-v_u * gutter_ao_falloff);
	color.rgb *= shade;

	// Deliberately no ALPHA write. Writing ALPHA at all moves a spatial material
	// into the transparent pipeline, where it stops writing depth — and two
	// depth-less page surfaces sort per-triangle against each other, so the page
	// underneath punched through the one turning over it in patches. Paper is
	// opaque; it belongs in the opaque pass.
	ALBEDO = color.rgb;

	// Fibre grain, applied through the mesh tangent frame. One fetch from a
	// small tiling texture rather than value noise: the procedural version cost
	// sixteen hash calls per fragment across four page surfaces, which is the
	// wrong shape for a tile GPU on a scene already over its frame budget.
	// RG carry the fibre gradient, B a slow roughness variation.
	vec3 grain = texture(grain_texture, UV * grain_tile).rgb;
	if (fibre_strength > 0.0) {
		NORMAL = normalize(NORMAL
			+ (TANGENT * (grain.r - 0.5) + BINORMAL * (grain.g - 0.5)) * fibre_strength);
	}

	ROUGHNESS = clamp(roughness - grain.b * roughness_variation, 0.02, 1.0);
	METALLIC = 0.0;
	SPECULAR = sheen;
	// Paper is thin: light reaching the far side bleeds through.
	BACKLIGHT = vec3(backlight_amount) * color.rgb * shade;
}
