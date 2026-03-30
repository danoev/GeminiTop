// gemini_draw.c — drawing primitives (text, rect, bar) via 8x16 bitmap font
//
// Known-good libgemini rendering path for the SP7021 framebuffer hijack setup.
// Keep this simple software renderer predictable and low-overhead unless a
// replacement is tested on the device.

#include "gemini.h"
#include "font_8x16.h"

#include <string.h>

#ifdef __ARM_NEON
#include <arm_neon.h>
#endif

static inline int clamp_i(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

void gem_draw_fill_rect(gem_fb_t *fb, int x, int y, int w, int h, uint32_t color)
{
    if (!fb) return;
    color |= 0xFF000000;

    uint32_t *pixels = gem_fb_pixels(fb);
    uint32_t stride = gem_fb_stride(fb);
    int fb_w = (int)gem_fb_width(fb);
    int fb_h = (int)gem_fb_height(fb);
    if (!pixels) return;

    int x0 = clamp_i(x, 0, fb_w);
    int y0 = clamp_i(y, 0, fb_h);
    int x1 = clamp_i(x + w, 0, fb_w);
    int y1 = clamp_i(y + h, 0, fb_h);

    uint32_t stride_px = stride / sizeof(uint32_t);
    for (int py = y0; py < y1; py++) {
        uint32_t *row = pixels + py * stride_px;
        int px = x0;
#ifdef __ARM_NEON
        uint32x4_t vc = vdupq_n_u32(color);
        for (; px + 4 <= x1; px += 4)
            vst1q_u32(row + px, vc);
#endif
        for (; px < x1; px++)
            row[px] = color;
    }
}

void gem_draw_rect(gem_fb_t *fb, int x, int y, int w, int h, uint32_t color)
{
    gem_draw_fill_rect(fb, x, y, w, 1, color);
    gem_draw_fill_rect(fb, x, y + h - 1, w, 1, color);
    gem_draw_fill_rect(fb, x, y, 1, h, color);
    gem_draw_fill_rect(fb, x + w - 1, y, 1, h, color);
}

static inline void put_pixel(int px, int py, uint32_t color,
                             uint32_t *pixels, uint32_t stride_px, int fb_w, int fb_h)
{
    if (px >= 0 && px < fb_w && py >= 0 && py < fb_h)
        pixels[py * stride_px + px] = color;
}

static void hline(uint32_t *pixels, uint32_t stride_px, int fb_w, int fb_h,
                  int x0, int x1, int y, uint32_t color)
{
    if (y < 0 || y >= fb_h) return;
    if (x0 < 0) x0 = 0;
    if (x1 >= fb_w) x1 = fb_w - 1;
    uint32_t *row = pixels + y * stride_px;
    int x = x0;
#ifdef __ARM_NEON
    uint32x4_t vc = vdupq_n_u32(color);
    for (; x + 4 <= x1; x += 4)
        vst1q_u32(row + x, vc);
#endif
    for (; x <= x1; x++)
        row[x] = color;
}

void gem_draw_fill_rounded_rect(gem_fb_t *fb, int x, int y, int w, int h, int r, uint32_t color)
{
    if (!fb || w <= 0 || h <= 0) return;
    color |= 0xFF000000;
    if (r < 0) r = 0;
    if (r > w / 2) r = w / 2;
    if (r > h / 2) r = h / 2;

    uint32_t *pixels = gem_fb_pixels(fb);
    uint32_t stride_px = gem_fb_stride(fb) / sizeof(uint32_t);
    int fb_w = (int)gem_fb_width(fb);
    int fb_h = (int)gem_fb_height(fb);
    if (!pixels) return;

    // Center rectangle (full width, excluding corner rows)
    for (int py = y + r; py < y + h - r; py++)
        hline(pixels, stride_px, fb_w, fb_h, x, x + w - 1, py, color);

    // Rounded corners using midpoint circle
    int cx1 = x + r, cy1 = y + r;
    int cx2 = x + w - 1 - r;
    int cx3 = x + r, cy3 = y + h - 1 - r;
    int cx4 = x + w - 1 - r;

    int px = 0, py = r, d = 1 - r;
    while (px <= py) {
        hline(pixels, stride_px, fb_w, fb_h, cx1 - py, cx2 + py, cy1 - px, color);
        hline(pixels, stride_px, fb_w, fb_h, cx1 - px, cx2 + px, cy1 - py, color);
        hline(pixels, stride_px, fb_w, fb_h, cx3 - py, cx4 + py, cy3 + px, color);
        hline(pixels, stride_px, fb_w, fb_h, cx3 - px, cx4 + px, cy3 + py, color);

        px++;
        if (d < 0) {
            d += 2 * px + 1;
        } else {
            py--;
            d += 2 * (px - py) + 1;
        }
    }
}

void gem_draw_rounded_rect(gem_fb_t *fb, int x, int y, int w, int h, int r, uint32_t color)
{
    if (!fb || w <= 0 || h <= 0) return;
    color |= 0xFF000000;
    if (r < 0) r = 0;
    if (r > w / 2) r = w / 2;
    if (r > h / 2) r = h / 2;

    uint32_t *pixels = gem_fb_pixels(fb);
    uint32_t stride_px = gem_fb_stride(fb) / sizeof(uint32_t);
    int fb_w = (int)gem_fb_width(fb);
    int fb_h = (int)gem_fb_height(fb);
    if (!pixels) return;

    // Straight edges
    gem_draw_fill_rect(fb, x + r, y, w - 2 * r, 1, color);
    gem_draw_fill_rect(fb, x + r, y + h - 1, w - 2 * r, 1, color);
    gem_draw_fill_rect(fb, x, y + r, 1, h - 2 * r, color);
    gem_draw_fill_rect(fb, x + w - 1, y + r, 1, h - 2 * r, color);

    // Corner arcs
    int cx1 = x + r, cy1 = y + r;
    int cx2 = x + w - 1 - r;
    int cx3 = x + r, cy3 = y + h - 1 - r;
    int cx4 = x + w - 1 - r;

    int px = 0, py = r, d = 1 - r;
    while (px <= py) {
        put_pixel(cx1 - px, cy1 - py, color, pixels, stride_px, fb_w, fb_h);
        put_pixel(cx1 - py, cy1 - px, color, pixels, stride_px, fb_w, fb_h);
        put_pixel(cx2 + px, cy1 - py, color, pixels, stride_px, fb_w, fb_h);
        put_pixel(cx2 + py, cy1 - px, color, pixels, stride_px, fb_w, fb_h);
        put_pixel(cx3 - px, cy3 + py, color, pixels, stride_px, fb_w, fb_h);
        put_pixel(cx3 - py, cy3 + px, color, pixels, stride_px, fb_w, fb_h);
        put_pixel(cx4 + px, cy3 + py, color, pixels, stride_px, fb_w, fb_h);
        put_pixel(cx4 + py, cy3 + px, color, pixels, stride_px, fb_w, fb_h);
        px++;
        if (d < 0) {
            d += 2 * px + 1;
        } else {
            py--;
            d += 2 * (px - py) + 1;
        }
    }
}

int gem_draw_char(gem_fb_t *fb, int x, int y, char ch, uint32_t color)
{
    if (!fb) return FONT_W;
    color |= 0xFF000000;

    uint32_t *pixels = gem_fb_pixels(fb);
    uint32_t stride = gem_fb_stride(fb);
    int fb_w = (int)gem_fb_width(fb);
    int fb_h = (int)gem_fb_height(fb);
    if (!pixels) return FONT_W;

    uint32_t stride_px = stride / sizeof(uint32_t);

    int idx = (unsigned char)ch - 0x20;
    if (idx < 0 || idx >= 96) idx = 0;

    for (int row = 0; row < FONT_H; row++) {
        int py = y + row;
        if (py < 0 || py >= fb_h) continue;
        uint8_t bits = font_data[idx][row];
        for (int col = 0; col < FONT_W; col++) {
            if (bits & (0x80 >> col)) {
                int px = x + col;
                if (px >= 0 && px < fb_w)
                    pixels[py * stride_px + px] = color;
            }
        }
    }
    return FONT_W;
}

int gem_draw_text(gem_fb_t *fb, int x, int y, const char *text, uint32_t color)
{
    int start_x = x;
    while (*text) {
        gem_draw_char(fb, x, y, *text, color);
        x += FONT_W;
        text++;
    }
    return x - start_x;
}

int gem_draw_text_scaled(gem_fb_t *fb, int x, int y, const char *text,
                         uint32_t color, int scale)
{
    if (!fb || scale <= 0) return 0;
    color |= 0xFF000000;

    uint32_t *pixels = gem_fb_pixels(fb);
    uint32_t stride = gem_fb_stride(fb);
    int fb_w = (int)gem_fb_width(fb);
    int fb_h = (int)gem_fb_height(fb);
    if (!pixels) return 0;

    uint32_t stride_px = stride / sizeof(uint32_t);
    int start_x = x;

    while (*text) {
        int idx = (unsigned char)*text - 0x20;
        if (idx < 0 || idx >= 96) idx = 0;

        for (int row = 0; row < FONT_H; row++) {
            uint8_t bits = font_data[idx][row];
            for (int col = 0; col < FONT_W; col++) {
                if (bits & (0x80 >> col)) {
                    for (int sy = 0; sy < scale; sy++) {
                        int py = y + row * scale + sy;
                        if (py < 0 || py >= fb_h) continue;
                        for (int sx = 0; sx < scale; sx++) {
                            int px = x + col * scale + sx;
                            if (px >= 0 && px < fb_w)
                                pixels[py * stride_px + px] = color;
                        }
                    }
                }
            }
        }
        x += FONT_W * scale;
        text++;
    }
    return x - start_x;
}

void gem_draw_bar(gem_fb_t *fb, int x, int y, int w, int h,
                  float fraction, uint32_t fg, uint32_t bg)
{
    if (fraction < 0.0f) fraction = 0.0f;
    if (fraction > 1.0f) fraction = 1.0f;

    int fill_w = (int)(w * fraction);

    gem_draw_fill_rect(fb, x, y, w, h, bg);
    if (fill_w > 0)
        gem_draw_fill_rect(fb, x, y, fill_w, h, fg);
}
