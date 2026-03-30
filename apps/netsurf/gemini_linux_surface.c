#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <linux/input.h>

#include "libnsfb.h"
#include "libnsfb_event.h"
#include "libnsfb_plot.h"
#include "gemini.h"
#include "nsfb.h"
#include "plot.h"
#include "surface.h"

#define GEMINI_QUEUE_CAP 64

typedef struct {
    gem_fb_t *fb;
    gem_input_t *input;
    nsfb_event_t queue[GEMINI_QUEUE_CAP];
    int q_read;
    int q_write;
} gemini_surface_t;

static void queue_event(gemini_surface_t *surface, const nsfb_event_t *event)
{
    int next = (surface->q_write + 1) % GEMINI_QUEUE_CAP;

    if (next == surface->q_read) {
        return;
    }

    surface->queue[surface->q_write] = *event;
    surface->q_write = next;
}

static bool dequeue_event(gemini_surface_t *surface, nsfb_event_t *event)
{
    if (surface->q_read == surface->q_write) {
        return false;
    }

    *event = surface->queue[surface->q_read];
    surface->q_read = (surface->q_read + 1) % GEMINI_QUEUE_CAP;
    return true;
}

static enum nsfb_key_code_e map_keycode(int code)
{
    switch (code) {
    case KEY_BACKSPACE: return NSFB_KEY_BACKSPACE;
    case KEY_TAB: return NSFB_KEY_TAB;
    case KEY_ENTER: return NSFB_KEY_RETURN;
    case KEY_ESC: return NSFB_KEY_ESCAPE;
    case KEY_SPACE: return NSFB_KEY_SPACE;
    case KEY_APOSTROPHE: return NSFB_KEY_QUOTE;
    case KEY_COMMA: return NSFB_KEY_COMMA;
    case KEY_MINUS: return NSFB_KEY_MINUS;
    case KEY_DOT: return NSFB_KEY_PERIOD;
    case KEY_SLASH: return NSFB_KEY_SLASH;
    case KEY_0: return NSFB_KEY_0;
    case KEY_1: return NSFB_KEY_1;
    case KEY_2: return NSFB_KEY_2;
    case KEY_3: return NSFB_KEY_3;
    case KEY_4: return NSFB_KEY_4;
    case KEY_5: return NSFB_KEY_5;
    case KEY_6: return NSFB_KEY_6;
    case KEY_7: return NSFB_KEY_7;
    case KEY_8: return NSFB_KEY_8;
    case KEY_9: return NSFB_KEY_9;
    case KEY_SEMICOLON: return NSFB_KEY_SEMICOLON;
    case KEY_EQUAL: return NSFB_KEY_EQUALS;
    case KEY_LEFTBRACE: return NSFB_KEY_LEFTBRACKET;
    case KEY_BACKSLASH: return NSFB_KEY_BACKSLASH;
    case KEY_RIGHTBRACE: return NSFB_KEY_RIGHTBRACKET;
    case KEY_GRAVE: return NSFB_KEY_BACKQUOTE;
    case KEY_A: return NSFB_KEY_a;
    case KEY_B: return NSFB_KEY_b;
    case KEY_C: return NSFB_KEY_c;
    case KEY_D: return NSFB_KEY_d;
    case KEY_E: return NSFB_KEY_e;
    case KEY_F: return NSFB_KEY_f;
    case KEY_G: return NSFB_KEY_g;
    case KEY_H: return NSFB_KEY_h;
    case KEY_I: return NSFB_KEY_i;
    case KEY_J: return NSFB_KEY_j;
    case KEY_K: return NSFB_KEY_k;
    case KEY_L: return NSFB_KEY_l;
    case KEY_M: return NSFB_KEY_m;
    case KEY_N: return NSFB_KEY_n;
    case KEY_O: return NSFB_KEY_o;
    case KEY_P: return NSFB_KEY_p;
    case KEY_Q: return NSFB_KEY_q;
    case KEY_R: return NSFB_KEY_r;
    case KEY_S: return NSFB_KEY_s;
    case KEY_T: return NSFB_KEY_t;
    case KEY_U: return NSFB_KEY_u;
    case KEY_V: return NSFB_KEY_v;
    case KEY_W: return NSFB_KEY_w;
    case KEY_X: return NSFB_KEY_x;
    case KEY_Y: return NSFB_KEY_y;
    case KEY_Z: return NSFB_KEY_z;
    case KEY_DELETE: return NSFB_KEY_DELETE;
    case KEY_KP0: return NSFB_KEY_KP0;
    case KEY_KP1: return NSFB_KEY_KP1;
    case KEY_KP2: return NSFB_KEY_KP2;
    case KEY_KP3: return NSFB_KEY_KP3;
    case KEY_KP4: return NSFB_KEY_KP4;
    case KEY_KP5: return NSFB_KEY_KP5;
    case KEY_KP6: return NSFB_KEY_KP6;
    case KEY_KP7: return NSFB_KEY_KP7;
    case KEY_KP8: return NSFB_KEY_KP8;
    case KEY_KP9: return NSFB_KEY_KP9;
    case KEY_KPDOT: return NSFB_KEY_KP_PERIOD;
    case KEY_KPSLASH: return NSFB_KEY_KP_DIVIDE;
    case KEY_KPASTERISK: return NSFB_KEY_KP_MULTIPLY;
    case KEY_KPMINUS: return NSFB_KEY_KP_MINUS;
    case KEY_KPPLUS: return NSFB_KEY_KP_PLUS;
    case KEY_KPENTER: return NSFB_KEY_KP_ENTER;
    case KEY_KPEQUAL: return NSFB_KEY_KP_EQUALS;
    case KEY_UP: return NSFB_KEY_UP;
    case KEY_DOWN: return NSFB_KEY_DOWN;
    case KEY_RIGHT: return NSFB_KEY_RIGHT;
    case KEY_LEFT: return NSFB_KEY_LEFT;
    case KEY_INSERT: return NSFB_KEY_INSERT;
    case KEY_HOME: return NSFB_KEY_HOME;
    case KEY_END: return NSFB_KEY_END;
    case KEY_PAGEUP: return NSFB_KEY_PAGEUP;
    case KEY_PAGEDOWN: return NSFB_KEY_PAGEDOWN;
    case KEY_F1: return NSFB_KEY_F1;
    case KEY_F2: return NSFB_KEY_F2;
    case KEY_F3: return NSFB_KEY_F3;
    case KEY_F4: return NSFB_KEY_F4;
    case KEY_F5: return NSFB_KEY_F5;
    case KEY_F6: return NSFB_KEY_F6;
    case KEY_F7: return NSFB_KEY_F7;
    case KEY_F8: return NSFB_KEY_F8;
    case KEY_F9: return NSFB_KEY_F9;
    case KEY_F10: return NSFB_KEY_F10;
    case KEY_F11: return NSFB_KEY_F11;
    case KEY_F12: return NSFB_KEY_F12;
    case KEY_NUMLOCK: return NSFB_KEY_NUMLOCK;
    case KEY_CAPSLOCK: return NSFB_KEY_CAPSLOCK;
    case KEY_SCROLLLOCK: return NSFB_KEY_SCROLLOCK;
    case KEY_RIGHTSHIFT: return NSFB_KEY_RSHIFT;
    case KEY_LEFTSHIFT: return NSFB_KEY_LSHIFT;
    case KEY_RIGHTCTRL: return NSFB_KEY_RCTRL;
    case KEY_LEFTCTRL: return NSFB_KEY_LCTRL;
    case KEY_RIGHTALT: return NSFB_KEY_RALT;
    case KEY_LEFTALT: return NSFB_KEY_LALT;
    default: return NSFB_KEY_UNKNOWN;
    }
}

