#version 450
/* u-gpudraw fill bench: one triangle over the whole target */
void main() {
	vec2 p[3] = vec2[](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
	gl_Position = vec4(p[gl_VertexIndex], 0.0, 1.0);
}
