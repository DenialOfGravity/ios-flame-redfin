#version 450
/* u-perfctr ALU calibration (vktest bench): alu.frag in mediump (RelaxedPrecision: half if ir3 lowers it) */
precision mediump float;
layout(location = 0) out mediump vec4 c;
void main() {
	mediump vec4 v = vec4(gl_FragCoord.xyxy) * vec4(0.001, 0.002, 0.003, 0.004);
	for (int i = 0; i < 16; i++)
		v = v * v * 0.5 + vec4(0.25);
	c = v;
}