static enum nsfb_key_code_e map_mouse_button(int button)
{
    switch (button) {
    case BTN_LEFT: return NSFB_KEY_MOUSE_1;
    case BTN_MIDDLE: return NSFB_KEY_MOUSE_2;
    case BTN_RIGHT: return NSFB_KEY_MOUSE_3;
    case BTN_SIDE: return NSFB_KEY_MOUSE_4;
    case BTN_EXTRA: return NSFB_KEY_MOUSE_5;
    default: return NSFB_KEY_UNKNOWN;
    }
}

static void queue_key(gemini_surface_t *surface,
                      bool down,
                      enum nsfb_key_code_e keycode)
{
    nsfb_event_t event;

    if (keycode == NSFB_KEY_UNKNOWN) {
        return;
    }

    memset(&event, 0, sizeof(event));
    event.type = down ? NSFB_EVENT_KEY_DOWN : NSFB_EVENT_KEY_UP;
    event.value.keycode = keycode;
    queue_event(surface, &event);
}

static void queue_move_abs(gemini_surface_t *surface, int x, int y)
{
    nsfb_event_t event;

    memset(&event, 0, sizeof(event));
    event.type = NSFB_EVENT_MOVE_ABSOLUTE;
    event.value.vector.x = x;
    event.value.vector.y = y;
    queue_event(surface, &event);
}

