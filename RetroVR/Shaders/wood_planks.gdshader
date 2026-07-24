// Procedural wood plank floor for the den scene.
// Staggered planks with per-plank tone variation, subtle grain streaks and
// darkened gap lines. Cheap enough for Quest (no textures, few hash calls).
shader_type spatial;

uniform vec3 base_color: source_color = vec3(0.42, 0.26, 0.14);
uniform float plank_length = 1.6;
uniform float plank_width = 0.14;
uniform float tone_variation: hint_range(0.0, 1.0) = 0.35;
uniform float gap_width: hint_range(0.001, 0.02) = 0.006;
uniform float roughness_value: hint_range(0.0, 1.0) = 0.55;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	// World-ish UV: the floor plane is 6x5 m, UV covers it once.
	vec2 pos = UV * vec2(6.0, 5.0);

	// Stagger every other row by half a plank length.
	float row = floor(pos.y / plank_width);
	float offset = mod(row, 2.0) * plank_length * 0.5;
	float col = floor((pos.x + offset) / plank_length);
	vec2 plank_id = vec2(col, row);

	// Per-plank tone.
	float tone = hash21(plank_id);
	vec3 col_out = base_color * (1.0 - tone_variation * 0.5 + tone_variation * tone);

	// Grain: fine streaks along the plank.
	float grain = sin(pos.y * 180.0 + tone * 40.0) * 0.5 + 0.5;
	col_out *= 0.96 + 0.04 * grain;
	float streak = hash21(vec2(floor(pos.y * 90.0), col));
	col_out *= 0.97 + 0.05 * streak;

	// Gap lines between planks.
	float gy = abs(fract(pos.y / plank_width) - 0.5) * plank_width;
	float gx = abs(fract((pos.x + offset) / plank_length) - 0.5) * plank_length;
	float gap = min(plank_width * 0.5 - gy, plank_length * 0.5 - gx);
	float dark = smoothstep(0.0, gap_width, gap);
	col_out *= mix(0.55, 1.0, dark);

	ALBEDO = col_out;
	ROUGHNESS = roughness_value + 0.15 * (1.0 - dark);
	METALLIC = 0.0;
}
