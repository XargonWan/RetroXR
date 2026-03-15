// Stencil-write pass — renders the mesh shape invisible but writes stencil=1.
// This is pass 1 of the stencil-based outline technique.
// The outline shader (pass 2, set as next_pass) only renders where stencil != 1,
// i.e. outside the original mesh silhouette, producing a clean ring outline.
shader_type spatial;
render_mode cull_back, depth_draw_always, unshaded, blend_mix;
stencil_mode write, compare_always, 1;

void fragment() {
	// Fully transparent — no color written to screen.
	// Stencil value 1 is written for every pixel the mesh covers.
	ALPHA = 0.0;
}
