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
uniform float fibre_strength : hint_range(0.0, 1.0) = 0.25;
uniform float backlight_amount : hint_range(0.0, 1.0) = 0.22;
uniform float sheen : hint_range(0.0, 1.0) = 0.18;

varying float v_u;

const float PI_ = 3.14159265;

// Rest height above the flat page plane, and its derivatives wrt u and v.
// Kept in one place so vertex() can build an exact normal instead of leaving a
// stale one behind.
void rest_shape(float u, float v, out float z, out float dzdu, out float dzdv) {
	float e = exp(-u * gutter_falloff);
	float edge = 2.0 * v - 1.0;
	float edge_p = abs(edge);

	// smoothstep(0.55, 1.0, u) and its derivative
	float t = clamp((u - 0.55) / 0.45, 0.0, 1.0);
	float droop = t * t * (3.0 - 2.0 * t);
	float droop_d = (u > 0.55 && u < 1.0) ? 6.0 * t * (1.0 - t) / 0.45 : 0.0;

	z = -gutter_dive * e
		+ bow_amount * sin(u * PI_)
		- fore_droop * droop
		+ edge_curl * edge_p * edge_p * edge_p * u;

	dzdu = gutter_dive * gutter_falloff * e
		+ bow_amount * PI_ * cos(u * PI_)
		- fore_droop * droop_d
		+ edge_curl * edge_p * edge_p * edge_p;

	dzdv = edge_curl * 6.0 * edge_p * edge_p * sign(edge) * u;
}

void vertex() {
	float w = max(page_size.x, 1e-5);
	float h = max(page_size.y, 1e-5);
	float u = clamp(0.5 + spine_sign * VERTEX.x / w, 0.0, 1.0);
	float v = clamp(0.5 + VERTEX.y / h, 0.0, 1.0);
	v_u = u;

	float z;
	float dzdu;
	float dzdv;
	rest_shape(u, v, z, dzdu, dzdv);

	VERTEX.z += z;

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

// Cheap value noise — paper fibre, no texture fetch. Same spirit as
// wood_planks.gdshader: a couple of hash calls is affordable on Quest.
float hash21(vec2 p) {
	p = fract(p * vec2(233.34, 851.73));
	p += dot(p, p + 23.45);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
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

	// Fibre grain, applied through the mesh tangent frame.
	if (fibre_strength > 0.0) {
		vec2 fp = UV * vec2(420.0, 560.0);
		float nx = vnoise(fp) - vnoise(fp + vec2(1.7, 0.0));
		float ny = vnoise(fp + vec2(0.0, 1.3)) - vnoise(fp);
		NORMAL = normalize(NORMAL + (TANGENT * nx + BINORMAL * ny) * fibre_strength * 0.5);
	}

	ROUGHNESS = roughness - vnoise(UV * 90.0) * 0.06;
	METALLIC = 0.0;
	SPECULAR = sheen;
	// Paper is thin: light reaching the far side bleeds through.
	BACKLIGHT = vec3(backlight_amount) * color.rgb * shade;
}
