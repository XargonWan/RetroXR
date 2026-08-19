shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform float progress : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float segment = step(0.14, fract(UV.x * 18.0));
	float inside = step(0.06, UV.y) * step(UV.y, 0.94);
	float filled = step(UV.x, progress);
	float pulse = 0.88 + 0.12 * sin(TIME * 4.0 - UV.x * 9.0);
	vec3 track = vec3(0.075, 0.085, 0.17);
	vec3 active = mix(vec3(0.28, 0.55, 1.0), vec3(0.20, 1.0, 0.70), UV.x) * pulse;
	vec3 color = mix(track, active, filled * segment * inside);
	ALBEDO = color;
}
