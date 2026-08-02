// Night-city view for the den window: gradient sky, moon, star field and
// building silhouettes with warm lit windows (subtle twinkle).
// Unshaded + emissive so it reads as a bright exterior against the dark room.
shader_type spatial;
render_mode unshaded;

uniform float emission_strength: hint_range(0.0, 4.0) = 1.4;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = UV;
	uv.y = 1.0 - uv.y;   // 0 = bottom of the window

	// Sky: deep night blue up top, faint city-glow amber at the horizon.
	vec3 sky_top = vec3(0.015, 0.02, 0.06);
	vec3 sky_horizon = vec3(0.12, 0.07, 0.05);
	vec3 col = mix(sky_horizon, sky_top, smoothstep(0.25, 0.85, uv.y));

	// Stars (upper sky only).
	float star_cell = hash21(floor(uv * vec2(90.0, 45.0)));
	if (star_cell > 0.985 && uv.y > 0.5) {
		float tw = 0.7 + 0.3 * sin(TIME * 2.0 + star_cell * 40.0);
		col += vec3(0.8, 0.85, 1.0) * tw * smoothstep(0.985, 1.0, star_cell);
	}

	// Moon with soft glow.
	vec2 moon_pos = vec2(0.76, 0.78);
	float md = length((uv - moon_pos) * vec2(2.0, 1.0));
	col += vec3(0.9, 0.92, 0.85) * smoothstep(0.075, 0.06, md);
	col += vec3(0.25, 0.28, 0.3) * smoothstep(0.3, 0.06, md) * 0.35;

	// Two rows of building silhouettes: far row (short) and near row (tall).
	for (int row = 0; row < 2; row++) {
		float fr = float(row);
		float bw = mix(0.09, 0.13, fr);                  // building width
		float bx = floor(uv.x / bw);
		float h = mix(0.28, 0.42, fr) * (0.5 + 0.5 * hash21(vec2(bx, fr * 7.0)));
		float base = mix(0.16, 0.0, fr);
		if (uv.y < base + h) {
			vec3 bcol = mix(vec3(0.03, 0.035, 0.05), vec3(0.015, 0.018, 0.028), fr);
			col = bcol;
			// Lit windows: small grid, ~35% lit, faint slow twinkle.
			vec2 wuv = vec2(fract(uv.x / bw), (uv.y - base) / h);
			vec2 wg = floor(wuv * vec2(5.0, 14.0 * h / 0.4));
			float lit = hash21(wg + vec2(bx * 13.1, fr * 3.7));
			vec2 wf = fract(wuv * vec2(5.0, 14.0 * h / 0.4));
			bool inside = wf.x > 0.25 && wf.x < 0.75 && wf.y > 0.3 && wf.y < 0.7;
			if (lit > 0.65 && inside) {
				float flicker = 0.85 + 0.15 * sin(TIME * 0.7 + lit * 90.0);
				vec3 wcol = mix(vec3(1.0, 0.75, 0.4), vec3(0.7, 0.85, 1.0), step(0.92, lit));
				col += wcol * flicker * mix(0.8, 1.2, fr);
			}
		}
	}

	// Unshaded: ALBEDO is the final surface color (EMISSION is ignored).
	ALBEDO = col * emission_strength;
}
