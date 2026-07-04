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

void fragment() {
	vec2 wuv = crt_warp(UV);
	vec3 col = texture(source_tex, wuv).rgb;
	col = crt_apply(col, wuv, FRAGCOORD.x);
	col *= crt_border(wuv);
	ALBEDO = clamp(col, 0.0, 1.0);
}
