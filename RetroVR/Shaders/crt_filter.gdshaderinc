// Shared CRT display filter for RetroVR TV screens.
//
// Included by crt_effect.gdshader (standalone, wraps any texture source — the
// libretro game picture or the VCR with the VHS effect off) and by
// vcr_effect.gdshader (chained after the VHS pass so tape + tube compose).
//
// Model: the *display* stage of the pipeline. crt_warp() maps quad UV to tube
// coordinates (barrel curvature) BEFORE the signal is sampled; crt_apply()
// adds scanlines, an RGB aperture mask and vignette; crt_border() blanks the
// rounded-glass edge. Everything is branchless-cheap and Quest-friendly.

uniform float crt_curvature : hint_range(0.0, 0.3) = 0.07;
uniform float crt_scanline_strength : hint_range(0.0, 1.0) = 0.30;
uniform float crt_scanline_count = 240.0;
uniform float crt_mask_strength : hint_range(0.0, 1.0) = 0.15;
uniform float crt_corner_radius : hint_range(0.001, 0.2) = 0.04;
uniform float crt_vignette : hint_range(0.0, 1.0) = 0.18;
uniform float crt_brightness = 1.25;

// Quad UV → tube UV. Pushes edges outward so the picture bulges like glass;
// coordinates leave [0,1] near the border (blanked by crt_border()).
vec2 crt_warp(vec2 uv) {
	vec2 cc = uv * 2.0 - 1.0;
	cc *= 1.0 + crt_curvature * dot(cc, cc);
	return cc * 0.5 + 0.5;
}

// 1.0 inside the rounded screen glass, fading to 0.0 outside.
float crt_border(vec2 wuv) {
	vec2 b = abs(wuv - 0.5) - (vec2(0.5) - vec2(crt_corner_radius));
	float d = length(max(b, vec2(0.0))) - crt_corner_radius;
	return 1.0 - smoothstep(-0.006, 0.0, d);
}

// Scanlines + aperture-grille mask + vignette + brightness compensation.
// wuv must be tube coordinates (post-warp, pre-wobble); frag_x = FRAGCOORD.x.
vec3 crt_apply(vec3 col, vec2 wuv, float frag_x) {
	// Fixed tube scanlines.
	float scan = 0.5 + 0.5 * cos(wuv.y * crt_scanline_count * 6.28318);
	col *= 1.0 - crt_scanline_strength * scan;

	// RGB aperture grille: each render-pixel column favours one channel.
	float ph = mod(frag_x, 3.0);
	vec3 mask = vec3(1.0 - crt_mask_strength);
	if (ph < 1.0) {
		mask.r = 1.0;
	} else if (ph < 2.0) {
		mask.g = 1.0;
	} else {
		mask.b = 1.0;
	}
	col *= mask;

	// Tube-corner light falloff.
	vec2 vc = wuv - 0.5;
	col *= 1.0 - dot(vc, vc) * crt_vignette * 2.0;

	// Compensate the darkening from scanlines + mask.
	return col * crt_brightness;
}
