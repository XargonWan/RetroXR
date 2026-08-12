// One optical disc: CD, DVD, PS1, PS2. Both faces, one surface, one draw call.
//
// Reads what Tools/gen_disc.gd bakes:
//   UV     planar over the disc's bounding square, so the scraped 600x600 label
//          art maps 1:1. That art is authored full-bleed to the rim WITH its own
//          transparent centre hole, correctly sized per system, so it is blended
//          straight on rather than fitted — and no synthetic print ring is
//          imposed, which would fight the alpha the art already carries.
//   UV2.x  face class: 1.0 label / 0.0 data / 0.5 rim and bore.
// The radius is derived here from length(VERTEX.xz) rather than baked: exact,
// one vertex instruction, and immune to attribute compression and node scale.
//
// OPAQUE, deliberately. The art composites into ALBEDO, so unlike the transparent
// quad this replaces it sorts correctly, writes depth, cannot z-fight the face
// below it, and takes the pickable outline. Never write ALPHA here.
//
// The rainbow is an ANALYTIC diffraction grating, not an environment reflection.
// It has to be: every room runs ambient_light_source = COLOR with no radiance map,
// one ReflectionProbe in one scene, no SDFGI and no SSR. There is nothing to
// reflect. Tools/plug_materials.gd already documents this as the reason the house
// metal standard is metallic 0.80 rather than 1.0 — which applies here too, since
// the ambient term is computed outside light() from ALBEDO/METALLIC/ROUGHNESS.
//
// A custom light() is what makes it correct rather than faked: Godot exposes no
// light data in fragment(), and the grating needs both the light and view vectors.
// Verified supported on the Mobile renderer the Quest build uses — forward_mobile
// includes the same scene_forward_lights_inc.glsl that honours LIGHT_CODE_USED.
// Two consequences worth knowing:
//   * defining light() compiles OUT the whole built-in BRDF, including the
//     clearcoat lobe. The lacquer coat below is hand-written for that reason, and
//     CLEARCOAT is deliberately never written.
//   * the docs claim light() is skipped on mobile because Force Vertex Shading is
//     on by default there. That is a Godot 3 carryover; in 4.7 the setting
//     defaults false and this project does not set it. Do not "fix" this.
//
// Because the grating is rotationally symmetric the pattern does NOT rotate when
// system.gd spins a seated disc — which is what a real spinning disc looks like.
shader_type spatial;
render_mode cull_back;

// --- surface ---------------------------------------------------------------
// The data side's reflective layer, seen through the substrate. PS1 is near-black
// (black-dyed polycarbonate), PS2 CD-ROM blue, a DVD silver-violet, a CD silver.
uniform vec3 data_color : source_color = vec3(0.78, 0.80, 0.84);
// Bare polycarbonate: the bore, the outer rim, the edge, and the wide clear
// annulus inside the metal. This is what carries a PS1 disc's black edge.
uniform vec3 poly_color : source_color = vec3(0.09, 0.10, 0.12);
// The unprinted label side — lacquer over the aluminium.
uniform vec3 lacquer_color : source_color = vec3(0.80, 0.81, 0.84);
// How much of the label side shows through the clear annulus when you look at the
// disc's underside. A real CD's hub is a window; a PS1's dyed substrate is not,
// which is why this is per-system rather than a constant.
uniform float poly_show_through : hint_range(0.0, 1.0) = 0.24;

// Zone radii in metres. Red Book, and the first pass had this wrong: the metal
// does not start at the clamping ring. From the bore outwards a CD is clear
// polycarbonate all the way to 22 mm, then ~1 mm of unrecorded mirror band, then
// the information area, then a clear rim. The wide transparent hub annulus is one
// of the most recognisable things about a disc's underside.
// Defaults are a 120 mm CD; disc.gd overrides them for the 80 mm mini-disc.
uniform float r_metal_start = 0.0220;   // clear polycarbonate ends, aluminium starts
uniform float r_data_start = 0.0230;    // mirror band ends, pits start
uniform float r_data_end = 0.0580;      // pits end, clear outer rim starts

// --- label -----------------------------------------------------------------
// hint_default_transparent matters: an unassigned sampler2D otherwise returns
// opaque white and would paint the whole label side blank.
uniform sampler2D label_tex : source_color, hint_default_transparent,
	filter_linear_mipmap_anisotropic, repeat_disable;

