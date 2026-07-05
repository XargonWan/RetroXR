// VCR / VHS screen effect for the RetroVR video player.
// Applied as a ShaderMaterial on the TV screen mesh; samples the live video
// texture produced by an FFmpegVideoStream and adds the classic tape look:
// chromatic aberration, scanlines, tape grain, a scrolling tracking band,
// horizontal wobble, color washout and a vignette.
//
// render_mode unshaded so the picture reads as a self-lit screen regardless of
// room lighting (matches how the plain StandardMaterial3D path used emission).
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

#include "res://Shaders/crt_filter.gdshaderinc"

uniform sampler2D video_tex : source_color, filter_linear, repeat_disable;

// Chained CRT display stage (set by the connected RetroTV when its CRT filter
// is on): tape signal (VHS effects above) → tube (curvature/scanlines/mask).
uniform bool crt_enabled = false;

// On-screen display (green corner text) from the connected TV, composited
// clean over the tape picture (the OSD is generated after tape decode, so it
// doesn't get tape noise) but before the CRT stage (so it curves with the tube).
uniform sampler2D osd_tex : source_color, filter_linear, repeat_disable;
uniform bool osd_enabled = false;

// Master switch (0 = pass the picture through untouched, 1 = full effect).
uniform float effect_amount : hint_range(0.0, 1.0) = 1.0;

uniform float aberration : hint_range(0.0, 0.01) = 0.0025;
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.22;
uniform float scanline_count = 240.0;
uniform float noise_strength : hint_range(0.0, 1.0) = 0.10;
uniform float wobble_strength : hint_range(0.0, 0.02) = 0.0016;
uniform float tracking_speed = 0.18;
uniform float tracking_strength : hint_range(0.0, 0.1) = 0.02;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.30;
uniform float desaturation : hint_range(0.0, 1.0) = 0.15;
uniform float brightness = 1.12;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	if (crt_enabled) {
		// Curve into tube coordinates first: the VHS signal distortions below
		// then happen "on the tube", and the border/scanlines stay fixed to it.
		uv = crt_warp(uv);
	}
	vec2 crt_uv = uv;
	float amt = effect_amount;

	// Scrolling tracking band — a distorted stripe that crawls up the screen,
	// plus a mirrored one near the bottom edge.
	float band = fract(uv.y + TIME * tracking_speed);
	float track = (smoothstep(0.965, 1.0, band) + smoothstep(0.035, 0.0, band)) * amt;

	// Horizontal wobble: a slow sine plus per-scanline jitter, amplified inside
	// the tracking band.
	float line_jitter = hash(vec2(floor(uv.y * scanline_count), floor(TIME * 24.0))) - 0.5;
	float wob = sin(uv.y * 60.0 + TIME * 5.0) * wobble_strength;
	uv.x += (wob + line_jitter * tracking_strength * track) * amt;

	// Chromatic aberration — split the colour channels horizontally, stronger in
	// the tracking band.
	float ab = aberration * amt * (1.0 + track * 4.0);
	float r = texture(video_tex, uv + vec2(ab, 0.0)).r;
	float g = texture(video_tex, uv).g;
	float b = texture(video_tex, uv - vec2(ab, 0.0)).b;
	vec3 col = vec3(r, g, b);

	// Slight colour washout.
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(luma), desaturation * amt);

	// Scanlines.
	float scan = sin(uv.y * scanline_count * 3.14159) * 0.5 + 0.5;
	col *= 1.0 - scanline_strength * scan * amt;

	// Tape grain.
	float n = hash(uv * vec2(320.0, 240.0) + fract(TIME) * 60.0);
	col += (n - 0.5) * noise_strength * amt;

	// Bright static crackle inside the tracking band.
	col += track * (hash(uv + fract(TIME)) - 0.3) * 0.5;

	// Vignette.
	vec2 vc = uv - 0.5;
	col *= 1.0 - dot(vc, vc) * vignette_strength * 2.0 * amt;

	col *= mix(1.0, brightness, amt);

	if (osd_enabled) {
		// Sample in tube space (pre-wobble) so the OSD stays put while the
		// tape picture swims underneath it.
		vec4 osd = texture(osd_tex, crt_uv);
		col = mix(col, osd.rgb, osd.a);
	}

	if (crt_enabled) {
		// Display stage: scanlines/mask/vignette in tube space (pre-wobble so
		// the tube geometry doesn't jitter with the tape). Beyond the curved
		// glass edge the quad goes transparent so the bezel shows through.
		col = crt_apply(col, crt_uv, FRAGCOORD.x);
		ALPHA = crt_border(crt_uv);
	}

	ALBEDO = clamp(col, 0.0, 1.0);
}
