#include "SDL_config.h"

#ifndef _SDL_dummyaudio_h
#define _SDL_dummyaudio_h

#include "../SDL_sysaudio.h"
#include "gemini.h"

#define _THIS SDL_AudioDevice *this

struct SDL_PrivateAudioData {
    gem_audio_t *audio;
    Uint8 *mixbuf;
    Uint32 mixlen;
    Uint32 write_delay;
    Uint32 initial_calls;
};

#endif
