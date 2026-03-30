// gemini_mixer.c — Software PCM mixer for libgemini
// Mixes up to GEM_MIXER_MAX_CHANNELS mono sources to stereo output via gem_audio.
// Used by games/emulators with multiple simultaneous sound effects.
//
// Known-good software mixing layer for the SP7021. This feeds the validated
// direct QtOutput backend in gemini_audio.c and is the reference path for game
// sound on the current firmware.

#include "gemini.h"

#include <stdlib.h>
#include <string.h>

#ifdef __ARM_NEON
#include <arm_neon.h>
#endif

typedef struct {
    const int16_t *data;
    uint32_t length;        // Total samples
    uint32_t pos;           // Current playback position
    int      vol_left;      // 0-255
    int      vol_right;     // 0-255
    int      active;
} mix_ch_t;

struct gem_mixer {
    gem_audio_t *audio;
    mix_ch_t ch[GEM_MIXER_MAX_CHANNELS];
    int16_t *buf;           // Stereo interleaved output buffer
    int buf_frames;         // Mono frames per update
    int sample_rate;
};

gem_mixer_t *gem_mixer_open(int sample_rate, int channels_out, int bits,
                            int buffer_ms)
{
    gem_mixer_t *m = calloc(1, sizeof(*m));
    if (!m) return NULL;

    m->sample_rate = sample_rate;
    m->buf_frames = (sample_rate * buffer_ms) / 1000;
    if (m->buf_frames < 64) m->buf_frames = 64;

    m->buf = calloc(m->buf_frames * 2, sizeof(int16_t));
    if (!m->buf) { free(m); return NULL; }

    m->audio = gem_audio_open(sample_rate, channels_out, bits);
    if (!m->audio)
        gem_log(GEM_LOG_WARN, "mixer: audio output unavailable\n");

    gem_log(GEM_LOG_INFO, "mixer: %d Hz, %d-bit, %d ms buffer (%d frames)\n",
            sample_rate, bits, buffer_ms, m->buf_frames);
    return m;
}

void gem_mixer_close(gem_mixer_t *m)
{
    if (!m) return;
    if (m->audio) gem_audio_close(m->audio);
    free(m->buf);
    free(m);
}

int gem_mixer_play(gem_mixer_t *m, int channel, const int16_t *data,
                   uint32_t num_samples, int vol_left, int vol_right)
{
    if (!m || !data || num_samples == 0) return -1;

    if (channel < 0) {
        for (int i = 0; i < GEM_MIXER_MAX_CHANNELS; i++) {
            if (!m->ch[i].active) { channel = i; break; }
        }
        if (channel < 0) channel = 0;  // steal channel 0 if all busy
    }
    if (channel >= GEM_MIXER_MAX_CHANNELS) return -1;

    mix_ch_t *c = &m->ch[channel];
    c->data = data;
    c->length = num_samples;
    c->pos = 0;
    c->vol_left = vol_left;
    c->vol_right = vol_right;
    c->active = 1;
    return channel;
}

void gem_mixer_stop(gem_mixer_t *m, int channel)
{
    if (!m || channel < 0 || channel >= GEM_MIXER_MAX_CHANNELS) return;
    m->ch[channel].active = 0;
}

void gem_mixer_set_volume(gem_mixer_t *m, int channel,
                          int vol_left, int vol_right)
{
    if (!m || channel < 0 || channel >= GEM_MIXER_MAX_CHANNELS) return;
    m->ch[channel].vol_left = vol_left;
    m->ch[channel].vol_right = vol_right;
}

int gem_mixer_is_playing(gem_mixer_t *m, int channel)
{
    if (!m || channel < 0 || channel >= GEM_MIXER_MAX_CHANNELS) return 0;
    return m->ch[channel].active;
}

void gem_mixer_update(gem_mixer_t *m)
{
    if (!m) return;

    int n = m->buf_frames;
    memset(m->buf, 0, n * 2 * sizeof(int16_t));

    for (int i = 0; i < GEM_MIXER_MAX_CHANNELS; i++) {
        mix_ch_t *c = &m->ch[i];
        if (!c->active || !c->data) continue;

        uint32_t rem = c->length - c->pos;
        uint32_t to_mix = rem < (uint32_t)n ? rem : (uint32_t)n;
        const int16_t *src = c->data + c->pos;

#ifdef __ARM_NEON
        // NEON: process 4 mono samples → 4 stereo pairs at a time
        int16x4_t vl = vdup_n_s16((int16_t)c->vol_left);
        int16x4_t vr = vdup_n_s16((int16_t)c->vol_right);
        uint32_t j = 0;
        for (; j + 4 <= to_mix; j += 4) {
            int16x4_t s = vld1_s16(src + j);

            // volume scale: (s * vol) >> 8
            int32x4_t ml = vmull_s16(s, vl);
            int32x4_t mr = vmull_s16(s, vr);
            int16x4_t sl = vshrn_n_s32(ml, 8);
            int16x4_t sr = vshrn_n_s32(mr, 8);

            // load existing stereo pairs and accumulate
            int16x4x2_t existing = vld2_s16(m->buf + j * 2);
            existing.val[0] = vqadd_s16(existing.val[0], sl);
            existing.val[1] = vqadd_s16(existing.val[1], sr);
            vst2_s16(m->buf + j * 2, existing);
        }
        // scalar remainder
        for (; j < to_mix; j++) {
            int s = src[j];
            int l = m->buf[j * 2]     + ((s * c->vol_left)  >> 8);
            int r = m->buf[j * 2 + 1] + ((s * c->vol_right) >> 8);
            if (l >  32767) l =  32767; else if (l < -32768) l = -32768;
            if (r >  32767) r =  32767; else if (r < -32768) r = -32768;
            m->buf[j * 2]     = (int16_t)l;
            m->buf[j * 2 + 1] = (int16_t)r;
        }
#else
        for (uint32_t j = 0; j < to_mix; j++) {
            int s = src[j];
            int l = m->buf[j * 2]     + ((s * c->vol_left)  >> 8);
            int r = m->buf[j * 2 + 1] + ((s * c->vol_right) >> 8);
            if (l >  32767) l =  32767; else if (l < -32768) l = -32768;
            if (r >  32767) r =  32767; else if (r < -32768) r = -32768;
            m->buf[j * 2]     = (int16_t)l;
            m->buf[j * 2 + 1] = (int16_t)r;
        }
#endif

        c->pos += to_mix;
        if (c->pos >= c->length) c->active = 0;
    }

    if (m->audio)
        gem_audio_write(m->audio, m->buf, n * 2 * sizeof(int16_t));
}
