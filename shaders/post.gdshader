// Applied to the low-res viewport: 4x4 ordered dither, colour quantise, vignette.
shader_type canvas_item;

uniform float levels = 28.0;

const float BAYER[16] = float[](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0);

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	vec2 px = floor(UV / TEXTURE_PIXEL_SIZE);
	int i = int(mod(px.y, 4.0)) * 4 + int(mod(px.x, 4.0));
	float d = BAYER[i] / 16.0 - 0.5;
	c.rgb = floor(c.rgb * levels + d + 0.5) / levels;
	float v = smoothstep(0.85, 0.35, length(UV - 0.5));
	c.rgb *= mix(0.35, 1.0, v);
	COLOR = vec4(c.rgb, 1.0);
}
