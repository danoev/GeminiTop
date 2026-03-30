/*
Copyright (C) 1996-1997 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/

#include "cmd.h"
#include "common.h"
#include "console.h"
#include "d_iface.h"
#include "d_local.h"
#include "draw.h"
#include "input.h"
#include "keys.h"
#include "menu.h"
#include "quakedef.h"
#include "render.h"
#include "screen.h"
#include "sound.h"
#include "sys.h"
#include "vid.h"
#include "zone.h"

#ifdef NQ_HACK
#include "host.h"
#endif
#ifdef QW_HACK
#include "client.h"
#endif

#include <linux/input-event-codes.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "gemini.h"

unsigned short d_8to16table[256];
unsigned d_8to24table[256];
viddef_t vid;

static gem_fb_t *gem_fb;
static gem_input_t *gem_input;
static qboolean gem_system_ready;
static qboolean gem_atexit_registered;
static qboolean palette_changed;

static byte *vid_surfcache;
static int vid_surfcachesize;
static int vid_highhunkmark;

static int *vid_scale_x;
static int *vid_scale_y;
static qboolean vid_clear_pending;

static int gem_view_x;
static int gem_view_y;
static int gem_view_width;
static int gem_view_height;

extern void IN_Gemini_AddMouseMotion(int dx, int dy);

static void
VID_Gemini_FreeBuffers(void)
{
    if (vid_scale_x) {
        free(vid_scale_x);
        vid_scale_x = NULL;
    }
    if (vid_scale_y) {
        free(vid_scale_y);
        vid_scale_y = NULL;
    }

    if (d_pzbuffer) {
        D_FlushCaches();
        Hunk_FreeToHighMark(vid_highhunkmark);
        d_pzbuffer = NULL;
    }
}

static void
VID_Gemini_ClosePlatform(void)
{
    if (gem_input) {
        gem_input_close(gem_input);
        gem_input = NULL;
    }
    if (gem_fb) {
        gem_fb_close(gem_fb);
        gem_fb = NULL;
    }
}

static void
VID_Gemini_Cleanup(void)
{
    VID_Gemini_FreeBuffers();
    VID_Gemini_ClosePlatform();
}

static void
VID_Gemini_AtExit(void)
{
    VID_Gemini_Cleanup();
    if (gem_system_ready) {
        gem_system_shutdown();
        gem_system_ready = false;
    }
}

static void
VID_Gemini_EnsureSystem(void)
{
    if (!gem_system_ready) {
        gem_system_init(VID_Gemini_Cleanup);
        gem_system_ready = true;
    }

    if (!gem_atexit_registered) {
        atexit(VID_Gemini_AtExit);
        gem_atexit_registered = true;
    }
}

static void
VID_Gemini_EnsurePlatform(void)
{
    VID_Gemini_EnsureSystem();

    if (!gem_fb) {
        gem_fb = gem_fb_open();
        if (!gem_fb)
            Sys_Error("GEMINI: unable to open framebuffer");
    }

    if (!gem_input) {
        gem_input = gem_input_open();
        if (!gem_input)
            Con_Printf("GEMINI: input unavailable, continuing without keyboard/mouse.\n");
    }
}

static int
VID_Gemini_ToRGB565(unsigned r, unsigned g, unsigned b)
{
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
}

void
VID_GetDesktopRect(vrect_t *rect)
{
    VID_Gemini_EnsurePlatform();

    rect->x = 0;
    rect->y = 0;
    rect->width = (int)gem_fb_width(gem_fb);
    rect->height = (int)gem_fb_height(gem_fb);
}

void
VID_SetPalette(const byte *palette)
{
    unsigned i;

    for (i = 0; i < 256; i++) {
        const unsigned r = palette[0];
        const unsigned g = palette[1];
        const unsigned b = palette[2];
        palette += 3;

        d_8to16table[i] = VID_Gemini_ToRGB565(r, g, b);
        d_8to24table[i] = 0xFF000000u | (r) | (g << 8) | (b << 16);
    }

    palette_changed = true;
}

void
VID_ShiftPalette(const byte *palette)
{
    VID_SetPalette(palette);
}

void
VID_InitColormap(const byte *palette)
{
    vid.colormap = host_colormap;
    vid.fullbright = 256 - LittleLong(*((int *)vid.colormap + 2048));
    VID_SetPalette(palette);
}

void
VID_SetDefaultMode(void)
{
}

static void
VID_Gemini_InitModeList(void)
{
    if (!vid_modelist) {
        vid_modelist = Hunk_HighAllocName(sizeof(*vid_modelist), "vidmodes");
    }

    memset(&vid_windowed_mode, 0, sizeof(vid_windowed_mode));
    vid_windowed_mode.width = 960;
    vid_windowed_mode.height = 720;
    vid_windowed_mode.bpp = 32;
    vid_windowed_mode.refresh = 60;
    vid_windowed_mode.min_scale = 1;
    vid_windowed_mode.resolution.scale = 0;
    vid_windowed_mode.resolution.width = 320;
    vid_windowed_mode.resolution.height = 240;

    if (vid_modelist) {
        vid_modelist[0] = vid_windowed_mode;
        vid_nummodes = 1;
    }
}

qboolean
VID_CheckAdequateMem(int width, int height)
{
    int tbuffersize;

    tbuffersize = width * height * (int)sizeof(*d_pzbuffer);
    tbuffersize += D_SurfaceCacheForRes(width, height);

    if ((host_parms.memsize - tbuffersize + SURFCACHE_SIZE_AT_320X200 + 0x10000 * 3) < minimum_memory)
        return false;

    return true;
}

static qboolean
VID_Gemini_AllocBuffers(int width, int height)
{
    const int tsize = D_SurfaceCacheForRes(width, height);
    const int tbuffersize = width * height * (int)sizeof(*d_pzbuffer) + tsize;

    if ((host_parms.memsize - tbuffersize + SURFCACHE_SIZE_AT_320X200 + 0x10000 * 3) < minimum_memory) {
        Con_SafePrintf("Not enough memory for video mode\n");
        return false;
    }

    VID_Gemini_FreeBuffers();

    vid_surfcachesize = tsize;
    vid_highhunkmark = Hunk_HighMark();
    d_pzbuffer = Hunk_HighAllocName(tbuffersize, "video");
    vid_surfcache = (byte *)d_pzbuffer + width * height * (int)sizeof(*d_pzbuffer);
    r_warpbuffer = Hunk_HighAllocName(width * height, "warpbuf");

    vid.buffer = vid.conbuffer = vid.direct = Hunk_HighAllocName(width * height, "vidbuf");
    vid.rowbytes = vid.conrowbytes = width;

    vid_scale_x = calloc((size_t)gem_view_width, sizeof(*vid_scale_x));
    vid_scale_y = calloc((size_t)gem_view_height, sizeof(*vid_scale_y));
    if (!vid_scale_x || !vid_scale_y) {
        VID_Gemini_FreeBuffers();
        Con_SafePrintf("Not enough memory for scale tables\n");
        return false;
    }

    for (int x = 0; x < gem_view_width; x++)
        vid_scale_x[x] = (x * width) / gem_view_width;
    for (int y = 0; y < gem_view_height; y++)
        vid_scale_y[y] = (y * height) / gem_view_height;

    R_AllocSurfEdges(false);
    return true;
}

static void
VID_Gemini_UpdateViewport(const qvidmode_t *mode)
{
    const int fb_width = (int)gem_fb_width(gem_fb);
    const int fb_height = (int)gem_fb_height(gem_fb);

    gem_view_width = qmin(mode->width, fb_width);
    gem_view_height = qmin(mode->height, fb_height);
    gem_view_x = (fb_width - gem_view_width) / 2;
    gem_view_y = (fb_height - gem_view_height) / 2;
    vid_clear_pending = true;
}

qboolean
window_visible(void)
{
    return true;
}

qboolean
VID_SetMode(const qvidmode_t *mode, const byte *palette)
{
    VID_Gemini_EnsurePlatform();

    if (!VID_CheckAdequateMem(mode->resolution.scale ? mode->width / mode->resolution.scale : mode->resolution.width,
                              mode->resolution.scale ? mode->height / mode->resolution.scale : mode->resolution.height)) {
        return false;
    }

    VID_Gemini_UpdateViewport(mode);
    VID_SetPalette(palette);
    VID_InitColormap(palette);
    VID_Mode_SetupViddef(mode, &vid);

    vid.numpages = 1;
    vid.aspect = 1.0f;
    vid.stretchblit = false;

    if (!VID_Gemini_AllocBuffers(vid.width, vid.height))
        return false;

    D_InitCaches(vid_surfcache, vid_surfcachesize);

    vid_currentmode = mode;
    vid.recalc_refdef = 1;
    palette_changed = true;

    SCR_CheckResize();
    Con_CheckResize();

    return true;
}

static void
VID_Gemini_Blit(void)
{
    uint32_t *dst;
    const int src_w = vid.width;
    const int stride_pixels = (int)(gem_fb_stride(gem_fb) / sizeof(uint32_t));
    const uint32_t *palette = d_8to24table;

    dst = gem_fb_pixels(gem_fb);
    if (!dst)
        return;

    if (vid_clear_pending) {
        gem_fb_clear(gem_fb, 0x00000000);
        vid_clear_pending = false;
        dst = gem_fb_pixels(gem_fb);
        if (!dst)
            return;
    }

    for (int y = 0; y < gem_view_height; y++) {
        const byte *src_row = vid.buffer + vid_scale_y[y] * src_w;
        uint32_t *dst_row = dst + (gem_view_y + y) * stride_pixels + gem_view_x;

        for (int x = 0; x < gem_view_width; x++) {
            dst_row[x] = palette[src_row[vid_scale_x[x]]];
        }
    }

    gem_fb_flip(gem_fb);
}

void
VID_Update(vrect_t *rects)
{
    (void)rects;

    if (!gem_fb || !vid.buffer || !vid_scale_x || !vid_scale_y)
        return;

    VID_Gemini_Blit();
    palette_changed = false;
}

void
D_BeginDirectRect(int x, int y, const byte *pbitmap, int width, int height)
{
    (void)x;
    (void)y;
    (void)pbitmap;
    (void)width;
    (void)height;
}

void
D_EndDirectRect(int x, int y, int width, int height)
{
    (void)x;
    (void)y;
    (void)width;
    (void)height;
}

void
VID_LockBuffer(void)
{
}

void
VID_UnlockBuffer(void)
{
}

void
VID_RegisterVariables(void)
{
}

void
VID_AddCommands(void)
{
}

static knum_t
VID_Gemini_TranslateKey(int code)
{
    switch (code) {
    case KEY_1: return K_1;
    case KEY_2: return K_2;
    case KEY_3: return K_3;
    case KEY_4: return K_4;
    case KEY_5: return K_5;
    case KEY_6: return K_6;
    case KEY_7: return K_7;
    case KEY_8: return K_8;
    case KEY_9: return K_9;
    case KEY_0: return K_0;
    case KEY_BACKSPACE: return K_BACKSPACE;
    case KEY_TAB: return K_TAB;
    case KEY_ENTER: return K_ENTER;
    case KEY_KPENTER: return K_KP_ENTER;
    case KEY_ESC: return K_ESCAPE;
    case KEY_SPACE: return K_SPACE;
    case KEY_MINUS: return K_MINUS;
    case KEY_EQUAL: return K_EQUALS;
    case KEY_LEFTBRACE: return K_LEFTBRACKET;
    case KEY_RIGHTBRACE: return K_RIGHTBRACKET;
    case KEY_BACKSLASH: return K_BACKSLASH;
    case KEY_102ND: return K_BACKSLASH;
    case KEY_SEMICOLON: return K_SEMICOLON;
    case KEY_APOSTROPHE: return K_QUOTE;
    case KEY_GRAVE: return K_BACKQUOTE;
    case KEY_COMMA: return K_COMMA;
    case KEY_DOT: return K_PERIOD;
    case KEY_SLASH: return K_SLASH;
    case KEY_KPASTERISK: return K_KP_MULTIPLY;
    case KEY_KPSLASH: return K_KP_DIVIDE;
    case KEY_KPMINUS: return K_KP_MINUS;
    case KEY_KPPLUS: return K_KP_PLUS;
    case KEY_KPEQUAL: return K_KP_EQUALS;
    case KEY_KP0: return K_KP0;
    case KEY_KP1: return K_KP1;
    case KEY_KP2: return K_KP2;
    case KEY_KP3: return K_KP3;
    case KEY_KP4: return K_KP4;
    case KEY_KP5: return K_KP5;
    case KEY_KP6: return K_KP6;
    case KEY_KP7: return K_KP7;
    case KEY_KP8: return K_KP8;
    case KEY_KP9: return K_KP9;
    case KEY_KPDOT: return K_KP_PERIOD;
    case KEY_UP: return K_UPARROW;
    case KEY_DOWN: return K_DOWNARROW;
    case KEY_LEFT: return K_LEFTARROW;
    case KEY_RIGHT: return K_RIGHTARROW;
    case KEY_INSERT: return K_INS;
    case KEY_DELETE: return K_DEL;
    case KEY_HOME: return K_HOME;
    case KEY_END: return K_END;
    case KEY_PAGEUP: return K_PGUP;
    case KEY_PAGEDOWN: return K_PGDN;
    case KEY_NUMLOCK: return K_NUMLOCK;
    case KEY_SCROLLLOCK: return K_SCROLLOCK;
    case KEY_CAPSLOCK: return K_CAPSLOCK;
    case KEY_SYSRQ: return K_SYSREQ;
    case KEY_PAUSE: return K_PAUSE;
    case KEY_F1: return K_F1;
    case KEY_F2: return K_F2;
    case KEY_F3: return K_F3;
    case KEY_F4: return K_F4;
    case KEY_F5: return K_F5;
    case KEY_F6: return K_F6;
    case KEY_F7: return K_F7;
    case KEY_F8: return K_F8;
    case KEY_F9: return K_F9;
    case KEY_F10: return K_F10;
    case KEY_F11: return K_F11;
    case KEY_F12: return K_F12;
    case KEY_F13: return K_F13;
    case KEY_F14: return K_F14;
    case KEY_F15: return K_F15;
    case KEY_LEFTSHIFT: return K_LSHIFT;
    case KEY_RIGHTSHIFT: return K_RSHIFT;
    case KEY_LEFTCTRL: return K_LCTRL;
    case KEY_RIGHTCTRL: return K_RCTRL;
    case KEY_LEFTALT: return K_LALT;
    case KEY_RIGHTALT: return K_RALT;
    case KEY_LEFTMETA: return K_LMETA;
    case KEY_RIGHTMETA: return K_RMETA;
    case KEY_COMPOSE: return K_COMPOSE;
    case KEY_HELP: return K_HELP;
    case KEY_MENU: return K_MENU;
    case KEY_POWER: return K_POWER;
    case KEY_UNDO: return K_UNDO;
    /* Letters: Linux KEY_* follow QWERTY layout, NOT alphabetical order,
       so each must be mapped individually (KEY_A=30, KEY_S=31, KEY_D=32...) */
    case KEY_Q: return K_q;
    case KEY_W: return K_w;
    case KEY_E: return K_e;
    case KEY_R: return K_r;
    case KEY_T: return K_t;
    case KEY_Y: return K_y;
    case KEY_U: return K_u;
    case KEY_I: return K_i;
    case KEY_O: return K_o;
    case KEY_P: return K_p;
    case KEY_A: return K_a;
    case KEY_S: return K_s;
    case KEY_D: return K_d;
    case KEY_F: return K_f;
    case KEY_G: return K_g;
    case KEY_H: return K_h;
    case KEY_J: return K_j;
    case KEY_K: return K_k;
    case KEY_L: return K_l;
    case KEY_Z: return K_z;
    case KEY_X: return K_x;
    case KEY_C: return K_c;
    case KEY_V: return K_v;
    case KEY_B: return K_b;
    case KEY_N: return K_n;
    case KEY_M: return K_m;
    default:
        break;
    }

    return K_UNKNOWN;
}

