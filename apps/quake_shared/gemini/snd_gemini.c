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

#include "common.h"
#include "console.h"
#include "quakedef.h"
#include "sound.h"
#include "sys.h"
#include "zone.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "gemini.h"

static struct {
    int speed;
    int bits;
    int channels;
} snd_params = { 22050, 16, 1 };

static int snd_inited;
static dma_t gem_dma;
static gem_audio_t *gem_audio;
static uint64_t submit_total_samples;
static uint32_t playback_start_ms;
static qboolean playback_started;

qboolean
SNDDMA_Init(void)
{
    int argnum;

    snd_inited = 0;
    gem_audio = NULL;
    submit_total_samples = 0;
    playback_start_ms = 0;
    playback_started = false;

    argnum = COM_CheckParm("-sndspeed");
    if (argnum)
        snd_params.speed = atoi(com_argv[argnum + 1]);

    argnum = COM_CheckParm("-sndbits");
    if (argnum) {
        int bits = atoi(com_argv[argnum + 1]);
        if (bits != 16)
            Con_Printf("GEMINI: only 16-bit audio is supported, ignoring -sndbits %d\n", bits);
    }

    snd_params.channels = COM_CheckParm("-sndstereo") ? 2 : 1;
    if (COM_CheckParm("-sndmono"))
        snd_params.channels = 1;

    shm = &gem_dma;
    memset(shm, 0, sizeof(*shm));
    shm->samplebits = 16;
    shm->speed = snd_params.speed;
    shm->channels = snd_params.channels;
    shm->samplepos = 0;
    shm->submission_chunk = 1;
    /*
     * Keep a larger software ring than SDL's default path uses so the
     * software mixer can stay comfortably ahead even when render frames dip.
     */
    shm->samples = 1 << Q_log2(shm->speed * shm->channels * 2);
    shm->buffer = Hunk_AllocName(shm->samples * (shm->samplebits / 8), "shm->buffer");
    memset(shm->buffer, 0, shm->samples * (shm->samplebits / 8));

    gem_audio = gem_audio_open(shm->speed, shm->channels, shm->samplebits);
    if (!gem_audio) {
        Con_Printf("GEMINI: failed to open audio output\n");
        shm = NULL;
        return false;
    }

    snd_inited = 1;
    snd_blocked = 0;
    return true;
}

int
SNDDMA_LockBuffer(void)
{
    return 0;
}

void
SNDDMA_UnlockBuffer(void)
{
}

int
SNDDMA_GetDMAPos(void)
{
    uint64_t elapsed_ms;
    uint64_t played_samples;

    if (!snd_inited || !shm)
        return 0;

    if (!playback_started || submit_total_samples == 0) {
        shm->samplepos = 0;
        return 0;
    }

    elapsed_ms = gem_get_ticks_ms() - playback_start_ms;
    played_samples =
        ((elapsed_ms * (uint64_t)shm->speed) / 1000ULL) * (uint64_t)shm->channels;
    if (played_samples > submit_total_samples)
        played_samples = submit_total_samples;

    shm->samplepos = (int)(played_samples & (uint64_t)(shm->samples - 1));
    return shm->samplepos;
}

void
SNDDMA_Shutdown(void)
{
    if (gem_audio) {
        gem_audio_close(gem_audio);
        gem_audio = NULL;
    }
    playback_started = false;
    playback_start_ms = 0;
    snd_inited = 0;
}

void
SNDDMA_Submit(void)
{
    const int bytes_per_sample = shm ? (shm->samplebits / 8) : 0;
    uint64_t target_total_samples;

    if (!snd_inited || !shm || !gem_audio || snd_blocked > 0 || bytes_per_sample <= 0)
        return;

    target_total_samples = (uint64_t)paintedtime * (uint64_t)shm->channels;
    if (target_total_samples > submit_total_samples + (uint64_t)shm->samples)
        submit_total_samples = target_total_samples - (uint64_t)shm->samples;

    while (submit_total_samples < target_total_samples) {
        const uint64_t offset = submit_total_samples & (uint64_t)(shm->samples - 1);
        const uint64_t remaining = target_total_samples - submit_total_samples;
        const uint64_t contiguous = (uint64_t)shm->samples - offset;
        const uint64_t chunk_samples = qmin(remaining, contiguous);
        const int chunk_bytes = (int)chunk_samples * bytes_per_sample;
        const int written = gem_audio_write(gem_audio,
                                            shm->buffer + (offset * bytes_per_sample),
                                            chunk_bytes);
        int written_samples;

        if (written <= 0)
            break;

        written_samples = written / bytes_per_sample;
        if (written_samples <= 0)
            break;

        if (!playback_started) {
            playback_started = true;
            playback_start_ms = gem_get_ticks_ms();
        }

        submit_total_samples += (uint64_t)written_samples;
    }
}

void
S_BlockSound(void)
{
    snd_blocked++;
}

void
S_UnblockSound(void)
{
    if (snd_blocked > 0)
        snd_blocked--;
}
