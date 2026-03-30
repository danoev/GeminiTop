#include "SDL_config.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "SDL_video.h"
#include "SDL_mouse.h"
#include "../SDL_sysvideo.h"
#include "../SDL_pixels_c.h"
#include "../../events/SDL_events_c.h"

#include "SDL_nullvideo.h"
#include "SDL_nullevents_c.h"

#define DUMMYVID_DRIVER_NAME "dummy"

static int g_system_init = 0;
static gem_fb_t *g_cleanup_fb = NULL;
static gem_input_t *g_cleanup_input = NULL;

static int DUMMY_VideoInit(_THIS, SDL_PixelFormat *vformat);
static SDL_Rect **DUMMY_ListModes(_THIS, SDL_PixelFormat *format, Uint32 flags);
static SDL_Surface *DUMMY_SetVideoMode(_THIS, SDL_Surface *current, int width, int height, int bpp, Uint32 flags);
static int DUMMY_SetColors(_THIS, int firstcolor, int ncolors, SDL_Color *colors);
static void DUMMY_VideoQuit(_THIS);
static int DUMMY_AllocHWSurface(_THIS, SDL_Surface *surface);
static int DUMMY_LockHWSurface(_THIS, SDL_Surface *surface);
static void DUMMY_UnlockHWSurface(_THIS, SDL_Surface *surface);
static void DUMMY_FreeHWSurface(_THIS, SDL_Surface *surface);
static void DUMMY_UpdateRects(_THIS, int numrects, SDL_Rect *rects);

static void gemini_process_cleanup(void)
{
    if (g_cleanup_input) {
        gem_input_close(g_cleanup_input);
        g_cleanup_input = NULL;
    }
    if (g_cleanup_fb) {
        gem_fb_close(g_cleanup_fb);
        g_cleanup_fb = NULL;
    }
    if (g_system_init) {
        gem_system_shutdown();
        g_system_init = 0;
    }
}

static void gemini_signal_cleanup(void)
{
    if (g_cleanup_input) {
        gem_input_close(g_cleanup_input);
        g_cleanup_input = NULL;
    }
    if (g_cleanup_fb) {
        gem_fb_close(g_cleanup_fb);
        g_cleanup_fb = NULL;
    }
}

static void ensure_system_initialized(void)
{
    if (!g_system_init) {
        gem_system_init(gemini_signal_cleanup);
        atexit(gemini_process_cleanup);
        g_system_init = 1;
    }
}

static int DUMMY_Available(void)
{
    const char *envr = SDL_getenv("SDL_VIDEODRIVER");
    return envr && (SDL_strcmp(envr, DUMMYVID_DRIVER_NAME) == 0);
}

static void DUMMY_DeleteDevice(SDL_VideoDevice *device)
{
    SDL_free(device->hidden);
    SDL_free(device);
}

static SDL_VideoDevice *DUMMY_CreateDevice(int devindex)
{
    SDL_VideoDevice *device;

    device = (SDL_VideoDevice *)SDL_malloc(sizeof(SDL_VideoDevice));
    if (device) {
        SDL_memset(device, 0, sizeof(*device));
        device->hidden = (struct SDL_PrivateVideoData *)SDL_malloc(sizeof(*device->hidden));
    }
    if ((device == NULL) || (device->hidden == NULL)) {
        SDL_OutOfMemory();
        if (device)
            SDL_free(device);
        return 0;
    }
    SDL_memset(device->hidden, 0, sizeof(*device->hidden));

    device->VideoInit = DUMMY_VideoInit;
    device->ListModes = DUMMY_ListModes;
    device->SetVideoMode = DUMMY_SetVideoMode;
    device->CreateYUVOverlay = NULL;
    device->SetColors = DUMMY_SetColors;
    device->UpdateRects = DUMMY_UpdateRects;
    device->VideoQuit = DUMMY_VideoQuit;
    device->AllocHWSurface = DUMMY_AllocHWSurface;
    device->CheckHWBlit = NULL;
    device->FillHWRect = NULL;
    device->SetHWColorKey = NULL;
    device->SetHWAlpha = NULL;
    device->LockHWSurface = DUMMY_LockHWSurface;
    device->UnlockHWSurface = DUMMY_UnlockHWSurface;
    device->FlipHWSurface = NULL;
    device->FreeHWSurface = DUMMY_FreeHWSurface;
    device->SetCaption = NULL;
    device->SetIcon = NULL;
    device->IconifyWindow = NULL;
    device->GrabInput = NULL;
    device->GetWMInfo = NULL;
    device->InitOSKeymap = DUMMY_InitOSKeymap;
    device->PumpEvents = DUMMY_PumpEvents;
    device->free = DUMMY_DeleteDevice;

    return device;
}

