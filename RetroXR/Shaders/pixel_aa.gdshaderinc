// Pixel-area ("pixel-AA") sampling for emulator pictures.
//
// A core frame is a small fixed grid — 240x160 on a GBA — shown on a surface in a
// 3D scene, so the ratio of screen pixels to source texels is some arbitrary
// non-integer number that changes with distance and angle. Neither hardware filter
// handles that well:
//
//   filter_linear   blends every texel with its neighbours at every ratio. Uniformly
//                   soft, which is how the GBA screen ended up looking blurry.
//   filter_nearest  is crisp only at INTEGER scale. Below 1:1 it DROPS source rows
//                   and columns outright (at 0.94x about 6% of them — glyph columns
//                   vanish, "SCORE" reads "SCOOR_"), and above 1:1 it makes texels
//                   unevenly sized. Either way the pattern crawls as the head moves.
//
// This samples the texel GRID instead: inside a texel the result is that texel's
// exact colour, and across a texel boundary it ramps over a distance of one screen
// pixel. Sharp edges, no dropped source pixels, nothing that crawls — the standard
// pixel-art AA trick, and the reason it is cheap is that the ramp is done by the
// hardware's own bilinear unit.
//
// The sampler MUST therefore be declared `filter_linear` (not nearest): this
// function positions the sample point so that bilinear only ever interpolates
// within one screen pixel of a texel edge.
//
// Beyond about 2x MINIFICATION a single tap can no longer represent what is under
// it and this degrades toward aliasing like anything else without mipmaps; RetroXR
// screens live near 1:1 (see Scripts/XR/xr_init.gd for the measured budgets), which is
// the range this is for.

// Sample position for `uv`, snapped to the texel grid with a one-screen-pixel ramp.
vec2 pixel_aa_uv(sampler2D tex, vec2 uv) {
	vec2 tsize = vec2(textureSize(tex, 0));
	vec2 tuv = uv * tsize;                       // uv in texels
	// fwidth = how many texels this screen pixel covers. >1 minifying, <1 magnifying.
	vec2 fw = max(fwidth(tuv), vec2(1e-5));
	// Distance from the texel centre, remapped so the transition is exactly one
	// screen pixel wide and clamped to the texel's own half-width: magnifying hard
	// (fw << 1) clamps to +/-0.5 and lands on texel centres, i.e. crisp like nearest.
	vec2 ramp = clamp((fract(tuv) - 0.5) / fw, -0.5, 0.5);
	return (floor(tuv) + 0.5 + ramp) / tsize;
}

vec4 pixel_aa(sampler2D tex, vec2 uv) {
	return texture(tex, pixel_aa_uv(tex, uv));
}
