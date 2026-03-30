// gemini_video.c — RetroArch video driver for Gemini SP7021
//
// Renders to /dev/fb0 using double-buffered page flipping.
// SP7021 display specifics:
//   - 1920x720 @ 32bpp BGRA (alpha in MSB, must be 0xFF)
//   - Virtual height 1440 for double buffering (two 720-line pages)
//   - FBIOPAN_DISPLAY for page flip
//   - Hardware compositor uses alpha channel (0x00 = transparent)
//
// Pixel conversion: libretro cores output XRGB8888 or RGB565.
// This driver converts to BGRA with alpha forced to 0xFF.
//
// Scaling: nearest-neighbor, aspect-preserving, centered on screen.
//
// RGUI support: menu frames received via poke interface, rendered when active.
//
// Target: RetroArch v1.17.0+ (struct layouts may need minor tweaks for other versions)

#ifdef HAVE_GEMINI

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>
#include <errno.h>

#ifdef __ARM_NEON
#include <arm_neon.h>
#endif

#include "../../retroarch.h"
#include "../../verbosity.h"
#include "../video_driver.h"

typedef struct {
    int fb_fd;
    uint8_t *fb_map;
    size_t map_size;
    uint32_t screen_w, screen_h;
    uint32_t stride;         // bytes per row
    uint32_t virt_h;         // virtual height (must be >= 2 * screen_h for double buffer)
    int page;                // currently displayed page (0 or 1)
    struct fb_var_screeninfo vinfo;
    bool rgb32;              // core pixel format: true = XRGB8888, false = RGB565

    // RGUI menu overlay
    bool menu_active;
    void *menu_frame;        // copy of last menu frame data
    size_t menu_frame_cap;
    unsigned menu_w, menu_h;
    bool menu_rgb32;
} gemini_video_t;

// get pointer to back buffer (the page not currently displayed)
static uint32_t *back_buffer(gemini_video_t *v)
{
    if (v->virt_h >= v->screen_h * 2) {
        int back = v->page ^ 1;
        return (uint32_t *)(v->fb_map + (size_t)back * v->screen_h * v->stride);
    }
    return (uint32_t *)v->fb_map;
}

// swap front and back pages
static void page_flip(gemini_video_t *v)
{
    if (v->virt_h < v->screen_h * 2)
        return;
    int back = v->page ^ 1;
    v->vinfo.yoffset = back * v->screen_h;
    v->vinfo.xoffset = 0;
    if (ioctl(v->fb_fd, FBIOPAN_DISPLAY, &v->vinfo) == 0)
        v->page = back;
}

// scale source frame to framebuffer (nearest-neighbor, centered, aspect-preserving)
// handles RGB565 and XRGB8888 input, outputs BGRA with 0xFF alpha
static void blit_scaled(uint32_t *dst, uint32_t dst_w, uint32_t dst_h, uint32_t dst_stride,
                        const void *src, unsigned src_w, unsigned src_h,
                        unsigned src_pitch, bool rgb32)
{
    if (!src || !src_w || !src_h)
        return;

    // compute scale (aspect-preserving, may be fractional)
    unsigned scale_num_x = dst_w;
    unsigned scale_den_x = src_w;
    unsigned scale_num_y = dst_h;
    unsigned scale_den_y = src_h;

    // pick smaller scale to preserve aspect
    // compare scale_num_x/scale_den_x vs scale_num_y/scale_den_y via cross-multiply
    unsigned out_w, out_h;
    if (scale_num_x * scale_den_y < scale_num_y * scale_den_x) {
        out_w = dst_w;
        out_h = src_h * dst_w / src_w;
    } else {
        out_h = dst_h;
        out_w = src_w * dst_h / src_h;
    }
    if (out_w > dst_w) out_w = dst_w;
    if (out_h > dst_h) out_h = dst_h;

    unsigned off_x = (dst_w - out_w) / 2;
    unsigned off_y = (dst_h - out_h) / 2;
    uint32_t stride_px = dst_stride / 4;

    for (unsigned dy = 0; dy < out_h; dy++) {
        unsigned sy = dy * src_h / out_h;
        uint32_t *drow = dst + (off_y + dy) * stride_px + off_x;
        const uint8_t *srow = (const uint8_t *)src + sy * src_pitch;

        if (rgb32) {
            const uint32_t *sp = (const uint32_t *)srow;
            for (unsigned dx = 0; dx < out_w; dx++) {
                unsigned sx = dx * src_w / out_w;
                drow[dx] = sp[sx] | 0xFF000000;
            }
        } else {
            const uint16_t *sp = (const uint16_t *)srow;
            for (unsigned dx = 0; dx < out_w; dx++) {
                unsigned sx = dx * src_w / out_w;
                uint16_t p = sp[sx];
                uint8_t r = (p >> 11) & 0x1F; r = (r << 3) | (r >> 2);
                uint8_t g = (p >> 5)  & 0x3F; g = (g << 2) | (g >> 4);
                uint8_t b =  p        & 0x1F; b = (b << 3) | (b >> 2);
                drow[dx] = 0xFF000000 | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
            }
        }
    }
}

