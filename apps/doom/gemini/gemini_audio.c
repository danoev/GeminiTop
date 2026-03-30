// gemini_audio.c — DOOM audio module, loads WAD lumps into gem_mixer

#include "doomtype.h"
#include "deh_str.h"
#include "i_sound.h"
#include "i_swap.h"
#include "i_system.h"
#include "m_argv.h"
#include "m_misc.h"
#include "w_wad.h"
#include "z_zone.h"

#include "gemini.h"

#include <stdlib.h>
#include <string.h>

// Satisfy i_sound.c config variable references (normally in i_sdlsound.c)
int use_libsamplerate = 0;
float libsamplerate_scale = 0.65f;

#define MIX_RATE  48000   // Matches the confirmed-working QtOutput track setup

static gem_mixer_t *mixer = NULL;
static boolean sound_initialized = false;
static boolean use_sfx_prefix;

// WAD lump loading: 8-bit unsigned mono -> 16-bit signed, resampled to MIX_RATE
static int16_t *LoadAndResample(sfxinfo_t *sfxinfo, uint32_t *out_len)
{
    int lumpnum = sfxinfo->lumpnum;
    byte *data = W_CacheLumpNum(lumpnum, PU_STATIC);
    unsigned int lumplen = W_LumpLength(lumpnum);

    // DOOM SFX lump header: byte[0..1] = 0x0003, byte[2..3] = sample rate,
    // byte[4..7] = sample count, byte[8+] = unsigned 8-bit PCM data
    if (lumplen < 8 || data[0] != 0x03 || data[1] != 0x00) {
        W_ReleaseLumpNum(lumpnum);
        *out_len = 0;
        return NULL;
    }

    int samplerate = (data[3] << 8) | data[2];
    uint32_t length = (data[7] << 24) | (data[6] << 16) | (data[5] << 8) | data[4];

    if (length > lumplen - 8 || length <= 48) {
        W_ReleaseLumpNum(lumpnum);
        *out_len = 0;
        return NULL;
    }

    // Skip header padding (DMX convention: skip first 16, last 16)
    byte *pcm8 = data + 24;    // 8 header + 16 padding
    length -= 32;

    // Resample to MIX_RATE
    uint32_t out_samples = ((uint64_t)length * MIX_RATE) / samplerate;
    if (out_samples == 0) {
        W_ReleaseLumpNum(lumpnum);
        *out_len = 0;
        return NULL;
    }

    int16_t *buf = malloc(out_samples * sizeof(int16_t));
    if (!buf) {
        W_ReleaseLumpNum(lumpnum);
        *out_len = 0;
        return NULL;
    }

    uint32_t ratio = (length << 16) / out_samples;
    for (uint32_t i = 0; i < out_samples; i++) {
        uint32_t src_idx = (i * ratio) >> 16;
        if (src_idx >= length) src_idx = length - 1;
        // Convert unsigned 8-bit to signed 16-bit
        int16_t s = ((int)pcm8[src_idx] - 128) << 8;
        buf[i] = s;
    }

    W_ReleaseLumpNum(lumpnum);
    *out_len = out_samples;
    return buf;
}

// sound_module_t implementation (DOOM interface -> gem_mixer)
static boolean I_Gemini_InitSound(boolean _use_sfx_prefix)
{
    use_sfx_prefix = _use_sfx_prefix;
    mixer = gem_mixer_open(MIX_RATE, 2, 16, 40);
    sound_initialized = true;
    return true;
}

static void I_Gemini_ShutdownSound(void)
{
    if (!sound_initialized)
        return;
    if (mixer) { gem_mixer_close(mixer); mixer = NULL; }
    sound_initialized = false;
}

static int I_Gemini_GetSfxLumpNum(sfxinfo_t *sfx)
{
    char namebuf[20];

    if (use_sfx_prefix) {
        M_snprintf(namebuf, sizeof(namebuf), "ds%s", DEH_String(sfx->name));
    } else {
        M_snprintf(namebuf, sizeof(namebuf), "%s", DEH_String(sfx->name));
    }

    return W_GetNumForName(namebuf);
}

static void I_Gemini_UpdateSound(void)
{
    if (sound_initialized && mixer)
        gem_mixer_update(mixer);
}

