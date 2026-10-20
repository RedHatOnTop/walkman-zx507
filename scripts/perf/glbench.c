// GPU cost model for the ZX507's GC7000NanoUltra: full-screen fills, blending,
// texturing and render-target switches, each timed between glFinish calls on an
// offscreen 720x1280 RGBA8 FBO. Runs beside the UI without touching the screen.
//
// Build: aarch64-linux-android29-clang -O2 glbench.c -lEGL -lGLESv2 -o glbench
// Usage: glbench [width height]
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now_ms(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static GLuint shader(GLenum type, const char *src) {
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	GLint ok;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[512];
		glGetShaderInfoLog(s, sizeof log, NULL, log);
		fprintf(stderr, "shader: %s\n", log);
		exit(1);
	}
	return s;
}

static GLuint program(const char *fs) {
	static const char *vs =
		"attribute vec2 p; varying vec2 uv;\n"
		"void main() { uv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }\n";
	GLuint p = glCreateProgram();
	glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
	glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
	glBindAttribLocation(p, 0, "p");
	glLinkProgram(p);
	return p;
}

static GLuint texture(int w, int h) {
	GLuint t;
	glGenTextures(1, &t);
	glBindTexture(GL_TEXTURE_2D, t);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	return t;
}

static GLuint fbo_for(GLuint tex) {
	GLuint f;
	glGenFramebuffers(1, &f);
	glBindFramebuffer(GL_FRAMEBUFFER, f);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		fprintf(stderr, "fbo incomplete\n");
		exit(1);
	}
	return f;
}

static void quad(float x0, float y0, float x1, float y1) {
	const float v[] = {x0, y0, x1, y0, x0, y1, x1, y1};
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, v);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

#define N 60
#define REPORT(name, t0, per)                                                     \
	printf("%-44s %7.3f ms per op\n", name, (now_ms() - (t0)) / (per))

