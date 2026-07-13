// CRT display filter for RetroVR TV screens.
// Applied by RetroTV as a wrapper over whatever picture source is showing —
// the libretro game texture or the VCR video (when the VHS effect is off).
// The VHS-enabled VCR path instead chains the same filter inside
// vcr_effect.gdshader (see crt_filter.gdshaderinc).
//
// render_mode unshaded so the picture reads as a self-lit screen.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

#include "res://Shaders/crt_filter.gdshaderinc"

uniform sampler2D source_tex : source_color, filter_linear, repeat_disable;

// On-screen display (green corner text) rendered by the TV into a transparent
// SubViewport texture and composited into the picture BEFORE the CRT stage,
// so the OSD is curved/scanlined like everything else on the tube.
uniform sampler2D osd_tex : source_color, filter_linear, repeat_disable;
uniform bool osd_enabled = false;

// Virtual Boy: the core outputs a side-by-side frame (left eye | right eye).
// When set, each eye samples ITS half so a TV shows real per-eye stereo instead
// of the squished side-by-side image (VIEW_INDEX is mono-left on desktop, so a
// flat screen shows the left eye).
uniform bool stereo_sbs = false;

void fragment() {
	vec2 wuv = crt_warp(UV);
	vec2 suv = wuv;
	if (stereo_sbs) {
		suv.x = wuv.x * 0.5 + (VIEW_INDEX == VIEW_RIGHT ? 0.5 : 0.0);
	}
	vec3 col = crt_smear_sample(source_tex, suv);
	if (osd_enabled) {
		vec4 osd = texture(osd_tex, wuv);
		col = mix(col, osd.rgb, osd.a);
	}
	col = crt_apply(col, wuv, FRAGCOORD.xy);
	ALBEDO = clamp(col, 0.0, 1.0);
	// Beyond the curved glass edge the quad is transparent (not black), so the
	// TV bezel shows through instead of a dark rectangle.
	ALPHA = crt_border(wuv);
}
