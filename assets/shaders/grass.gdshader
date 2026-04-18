shader_type spatial;
render_mode cull_disabled;

uniform float blade_bend = 0.5;
uniform vec3 color = vec3(0.3, 0.6, 0.1);
uniform sampler2D patch_noise;
uniform float patch_scale = 5.0;
uniform float size_small = 0.2;
uniform float size_large = 0.8;
uniform vec3 color_small: source_color = vec3(0.3, 0.6, 0.1);
uniform vec3 color_large: source_color = vec3(0.9, 0.9, 0.2);
uniform sampler2D wind_noise;
uniform float wind_strength = 0.1;
uniform float wind_bend_strength = 2.0;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float object_radius = 1.0;
uniform vec3 object_position;

varying float patch_factor;
varying float current_wind_bend;
varying float bottom_to_top;

void vertex() {
	bottom_to_top = 1.0 - UV.y;

	// Wind logic
	vec2 wind_position = NODE_POSITION_WORLD.xz / 10.0;
	wind_position -= (TIME + 8.0) * wind_direction * wind_strength;

	current_wind_bend = texture(wind_noise, wind_position).x;

	current_wind_bend *= wind_strength;
	current_wind_bend *= bottom_to_top * 2.0;

	mat4 inv_model = inverse(MODEL_MATRIX);
	vec2 local_direction = (inv_model * vec4(wind_direction.x, 0.0, wind_direction.y, 0.0)).xz;

	VERTEX.xz += current_wind_bend * local_direction * wind_bend_strength;

	// Bend away from the object
	float object_distance = distance(object_position, NODE_POSITION_WORLD);
	float bend_away_strength = max(object_radius - object_distance, 0.0) / object_radius;
	vec2 bend_direction = normalize(object_position.xz - NODE_POSITION_WORLD.xz);

	VERTEX.xz -= (inv_model * vec4(bend_direction.x, 0.0, bend_direction.y, 0.0)).xz
			* bend_away_strength * bottom_to_top;
	VERTEX.y -= bend_away_strength * bottom_to_top * 0.5;

	// General appearance
	VERTEX.z += blade_bend * pow(bottom_to_top, 2.0);

	patch_factor = texture(patch_noise, NODE_POSITION_WORLD.xz / patch_scale).r;
	VERTEX *= mix(size_small, size_large, patch_factor);

	NORMAL = mix(NORMAL, vec3(0.0, 1.0, 0.0), bottom_to_top);
}

void fragment() {
	if (!FRONT_FACING) NORMAL = -NORMAL;
	AO = bottom_to_top;
	AO_LIGHT_AFFECT = 1.0;
	
	BACKLIGHT = vec3(0.2);
	ROUGHNESS = 0.4;
	SPECULAR = 0.2;
	
	ALBEDO = mix(color_small, color_large, patch_factor);
}
