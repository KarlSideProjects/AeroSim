// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

shader_type spatial;

render_mode skip_vertex_transform, cull_disabled, blend_mix;

uniform vec2 wind_direction = vec2(1.0, 1.0);
uniform float wind_force : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float wind_phase = 0.0;

varying vec4 data;

const float MAX_BEND_METERS = 0.42;
const float MAX_LATERAL_SWAY_METERS = 0.04;

void vertex() {
	float blade_height = clamp(VERTEX.y + 0.55, 0.0, 1.0);
	data[2] = blade_height * blade_height;

	// A broad lower third and pinched tip turn the ribbon into a blade shape.
	VERTEX.xz *= mix(0.72, 0.08, smoothstep(0.0, 1.0, blade_height));

	// Brighten tips
	COLOR = mix(COLOR, vec4(1.0), smoothstep(0.9, 1.0, data[2]));
	// Darken base, skip is scale is less than threshold, as this means "grow in" is occuring.
	COLOR *= INSTANCE_CUSTOM[3] < 0.35 ? 1. : mix(1.0, 0.75, smoothstep(0.35, 0.0, data[2]));
	// Save red/green shift for fragment
	data.rg = INSTANCE_CUSTOM.rg;

	// World space vertex
	vec3 w_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// The process shader supplies a coherent, simulation-time wind sample.
	float scale = pow(INSTANCE_CUSTOM[3] * INSTANCE_CUSTOM[3], 0.707);
	float force = min(MAX_BEND_METERS, pow(INSTANCE_CUSTOM[2] * data[2] * scale, 0.707));

	// A small spatial phase offset keeps the gust visibly coherent without a rigid sheet.
	float coherent_gust = sin(wind_phase * 1.7 + dot(w_vertex.xz, vec2(0.037, 0.053)) + data.r * 6.28318);
	float lateral_wobble = coherent_gust * MAX_LATERAL_SWAY_METERS * data[2] * wind_force;
	vec2 direction = length(wind_direction) > 0.0001 ? normalize(wind_direction) : vec2(1.0, 0.0);
	w_vertex.xz += direction * force + vec2(-direction.y, direction.x) * lateral_wobble;
	w_vertex.y -= min(0.14, force * data[2]);

	// Save final wind force value for fragment.
	data[3] = force;

	VERTEX = (VIEW_MATRIX * vec4(w_vertex, 1.0)).xyz;
	NORMAL = MODELVIEW_NORMAL_MATRIX * NORMAL;
	BINORMAL = MODELVIEW_NORMAL_MATRIX * BINORMAL;
	TANGENT = MODELVIEW_NORMAL_MATRIX * TANGENT;
}

void fragment() {
	float color_variation = dot(data.rg, vec2(0.65, 0.35));
	vec3 base_color = mix(vec3(0.13, 0.18, 0.035), vec3(0.27, 0.33, 0.075), data[2]);
	ALBEDO = base_color * mix(0.88, 1.10, color_variation);
	ALBEDO *= pow(COLOR.rgb, vec3(2.2));
	// Modify roughness / specular based on wind force for added detail
	float spec_rough = clamp(max(data[2], data[3]), 0., 1.);
	ROUGHNESS = 1. - spec_rough;
	SPECULAR = clamp(spec_rough * 0.25, 0., .15);

	BACKLIGHT = vec3(0.33);
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	ALBEDO = pow(ALBEDO, vec3(0.4));
	#endif
}
