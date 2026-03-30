// libgemini note:
// This header and the companion libgemini sources reflect a known-good runtime
// configuration for the SunPlus SP7021 Gemini head unit in the USB-launcher
// environment. Preserve the current audio/video/input/system assumptions unless
// they are re-validated on hardware.

#ifndef GEMINI_H
#define GEMINI_H

#include <stdint.h>
#include <stdbool.h>

// logging
#define GEM_LOG_ERROR  0
#define GEM_LOG_WARN   1
#define GEM_LOG_INFO   2
#define GEM_LOG_DEBUG  3

void gem_log_init(void);                // Read GEM_LOG_LEVEL env var (error/warn/info/debug)
void gem_log_set_level(int level);      // Set level programmatically
void gem_log(int level, const char *fmt, ...)
     __attribute__((format(printf, 2, 3)));

// video

typedef struct gem_fb gem_fb_t;

gem_fb_t *gem_fb_open(void);
void      gem_fb_close(gem_fb_t *fb);
uint32_t *gem_fb_pixels(gem_fb_t *fb);       // Get pointer to current back buffer
uint32_t  gem_fb_stride(gem_fb_t *fb);       // Stride in bytes
uint32_t  gem_fb_width(gem_fb_t *fb);        // Display width in pixels (e.g. 1920)
uint32_t  gem_fb_height(gem_fb_t *fb);       // Display height in pixels (e.g. 720)
void      gem_fb_copy_front_to_back(gem_fb_t *fb); // Duplicate current display page into back buffer
void      gem_fb_flip(gem_fb_t *fb);         // Swap front/back buffer (FBIOPAN_DISPLAY)
void      gem_fb_clear(gem_fb_t *fb, uint32_t color); // Fill back buffer (alpha forced 0xFF)

// Blit a smaller buffer to the framebuffer with nearest-neighbor scaling, centered.
// src is width*height uint32_t pixels in 0x00RRGGBB format (alpha is forced to 0xFF).
void      gem_fb_blit_scaled(gem_fb_t *fb, const uint32_t *src, int src_w, int src_h);

// drawing primitives (8x16 bitmap font)
#define GEM_FONT_W 8
#define GEM_FONT_H 16

void gem_draw_fill_rect(gem_fb_t *fb, int x, int y, int w, int h, uint32_t color);
void gem_draw_rect(gem_fb_t *fb, int x, int y, int w, int h, uint32_t color);
void gem_draw_fill_rounded_rect(gem_fb_t *fb, int x, int y, int w, int h, int r, uint32_t color);
void gem_draw_rounded_rect(gem_fb_t *fb, int x, int y, int w, int h, int r, uint32_t color);
int  gem_draw_char(gem_fb_t *fb, int x, int y, char ch, uint32_t color);
int  gem_draw_text(gem_fb_t *fb, int x, int y, const char *text, uint32_t color);
int  gem_draw_text_scaled(gem_fb_t *fb, int x, int y, const char *text,
                          uint32_t color, int scale);
void gem_draw_bar(gem_fb_t *fb, int x, int y, int w, int h,
                  float fraction, uint32_t fg, uint32_t bg);

// input

// Unified event types
typedef enum {
    GEM_EVENT_NONE = 0,
    GEM_EVENT_KEY_DOWN,
    GEM_EVENT_KEY_UP,
    GEM_EVENT_TOUCH_DOWN,
    GEM_EVENT_TOUCH_UP,
    GEM_EVENT_TOUCH_MOVE,
    GEM_EVENT_MOUSE_MOVE,      // Relative mouse motion
    GEM_EVENT_MOUSE_BUTTON,    // Mouse button
    GEM_EVENT_GAMEPAD_BUTTON,  // Gamepad button press/release
    GEM_EVENT_GAMEPAD_AXIS,    // Gamepad analog axis
} gem_event_type_t;

typedef struct {
    gem_event_type_t type;
    union {
        struct { int code; } key;                          // Linux KEY_* code
        struct { int x, y; } touch;                        // Absolute touch coordinates
        struct { int dx, dy; } mouse_move;                 // Relative mouse delta
        struct { int button; int pressed; } mouse_button;  // BTN_LEFT etc
        struct { int button; int pressed; } gamepad_button; // BTN_SOUTH etc
        struct { int axis; int value; } gamepad_axis;      // ABS_X, ABS_Y etc (-32768..32767 normalized)
    };
} gem_event_t;

typedef struct gem_input gem_input_t;

gem_input_t *gem_input_open(void);
void         gem_input_close(gem_input_t *in);
bool         gem_input_poll(gem_input_t *in, gem_event_t *ev);  // Returns true if event available
bool         gem_input_has_gamepad(gem_input_t *in);             // Any gamepad connected?

// audio
typedef struct gem_audio gem_audio_t;

// Open audio output. rate=sample rate (e.g. 11025, 22050, 44100), channels=1 or 2, bits=16
// Spawns as_spaudiotrack reading from a FIFO.
gem_audio_t *gem_audio_open(int rate, int channels, int bits);
void         gem_audio_close(gem_audio_t *a);

// Write PCM data. Non-blocking — drops data silently if pipe is full.
// Returns bytes actually written (may be less than len if pipe full).
int          gem_audio_write(gem_audio_t *a, const void *pcm, int len);

// audio mixer (software N-channel PCM mixer -> gem_audio)
#define GEM_MIXER_MAX_CHANNELS 16

typedef struct gem_mixer gem_mixer_t;

// Open a mixer. Internally opens gem_audio for output.
// buffer_ms = mixing buffer size in milliseconds (e.g. 40).
gem_mixer_t *gem_mixer_open(int sample_rate, int channels_out, int bits,
                            int buffer_ms);
void         gem_mixer_close(gem_mixer_t *m);

// Play mono S16LE samples on a channel. Data is NOT copied — caller keeps it alive.
// channel >= 0: use that channel (replaces current sound).
// channel < 0: auto-assign a free channel.
// Returns channel number or -1 on failure.
int  gem_mixer_play(gem_mixer_t *m, int channel, const int16_t *data,
                    uint32_t num_samples, int vol_left, int vol_right);
void gem_mixer_stop(gem_mixer_t *m, int channel);
void gem_mixer_set_volume(gem_mixer_t *m, int channel, int vol_left, int vol_right);
int  gem_mixer_is_playing(gem_mixer_t *m, int channel);

// Mix all active channels and write to audio output. Call once per frame.
void gem_mixer_update(gem_mixer_t *m);

// system / lifecycle

// SIGSTOPs stock Launcher, installs signal handlers. cleanup_fn called on fatal signal (can be NULL).
void gem_system_init(void (*cleanup_fn)(void));

// SIGCONTs stock Launcher.
void gem_system_shutdown(void);

// Get milliseconds since gem_system_init()
uint32_t gem_get_ticks_ms(void);

// Sleep for ms milliseconds
void gem_sleep_ms(uint32_t ms);

#endif // GEMINI_H
