#include "SDL_config.h"

#include "SDL_rwops.h"
#include "SDL_timer.h"
#include "SDL_audio.h"
#include "../SDL_audiomem.h"
#include "../SDL_audio_c.h"
#include "../SDL_audiodev_c.h"
#include "SDL_dummyaudio.h"

#define DUMMYAUD_DRIVER_NAME "dummy"

static int DUMMYAUD_OpenAudio(_THIS, SDL_AudioSpec *spec);
static void DUMMYAUD_WaitAudio(_THIS);
static void DUMMYAUD_PlayAudio(_THIS);
static Uint8 *DUMMYAUD_GetAudioBuf(_THIS);
static void DUMMYAUD_CloseAudio(_THIS);

static int DUMMYAUD_FormatBits(Uint16 format)
{
    switch (format) {
    case AUDIO_U8:
    case AUDIO_S8:
        return 8;
    case AUDIO_U16LSB:
    case AUDIO_S16LSB:
    case AUDIO_U16MSB:
    case AUDIO_S16MSB:
        return 16;
    default:
        return 0;
    }
}

static int DUMMYAUD_Available(void)
{
    const char *envr = SDL_getenv("SDL_AUDIODRIVER");
    return envr && (SDL_strcmp(envr, DUMMYAUD_DRIVER_NAME) == 0);
}

static void DUMMYAUD_DeleteDevice(SDL_AudioDevice *device)
{
    SDL_free(device->hidden);
    SDL_free(device);
}

static SDL_AudioDevice *DUMMYAUD_CreateDevice(int devindex)
{
    SDL_AudioDevice *this;

    this = (SDL_AudioDevice *)SDL_malloc(sizeof(SDL_AudioDevice));
    if (this) {
        SDL_memset(this, 0, sizeof(*this));
        this->hidden = (struct SDL_PrivateAudioData *)SDL_malloc(sizeof(*this->hidden));
    }
    if ((this == NULL) || (this->hidden == NULL)) {
        SDL_OutOfMemory();
        if (this)
            SDL_free(this);
        return 0;
    }
    SDL_memset(this->hidden, 0, sizeof(*this->hidden));

    this->OpenAudio = DUMMYAUD_OpenAudio;
    this->WaitAudio = DUMMYAUD_WaitAudio;
    this->PlayAudio = DUMMYAUD_PlayAudio;
    this->GetAudioBuf = DUMMYAUD_GetAudioBuf;
    this->CloseAudio = DUMMYAUD_CloseAudio;
    this->free = DUMMYAUD_DeleteDevice;
    return this;
}

AudioBootStrap DUMMYAUD_bootstrap = {
    DUMMYAUD_DRIVER_NAME, "Gemini SDL audio driver",
    DUMMYAUD_Available, DUMMYAUD_CreateDevice
};

static void DUMMYAUD_WaitAudio(_THIS)
{
    if (this->hidden->initial_calls)
        this->hidden->initial_calls--;
    else
        SDL_Delay(this->hidden->write_delay);
}

static void DUMMYAUD_PlayAudio(_THIS)
{
    if (this->hidden->audio && this->hidden->mixbuf && this->hidden->mixlen)
        (void)gem_audio_write(this->hidden->audio, this->hidden->mixbuf, (int)this->hidden->mixlen);
}

static Uint8 *DUMMYAUD_GetAudioBuf(_THIS)
{
    return this->hidden->mixbuf;
}

static void DUMMYAUD_CloseAudio(_THIS)
{
    if (this->hidden->audio) {
        gem_audio_close(this->hidden->audio);
        this->hidden->audio = NULL;
    }
    if (this->hidden->mixbuf) {
        SDL_FreeAudioMem(this->hidden->mixbuf);
        this->hidden->mixbuf = NULL;
    }
}

static int DUMMYAUD_OpenAudio(_THIS, SDL_AudioSpec *spec)
{
    float bytes_per_sec;
    int bits = DUMMYAUD_FormatBits(spec->format);

    if (bits == 0) {
        SDL_SetError("Unsupported audio format 0x%x", spec->format);
        return -1;
    }

    this->hidden->audio = gem_audio_open(spec->freq, spec->channels, bits);
    if (!this->hidden->audio) {
        SDL_SetError("Gemini audio open failed");
        return -1;
    }

    this->hidden->mixlen = spec->size;
    this->hidden->mixbuf = (Uint8 *)SDL_AllocAudioMem(this->hidden->mixlen);
    if (this->hidden->mixbuf == NULL) {
        gem_audio_close(this->hidden->audio);
        this->hidden->audio = NULL;
        return -1;
    }
    SDL_memset(this->hidden->mixbuf, spec->silence, spec->size);

    bytes_per_sec = (float)((bits / 8) * spec->channels * spec->freq);
    this->hidden->initial_calls = 2;
    this->hidden->write_delay = (Uint32)(((float)spec->size / bytes_per_sec) * 1000.0f);
    return 0;
}
