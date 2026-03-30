#include "gemini.h"
#include "logo_asset.h"

#include <linux/input-event-codes.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define COLOR_BLACK 0x000000
#define COLOR_WHITE 0xF7F7F7

typedef struct {
    float x;
    float y;
    float vx;
    float vy;
    int w;
    int h;
} logo_state_t;

static gem_fb_t *g_fb;
static gem_input_t *g_input;
static int g_fb_w;
static int g_fb_h;
static bool g_running = true;
static uint32_t g_last_tick;
static logo_state_t g_logo;

static void app_cleanup(void)
{
    if (g_input) {
        gem_input_close(g_input);
        g_input = NULL;
    }
    if (g_fb) {
        gem_fb_close(g_fb);
        g_fb = NULL;
    }
    gem_system_shutdown();
}

static int clamp_i(int value, int lo, int hi)
{
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

static int logo_width(void)
{
    if (dvd_logo_width > 0)
        return (int)dvd_logo_width;
    return 320;
}

static int logo_height(void)
{
    if (dvd_logo_height > 0)
        return (int)dvd_logo_height;
    return 132;
}

static void init_logo(void)
{
    g_logo.w = logo_width();
    g_logo.h = logo_height();
    g_logo.x = (float)((g_fb_w - g_logo.w) / 2);
    g_logo.y = (float)((g_fb_h - g_logo.h) / 2);
    g_logo.vx = 420.0f;
    g_logo.vy = 276.0f;
}

static void update_logo(void)
{
    uint32_t now = gem_get_ticks_ms();
    float dt = (float)(now - g_last_tick) / 1000.0f;

    g_last_tick = now;
    if (dt <= 0.0f)
        return;
    if (dt > 0.05f)
        dt = 0.05f;

    g_logo.x += g_logo.vx * dt;
    g_logo.y += g_logo.vy * dt;

    if (g_logo.x <= 0.0f) {
        g_logo.x = 0.0f;
        g_logo.vx = -g_logo.vx;
    } else if (g_logo.x + g_logo.w >= g_fb_w) {
        g_logo.x = (float)(g_fb_w - g_logo.w);
        g_logo.vx = -g_logo.vx;
    }

    if (g_logo.y <= 0.0f) {
        g_logo.y = 0.0f;
        g_logo.vy = -g_logo.vy;
    } else if (g_logo.y + g_logo.h >= g_fb_h) {
        g_logo.y = (float)(g_fb_h - g_logo.h);
        g_logo.vy = -g_logo.vy;
    }
}

static void draw_fallback_logo(int dst_x, int dst_y)
{
    int outer_w = g_logo.w;
    int outer_h = g_logo.h;
    int text_scale = 6;
    int text_w = (int)strlen("DVD") * GEM_FONT_W * text_scale;
    int text_h = GEM_FONT_H * text_scale;

    gem_draw_fill_rounded_rect(g_fb, dst_x, dst_y, outer_w, outer_h, 28, COLOR_WHITE);
    gem_draw_rounded_rect(g_fb, dst_x, dst_y, outer_w, outer_h, 28, COLOR_WHITE);
    gem_draw_text_scaled(g_fb,
                         dst_x + (outer_w - text_w) / 2,
                         dst_y + (outer_h - text_h) / 2,
                         "DVD",
                         COLOR_BLACK,
                         text_scale);
}

static void draw_png_logo(int dst_x, int dst_y)
{
    uint32_t *pixels = gem_fb_pixels(g_fb);
    uint32_t stride_px = gem_fb_stride(g_fb) / sizeof(uint32_t);

    for (unsigned int y = 0; y < dvd_logo_height; y++) {
        int py = dst_y + (int)y;
        const uint8_t *src_row;
        uint32_t *dst_row;

        if (py < 0 || py >= g_fb_h)
            continue;

        src_row = dvd_logo_rgba + (y * dvd_logo_width * 4);
        dst_row = pixels + ((uint32_t)py * stride_px);

        for (unsigned int x = 0; x < dvd_logo_width; x++) {
            int px = dst_x + (int)x;
            const uint8_t *src = src_row + (x * 4);
            uint32_t alpha;
            uint32_t r;
            uint32_t g;
            uint32_t b;

            if (px < 0 || px >= g_fb_w)
                continue;

            alpha = src[3];
            if (!alpha)
                continue;

            r = (uint32_t)src[0] * alpha / 255U;
            g = (uint32_t)src[1] * alpha / 255U;
            b = (uint32_t)src[2] * alpha / 255U;
            dst_row[px] = 0xFF000000U | (r << 16) | (g << 8) | b;
        }
    }
}

static void render_frame(void)
{
    int dst_x = clamp_i((int)g_logo.x, 0, g_fb_w);
    int dst_y = clamp_i((int)g_logo.y, 0, g_fb_h);

    gem_fb_clear(g_fb, COLOR_BLACK);

    if (dvd_logo_width > 0 && dvd_logo_height > 0 && dvd_logo_rgba_len >= dvd_logo_width * dvd_logo_height * 4U)
        draw_png_logo(dst_x, dst_y);
    else
        draw_fallback_logo(dst_x, dst_y);

    gem_fb_flip(g_fb);
}

static void process_input(void)
{
    gem_event_t ev;

    while (gem_input_poll(g_input, &ev)) {
        switch (ev.type) {
        case GEM_EVENT_TOUCH_DOWN:
        case GEM_EVENT_MOUSE_BUTTON:
            g_running = false;
            return;
        case GEM_EVENT_KEY_DOWN:
            if (ev.key.code == KEY_ESC)
                g_running = false;
            break;
        default:
            break;
        }
    }
}

int main(void)
{
    gem_log_init();
    gem_system_init(app_cleanup);

    g_fb = gem_fb_open();
    g_input = gem_input_open();
    if (!g_fb || !g_input) {
        gem_log(GEM_LOG_ERROR, "dvdlogo: failed to initialize video/input\n");
        app_cleanup();
        return 1;
    }

    g_fb_w = (int)gem_fb_width(g_fb);
    g_fb_h = (int)gem_fb_height(g_fb);
    init_logo();
    g_last_tick = gem_get_ticks_ms();

    while (g_running) {
        process_input();
        update_logo();
        render_frame();
        gem_sleep_ms(16);
    }

    app_cleanup();
    return 0;
}
