// Screen-window material — shows one rectangular region of a composite
// framebuffer on a full quad. Used wherever a core renders several screens
// into ONE texture and a surface should show just one of them:
//   * a dual-screen handheld's own top/bottom LCDs (DS / 3DS), and
//   * a TV connected to one of that handheld's TOP/BOTTOM video-out cables.
//
// `source_rect` is the UV window (x, y, w, h) into `source_tex`. For
// stereoscopic side-by-side sources (patched azahar: left half = left eye,
// right half = right eye) `eye_shift` moves the sample window right for the
// RIGHT eye — the same VIEW_INDEX trick as vb_stereo.gdshader, so the quad
// shows real per-eye depth in the headset and the left eye's image flat on
// desktop.
//
// A connected RetroTV chains its tube look through here exactly like it does
// with the VCR's tape shader: it flips `crt_enabled` and feeds the shared
// crt_filter uniforms + the OSD texture, instead of wrapping the material.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

#include "res://Shaders/crt_filter.gdshaderinc"

uniform sampler2D source_tex : source_color, filter_nearest, repeat_disable;
uniform vec4 source_rect = vec4(0.0, 0.0, 1.0, 1.0);
// Added to the sample x for the RIGHT eye (0 = mono source).
uniform float eye_shift = 0.0;

// Chained CRT display stage (set by a connected RetroTV when its CRT is on).
uniform bool crt_enabled = false;

// On-screen display from the connected TV, composited before the CRT stage.
uniform sampler2D osd_tex : source_color, filter_linear, repeat_disable;
uniform bool osd_enabled = false;

void fragment() {
	vec2 wuv = crt_enabled ? crt_warp(UV) : UV;
	vec2 suv = source_rect.xy + wuv * source_rect.zw;
	if (VIEW_INDEX == VIEW_RIGHT) {
		suv.x += eye_shift;
	}
	vec3 col = texture(source_tex, suv).rgb;
	if (osd_enabled) {
		vec4 osd = texture(osd_tex, wuv);
		col = mix(col, osd.rgb, osd.a);
	}
	if (crt_enabled) {
		col = crt_apply(col, wuv, FRAGCOORD.xy);
		ALPHA = crt_border(wuv);
	}
	ALBEDO = clamp(col, 0.0, 1.0);
}