static void *gemini_gfx_init(const video_info_t *video,
      input_driver_t **input, void **input_data)
{
    gemini_video_t *v = calloc(1, sizeof(*v));
    if (!v) return NULL;

    v->fb_fd = open("/dev/fb0", O_RDWR);
    if (v->fb_fd < 0) {
        RARCH_ERR("[Gemini] open /dev/fb0: %s\n", strerror(errno));
        free(v);
        return NULL;
    }

    struct fb_fix_screeninfo finfo;
    if (ioctl(v->fb_fd, FBIOGET_VSCREENINFO, &v->vinfo) < 0 ||
        ioctl(v->fb_fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        RARCH_ERR("[Gemini] framebuffer ioctl: %s\n", strerror(errno));
        close(v->fb_fd);
        free(v);
        return NULL;
    }

    v->screen_w = v->vinfo.xres;
    v->screen_h = v->vinfo.yres;
    v->stride   = finfo.line_length;
    v->virt_h   = v->vinfo.yres_virtual;
    v->rgb32    = video->rgb32;

    // reset pan to page 0
    v->vinfo.yoffset = 0;
    v->vinfo.xoffset = 0;
    ioctl(v->fb_fd, FBIOPAN_DISPLAY, &v->vinfo);

    // mmap entire virtual framebuffer
    v->map_size = (size_t)v->stride * v->virt_h;
    v->fb_map = mmap(NULL, v->map_size, PROT_READ | PROT_WRITE, MAP_SHARED, v->fb_fd, 0);
    if (v->fb_map == MAP_FAILED) {
        RARCH_ERR("[Gemini] mmap: %s\n", strerror(errno));
        close(v->fb_fd);
        free(v);
        return NULL;
    }

    // clear entire fb to opaque black (alpha=0xFF required by SP7021 compositor)
    uint32_t *p = (uint32_t *)v->fb_map;
    size_t total = v->map_size / 4;
    size_t i = 0;
#ifdef __ARM_NEON
    uint32x4_t vblack = vdupq_n_u32(0xFF000000);
    for (; i + 4 <= total; i += 4)
        vst1q_u32(p + i, vblack);
#endif
    for (; i < total; i++)
        p[i] = 0xFF000000;
    v->page = 0;

    RARCH_LOG("[Gemini] Video: %ux%u stride=%u virt=%u double=%s rgb32=%s\n",
              v->screen_w, v->screen_h, v->stride, v->virt_h,
              (v->virt_h >= v->screen_h * 2) ? "yes" : "no",
              v->rgb32 ? "yes" : "no");

    // we don't provide input — let RetroArch use a separate input driver
    *input      = NULL;
    *input_data = NULL;
    return v;
}

// clear a rectangle in the framebuffer to opaque black
static void clear_rect(uint32_t *buf, uint32_t stride_px,
                       unsigned x, unsigned y, unsigned w, unsigned h)
{
    for (unsigned dy = 0; dy < h; dy++) {
        uint32_t *row = buf + (y + dy) * stride_px + x;
        unsigned dx = 0;
#ifdef __ARM_NEON
        uint32x4_t vblack = vdupq_n_u32(0xFF000000);
        for (; dx + 4 <= w; dx += 4)
            vst1q_u32(row + dx, vblack);
#endif
        for (; dx < w; dx++)
            row[dx] = 0xFF000000;
    }
}

// clear only the letterbox borders around the content area
static void clear_letterbox(uint32_t *buf, uint32_t screen_w, uint32_t screen_h,
                            uint32_t stride_px,
                            unsigned off_x, unsigned off_y,
                            unsigned out_w, unsigned out_h)
{
    // top bar
    if (off_y > 0)
        clear_rect(buf, stride_px, 0, 0, screen_w, off_y);
    // bottom bar
    unsigned bot_y = off_y + out_h;
    if (bot_y < screen_h)
        clear_rect(buf, stride_px, 0, bot_y, screen_w, screen_h - bot_y);
    // left bar (between top/bottom bars)
    if (off_x > 0)
        clear_rect(buf, stride_px, 0, off_y, off_x, out_h);
    // right bar (between top/bottom bars)
    unsigned right_x = off_x + out_w;
    if (right_x < screen_w)
        clear_rect(buf, stride_px, right_x, off_y, screen_w - right_x, out_h);
}

// compute aspect-preserving output geometry
static void compute_output_geometry(unsigned dst_w, unsigned dst_h,
                                    unsigned src_w, unsigned src_h,
                                    unsigned *out_w, unsigned *out_h,
                                    unsigned *off_x, unsigned *off_y)
{
    if (src_w == 0 || src_h == 0) {
        *out_w = *out_h = *off_x = *off_y = 0;
        return;
    }
    if ((unsigned long)src_w * dst_h > (unsigned long)src_h * dst_w) {
        *out_w = dst_w;
        *out_h = src_h * dst_w / src_w;
    } else {
        *out_h = dst_h;
        *out_w = src_w * dst_h / src_h;
    }
    if (*out_w > dst_w) *out_w = dst_w;
    if (*out_h > dst_h) *out_h = dst_h;
    *off_x = (dst_w - *out_w) / 2;
    *off_y = (dst_h - *out_h) / 2;
}

static bool gemini_gfx_frame(void *data, const void *frame,
      unsigned width, unsigned height, uint64_t frame_count,
      unsigned pitch, const char *msg, video_frame_info_t *video_info)
{
    gemini_video_t *v = (gemini_video_t *)data;
    if (!v) return true;

    uint32_t *back = back_buffer(v);
    uint32_t stride_px = v->stride / 4;

    const void *src;
    unsigned src_w, src_h, src_pitch;
    bool rgb32;

    if (v->menu_active && v->menu_frame) {
        src       = v->menu_frame;
        src_w     = v->menu_w;
        src_h     = v->menu_h;
        src_pitch = v->menu_w * (v->menu_rgb32 ? 4 : 2);
        rgb32     = v->menu_rgb32;
    } else if (frame && width > 0 && height > 0) {
        src       = frame;
        src_w     = width;
        src_h     = height;
        src_pitch = pitch;
        rgb32     = v->rgb32;
    } else {
        // no content — clear entire screen
        for (size_t i = 0; i < (size_t)v->screen_h * stride_px; i++)
            back[i] = 0xFF000000;
        page_flip(v);
        return true;
    }

    unsigned out_w, out_h, off_x, off_y;
    compute_output_geometry(v->screen_w, v->screen_h, src_w, src_h,
                            &out_w, &out_h, &off_x, &off_y);

    // clear only the letterbox borders, not the content area
    clear_letterbox(back, v->screen_w, v->screen_h, stride_px,
                    off_x, off_y, out_w, out_h);

    blit_scaled(back, v->screen_w, v->screen_h, v->stride,
                src, src_w, src_h, src_pitch, rgb32);

    page_flip(v);
    return true;
}

static void gemini_gfx_set_nonblock_state(void *data, bool state,
      bool adaptive_vsync_enabled, unsigned swap_interval)
{
    // no vsync on direct framebuffer — always non-blocking
    (void)data; (void)state; (void)adaptive_vsync_enabled; (void)swap_interval;
}

static bool gemini_gfx_alive(void *data)
{
    (void)data;
    return true;
}

static bool gemini_gfx_focus(void *data)
{
    (void)data;
    return true;
}

static bool gemini_gfx_suppress_screensaver(void *data, bool enable)
{
    (void)data; (void)enable;
    return true;
}

static bool gemini_gfx_set_shader(void *data, enum rarch_shader_type type, const char *path)
{
    (void)data; (void)type; (void)path;
    return false; // no shader support on software fb
}

static void gemini_gfx_viewport_info(void *data, struct video_viewport *vp)
{
    gemini_video_t *v = (gemini_video_t *)data;
    if (!v || !vp) return;
    vp->x      = 0;
    vp->y      = 0;
    vp->width  = v->screen_w;
    vp->height = v->screen_h;
    vp->full_width  = v->screen_w;
    vp->full_height = v->screen_h;
}

static void gemini_gfx_free(void *data)
{
    gemini_video_t *v = (gemini_video_t *)data;
    if (!v) return;

    // clear screen on exit
    if (v->fb_map && v->fb_map != MAP_FAILED) {
        uint32_t *p = (uint32_t *)v->fb_map;
        size_t total = v->map_size / 4;
        size_t i = 0;
#ifdef __ARM_NEON
        uint32x4_t vblack = vdupq_n_u32(0xFF000000);
        for (; i + 4 <= total; i += 4)
            vst1q_u32(p + i, vblack);
#endif
        for (; i < total; i++)
            p[i] = 0xFF000000;
        munmap(v->fb_map, v->map_size);
    }
    if (v->fb_fd >= 0)
        close(v->fb_fd);
    free(v->menu_frame);
    free(v);
}

// poke interface — RGUI menu rendering support

static void gemini_poke_set_texture_frame(void *data, const void *frame,
      bool rgb32, unsigned width, unsigned height, float alpha)
{
    gemini_video_t *v = (gemini_video_t *)data;
    size_t size;
    void *copy;

    if (!v || !frame) return;

    size = (size_t)width * height * (rgb32 ? 4 : 2);
    copy = v->menu_frame;
    if (!copy || size > v->menu_frame_cap) {
        copy = realloc(v->menu_frame, size);
        if (!copy)
            return;
        v->menu_frame = copy;
        v->menu_frame_cap = size;
    }

    memcpy(v->menu_frame, frame, size);
    v->menu_w     = width;
    v->menu_h     = height;
    v->menu_rgb32 = rgb32;
    (void)alpha;
}

static void gemini_poke_set_texture_enable(void *data, bool enable, bool fullscreen)
{
    gemini_video_t *v = (gemini_video_t *)data;
    if (!v) return;
    v->menu_active = enable;
    (void)fullscreen; // always render menu fullscreen on this device
}

static void gemini_gfx_get_poke_interface(void *data,
      const video_poke_interface_t **iface)
{
    // designated initializers: unset pointers default to NULL
    static video_poke_interface_t poke = {
        .set_texture_frame  = gemini_poke_set_texture_frame,
        .set_texture_enable = gemini_poke_set_texture_enable,
    };
    (void)data;
    *iface = &poke;
}

video_driver_t video_gemini = {
    gemini_gfx_init,
    gemini_gfx_frame,
    gemini_gfx_set_nonblock_state,
    gemini_gfx_alive,
    gemini_gfx_focus,
    gemini_gfx_suppress_screensaver,
    NULL,                          /* has_windowed */
    gemini_gfx_set_shader,
    gemini_gfx_free,
    "gemini",
    NULL,                          /* set_viewport */
    NULL,                          /* set_rotation */
    gemini_gfx_viewport_info,
    NULL,                          /* read_viewport */
    NULL,                          /* read_frame_raw */
#ifdef HAVE_OVERLAY
    NULL,                          /* overlay_interface */
#endif
#ifdef HAVE_VIDEO_LAYOUT
    NULL,                          /* video_layout */
#endif
    gemini_gfx_get_poke_interface,
    NULL,                          /* wrap_type_to_enum */
#ifdef HAVE_GFX_WIDGETS
    NULL                           /* gfx_widgets_enabled */
#endif
};

#endif /* HAVE_GEMINI */
