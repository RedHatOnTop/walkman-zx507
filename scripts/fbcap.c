// fbcap: record what the display controller actually scans out.
//
// Polls the primary plane's framebuffer id through DRM and, each time it
// changes, copies a 4x-downsampled RGBA image of that framebuffer to a file.
// SurfaceFlinger's screencap/screenrecord compose their own frames, so they
// cannot show what the HWC committed; this reads the committed buffer itself.
//
// Build (host): python -m ziglang cc -target aarch64-linux-musl -static -O2
// Run (device, root): fbcap <plane-id> <seconds> <out-file> [delay-us]
// delay-us waits after a framebuffer becomes current before copying it,
// to tell a late render apart from one that never lands.
// Output: per frame a 16-byte header (u64 monotonic us, u32 fb id, u32 0)
// followed by W/4 x H/4 RGBA pixels. A first header carries W/4, H/4.

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

struct drm_set_client_cap { uint64_t capability, value; };
struct drm_mode_get_plane {
	uint32_t plane_id, crtc_id, fb_id, possible_crtcs, gamma_size, count_format_types;
	uint64_t format_type_ptr;
};
struct drm_mode_fb_cmd { uint32_t fb_id, width, height, pitch, bpp, depth, handle; };
struct drm_mode_map_dumb { uint32_t handle, pad; uint64_t offset; };

#define DRM_IOCTL_SET_CLIENT_CAP _IOW('d', 0x0D, struct drm_set_client_cap)
#define DRM_IOCTL_MODE_GETFB _IOWR('d', 0xAD, struct drm_mode_fb_cmd)
#define DRM_IOCTL_MODE_MAP_DUMB _IOWR('d', 0xB3, struct drm_mode_map_dumb)
#define DRM_IOCTL_MODE_GETPLANE _IOWR('d', 0xB6, struct drm_mode_get_plane)
#define DRM_CLIENT_CAP_UNIVERSAL_PLANES 2

#define MAXFB 64

struct mapped { uint32_t fb_id, width, height, pitch; uint8_t *base; size_t len; };

static uint64_t now_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static struct mapped *map_fb(int fd, struct mapped *tab, int *n, uint32_t fb_id)
{
	for (int i = 0; i < *n; i++)
		if (tab[i].fb_id == fb_id)
			return &tab[i];
	if (*n == MAXFB)
		return NULL;
	struct drm_mode_fb_cmd fb = { .fb_id = fb_id };
	if (ioctl(fd, DRM_IOCTL_MODE_GETFB, &fb) || !fb.handle) {
		fprintf(stderr, "GETFB %u: %s handle=%u\n", fb_id, strerror(errno), fb.handle);
		return NULL;
	}
	struct drm_mode_map_dumb md = { .handle = fb.handle };
	if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
		fprintf(stderr, "MAP_DUMB %u: %s\n", fb_id, strerror(errno));
		return NULL;
	}
	size_t len = (size_t)fb.pitch * fb.height;
	void *p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, md.offset);
	if (p == MAP_FAILED) {
		fprintf(stderr, "mmap %u: %s\n", fb_id, strerror(errno));
		return NULL;
	}
	struct mapped *m = &tab[(*n)++];
	*m = (struct mapped){ fb_id, fb.width, fb.height, fb.pitch, p, len };
	fprintf(stderr, "fb %u: %ux%u pitch %u bpp %u\n", fb_id, fb.width, fb.height, fb.pitch, fb.bpp);
	return m;
}

int main(int argc, char **argv)
{
	if (argc != 4 && argc != 5) {
		fprintf(stderr, "usage: %s <plane-id> <seconds> <out-file> [delay-us]\n", argv[0]);
		return 2;
	}
	uint32_t plane = strtoul(argv[1], NULL, 0);
	uint32_t delay = argc == 5 ? strtoul(argv[4], NULL, 0) : 0;
	uint64_t end = now_us() + strtoull(argv[2], NULL, 0) * 1000000;
	int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror("open /dev/dri/card0");
		return 1;
	}
	struct drm_set_client_cap cap = { DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1 };
	ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &cap);
	FILE *out = fopen(argv[3], "wb");
	if (!out) {
		perror("fopen");
		return 1;
	}

	static struct mapped tab[MAXFB];
	int ntab = 0, frames = 0, wrote_dims = 0;
	uint32_t last = 0;
	uint8_t *row = NULL;
	while (now_us() < end) {
		struct drm_mode_get_plane gp = { .plane_id = plane };
		if (ioctl(fd, DRM_IOCTL_MODE_GETPLANE, &gp)) {
			perror("GETPLANE");
			return 1;
		}
		if (gp.fb_id && gp.fb_id != last) {
			uint64_t t = now_us();
			if (delay)
				usleep(delay);
			struct mapped *m = map_fb(fd, tab, &ntab, gp.fb_id);
			if (!m)
				return 1;
			uint32_t w = m->width / 4, h = m->height / 4;
			if (!wrote_dims) {
				uint32_t dims[4] = { w, h, 0, 0 };
				fwrite(dims, sizeof dims, 1, out);
				row = malloc((size_t)w * 4);
				wrote_dims = 1;
			}
			uint32_t hdr[4] = { (uint32_t)t, (uint32_t)(t >> 32), gp.fb_id, 0 };
			fwrite(hdr, sizeof hdr, 1, out);
			for (uint32_t y = 0; y < h; y++) {
				const uint32_t *src = (const uint32_t *)(m->base + (size_t)y * 4 * m->pitch);
				for (uint32_t x = 0; x < w; x++)
					((uint32_t *)row)[x] = src[x * 4];
				fwrite(row, (size_t)w * 4, 1, out);
			}
			last = gp.fb_id;
			frames++;
		}
		usleep(500);
	}
	fclose(out);
	fprintf(stderr, "%d frames, %d framebuffers\n", frames, ntab);
	return 0;
}
