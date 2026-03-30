// gemini_audio.c — RetroArch audio driver for Gemini SP7021
//
// Audio pipeline:
//   RetroArch core -> ring buffer -> libaudio / QtOutput

#ifdef HAVE_GEMINI

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>

#include "../../retroarch.h"
#include "../../verbosity.h"
#include "../audio_driver.h"

#define RING_SIZE     (256 * 1024)
#define RING_MASK     (RING_SIZE - 1)
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

typedef struct {
    void *libaudio;
    void *track;
    spaudio_destroy_fn destroy_track;
    track_start_fn start_fn;
    track_stop_fn stop_fn;
    track_write_fn write_fn;

    uint8_t ring[RING_SIZE];
    size_t ring_read;
    size_t ring_write;

    bool nonblock;
    bool active;
    unsigned rate;
} gemini_audio_t;

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

static size_t ring_filled(gemini_audio_t *a)
{
    return (a->ring_write - a->ring_read) & RING_MASK;
}

static size_t ring_free(gemini_audio_t *a)
{
    return RING_SIZE - 1 - ring_filled(a);
}

static void ring_drain(gemini_audio_t *a)
{
    if (!a || !a->track || !a->write_fn)
        return;

    size_t filled = ring_filled(a);
    while (filled > 0) {
        size_t pos = a->ring_read & RING_MASK;
        size_t chunk = RING_SIZE - pos;
        if (chunk > filled)
            chunk = filled;

        int n = a->write_fn(a->track, a->ring + pos, (int)chunk, 0);
        if (n <= 0)
            break;

        a->ring_read += (size_t)n;
        filled -= (size_t)n;
    }
}

static size_t ring_push(gemini_audio_t *a, const uint8_t *data, size_t len)
{
    size_t avail = ring_free(a);
    if (len > avail)
        len = avail;
    if (!len)
        return 0;

    size_t pos = a->ring_write & RING_MASK;
    size_t first = RING_SIZE - pos;
    if (first > len)
        first = len;

    memcpy(a->ring + pos, data, first);
    if (len > first)
        memcpy(a->ring, data + first, len - first);

    a->ring_write += len;
    return len;
}

static void *gemini_audio_init(const char *device, unsigned rate,
      unsigned latency, unsigned block_frames, unsigned *new_rate)
{
    (void)device;
    (void)latency;
    (void)block_frames;

    gemini_audio_t *a = (gemini_audio_t *)calloc(1, sizeof(*a));
    if (!a)
        return NULL;

    int bit_depth = map_bit_depth(16);
    int channel_mode = map_channel_mode(2);
    if (bit_depth < 0) {
        free(a);
        return NULL;
    }

    a->libaudio = dlopen("libaudio.so.2", RTLD_NOW | RTLD_GLOBAL);
    if (!a->libaudio)
        a->libaudio = dlopen("libaudio.so", RTLD_NOW | RTLD_GLOBAL);
    if (!a->libaudio) {
        RARCH_ERR("[Gemini] dlopen libaudio failed: %s\n", dlerror());
        free(a);
        return NULL;
    }

    dlerror();
    spaudio_create_fn create_track =
        (spaudio_create_fn)dlsym(a->libaudio, kCreateSymbol);
    const char *err = dlerror();
    if (!create_track || err) {
        RARCH_ERR("[Gemini] dlsym create failed: %s\n", err ? err : "missing symbol");
        dlclose(a->libaudio);
        free(a);
        return NULL;
    }

    dlerror();
    a->destroy_track = (spaudio_destroy_fn)dlsym(a->libaudio, kDestroySymbol);
    err = dlerror();
    if (!a->destroy_track || err) {
        RARCH_ERR("[Gemini] dlsym destroy failed: %s\n", err ? err : "missing symbol");
        dlclose(a->libaudio);
        free(a);
        return NULL;
    }

    RARCH_LOG("[Gemini] Audio: opening %s/%s rate=%u bit_enum=%d channel_enum=%d\n",
              AS_TRACK_NAME, AS_TAG_NAME, rate, bit_depth, channel_mode);

    a->track = create_track(AS_TRACK_NAME, AS_TAG_NAME, (int)rate, bit_depth,
                            channel_mode, AS_BUFFER_MS);
    if (!a->track) {
        RARCH_ERR("[Gemini] create track returned NULL\n");
        dlclose(a->libaudio);
        free(a);
        return NULL;
    }

    a->start_fn = track_start(a->track);
    a->stop_fn = track_stop(a->track);
    a->write_fn = track_write(a->track);
    track_set_volume_fn set_volume = track_set_volume(a->track);

    if (!a->start_fn || !a->stop_fn || !a->write_fn) {
        RARCH_ERR("[Gemini] track vtable incomplete start=%p stop=%p write=%p\n",
                  (void *)a->start_fn, (void *)a->stop_fn, (void *)a->write_fn);
        a->destroy_track(a->track);
        dlclose(a->libaudio);
        free(a);
        return NULL;
    }

    if (set_volume) {
        int rc = set_volume(a->track, 100);
        RARCH_LOG("[Gemini] set volume rc=%d\n", rc);
    }

    {
        int rc = a->start_fn(a->track);
        RARCH_LOG("[Gemini] direct start rc=%d\n", rc);
        if (rc < 0) {
            a->destroy_track(a->track);
            dlclose(a->libaudio);
            free(a);
            return NULL;
        }
    }

    a->rate = rate;
    a->active = true;
    *new_rate = rate;
    return a;
}

