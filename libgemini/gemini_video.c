// gemini_video.c — framebuffer access (/dev/fb0, double-buffered)
//
// Known-good framebuffer path for the SP7021 custom launcher stack. The current
// fb0 assumptions, pan-reset logic, and double-buffer behavior were validated
// on-device and should be treated as the baseline configuration.

#include "gemini.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

#ifdef __ARM_NEON
#include <arm_neon.h>
#endif

struct gem_fb {
    int fd;
    uint8_t *map;
    size_t map_size;
    uint32_t width;
    uint32_t height;
    uint32_t stride;       // bytes per row
    uint32_t virt_height;  // virtual height (for double buffering)
    int current_page;      // 0 or 1
    struct fb_var_screeninfo vinfo; // cached for flip (avoids ioctl per frame)
};

static void gem_fb_reset_pan(gem_fb_t *fb)
{
    if (!fb)
        return;
    fb->vinfo.yoffset = 0;
    fb->vinfo.xoffset = 0;
    if (ioctl(fb->fd, FBIOPAN_DISPLAY, &fb->vinfo) != 0) {
        fb->vinfo.activate = FB_ACTIVATE_NOW | FB_ACTIVATE_FORCE;
        ioctl(fb->fd, FBIOPUT_VSCREENINFO, &fb->vinfo);
    }
    fb->current_page = 0;
}