// --- diffraction -----------------------------------------------------------
// Track pitch in MICROMETRES, and it does real work. At 1.6 (CD) four diffraction
// orders land in the visible band, giving the repeating spectral bands a CD
// shows; at 0.74 (DVD) one does, giving the single broad sweep a DVD shows. The
// difference between a PS1 disc and a Wii disc is this one number.
uniform float track_pitch = 1.6;
uniform float irid_strength : hint_range(0.0, 4.0) = 0.5;
// The label side's unprinted lacquer shows a much fainter rainbow of its own.
uniform float irid_label : hint_range(0.0, 1.0) = 0.10;
// A view-only floor. A DVD's single order needs |L.g + V.g| >= 0.51 before any
// colour appears at all, so held flat under a ceiling light it would otherwise be
// a plain mirror. Small enough not to glow inside a shut console tray.
uniform float irid_ambient : hint_range(0.0, 1.0) = 0.10;
// Widens the spectral response, standing in for a light that is not a point.
// Narrow reads as a laser; too wide washes to white.
uniform float spectral_width : hint_range(0.5, 3.0) = 1.0;
// Extra band widening from the screen-space derivative. This is a STEREO fix as
// much as an aliasing one: with openxr/multiview each eye computes its own view
// vector, so tight bands land in different places per eye and produce genuine
// binocular rivalry. Tune it in the headset, not on a monitor.
uniform float band_aa : hint_range(0.0, 4.0) = 1.5;

// --- lighting --------------------------------------------------------------
uniform float disc_specular : hint_range(0.0, 1.0) = 0.6;
uniform float light_gain : hint_range(0.0, 4.0) = 1.0;
uniform float spec_gain : hint_range(0.0, 4.0) = 0.7;
uniform float varnish : hint_range(0.0, 2.0) = 0.35;

varying vec3 v_radial;    // view-space radial = the grating vector
varying float v_radius;   // model-space distance from the spindle, in metres
varying vec3 v_irid;      // iridescence mask x substrate tint, read in light()
varying float v_blur;     // spectral widening from the derivative, ditto


void vertex() {
	v_radius = length(VERTEX.xz);
	// Never degenerate: there is a 15 mm hole where the singularity would be.
	v_radial = normalize((MODELVIEW_MATRIX * vec4(VERTEX.x, 0.0, VERTEX.z, 0.0)).xyz);
}


// A quartic bump standing in for a gaussian. Deliberately not exp(): four orders
// times three lobes is twelve transcendentals per light per pixel, and this is a
// Quest target. Reaches exactly zero at |x - mu| = hw, which also removes the
// need for a separate visible-band window.
float bump(float x, float mu, float hw) {
	float t = (x - mu) / hw;
	float k = max(0.0, 1.0 - t * t);
	return k * k;
}


// Wavelength in MICROMETRES to linear RGB. Three lobes, plus a second red term for
// the violet end of the spectrum — without it short wavelengths come out blue
// instead of purple, which is the giveaway of a cheap rainbow.
vec3 spectral(float w, float blur) {
	float k = spectral_width;
	return vec3(
		bump(w, 0.600, 0.105 * k + blur) + 0.30 * bump(w, 0.425, 0.055 * k + blur),
		bump(w, 0.540, 0.110 * k + blur),
		bump(w, 0.455, 0.095 * k + blur)
	);
}


// Reflective diffraction off concentric tracks.
//
//   lambda_m = pitch * |L.g + V.g| / m
//
// g is the radial direction because the tracks are circles, so the grating lines
// run azimuthally. The absolute value is not cosmetic: g points outward, so
// without it the sign flips across the disc and only half of it would light up.
//
// The zeroth order falls out for free — at the mirror direction L and V have
// opposite tangential components, the sum goes to zero, and there is no colour.
// That is why the specular streak stays white and the spectrum appears either
// side of it, as on a real disc.
//
// Four orders: |L.g + V.g| reaches ~1.4 at grazing angles, and a CD's third order
// only covers up to 1.41, so stopping at three cuts to black exactly where the
// effect is strongest.
vec3 grating(vec3 L, vec3 V, vec3 g, float blur) {
	float u = abs(dot(L, g) + dot(V, g));
	vec3 acc = vec3(0.0);
	for (int m = 1; m <= 4; m++) {
		float fm = float(m);
		// Higher orders are dimmer and, being compressed in wavelength, blur more.
		acc += spectral(track_pitch * u / fm, blur / fm) / fm;
	}
	// Normalise by sum(1/m) over the four orders, so adding an order changes where
	// colour appears rather than how bright the disc is.
	return acc * (1.0 / 2.0833);
}


