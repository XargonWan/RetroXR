shader_type spatial;

// Book binding. One box mesh plays two roles depending on how the book sits:
//
//   CLOSED  — the outward spine you read off a shelf. The cover artwork wraps
//             around it (sampled from the cover's own inner edge, so the
//             binding always matches the book instead of a hardcoded colour)
//             and a fake cylindrical normal rounds it across the thickness.
//   OPEN    — the binding seen down in the gutter valley, recessed below the
//             page stacks. Reads as shadow, with a soft crease down the middle.

uniform sampler2D cover_texture : source_color, hint_default_black, filter_linear_mipmap;
uniform vec4 fallback_tint : source_color = vec4(0.16, 0.16, 0.20, 1.0);
// 0 = outward spine (closed), 1 = gutter floor (open).
uniform float gutter_shade : hint_range(0.0, 1.0) = 0.0;
uniform float spine_depth = 0.0075;
uniform float spine_height = 0.25;
uniform float spine_width = 0.012;
uniform float round_amount : hint_range(0.0, 1.5) = 0.55;
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
uniform bool has_cover = false;

varying float v_t;      // 0..1 across the book's thickness
varying float v_v;      // 0..1 up the spine
varying float v_x;      // 0 at the outward edge, 1 at the page edge
varying float v_out;    // 1 on the outward-facing spine face
varying float v_top;    // 1 on the face that becomes the gutter floor

void vertex() {
	float d = max(spine_depth, 1e-5);
	v_t = clamp(VERTEX.z / d + 0.5, 0.0, 1.0);
	v_v = clamp(VERTEX.y / max(spine_height, 1e-5) + 0.5, 0.0, 1.0);
	v_x = clamp(VERTEX.x / max(spine_width, 1e-5) + 0.5, 0.0, 1.0);
	v_out = step(0.5, abs(NORMAL.x));
	v_top = step(0.5, NORMAL.z);

	if (v_out > 0.5 && round_amount > 0.0) {
		// Bend the outward face's normal across the thickness so a flat box
		// catches light like a rounded binding.
		float a = (v_t * 2.0 - 1.0) * round_amount;
		NORMAL = normalize(vec3(NORMAL.x * cos(a), NORMAL.y, sin(a)));
	} else if (v_top > 0.5 && round_amount > 0.0) {
		// On a closed book this face is the cover carrying on over the binding,
		// so it has to roll away toward the outward edge instead of sitting
		// flat — otherwise the spine reads as a separate strip laid on top.
		float a = (1.0 - v_x) * round_amount;
		NORMAL = normalize(vec3(-sin(a), NORMAL.y, cos(a)));
	}
}

void fragment() {
	// Wrap the cover's inner edge around the binding: a vertical strip taken
	// from the very edge of the cover art, so a red magazine gets a red spine.
	// cover_texture is a 1 px wide strip of the cover's averaged inner edge, so
	// the binding carries the artwork's colour bands up its length.
	vec3 base = fallback_tint.rgb;
	if (has_cover) {
		vec3 edge = texture(cover_texture, vec2(0.5, 1.0 - v_v)).rgb;
		base = mix(fallback_tint.rgb, edge * 0.8, 0.88);
	}

	// Head and tail of the spine wear and shade darker than its middle.
	base *= 1.0 - 0.30 * exp(-v_v * 22.0) - 0.30 * exp(-(1.0 - v_v) * 22.0);

	// Closed: shade the roll across the thickness. Open: the valley floor is in
	// shadow, deepest right at the crease.
	float roll = mix(0.72, 1.0, 1.0 - abs(v_t * 2.0 - 1.0));
	// The cover-continuation face shades along the width instead.
	roll = mix(roll, mix(0.62, 1.0, v_x), v_top * (1.0 - gutter_shade));
	float crease = 1.0 - 0.55 * exp(-abs(v_t * 2.0 - 1.0) * 3.0);
	float lit = mix(roll, crease * 0.30, gutter_shade * v_top);
	lit = mix(lit, lit * 0.45, gutter_shade * (1.0 - v_top));

	ALBEDO = base * lit;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = mix(0.3, 0.05, gutter_shade);
}
