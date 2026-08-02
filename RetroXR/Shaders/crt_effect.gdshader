// CRT display filter for RetroXR TV screens.
// Applied by RetroTV as a wrapper over whatever picture source is showing —
// the libretro game texture or the VCR video (when the VHS effect is off).
// The VHS-enabled VCR path instead chains the same filter inside
// vcr_effect.gdshader (see crt_filter.gdshaderinc).
//
// render_mode unshaded so the picture reads as a self-lit screen.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

#include "res://Shaders/crt_filter.gdshaderinc"
#include "res://Shaders/pixel_aa.gdshaderinc"

// filter_linear is REQUIRED by pixel_aa (it does the sub-pixel ramp).
//
// This used to sample with plain bilinear on the theory that the CRT stage masks
// the softness anyway, and that pixel-grid snapping would make the VCR's magnified
// video blocky. Neither holds: it left this as the only core-picture path in the
// project that wasn't pixel-AA sampled (and the softest), and at the ~1:1 ratio a
// 640x480 video hits on a 0.35 m tube pixel_aa is within a hair of bilinear, so the
// video concern never bites in practice.
uniform sampler2D source_tex : source_color, filter_linear, repeat_disable;

// On-screen display (green corner text) rendered by the TV into a transparent
// SubViewport texture and composited into the picture BEFORE the CRT stage,
// so the OSD is curved/scanlined like everything else on the tube.
uniform sampler2D osd_tex : source_color, filter_linear, repeat_disable;
uniform bool osd_enabled = false;

// NOTE: stereo side-by-side sources (Virtual Boy) are no longer split here —
// RetroTV wraps them with screen_window.gdshader instead (which chains this
// CRT stage inside it), so the per-eye split works with the CRT off too.

void fragment() {
	vec2 wuv = crt_warp(UV);
	vec2 suv = pixel_aa_uv(source_tex, wuv);

	vec3 col = crt_smear_sample(source_tex, suv);
	col = crt_notch_sample(source_tex, suv, col);
	vec3 glow = crt_glow(source_tex, wuv);

	if (osd_enabled) {
		vec4 osd = texture(osd_tex, wuv);
		col = mix(col, osd.rgb, osd.a);
	}

	ALBEDO = clamp(crt_apply_full(col, glow, wuv), 0.0, 1.0);
	// Beyond the curved glass edge the quad is transparent (not black), so the
	// TV bezel shows through instead of a dark rectangle.
	ALPHA = crt_border(wuv);
}