void fragment() {
	float face = UV2.x;
	float r = v_radius;

	// The aluminium layer, and the pitted area inside it that actually diffracts.
	float metal = smoothstep(r_metal_start - 0.0004, r_metal_start + 0.0004, r)
		* (1.0 - smoothstep(r_data_end, r_data_end + 0.0010, r));
	float pits = smoothstep(r_data_start - 0.0004, r_data_start + 0.0004, r)
		* (1.0 - smoothstep(r_data_end - 0.0008, r_data_end, r));

	vec3 V = normalize(VIEW);
	vec3 g = normalize(v_radial);
	// Derivatives must be taken here, not in light(): under the per-light loop
	// they sit in non-uniform control flow, which is undefined on real hardware.
	// Clamped: g swings fastest near the bore, and an unbounded blur there washes
	// the inner bands to grey.
	v_blur = min(track_pitch * fwidth(dot(V, g)) * band_aa, 0.12);

	if (face > 0.75) {
		// --- label side ---
		vec4 art = texture(label_tex, UV);
		// A real disc leaves an unprinted rim. The scraped scans crop anywhere
		// from 0.97 to 1.00 of half-width, so trimming here makes every title
		// finish at the same radius and lets the rim read as polycarbonate.
		art.a *= 1.0 - smoothstep(r_data_end, r_data_end + 0.0015, r);
		vec3 base = mix(poly_color, lacquer_color, metal);
		ALBEDO = mix(base, art.rgb, art.a);
		// Matte ink against glossy unprinted lacquer. This one contrast is the
		// single biggest cue that a printed disc is a printed disc.
		METALLIC = mix(0.75 * metal, 0.0, art.a);
		ROUGHNESS = mix(mix(0.09, 0.14, metal), 0.52, art.a);
		v_irid = vec3(pits * irid_label * irid_strength * (1.0 - art.a))
			* sqrt(lacquer_color);
	} else if (face > 0.25) {
		// --- rim and bore: bare substrate ---
		ALBEDO = poly_color;
		METALLIC = 0.0;
		ROUGHNESS = 0.08;
		v_irid = vec3(0.0);
	} else {
		// --- data side ---
		// Inside the metal it is a window: you see the label side's underside,
		// dimmed and tinted by the substrate.
		vec3 clear_look = mix(poly_color, lacquer_color, poly_show_through);
		ALBEDO = mix(clear_look, data_color, metal);
		METALLIC = mix(0.05, 0.80, metal);
		ROUGHNESS = mix(0.07, 0.13, metal);
		// Tinted by the substrate. The diffracted ray makes the same two-pass trip
		// through the dye as the specular one, so a PS1's black disc must dim its
		// own rainbow — untinted it blows out to white and stops reading as black.
		// sqrt, not the colour itself: data_color is the double-pass reflectance,
		// and taking it straight leaves the PS1 too dark to read as a disc at all.
		v_irid = vec3(pits * irid_strength) * sqrt(data_color);
	}

	SPECULAR = disc_specular;

	// View-only floor, so a disc never goes completely dead in a room whose lights
	// happen to miss the grating condition. L = V is the retroreflective case.
	if (dot(v_irid, vec3(1.0)) > 0.003) {
		EMISSION += grating(V, V, g, v_blur) * v_irid * irid_ambient;
	}
}


void light() {
	vec3 N = normalize(NORMAL);
	vec3 L = normalize(LIGHT);
	vec3 V = normalize(VIEW);
	float ndl = max(dot(N, L), 0.0);
	vec3 radiance = LIGHT_COLOR * ATTENUATION;

	// Lambert. Metal has no diffuse lobe.
	DIFFUSE_LIGHT += ALBEDO * radiance * ndl * (1.0 - METALLIC) * light_gain;

	// Normalised Blinn-Phong standing in for GGX. The exponent is clamped because
	// a mirror-smooth roughness sends it to six figures.
	vec3 H = normalize(L + V);
	float ndh = max(dot(N, H), 0.0);
	float a = max(ROUGHNESS * ROUGHNESS, 0.0025);
	float shine = clamp(2.0 / (a * a) - 2.0, 1.0, 2048.0);
	vec3 f0 = mix(vec3(0.08 * disc_specular), ALBEDO, METALLIC);
	vec3 fres = f0 + (1.0 - f0) * pow(1.0 - max(dot(V, H), 0.0), 5.0);
	SPECULAR_LIGHT += radiance * ndl * fres * pow(ndh, shine)
		* ((shine + 8.0) / 25.13) * spec_gain;

	// The lacquer coat, hand-written because defining light() compiles the
	// built-in clearcoat lobe out.
	SPECULAR_LIGHT += radiance * ndl * varnish * pow(ndh, 220.0);

	// Diffraction. Gated on the light reaching this side, so a disc in a shut
	// tray stays dark rather than glowing.
	if (dot(v_irid, vec3(1.0)) > 0.003 && dot(N, V) > 0.0) {
		SPECULAR_LIGHT += radiance * ndl * v_irid
			* grating(L, V, normalize(v_radial), v_blur);
	}
}
