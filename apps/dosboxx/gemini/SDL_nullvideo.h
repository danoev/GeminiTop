#include "SDL_config.h"

#ifndef _SDL_nullvideo_h
#define _SDL_nullvideo_h

#include "../SDL_sysvideo.h"
#include "gemini.h"

#define _THIS SDL_VideoDevice *this

struct SDL_PrivateVideoData {
    int w;
    int h;
    int fb_w;
    int fb_h;
    int blit_x;
    int blit_y;
    int blit_w;
    int blit_h;
    int touch_active;
    int touch_button_down;
    void *buffer;
    uint32_t *argb_buffer;
    gem_fb_t *fb;
    gem_input_t *input;
};

#endif