gem_fb_t *gem_fb_open(void)
{
    gem_fb_t *fb = calloc(1, sizeof(gem_fb_t));
    if (!fb) return NULL;

    fb->fd = open("/dev/fb0", O_RDWR);
    if (fb->fd < 0) {
        gem_log(GEM_LOG_ERROR, "video: open /dev/fb0: %s\n", strerror(errno));
        free(fb);
        return NULL;
    }

    struct fb_fix_screeninfo finfo;

    if (ioctl(fb->fd, FBIOGET_VSCREENINFO, &fb->vinfo) < 0) {
        gem_log(GEM_LOG_ERROR, "video: FBIOGET_VSCREENINFO: %s\n", strerror(errno));
        close(fb->fd);
        free(fb);
        return NULL;
    }

    if (ioctl(fb->fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        gem_log(GEM_LOG_ERROR, "video: FBIOGET_FSCREENINFO: %s\n", strerror(errno));
        close(fb->fd);
        free(fb);
        return NULL;
    }

    fb->width = fb->vinfo.xres;
    fb->height = fb->vinfo.yres;
    fb->stride = finfo.line_length;
    fb->virt_height = fb->vinfo.yres_virtual;

    gem_log(GEM_LOG_INFO, "video: %ux%u bpp=%u stride=%u double-buffer=%s\n",
            fb->width, fb->height, fb->vinfo.bits_per_pixel, fb->stride,
            (fb->virt_height >= fb->height * 2) ? "yes" : "no");

    // Reset pan to page 0
    if (fb->vinfo.yoffset != 0 || fb->vinfo.xoffset != 0) {
        gem_log(GEM_LOG_DEBUG, "video: resetting pan from yoffset=%u\n", fb->vinfo.yoffset);
        gem_fb_reset_pan(fb);
    }

    // mmap the full virtual framebuffer
    fb->map_size = (size_t)fb->stride * fb->virt_height;
    if (fb->map_size < (size_t)fb->stride * fb->height)
        fb->map_size = (size_t)fb->stride * fb->height;

    fb->map = mmap(NULL, fb->map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb->fd, 0);
    if (fb->map == MAP_FAILED) {
        gem_log(GEM_LOG_ERROR, "video: mmap: %s\n", strerror(errno));
        close(fb->fd);
        free(fb);
        return NULL;
    }

    fb->current_page = 0;

    // Clear entire FB to opaque black
    // Alpha must be 0xFF — SP7021 display controller respects alpha
    uint32_t *p = (uint32_t *)fb->map;
    size_t count = fb->map_size / sizeof(uint32_t);
    size_t i = 0;
#ifdef __ARM_NEON
    uint32x4_t vblack = vdupq_n_u32(0xFF000000);
    for (; i + 4 <= count; i += 4)
        vst1q_u32(p + i, vblack);
#endif
    for (; i < count; i++)
        p[i] = 0xFF000000;

    return fb;
}

void gem_fb_close(gem_fb_t *fb)
{
    if (!fb) return;
    if (fb->fd >= 0)
        gem_fb_reset_pan(fb);
    if (fb->map && fb->map != MAP_FAILED)
        munmap(fb->map, fb->map_size);
    if (fb->fd >= 0)
        close(fb->fd);
    free(fb);
}

uint32_t *gem_fb_pixels(gem_fb_t *fb)
{
    if (!fb) return NULL;
    // Return pointer to the back buffer (the page NOT currently displayed)
    int back_page = fb->current_page ^ 1;
    // Only use double-buffering if virtual height supports it
    if (fb->virt_height >= fb->height * 2) {
        size_t offset = (size_t)back_page * fb->height * fb->stride;
        return (uint32_t *)(fb->map + offset);
    }
    // Single buffer fallback
    return (uint32_t *)fb->map;
}

uint32_t gem_fb_stride(gem_fb_t *fb)
{
    if (!fb) return 0;
    return fb->stride;
}

uint32_t gem_fb_width(gem_fb_t *fb)
{
    if (!fb) return 0;
    return fb->width;
}

uint32_t gem_fb_height(gem_fb_t *fb)
{
    if (!fb) return 0;
    return fb->height;
}

void gem_fb_copy_front_to_back(gem_fb_t *fb)
{
    uint8_t *front;
    uint8_t *back;
    size_t page_bytes;

    if (!fb || fb->virt_height < fb->height * 2)
        return;

    page_bytes = (size_t)fb->stride * fb->height;
    front = fb->map + (size_t)fb->current_page * page_bytes;
    back = fb->map + (size_t)(fb->current_page ^ 1) * page_bytes;
    memmove(back, front, page_bytes);
}

void gem_fb_flip(gem_fb_t *fb)
{
    if (!fb) return;
    if (fb->virt_height < fb->height * 2) {
        // Single-buffer mode — no flip needed, drawing goes directly to display
        return;
    }

    int back_page = fb->current_page ^ 1;
    fb->vinfo.yoffset = back_page * fb->height;
    fb->vinfo.xoffset = 0;
    if (ioctl(fb->fd, FBIOPAN_DISPLAY, &fb->vinfo) == 0) {
        fb->current_page = back_page;
    } else {
        static int flip_errors = 0;
        if (++flip_errors <= 3)
            gem_log(GEM_LOG_ERROR, "video: FBIOPAN_DISPLAY failed: %s (page=%d yoff=%u)\n",
                    strerror(errno), back_page, fb->vinfo.yoffset);
    }
}

void gem_fb_clear(gem_fb_t *fb, uint32_t color)
{
    if (!fb) return;
    // Force alpha to 0xFF
    color |= 0xFF000000;
    uint32_t *pixels = gem_fb_pixels(fb);
    if (!pixels) return;
    // Use stride-aware fill
    for (uint32_t y = 0; y < fb->height; y++) {
        uint32_t *row = (uint32_t *)((uint8_t *)pixels + y * fb->stride);
        uint32_t x = 0;
#ifdef __ARM_NEON
        uint32x4_t vc = vdupq_n_u32(color);
        for (; x + 4 <= fb->width; x += 4)
            vst1q_u32(row + x, vc);
#endif
        for (; x < fb->width; x++)
            row[x] = color;
    }
}

void gem_fb_blit_scaled(gem_fb_t *fb, const uint32_t *src, int src_w, int src_h)
{
    if (!fb || !src || src_w <= 0 || src_h <= 0) return;

    uint32_t *pixels = gem_fb_pixels(fb);
    if (!pixels) return;

    // Compute uniform scale factor, centered on display
    unsigned int scaled_w, scaled_h;
    if ((unsigned int)src_w * fb->height > (unsigned int)src_h * fb->width) {
        // Width-limited
        scaled_w = fb->width;
        scaled_h = ((unsigned int)fb->width * src_h) / src_w;
    } else {
        // Height-limited
        scaled_h = fb->height;
        scaled_w = ((unsigned int)fb->height * src_w) / src_h;
    }

    unsigned int offset_x = (fb->width - scaled_w) / 2;
    unsigned int offset_y = (fb->height - scaled_h) / 2;

    // Cached X source lookup table for nearest-neighbor (avoids per-pixel divide)
    #define MAX_SCALE_WIDTH 2048
    static unsigned int src_x_cache[MAX_SCALE_WIDTH];
    static int cache_src_w = 0;
    static unsigned int cache_scaled_w = 0;

    if (scaled_w > MAX_SCALE_WIDTH) scaled_w = MAX_SCALE_WIDTH;

    if (src_w != cache_src_w || scaled_w != cache_scaled_w) {
        for (unsigned int x = 0; x < scaled_w; x++)
            src_x_cache[x] = (x * src_w) / scaled_w;
        cache_src_w = src_w;
        cache_scaled_w = scaled_w;
    }

    for (unsigned int y = 0; y < scaled_h; y++) {
        unsigned int src_y = (y * src_h) / scaled_h;
        const uint32_t *src_row = src + src_y * src_w;
        uint32_t *dst_row = (uint32_t *)((uint8_t *)pixels + (y + offset_y) * fb->stride) + offset_x;

        for (unsigned int x = 0; x < scaled_w; x++) {
            // Force 0xFF alpha — source may have alpha=0x00
            dst_row[x] = src_row[src_x_cache[x]] | 0xFF000000;
        }
    }
}