VideoBootStrap DUMMY_bootstrap = {
    DUMMYVID_DRIVER_NAME, "Gemini SDL video driver",
    DUMMY_Available, DUMMY_CreateDevice
};

static void update_blit_rect(_THIS)
{
    if (this->hidden->w <= 0 || this->hidden->h <= 0 ||
        this->hidden->fb_w <= 0 || this->hidden->fb_h <= 0) {
        this->hidden->blit_x = 0;
        this->hidden->blit_y = 0;
        this->hidden->blit_w = 0;
        this->hidden->blit_h = 0;
        return;
    }

    if ((this->hidden->w * this->hidden->fb_h) > (this->hidden->h * this->hidden->fb_w)) {
        this->hidden->blit_w = this->hidden->fb_w;
        this->hidden->blit_h = (this->hidden->fb_w * this->hidden->h) / this->hidden->w;
    } else {
        this->hidden->blit_h = this->hidden->fb_h;
        this->hidden->blit_w = (this->hidden->fb_h * this->hidden->w) / this->hidden->h;
    }

    this->hidden->blit_x = (this->hidden->fb_w - this->hidden->blit_w) / 2;
    this->hidden->blit_y = (this->hidden->fb_h - this->hidden->blit_h) / 2;
}

static uint32_t read_pixel(const uint8_t *src, int bpp)
{
    uint32_t pixel = 0;

    switch (bpp) {
    case 1:
        pixel = *src;
        break;
    case 2:
        pixel = *(const uint16_t *)src;
        break;
    case 3:
        pixel = (uint32_t)src[0] | ((uint32_t)src[1] << 8) | ((uint32_t)src[2] << 16);
        break;
    case 4:
        pixel = *(const uint32_t *)src;
        break;
    default:
        break;
    }

    return pixel;
}

static void convert_to_argb8888(_THIS)
{
    int x;
    int y;
    int bytes_per_pixel;
    uint8_t *src_pixels;
    SDL_PixelFormat *format;

    if (!this->screen || !this->screen->pixels || !this->hidden->argb_buffer)
        return;

    bytes_per_pixel = this->screen->format->BytesPerPixel;
    src_pixels = (uint8_t *)this->screen->pixels;
    format = this->screen->format;

    for (y = 0; y < this->hidden->h; y++) {
        uint8_t *src_row = src_pixels + (size_t)y * this->screen->pitch;
        uint32_t *dst_row = this->hidden->argb_buffer + (size_t)y * this->hidden->w;

        for (x = 0; x < this->hidden->w; x++) {
            uint8_t r = 0;
            uint8_t g = 0;
            uint8_t b = 0;
            uint8_t a = 0xff;
            uint32_t pixel = read_pixel(src_row + (size_t)x * bytes_per_pixel, bytes_per_pixel);

            if (format->BitsPerPixel == 8 && format->palette &&
                format->palette->colors && pixel < (uint32_t)format->palette->ncolors) {
                SDL_Color color = format->palette->colors[pixel];
                r = color.r;
                g = color.g;
                b = color.b;
            } else {
                SDL_GetRGBA(pixel, format, &r, &g, &b, &a);
                (void)a;
            }

            dst_row[x] = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
        }
    }
}

int DUMMY_VideoInit(_THIS, SDL_PixelFormat *vformat)
{
    ensure_system_initialized();

    this->hidden->fb = gem_fb_open();
    if (!this->hidden->fb) {
        SDL_SetError("Unable to open Gemini framebuffer");
        return -1;
    }

    this->hidden->input = gem_input_open();
    if (!this->hidden->input) {
        gem_fb_close(this->hidden->fb);
        this->hidden->fb = NULL;
        SDL_SetError("Unable to open Gemini input");
        return -1;
    }

    this->hidden->fb_w = (int)gem_fb_width(this->hidden->fb);
    this->hidden->fb_h = (int)gem_fb_height(this->hidden->fb);
    g_cleanup_fb = this->hidden->fb;
    g_cleanup_input = this->hidden->input;

    vformat->BitsPerPixel = 32;
    vformat->BytesPerPixel = 4;

    this->info.current_w = this->hidden->fb_w;
    this->info.current_h = this->hidden->fb_h;
    this->info.vfmt = vformat;
    this->info.wm_available = 0;
    this->info.video_mem = (Uint32)((this->hidden->fb_w * this->hidden->fb_h * 4) / 1024);
    return 0;
}

