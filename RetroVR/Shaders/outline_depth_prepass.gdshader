// Depth-only prepass — renders the mesh shape invisible but writes to the depth buffer.
// This is pass 1 of the fake-stencil outline technique.
// The outline shader (pass 2, set as next_pass) depth-tests against this,
// so back-face silhouette fragments outside the object's 2D footprint always
// pass while interior back faces (behind this depth mask) are hidden.
shader_type spatial;
render_mode cull_back, depth_draw_always, blend_mix;

void fragment() {
	// Fully transparent — no color written to screen.
	// depth_draw_always means depth IS still written regardless of alpha.
	ALPHA = 0.0;
}
