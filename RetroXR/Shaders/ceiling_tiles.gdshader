shader_type spatial;

// Drop ceiling tile grid — off-white tiles with dark aluminum grid lines
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 tile_color : source_color = vec3(0.88, 0.86, 0.82);
uniform vec3 grid_color : source_color = vec3(0.25, 0.25, 0.25);
uniform float tile_scale : hint_range(0.5, 10.0) = 5.0;
uniform float grid_width : hint_range(0.005, 0.05) = 0.02;

void fragment() {
	vec2 uv = UV * tile_scale;
	vec2 cell = fract(uv);

	// Grid lines along edges
	float grid = step(cell.x, grid_width) + step(1.0 - grid_width, cell.x);
	grid += step(cell.y, grid_width) + step(1.0 - grid_width, cell.y);
	grid = clamp(grid, 0.0, 1.0);

	ALBEDO = mix(tile_color, grid_color, grid);
	ROUGHNESS = mix(0.9, 0.5, grid);
	METALLIC = mix(0.0, 0.4, grid);
}
