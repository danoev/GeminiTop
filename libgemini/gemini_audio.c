// gemini_audio.c — direct PCM output via libaudio / QtOutput
//
// Known-good SP7021 audio path:
//   libaudio -> SPAudioTrack::create("QtOutput", "alternative", ...)
// This replaces the older FIFO/as_spaudiotrack attempt and is the validated
// backend that produced working game audio on hardware. Treat these track/tag
// values and PCM format assumptions as the reference configuration.

#include "gemini.h"

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define AS_TRACK_NAME "QtOutput"
#define AS_TAG_NAME   "alternative"
#define AS_BUFFER_MS  200

typedef void *(*spaudio_create_fn)(const char *, const char *, int, int, int, int);
typedef void (*spaudio_destroy_fn)(void *);
typedef int (*track_start_fn)(void *);
typedef int (*track_stop_fn)(void *);
typedef int (*track_set_volume_fn)(void *, int);
typedef int (*track_write_fn)(void *, uint8_t *, int, int);

static const char *kCreateSymbol = "_ZN5audio12SPAudioTrack6createEPKcS2_iiii";
static const char *kDestroySymbol = "_ZN5audio12SPAudioTrack7destroyEPS0_";

struct gem_audio {
    void *libaudio;
    void *track;
    spaudio_destroy_fn destroy_track;
    track_stop_fn stop_fn;
    track_write_fn write_fn;
    int rate;
    int channels;
    int bits;
};

static void **track_vtable(void *track)
{
    return track ? *(void ***)track : NULL;
}

static track_start_fn track_start(void *track)
{
    void **vt = track_vtable(track);
    return vt ? (track_start_fn)vt[1] : NULL;
}

static track_stop_fn track_stop(void *track)
{
    void **vt = track_vtable(track);
    return vt ? (track_stop_fn)vt[2] : NULL;
}

static track_set_volume_fn track_set_volume(void *track)
{
    void **vt = track_vtable(track);
    return vt ? (track_set_volume_fn)vt[4] : NULL;
}

static track_write_fn track_write(void *track)
{
    void **vt = track_vtable(track);
    return vt ? (track_write_fn)vt[12] : NULL;
}

static int map_bit_depth(int bits)
{
    switch (bits) {
    case 8:
        return 0;
    case 16:
        return 1;
    case 32:
        return 2;
    default:
        return -1;
    }
}

static int map_channel_mode(int channels)
{
    switch (channels) {
    case 1:
        return 0;
    case 2:
        return 1;
    case 6:
        return 11;
    default:
        return 22;
    }
}

gem_audio_t *gem_audio_open(int rate, int channels, int bits)
{
    gem_audio_t *a = calloc(1, sizeof(gem_audio_t));
    if (!a)
        return NULL;

    int bit_depth = map_bit_depth(bits);
    int channel_mode = map_channel_mode(channels);
    if (bit_depth < 0) {
        gem_log(GEM_LOG_ERROR, "audio: unsupported PCM bit depth %d\n", bits);
        free(a);
        return NULL;
    }

    a->libaudio = dlopen("libaudio.so.2", RTLD_NOW | RTLD_GLOBAL);
    if (!a->libaudio)
        a->libaudio = dlopen("libaudio.so", RTLD_NOW | RTLD_GLOBAL);
    if (!a->libaudio) {
        gem_log(GEM_LOG_ERROR, "audio: dlopen libaudio failed: %s\n", dlerror());
        free(a);
        return NULL;
    }

    dlerror();
    spaudio_create_fn create_track =
        (spaudio_create_fn)dlsym(a->libaudio, kCreateSymbol);
    const char *err = dlerror();
    if (!create_track || err) {
        gem_log(GEM_LOG_ERROR, "audio: dlsym create failed: %s\n",
                err ? err : "missing symbol");
        dlclose(a->libaudio);
        free(a);
        return NULL;
    }

    dlerror();
    a->destroy_track = (spaudio_destroy_fn)dlsym(a->libaudio, kDestroySymbol);
    err = dlerror();
    if (!a->destroy_track || err) {
        gem_log(GEM_LOG_ERROR, "audio: dlsym destroy failed: %s\n",
                err ? err : "missing symbol");
        dlclose(a->libaudio);
        free(a);
        return NULL;
    }

    gem_log(GEM_LOG_INFO,
            "audio: open track=%s tag=%s rate=%d ch=%d bits=%d bit_enum=%d channel_enum=%d\n",
            AS_TRACK_NAME, AS_TAG_NAME, rate, channels, bits, bit_depth, channel_mode);

    a->track = create_track(AS_TRACK_NAME, AS_TAG_NAME, rate, bit_depth,
                            channel_mode, AS_BUFFER_MS);
    if (!a->track) {
        gem_log(GEM_LOG_ERROR, "audio: create track returned NULL\n");
        dlclose(a->libaudio);
        free(a);
        return NULL;
    }

    track_set_volume_fn set_volume = track_set_volume(a->track);
    track_start_fn start_fn = track_start(a->track);
    a->stop_fn = track_stop(a->track);
    a->write_fn = track_write(a->track);

    if (!start_fn || !a->stop_fn || !a->write_fn) {
        gem_log(GEM_LOG_ERROR, "audio: track vtable incomplete start=%p stop=%p write=%p\n",
                (void *)start_fn, (void *)a->stop_fn, (void *)a->write_fn);
        a->destroy_track(a->track);
        dlclose(a->libaudio);
        free(a);
        return NULL;
    }

    if (set_volume) {
        int rc = set_volume(a->track, 100);
        gem_log(GEM_LOG_DEBUG, "audio: set volume rc=%d\n", rc);
    }

    {
        int rc = start_fn(a->track);
        gem_log(GEM_LOG_INFO, "audio: direct start rc=%d\n", rc);
        if (rc < 0) {
            a->destroy_track(a->track);
            dlclose(a->libaudio);
            free(a);
            return NULL;
        }
    }

    a->rate = rate;
    a->channels = channels;
    a->bits = bits;
    return a;
}

void gem_audio_close(gem_audio_t *a)
{
    if (!a)
        return;

    if (a->track && a->stop_fn)
        a->stop_fn(a->track);

    if (a->track && a->destroy_track)
        a->destroy_track(a->track);

    if (a->libaudio)
        dlclose(a->libaudio);

    free(a);
}

int gem_audio_write(gem_audio_t *a, const void *pcm, int len)
{
    if (!a || !a->track || !a->write_fn || !pcm || len <= 0)
        return 0;

    int wrote = a->write_fn(a->track, (uint8_t *)pcm, len, 0);
    return wrote > 0 ? wrote : 0;
}