static void queue_move_rel(gemini_surface_t *surface, int dx, int dy)
{
    nsfb_event_t event;

    memset(&event, 0, sizeof(event));
    event.type = NSFB_EVENT_MOVE_RELATIVE;
    event.value.vector.x = dx;
    event.value.vector.y = dy;
    queue_event(surface, &event);
}

static void gemini_pump_input(gemini_surface_t *surface)
{
    gem_event_t event;

    while (gem_input_poll(surface->input, &event)) {
        switch (event.type) {
        case GEM_EVENT_KEY_DOWN:
            queue_key(surface, true, map_keycode(event.key.code));
            break;
        case GEM_EVENT_KEY_UP:
            queue_key(surface, false, map_keycode(event.key.code));
            break;
        case GEM_EVENT_TOUCH_DOWN:
            queue_move_abs(surface, event.touch.x, event.touch.y);
            queue_key(surface, true, NSFB_KEY_MOUSE_1);
            break;
        case GEM_EVENT_TOUCH_UP:
            queue_move_abs(surface, event.touch.x, event.touch.y);
            queue_key(surface, false, NSFB_KEY_MOUSE_1);
            break;
        case GEM_EVENT_TOUCH_MOVE:
            queue_move_abs(surface, event.touch.x, event.touch.y);
            break;
        case GEM_EVENT_MOUSE_MOVE:
            queue_move_rel(surface, event.mouse_move.dx, event.mouse_move.dy);
            break;
        case GEM_EVENT_MOUSE_BUTTON:
            queue_key(surface,
                      event.mouse_button.pressed,
                      map_mouse_button(event.mouse_button.button));
            break;
        default:
            break;
        }
    }
}

static int gemini_defaults(nsfb_t *nsfb)
{
    nsfb->width = 1920;
    nsfb->height = 720;
    nsfb->format = NSFB_FMT_XRGB8888;
    select_plotters(nsfb);
    return 0;
}

static int gemini_set_geometry(nsfb_t *nsfb,
                               int width,
                               int height,
                               enum nsfb_format_e format)
{
    int old_size;
    int new_size;
    int old_width = nsfb->width;
    int old_height = nsfb->height;
    enum nsfb_format_e old_format = nsfb->format;
    uint8_t *fbptr;

    old_size = (nsfb->width * nsfb->height * nsfb->bpp) / 8;

    if (width > 0) {
        nsfb->width = width;
    }
    if (height > 0) {
        nsfb->height = height;
    }
    if (format != NSFB_FMT_ANY) {
        nsfb->format = format;
    }

    select_plotters(nsfb);

    new_size = (nsfb->width * nsfb->height * nsfb->bpp) / 8;
    fbptr = realloc(nsfb->ptr, new_size);
    if ((new_size > 0) && (fbptr == NULL)) {
        nsfb->width = old_width;
        nsfb->height = old_height;
        nsfb->format = old_format;
        select_plotters(nsfb);
        return -1;
    }

    if (new_size > old_size && fbptr != NULL) {
        memset(fbptr + old_size, 0, (size_t)(new_size - old_size));
    }

    nsfb->ptr = fbptr;
    nsfb->linelen = (nsfb->width * nsfb->bpp) / 8;
    return 0;
}

