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

void fragment() {
	vec2 wuv = crt_warp(UV);
	vec3 col = texture(source_tex, wuv).rgb;
	if (osd_enabled) {
		vec4 osd = texture(osd_tex, wuv);
		col = mix(col, osd.rgb, osd.a);
	}
	col = crt_apply(col, wuv, FRAGCOORD.x);
	ALBEDO = clamp(col, 0.0, 1.0);
	// Beyond the curved glass edge the quad is transparent (not black), so the
	// TV bezel shows through instead of a dark rectangle.
	ALPHA = crt_border(wuv);
}
