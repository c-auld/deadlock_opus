// PS1-style surface: vertex snapping to a low-res grid + partially affine texture mapping.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D albedo_tex : source_color, hint_default_white, filter_nearest, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
uniform bool world_uv = false;
uniform float tex_scale = 0.5;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 0.0;
uniform float snap_div = 1.5;
uniform float affine_amount = 0.7;

varying vec3 aff_uv;
varying vec2 persp_uv;

void vertex() {
	vec2 uv = UV;
	if (world_uv) {
		vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		vec3 wn = abs((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
		if (wn.y > wn.x && wn.y > wn.z) {
			uv = wp.xz;
		} else if (wn.x > wn.z) {
			uv = vec2(wp.z, -wp.y);
		} else {
			uv = vec2(wp.x, -wp.y);
		}
		uv *= tex_scale;
	}
	vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	if (clip.w > 0.0) {
		vec2 grid = VIEWPORT_SIZE * 0.5 / snap_div;
		clip.xy = round(clip.xy / clip.w * grid) / grid * clip.w;
	}
	POSITION = clip;
	persp_uv = uv;
	aff_uv = vec3(uv * clip.w, clip.w);
}

void fragment() {
	vec2 uv = mix(persp_uv, aff_uv.xy / aff_uv.z, affine_amount);
	vec4 c = texture(albedo_tex, uv) * tint;
	ALBEDO = c.rgb;
	EMISSION = emission_color.rgb * emission_energy;
}
