// Rest shape of a sheet of paper lying on its stack, and of the stack itself.
//
// Shared by paper.gdshader (the sheet) and page_edge.gdshader (the block under
// it) so the two cannot disagree. They did, twice: the block's flat top face
// showed through the sheet beside the spine, then again at the fore edge where
// the sheet droops and the block did not.
//
// Split into three parts because the block follows only some of them:
//
//   gutter  — the sheet dives into the binding. The block THINS here: its top
//             follows, its underside does not, because the leaves converge on
//             the spine.
//   sag     — droop at the unsupported fore edge, plus the top and bottom edges
//             curling up. The WHOLE block moves with this, since the block sags
//             as one lump.
//   bow     — the top sheet lifting clear of the stack. The block does NOT
//             follow; this is the sheet leaving it behind.
//
// u = 0 at the gutter, 1 at the fore edge. v = 0 bottom, 1 top.

void paper_rest_parts(float u, float v,
		float p_gutter_dive, float p_gutter_falloff,
		float p_bow_amount, float p_fore_droop, float p_edge_curl,
		out float gutter, out float sag, out float bow) {
	float edge = abs(2.0 * v - 1.0);
	float t = clamp((u - 0.55) / 0.45, 0.0, 1.0);
	gutter = -p_gutter_dive * exp(-u * p_gutter_falloff);
	sag = -p_fore_droop * (t * t * (3.0 - 2.0 * t)) + p_edge_curl * edge * edge * edge * u;
	bow = p_bow_amount * sin(u * PAPER_PI);
}

// Slope of the full rest shape, for building the sheet's normal without
// finite differences.
void paper_rest_slope(float u, float v,
		float p_gutter_dive, float p_gutter_falloff,
		float p_bow_amount, float p_fore_droop, float p_edge_curl,
		out float dzdu, out float dzdv) {
	float e = 2.0 * v - 1.0;
	float edge = abs(e);
	float t = clamp((u - 0.55) / 0.45, 0.0, 1.0);
	float droop_d = (u > 0.55 && u < 1.0) ? 6.0 * t * (1.0 - t) / 0.45 : 0.0;
	dzdu = p_gutter_dive * p_gutter_falloff * exp(-u * p_gutter_falloff)
		+ p_bow_amount * PAPER_PI * cos(u * PAPER_PI)
		- p_fore_droop * droop_d
		+ p_edge_curl * edge * edge * edge;
	dzdv = p_edge_curl * 6.0 * edge * edge * sign(e) * u;
}