static void I_Gemini_UpdateSoundParams(int handle, int vol, int sep)
{
    if (!sound_initialized || !mixer) return;
    // sep: 0=full left, 127=center, 254=full right
    int vl = ((254 - sep) * vol) / 127;
    int vr = (sep * vol) / 127;
    if (vl > 255) vl = 255;
    if (vr > 255) vr = 255;
    gem_mixer_set_volume(mixer, handle, vl, vr);
}

static int I_Gemini_StartSound(sfxinfo_t *sfxinfo, int channel, int vol, int sep)
{
    if (!sound_initialized || !mixer) return -1;

    // Load and cache the sound data (DOOM-specific WAD format)
    if (sfxinfo->driver_data == NULL) {
        uint32_t len;
        int16_t *data = LoadAndResample(sfxinfo, &len);
        if (!data) return -1;
        sfxinfo->driver_data = data;
        sfxinfo->numchannels = (int)len;
    }

    int vl = ((254 - sep) * vol) / 127;
    int vr = (sep * vol) / 127;
    if (vl > 255) vl = 255;
    if (vr > 255) vr = 255;

    return gem_mixer_play(mixer, channel, sfxinfo->driver_data,
                          (uint32_t)sfxinfo->numchannels, vl, vr);
}

static void I_Gemini_StopSound(int handle)
{
    if (sound_initialized && mixer)
        gem_mixer_stop(mixer, handle);
}

static boolean I_Gemini_SoundIsPlaying(int handle)
{
    if (!sound_initialized || !mixer) return false;
    return gem_mixer_is_playing(mixer, handle);
}

static void I_Gemini_PrecacheSounds(sfxinfo_t *sounds, int num_sounds)
{
    // Load on demand in StartSound — 256MB RAM is tight
}

// music stubs — no MIDI synth
static boolean I_Gemini_InitMusic(void) { return false; }
static void    I_Gemini_ShutdownMusic(void) {}
static void    I_Gemini_SetMusicVolume(int vol) { (void)vol; }
static void    I_Gemini_PauseMusic(void) {}
static void    I_Gemini_ResumeMusic(void) {}
static void   *I_Gemini_RegisterSong(void *data, int len) { (void)data; (void)len; return NULL; }
static void    I_Gemini_UnRegisterSong(void *handle) { (void)handle; }
static void    I_Gemini_PlaySong(void *handle, boolean looping) { (void)handle; (void)looping; }
static void    I_Gemini_StopSong(void) {}
static boolean I_Gemini_MusicIsPlaying(void) { return false; }

// module structs exported for i_sound.c
static snddevice_t sound_gemini_devices[] = {
    SNDDEVICE_SB,
    SNDDEVICE_PAS,
    SNDDEVICE_GUS,
    SNDDEVICE_WAVEBLASTER,
    SNDDEVICE_SOUNDCANVAS,
    SNDDEVICE_AWE32,
};

sound_module_t DG_sound_module = {
    sound_gemini_devices,
    arrlen(sound_gemini_devices),
    I_Gemini_InitSound,
    I_Gemini_ShutdownSound,
    I_Gemini_GetSfxLumpNum,
    I_Gemini_UpdateSound,
    I_Gemini_UpdateSoundParams,
    I_Gemini_StartSound,
    I_Gemini_StopSound,
    I_Gemini_SoundIsPlaying,
    I_Gemini_PrecacheSounds,
};

static snddevice_t music_gemini_devices[] = {
    SNDDEVICE_SB,
    SNDDEVICE_PAS,
    SNDDEVICE_GUS,
    SNDDEVICE_WAVEBLASTER,
    SNDDEVICE_SOUNDCANVAS,
    SNDDEVICE_GENMIDI,
    SNDDEVICE_AWE32,
};

music_module_t DG_music_module = {
    music_gemini_devices,
    arrlen(music_gemini_devices),
    I_Gemini_InitMusic,
    I_Gemini_ShutdownMusic,
    I_Gemini_SetMusicVolume,
    I_Gemini_PauseMusic,
    I_Gemini_ResumeMusic,
    I_Gemini_RegisterSong,
    I_Gemini_UnRegisterSong,
    I_Gemini_PlaySong,
    I_Gemini_StopSong,
    I_Gemini_MusicIsPlaying,
    NULL,   // Poll
};
