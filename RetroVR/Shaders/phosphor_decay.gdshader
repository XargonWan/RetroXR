// Phosphor persistence accumulator for the RetroTV.
//
// Run by tv.gd as a ping-pong pair of SubViewports at the core's own resolution:
// each frame one viewport renders this over the live frame plus the OTHER
// viewport's contents, and the result becomes the CRT stage's picture source.
// Reading the other viewport naturally yields last frame's image, which is exactly
// what `prev` should be.
//
// max() rather than mix() because a phosphor doesn't dim a fresh excitation — the
// beam relights it to full and the decay only shows where nothing new was drawn.
//
// Deliberately NOT source_color on either sampler. This is a passthrough stage, so
// it stores values in whatever encoding the core handed us; the CRT shader that
// samples the result declares source_color and decodes exactly as it would have
// decoded the core texture directly. With decay at 0 the output is bit-identical
// to the input, which is the invariant the gamma probe checks.
shader_type canvas_item;

uniform sampler2D src : filter_nearest, repeat_disable;
uniform sampler2D prev : filter_nearest, repeat_disable;

// Per-frame survival fraction, per channel. Red decays slowest — Y2O2S:Eu has a
// ~1 ms tail — and blue fastest, which is why a CRT's afterglow goes warm as it
// fades. Set from tv.gd's crt_persistence.
uniform vec3 decay = vec3(0.30, 0.26, 0.21);

void fragment() {
	vec3 c = texture(src, UV).rgb;
	vec3 p = texture(prev, UV).rgb * decay;
	COLOR = vec4(max(c, p), 1.0);
}