SDL_Rect **DUMMY_ListModes(_THIS, SDL_PixelFormat *format, Uint32 flags)
{
    (void)this;
    (void)format;
    (void)flags;
    return (SDL_Rect **)-1;
}

SDL_Surface *DUMMY_SetVideoMode(_THIS, SDL_Surface *current,
                                int width, int height, int bpp, Uint32 flags)
{
    size_t buffer_bytes;

    if (this->hidden->buffer) {
        SDL_free(this->hidden->buffer);
        this->hidden->buffer = NULL;
    }
    if (this->hidden->argb_buffer) {
        SDL_free(this->hidden->argb_buffer);
        this->hidden->argb_buffer = NULL;
    }

    buffer_bytes = (size_t)width * height * (size_t)(bpp / 8);
    this->hidden->buffer = SDL_malloc(buffer_bytes);
    if (!this->hidden->buffer) {
        SDL_SetError("Couldn't allocate Gemini SDL buffer");
        return NULL;
    }
    SDL_memset(this->hidden->buffer, 0, buffer_bytes);

    this->hidden->argb_buffer = (uint32_t *)SDL_malloc((size_t)width * height * sizeof(uint32_t));
    if (!this->hidden->argb_buffer) {
        SDL_free(this->hidden->buffer);
        this->hidden->buffer = NULL;
        SDL_SetError("Couldn't allocate Gemini SDL conversion buffer");
        return NULL;
    }

    if (!SDL_ReallocFormat(current, bpp, 0, 0, 0, 0)) {
        SDL_free(this->hidden->argb_buffer);
        SDL_free(this->hidden->buffer);
        this->hidden->argb_buffer = NULL;
        this->hidden->buffer = NULL;
        SDL_SetError("Couldn't allocate SDL pixel format");
        return NULL;
    }

    this->hidden->w = current->w = width;
    this->hidden->h = current->h = height;
    current->flags = (flags | SDL_SWSURFACE | SDL_FULLSCREEN) & ~SDL_HWSURFACE;
    current->pitch = current->w * (bpp / 8);
    current->pixels = this->hidden->buffer;

    update_blit_rect(this);
    return current;
}

static int DUMMY_AllocHWSurface(_THIS, SDL_Surface *surface)
{
    (void)this;
    (void)surface;
    return -1;
}

static void DUMMY_FreeHWSurface(_THIS, SDL_Surface *surface)
{
    (void)this;
    (void)surface;
}

static int DUMMY_LockHWSurface(_THIS, SDL_Surface *surface)
{
    (void)this;
    (void)surface;
    return 0;
}

static void DUMMY_UnlockHWSurface(_THIS, SDL_Surface *surface)
{
    (void)this;
    (void)surface;
}

static void DUMMY_UpdateRects(_THIS, int numrects, SDL_Rect *rects)
{
    (void)numrects;
    (void)rects;

    if (!this->hidden->fb || !this->hidden->argb_buffer || !this->screen)
        return;

    convert_to_argb8888(this);
    gem_fb_clear(this->hidden->fb, 0xff000000);
    gem_fb_blit_scaled(this->hidden->fb, this->hidden->argb_buffer,
                       this->hidden->w, this->hidden->h);
    gem_fb_flip(this->hidden->fb);
}

int DUMMY_SetColors(_THIS, int firstcolor, int ncolors, SDL_Color *colors)
{
    (void)this;
    (void)firstcolor;
    (void)ncolors;
    (void)colors;
    return 1;
}

void DUMMY_VideoQuit(_THIS)
{
    if (this->hidden->input) {
        gem_input_close(this->hidden->input);
        if (g_cleanup_input == this->hidden->input)
            g_cleanup_input = NULL;
        this->hidden->input = NULL;
    }

    if (this->hidden->fb) {
        gem_fb_close(this->hidden->fb);
        if (g_cleanup_fb == this->hidden->fb)
            g_cleanup_fb = NULL;
        this->hidden->fb = NULL;
    }

    if (this->hidden->argb_buffer) {
        SDL_free(this->hidden->argb_buffer);
        this->hidden->argb_buffer = NULL;
    }

    if (this->hidden->buffer) {
        SDL_free(this->hidden->buffer);
        this->hidden->buffer = NULL;
    }

    if (this->screen)
        this->screen->pixels = NULL;
}
