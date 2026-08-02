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
//   sag     — droop where the block overhangs unsupported at the fore edge. The
//             WHOLE block moves with this, since it sags as one lump. Must stay
//             independent of v (see below).
//   lift    — the top sheet leaving the block behind: bowing up off the stack,
//             and its leading edges curling. The block does NOT follow. Both
//             terms are non-negative, which is what makes it impossible for the
//             block to surface through the sheet.
//
// u = 0 at the gutter, 1 at the fore edge. v = 0 bottom, 1 top.

void paper_rest_parts(float u, float v,
		float p_gutter_dive, float p_gutter_falloff,
		float p_bow_amount, float p_fore_droop, float p_edge_curl,
		out float gutter, out float sag, out float lift) {
	float edge = abs(2.0 * v - 1.0);
	float t = clamp((u - 0.55) / 0.45, 0.0, 1.0);
	gutter = -p_gutter_dive * exp(-u * p_gutter_falloff);
	// Followed by the block, so it must not vary with v: the block's top face is
	// a plain BoxMesh quad whose only vertices are the four corners, all at
	// v = 0 or 1. Anything shaped along v gets interpolated straight across the
	// middle instead of following the sheet, which is how edge_curl used to lift
	// the block ~2mm above the page along its horizontal centreline.
	sag = -p_fore_droop * (t * t * (3.0 - 2.0 * t));
	// NOT followed by the block: the sheet leaving it behind. Both terms are
	// non-negative, which is what guarantees the block can never surface
	// through the page rather than merely being tuned not to.
	lift = p_bow_amount * sin(u * PAPER_PI) + p_edge_curl * edge * edge * edge * u;
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
