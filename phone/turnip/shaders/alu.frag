#version 450
/* u-perfctr ALU calibration (vktest bench): 16 dependent vec4 mul + fma steps, ~128 scalar fp32 ALU instructions a pixel */
layout(location = 0) out vec4 c;
void main() {
	vec4 v = gl_FragCoord.xyxy * vec4(0.001, 0.002, 0.003, 0.004);
	for (int i = 0; i < 16; i++)
		v = v * v * 0.5 + vec4(0.25);
	c = v;
}