static knum_t
VID_Gemini_TranslateMouseButton(int button)
{
    switch (button) {
    case BTN_LEFT: return K_MOUSE1;
    case BTN_RIGHT: return K_MOUSE2;
    case BTN_MIDDLE: return K_MOUSE3;
    case BTN_SIDE: return K_MOUSE4;
    case BTN_EXTRA: return K_MOUSE5;
    case BTN_FORWARD: return K_MOUSE6;
    case BTN_BACK: return K_MOUSE7;
    case BTN_TASK: return K_MOUSE8;
    default:
        return K_UNKNOWN;
    }
}

void
VID_ProcessEvents(void)
{
    gem_event_t event;

    if (!gem_input)
        return;

    while (gem_input_poll(gem_input, &event)) {
        switch (event.type) {
        case GEM_EVENT_KEY_DOWN:
        case GEM_EVENT_KEY_UP: {
            const knum_t key = VID_Gemini_TranslateKey(event.key.code);
            if (key != K_UNKNOWN)
                Key_Event(key, event.type == GEM_EVENT_KEY_DOWN);
            break;
        }
        case GEM_EVENT_MOUSE_MOVE:
            IN_Gemini_AddMouseMotion(event.mouse_move.dx, event.mouse_move.dy);
            break;
        case GEM_EVENT_MOUSE_BUTTON: {
            const knum_t key = VID_Gemini_TranslateMouseButton(event.mouse_button.button);
            if (key != K_UNKNOWN)
                Key_Event(key, event.mouse_button.pressed);
            break;
        }
        default:
            break;
        }
    }

    IN_Commands();
}

void
VID_Init(const byte *palette)
{
    const qvidmode_t *mode;

    VID_Gemini_EnsurePlatform();
    VID_Gemini_InitModeList();
    VID_LoadConfig();

    mode = VID_GetCmdlineMode();
    if (!mode)
        mode = VID_GetModeFromCvars();
    if (!mode)
        mode = &vid_windowed_mode;

    if (!VID_SetMode(mode, palette))
        Sys_Error("GEMINI: failed to set video mode");

    vid_menudrawfn = VID_MenuDraw;
    vid_menukeyfn = VID_MenuKey;
    vsync_available = false;
    adaptive_vsync_available = false;
}

void
VID_Shutdown(void)
{
    VID_Gemini_FreeBuffers();
    VID_Gemini_ClosePlatform();
}

#ifndef _WIN32
void
Sys_SendKeyEvents(void)
{
    VID_ProcessEvents();
}
#endif