static int gemini_initialise(nsfb_t *nsfb)
{
    gemini_surface_t *surface;
    size_t size;

    gem_system_init(NULL);

    surface = calloc(1, sizeof(*surface));
    if (surface == NULL) {
        return -1;
    }

    surface->fb = gem_fb_open();
    if (surface->fb == NULL) {
        free(surface);
        gem_system_shutdown();
        return -1;
    }

    surface->input = gem_input_open();
    if (surface->input == NULL) {
        gem_fb_close(surface->fb);
        free(surface);
        gem_system_shutdown();
        return -1;
    }

    nsfb->surface_priv = surface;

    if (nsfb->width <= 0) {
        nsfb->width = (int)gem_fb_width(surface->fb);
    }
    if (nsfb->height <= 0) {
        nsfb->height = (int)gem_fb_height(surface->fb);
    }
    if (nsfb->format == NSFB_FMT_ANY) {
        nsfb->format = NSFB_FMT_XRGB8888;
    }

    select_plotters(nsfb);

    size = (size_t)((nsfb->width * nsfb->height * nsfb->bpp) / 8);
    nsfb->ptr = realloc(nsfb->ptr, size);
    if ((size > 0) && (nsfb->ptr == NULL)) {
        gem_input_close(surface->input);
        gem_fb_close(surface->fb);
        free(surface);
        nsfb->surface_priv = NULL;
        gem_system_shutdown();
        return -1;
    }

    memset(nsfb->ptr, 0, size);
    nsfb->linelen = (nsfb->width * nsfb->bpp) / 8;

    gem_fb_clear(surface->fb, 0x00000000u);
    gem_fb_flip(surface->fb);
    gem_fb_clear(surface->fb, 0x00000000u);
    return 0;
}

static int gemini_finalise(nsfb_t *nsfb)
{
    gemini_surface_t *surface = nsfb->surface_priv;

    free(nsfb->ptr);
    nsfb->ptr = NULL;

    if (surface != NULL) {
        if (surface->input != NULL) {
            gem_input_close(surface->input);
        }
        if (surface->fb != NULL) {
            gem_fb_close(surface->fb);
        }
        free(surface);
        nsfb->surface_priv = NULL;
    }

    gem_system_shutdown();
    return 0;
}

static bool gemini_input(nsfb_t *nsfb, nsfb_event_t *event, int timeout)
{
    gemini_surface_t *surface = nsfb->surface_priv;
    uint32_t start;

    if (surface == NULL || event == NULL) {
        return false;
    }

    if (dequeue_event(surface, event)) {
        return true;
    }

    start = gem_get_ticks_ms();

    for (;;) {
        gemini_pump_input(surface);
        if (dequeue_event(surface, event)) {
            return true;
        }
        if (timeout == 0) {
            return false;
        }
        if (timeout > 0) {
            uint32_t now = gem_get_ticks_ms();
            if ((uint32_t)(now - start) >= (uint32_t)timeout) {
                return false;
            }
        }
        gem_sleep_ms(5);
    }
}

static int gemini_claim(nsfb_t *nsfb, nsfb_bbox_t *box)
{
    (void)nsfb;
    (void)box;
    return 0;
}

static int gemini_update(nsfb_t *nsfb, nsfb_bbox_t *box)
{
    gemini_surface_t *surface = nsfb->surface_priv;
    uint32_t *dst;
    uint32_t stride_px;
    int y;

    (void)box;

    if (surface == NULL || surface->fb == NULL || nsfb->ptr == NULL) {
        return -1;
    }

    dst = gem_fb_pixels(surface->fb);
    if (dst == NULL) {
        return -1;
    }

    stride_px = gem_fb_stride(surface->fb) / sizeof(uint32_t);
    for (y = 0; y < nsfb->height; y++) {
        memcpy(dst + (size_t)y * stride_px,
               nsfb->ptr + (size_t)y * (size_t)nsfb->linelen,
               (size_t)nsfb->width * sizeof(uint32_t));
    }

    gem_fb_flip(surface->fb);
    return 0;
}

static const nsfb_surface_rtns_t gemini_rtns = {
    .defaults = gemini_defaults,
    .initialise = gemini_initialise,
    .finalise = gemini_finalise,
    .geometry = gemini_set_geometry,
    .input = gemini_input,
    .claim = gemini_claim,
    .update = gemini_update,
};

NSFB_SURFACE_DEF(linux, NSFB_SURFACE_LINUX, &gemini_rtns)