int main(int argc, char **argv) {
	int W = argc > 2 ? atoi(argv[1]) : 720, H = argc > 2 ? atoi(argv[2]) : 1280;

	EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	eglInitialize(d, NULL, NULL);
	const EGLint ca[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE,
			     EGL_PBUFFER_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
			     EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
	EGLConfig c;
	EGLint n;
	eglChooseConfig(d, ca, &c, 1, &n);
	const EGLint pa[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
	EGLSurface s = eglCreatePbufferSurface(d, c, pa);
	const EGLint xa[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
	EGLContext x = eglCreateContext(d, c, EGL_NO_CONTEXT, xa);
	if (!eglMakeCurrent(d, s, s, x)) {
		fprintf(stderr, "eglMakeCurrent failed: 0x%x\n", eglGetError());
		return 1;
	}
	printf("%s / %s, target %dx%d\n", glGetString(GL_RENDERER), glGetString(GL_VERSION), W, H);

	GLuint solid = program("precision mediump float; uniform vec4 c;\n"
			       "void main() { gl_FragColor = c; }\n");
	GLuint textured = program("precision mediump float; varying vec2 uv; uniform sampler2D t;\n"
				  "void main() { gl_FragColor = texture2D(t, uv) * 0.9; }\n");
	glEnableVertexAttribArray(0);

	GLuint main_tex = texture(W, H), main_fbo = fbo_for(main_tex);
	GLuint src_tex = texture(W, H);
	GLuint layer_tex = texture(W, H * 135 / 1280), layer_fbo = fbo_for(layer_tex);
	glViewport(0, 0, W, H);

	glBindFramebuffer(GL_FRAMEBUFFER, main_fbo);
	glUseProgram(solid);
	glUniform4f(glGetUniformLocation(solid, "c"), 0.2f, 0.3f, 0.4f, 0.5f);
	quad(-1, -1, 1, 1);
	glFinish();

	double t0 = now_ms();
	for (int i = 0; i < N; i++) {
		glClearColor(0, 0, 0, i & 1);
		glClear(GL_COLOR_BUFFER_BIT);
		quad(-1, -1, -0.99f, -0.99f);
	}
	glFinish();
	REPORT("clear full target (+ tiny draw)", t0, N);

	glDisable(GL_BLEND);
	t0 = now_ms();
	for (int i = 0; i < N; i++)
		quad(-1, -1, 1, 1);
	glFinish();
	REPORT("solid full-screen quad, no blend", t0, N);

	glEnable(GL_BLEND);
	glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
	t0 = now_ms();
	for (int i = 0; i < N; i++)
		quad(-1, -1, 1, 1);
	glFinish();
	REPORT("solid full-screen quad, src-over blend", t0, N);

	glUseProgram(textured);
	glBindTexture(GL_TEXTURE_2D, src_tex);
	glDisable(GL_BLEND);
	t0 = now_ms();
	for (int i = 0; i < N; i++)
		quad(-1, -1, 1, 1);
	glFinish();
	REPORT("textured full-screen quad, no blend", t0, N);

	glEnable(GL_BLEND);
	t0 = now_ms();
	for (int i = 0; i < N; i++)
		quad(-1, -1, 1, 1);
	glFinish();
	REPORT("textured full-screen quad, src-over blend", t0, N);

	// One offscreen pass the way hwui renders a layer or an alpha saveLayer:
	// switch to a 720x135 target, clear + draw, switch back, composite it.
	glUseProgram(solid);
	t0 = now_ms();
	for (int i = 0; i < N; i++) {
		glBindFramebuffer(GL_FRAMEBUFFER, layer_fbo);
		glViewport(0, 0, W, H * 135 / 1280);
		glClear(GL_COLOR_BUFFER_BIT);
		quad(-0.5f, -0.5f, 0.5f, 0.5f);
		glBindFramebuffer(GL_FRAMEBUFFER, main_fbo);
		glViewport(0, 0, W, H);
		glUseProgram(textured);
		glBindTexture(GL_TEXTURE_2D, layer_tex);
		quad(-1, 0.6f, 1, 0.81f);
		glUseProgram(solid);
	}
	glFinish();
	REPORT("720x135 layer pass: switch, draw, composite", t0, N);

	t0 = now_ms();
	for (int i = 0; i < N; i++) {
		glUseProgram(textured);
		glBindTexture(GL_TEXTURE_2D, src_tex);
		quad(-1, 0.6f, 1, 0.81f);
		glUseProgram(solid);
		quad(-0.5f, 0.65f, 0.5f, 0.75f);
	}
	glFinish();
	REPORT("same draws without the target switch", t0, N);

	// glCopyTexSubImage2D from the bound target, as Skia's saveBehind does.
	glBindTexture(GL_TEXTURE_2D, layer_tex);
	t0 = now_ms();
	for (int i = 0; i < N; i++) {
		quad(-1, -1, 1, 1);
		glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, 36, 108);
	}
	glFinish();
	REPORT("full quad + glCopyTexSubImage2D 36x108", t0, N);

	// Upload into a texture the previous draw still samples.
	glUseProgram(textured);
	static unsigned char px[64 * 64 * 4];
	GLuint small = texture(64, 64);
	t0 = now_ms();
	for (int i = 0; i < N; i++) {
		glBindTexture(GL_TEXTURE_2D, small);
		quad(-1, -1, 1, 1);
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 14, 26, GL_RGBA, GL_UNSIGNED_BYTE, px);
	}
	glFinish();
	REPORT("full quad + glTexSubImage2D 14x26 (in use)", t0, N);

	// Shader clock: unrolled, independent vec4 MAD chains on a 128x128 target, so
	// memory traffic is negligible. One vec4 MAD per clock is 8 FLOP per clock;
	// the difference between two chain lengths cancels the fixed per-pixel cost.
	GLuint alu_tex = texture(128, 128), alu_fbo = fbo_for(alu_tex);
	glBindFramebuffer(GL_FRAMEBUFFER, alu_fbo);
	glViewport(0, 0, 128, 128);
	glDisable(GL_BLEND);
	double ms[2];
	const int iters[2] = {16, 48};
	for (int k = 0; k < 2; k++) {
		static char fs[16384];
		int len = snprintf(fs, sizeof fs,
				   "precision highp float; varying vec2 uv; uniform vec4 a, b;\n"
				   "void main() {\n"
				   "  vec4 x0 = vec4(uv, uv.yx), x1 = x0 + a, x2 = x0 + b, x3 = x0 * a;\n");
		for (int i = 0; i < iters[k]; i++)
			len += snprintf(fs + len, sizeof fs - len,
					"  x0 = x0 * x1 + a; x1 = x1 * x2 + b; x2 = x2 * x3 + a; x3 = x3 * x0 + b;\n");
		snprintf(fs + len, sizeof fs - len, "  gl_FragColor = x0 + x1 + x2 + x3;\n}\n");
		GLuint alu = program(fs);
		glUseProgram(alu);
		glUniform4f(glGetUniformLocation(alu, "a"), 0.999f, 0.998f, 0.997f, 0.996f);
		glUniform4f(glGetUniformLocation(alu, "b"), 0.001f, 0.002f, 0.003f, 0.004f);
		quad(-1, -1, 1, 1);
		glFinish();
		t0 = now_ms();
		for (int i = 0; i < N; i++)
			quad(-1, -1, 1, 1);
		glFinish();
		ms[k] = (now_ms() - t0) / N;
		printf("ALU %3d x 4 vec4 MAD per pixel (unrolled)   %7.3f ms per op\n", iters[k], ms[k]);
	}
	double mads = (double)(iters[1] - iters[0]) * 4 * 128 * 128;
	printf("marginal vec4 MAD rate %.3f G/s = %.2f GFLOPS (1 MAD/clk -> %.0f MHz)\n",
	       mads / (ms[1] - ms[0]) / 1e6, mads * 8 / (ms[1] - ms[0]) / 1e6,
	       mads / (ms[1] - ms[0]) / 1e3);

	eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglTerminate(d);
	return 0;
}