static ssize_t gemini_audio_write(void *data, const void *buf, size_t size)
{
    gemini_audio_t *a = (gemini_audio_t *)data;
    if (!a || !a->active)
        return -1;

    ring_drain(a);

    if (a->nonblock)
        return (ssize_t)ring_push(a, (const uint8_t *)buf, size);

    size_t written = 0;
    while (written < size) {
        size_t n = ring_push(a, (const uint8_t *)buf + written, size - written);
        written += n;
        if (written < size) {
            ring_drain(a);
            usleep(1000);
        }
    }
    return (ssize_t)written;
}

static bool gemini_audio_stop(void *data)
{
    gemini_audio_t *a = (gemini_audio_t *)data;
    if (!a)
        return true;

    a->active = false;
    if (a->track && a->stop_fn)
        a->stop_fn(a->track);
    return true;
}

static bool gemini_audio_start(void *data, bool is_shutdown)
{
    (void)is_shutdown;
    gemini_audio_t *a = (gemini_audio_t *)data;
    if (a) {
        a->active = true;
        if (a->track && a->start_fn)
            a->start_fn(a->track);
    }
    return true;
}

static bool gemini_audio_alive(void *data)
{
    gemini_audio_t *a = (gemini_audio_t *)data;
    return a && a->active;
}

static void gemini_audio_set_nonblock_state(void *data, bool toggle)
{
    gemini_audio_t *a = (gemini_audio_t *)data;
    if (a)
        a->nonblock = toggle;
}

static void gemini_audio_free(void *data)
{
    gemini_audio_t *a = (gemini_audio_t *)data;
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

static bool gemini_audio_use_float(void *data)
{
    (void)data;
    return false;
}

static size_t gemini_audio_write_avail(void *data)
{
    gemini_audio_t *a = (gemini_audio_t *)data;
    if (!a)
        return 0;
    ring_drain(a);
    return ring_free(a);
}

static size_t gemini_audio_buffer_size(void *data)
{
    (void)data;
    return RING_SIZE;
}

audio_driver_t audio_gemini = {
    gemini_audio_init,
    gemini_audio_write,
    gemini_audio_stop,
    gemini_audio_start,
    gemini_audio_alive,
    gemini_audio_set_nonblock_state,
    gemini_audio_free,
    gemini_audio_use_float,
    "gemini",
    NULL,
    NULL,
    gemini_audio_write_avail,
    gemini_audio_buffer_size,
};

#endif /* HAVE_GEMINI */
