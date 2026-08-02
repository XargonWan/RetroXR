// Lit PVC/rubber jacket for VerletRope's tube.
//
// The rope was SHADING_MODE_UNSHADED, which is why it read as a flat black
// silhouette rather than a cable — it received no light at all.
//
// It could not simply be switched to a lit StandardMaterial3D, because the tube
// mesh carries ARRAY_VERTEX and ARRAY_INDEX and nothing else. There is no normal
// array, and adding one would break the reason it is fast: the rope re-uploads
// its positions every frame through surface_update_vertex_region, whose buffer
// layout is position-only. Interleaving compressed normals there means rebuilding
// the whole surface each frame instead.
//
// Instead the tube ships its normal as a CUSTOM0 attribute. Custom attributes
// live in the ATTRIBUTE buffer, which has its own region-update call, so the
// normal rides along for one extra bulk upload per frame and the vertex fast path
// is untouched. The radial vector was already being computed to place each vertex,
// so producing it costs nothing.
//
// This replaced screen-space derivative normals, which shaded each facet FLAT and
// made even a 12-sided tube read as a banded prism rather than a cord.
//
// Deliberately does not write ALPHA: doing so in a spatial shader silently flags
// the material transparent and drops it out of the depth prepass, after which
// cables interleave with the geometry they lie on.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 cable_color : source_color = vec3(0.15, 0.15, 0.15);
// Moulded PVC: not a mirror, but glossy enough to catch a highlight along the
// top of a run. Fully rough reads as cloth and put us back at "flat".
uniform float cable_roughness : hint_range(0.0, 1.0) = 0.38;
uniform float cable_specular : hint_range(0.0, 1.0) = 0.5;
// Lifts the side facets that face away from every light, so a cord lying on a
// dark carpet still has a readable round form instead of dissolving into it.
uniform float ambient_wrap : hint_range(0.0, 1.0) = 0.12;

void vertex() {
	// Model space here, and the rope is top_level with an identity transform, so
	// this is the world-space radial the mesh builder wrote. Godot takes it to
	// view space itself.
	NORMAL = normalize(CUSTOM0.xyz);
}

void fragment() {
	ALBEDO = cable_color * (1.0 + ambient_wrap);
	ROUGHNESS = cable_roughness;
	METALLIC = 0.0;
	SPECULAR = cable_specular;
}
