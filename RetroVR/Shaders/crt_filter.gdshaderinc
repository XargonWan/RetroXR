// Shared CRT display filter for RetroVR TV screens.
//
// The tube look (aperture/slot mask, scanlines, grain, YIQ smear, VHS wiggle) is
// PORTED from the Flowerwall CRT shader by Art (art-oria), MIT licensed:
//   https://github.com/art-oria/Flowerwall-CRT-shader-for-Godot
// Flowerwall is a fullscreen `canvas_item` post-process; here its algorithm is
// re-expressed as the *display stage* of a `spatial` material so it applies to
// the one 3D TV tube (sampling the game/tape picture) instead of the whole VR
// framebuffer, and composites with RetroVR's OSD + rounded-glass bezel.
//
// Included by crt_effect.gdshader (wraps any picture source) and by
// vcr_effect.gdshader (chained after the VHS pass). Public interface kept stable
// for both: crt_warp(uv) → tube UV, crt_border(wuv) → glass-edge alpha,
// crt_apply(col, wuv, fragcoord) → mask/scanlines/grain/vignette. crt_effect
// additionally uses crt_smear_sample() at sample time.
//
// The mask + scanlines key off FRAGCOORD (render pixels) exactly like the
// original aperture grille — so zooming into a tube resolves the RGB triads.

// ── Geometry ────────────────────────────────────────────────────────────────
uniform float crt_curvature : hint_range(0.0, 0.3) = 0.07;
uniform float crt_corner_radius : hint_range(0.001, 0.2) = 0.04;

// ── Aperture / slot mask (Flowerwall grid/slot) ─────────────────────────────
// 0 = off, 1 = grid (straight RGB stripes), 2 = slot (staggered per row block).
uniform int crt_mask_mode : hint_range(0, 2) = 2;
uniform float crt_mask_strength : hint_range(0.0, 1.0) = 0.45;
uniform float crt_pixel_size : hint_range(2.0, 8.0) = 3.0;

// ── Scanlines ───────────────────────────────────────────────────────────────
uniform float crt_scanline_strength : hint_range(0.0, 1.0) = 0.35;
uniform float crt_scanline_thickness : hint_range(0.0, 8.0) = 1.0;
uniform float crt_scanline_interval : hint_range(1.0, 20.0) = 3.0;

// ── Grain / analog artefacts ────────────────────────────────────────────────
uniform float crt_grain : hint_range(0.0, 1.0) = 0.06;
uniform float crt_smear : hint_range(0.0, 1.0) = 0.0;
uniform float crt_wiggle : hint_range(0.0, 0.2) = 0.0;

// ── Tube light ──────────────────────────────────────────────────────────────
uniform float crt_vignette : hint_range(0.0, 1.0) = 0.18;
uniform float crt_brightness : hint_range(0.5, 2.0) = 1.25;


float crt_hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec3 rgb2yiq(vec3 c) {
	return vec3(
		0.2989 * c.r + 0.5959 * c.g + 0.2115 * c.b,
		0.5870 * c.r - 0.2744 * c.g - 0.5229 * c.b,
		0.1140 * c.r - 0.3216 * c.g + 0.3114 * c.b);
}

vec3 yiq2rgb(vec3 c) {
	return vec3(
		c.x + c.y + c.z,
		0.956 * c.x - 0.2720 * c.y - 1.1060 * c.z,
		0.6210 * c.x - 0.6474 * c.y + 1.7046 * c.z);
}

// Quad UV → tube UV: optional VHS wiggle, then barrel curvature. Coordinates
// leave [0,1] near the border (blanked by crt_border()).
vec2 crt_warp(vec2 uv) {
	if (crt_wiggle > 0.0) {
		uv.x += (crt_hash(vec2(uv.y * 8.0, floor(TIME * 30.0))) - 0.5) * crt_wiggle * 0.15;
	}
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

// Optional NTSC-style chroma smear: keep luma sharp, bleed I/Q from taps to the
// right. Called at sample time by crt_effect (the VCR path has its own smear).
vec3 crt_smear_sample(sampler2D tex, vec2 uv) {
	vec3 c0 = texture(tex, uv).rgb;
	if (crt_smear <= 0.0) {
		return c0;
	}
	float d = crt_smear * 0.012;
	vec3 y0 = rgb2yiq(c0);
	vec3 yi = rgb2yiq(texture(tex, uv + vec2(d, 0.0)).rgb);
	vec3 yq = rgb2yiq(texture(tex, uv + vec2(d * 2.2, 0.0)).rgb);
	return yiq2rgb(vec3(y0.x, yi.y, yq.z));
}

// Display stage: RGB aperture/slot mask + scanlines + grain + vignette, keyed to
// render pixels (fc = FRAGCOORD.xy) so the triads are physical like real glass.
vec3 crt_apply(vec3 col, vec2 wuv, vec2 fc) {
	// Film grain.
	if (crt_grain > 0.0) {
		float g = crt_hash(wuv * vec2(320.0, 240.0) + fract(TIME) * 60.0) - 0.5;
		col += g * crt_grain;
	}

	int ps = int(max(2.0, crt_pixel_size));
	int cellw = max(1, ps / 3);   // width in px of each R/G/B sub-stripe

	// Aperture (grid) or slot mask.
	if (crt_mask_mode > 0) {
		int phase = int(fc.x) / cellw;
		if (crt_mask_mode == 2) {
			// Slot: shift the triad phase every row block so cells stagger.
			int block = int(fc.y) / ps;
			phase += block;
		}
		int idx = phase % 3;
		vec3 m = vec3(1.0 - crt_mask_strength);
		if (idx == 0) {
			m.r = 1.0;
		} else if (idx == 1) {
			m.g = 1.0;
		} else {
			m.b = 1.0;
		}
		col *= m;
	}

	// Scanlines: dark lines `thickness` px tall every `period` px. When a mask is
	// on the period follows the mask cell; otherwise the standalone interval.
	if (crt_scanline_strength > 0.0) {
		float period = (crt_mask_mode == 0) ? crt_scanline_interval : float(ps);
		float sl = mod(fc.y, period);
		float dark = 1.0 - step(crt_scanline_thickness, sl);
		col *= 1.0 - crt_scanline_strength * dark;
	}

	// Tube-corner light falloff.
	vec2 vc = wuv - 0.5;
	col *= 1.0 - dot(vc, vc) * crt_vignette * 2.0;

	// Compensate the darkening from scanlines + mask.
	return col * crt_brightness;
}
