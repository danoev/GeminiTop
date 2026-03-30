#include "gemini.h"

#include <linux/input-event-codes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define AUDIO_RATE 22050
#define AUDIO_CHANNELS 2
#define AUDIO_BITS 16
#define AUDIO_CHUNK_FRAMES 256
#define MAX_NOTES 128
#define TABLE_SIZE 2048
#define WHITE_KEY_COUNT 8
#define BLACK_KEY_COUNT 5
#define DEFAULT_OCTAVE 4
#define MIN_OCTAVE 2
#define MAX_OCTAVE 6
#define COLOR_BG 0x0F141B
#define COLOR_PANEL 0x15202B
#define COLOR_PANEL_BORDER 0x2B3B4A
#define COLOR_TEXT 0xE7EEF7
#define COLOR_SUBTEXT 0x8CA0B3
#define COLOR_ACCENT 0xF2C14E
#define COLOR_ACCENT_DIM 0x8D6A14
#define COLOR_WHITE_KEY 0xF4F1EA
#define COLOR_WHITE_KEY_EDGE 0xA9B0BA
#define COLOR_WHITE_KEY_ACTIVE 0xFFE3A3
#define COLOR_BLACK_KEY 0x202630
#define COLOR_BLACK_KEY_EDGE 0x3E4A57
#define COLOR_BLACK_KEY_ACTIVE 0xFFBC42

typedef struct {
    int x;
    int y;
    int w;
    int h;
} ui_rect_t;

typedef struct {
    int x;
    int y;
    int w;
    int h;
    int midi;
    int semitone;
    bool is_black;
    char label[16];
} piano_key_t;

typedef struct {
    bool active;
    bool gate;
    float phase;
    float step;
    float level;
    float peak;
} synth_note_t;

typedef enum {
    TOUCH_TARGET_NONE = 0,
    TOUCH_TARGET_KEY,
    TOUCH_TARGET_OCTAVE_DOWN,
    TOUCH_TARGET_OCTAVE_UP,
    TOUCH_TARGET_EXIT,
} touch_target_type_t;

typedef struct {
    touch_target_type_t type;
    int key_index;
} touch_target_t;

static gem_fb_t *g_fb;
static gem_input_t *g_input;
static gem_audio_t *g_audio;

static int g_fb_w;
static int g_fb_h;

static synth_note_t g_notes[MAX_NOTES];
static float g_freq_table[MAX_NOTES];
static int16_t g_audio_buffer[AUDIO_CHUNK_FRAMES * AUDIO_CHANNELS];
static int16_t g_wave_table[TABLE_SIZE];

static piano_key_t g_white_keys[WHITE_KEY_COUNT];
static piano_key_t g_black_keys[BLACK_KEY_COUNT];
static int g_white_count;
static int g_black_count;
static int g_octave = DEFAULT_OCTAVE;
static int g_last_note = 60;
static bool g_running = true;
static bool g_touch_down = false;
static int g_touch_note = -1;
static touch_target_t g_touch_target;
static double g_pending_frames = 0.0;
static uint32_t g_last_audio_ms = 0;

static ui_rect_t g_header_rect;
static ui_rect_t g_octave_down_button;
static ui_rect_t g_octave_up_button;
static ui_rect_t g_octave_badge_rect;
static ui_rect_t g_exit_button;
static ui_rect_t g_meter_rect;
static int g_header_inner_pad;
static bool g_compact_header = false;

static const int kWhiteSemitones[WHITE_KEY_COUNT] = { 0, 2, 4, 5, 7, 9, 11, 12 };
static const int kBlackSemitones[BLACK_KEY_COUNT] = { 1, 3, 6, 8, 10 };
static const int kBlackAnchorWhite[BLACK_KEY_COUNT] = { 0, 1, 3, 4, 5 };
static const char *kWhiteLabels[WHITE_KEY_COUNT] = { "C", "D", "E", "F", "G", "A", "B", "C" };
static const char *kBlackLabels[BLACK_KEY_COUNT] = { "C#", "D#", "F#", "G#", "A#" };

static void app_cleanup(void)
{
    if (g_audio) {
        gem_audio_close(g_audio);
        g_audio = NULL;
    }
    if (g_input) {
        gem_input_close(g_input);
        g_input = NULL;
    }
    if (g_fb) {
        gem_fb_close(g_fb);
        g_fb = NULL;
    }
    gem_system_shutdown();
}

static int clamp_i(int value, int lo, int hi)
{
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

static float clamp_f(float value, float lo, float hi)
{
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

static int text_width(const char *text, int scale)
{
    return (int)strlen(text) * GEM_FONT_W * scale;
}

static int midi_to_octave(int midi)
{
    return (midi / 12) - 1;
}

static void midi_to_name(int midi, char *buffer, size_t buffer_size)
{
    static const char *names[12] = {
        "C", "C#", "D", "D#", "E", "F",
        "F#", "G", "G#", "A", "A#", "B"
    };

    snprintf(buffer, buffer_size, "%s%d", names[midi % 12], midi_to_octave(midi));
}

static void build_wave_table(void)
{
    for (int i = 0; i < TABLE_SIZE; i++) {
        float phase = (2.0f * (float)M_PI * (float)i) / (float)TABLE_SIZE;
        float wave = sinf(phase);
        wave += 0.32f * sinf(phase * 2.0f);
        wave += 0.12f * sinf(phase * 3.0f);
        wave += 0.05f * sinf(phase * 5.0f);
        wave *= 0.62f;
        g_wave_table[i] = (int16_t)(wave * 32767.0f);
    }
}

static void init_freq_table(void)
{
    for (int midi = 0; midi < MAX_NOTES; midi++)
        g_freq_table[midi] = 440.0f * powf(2.0f, ((float)midi - 69.0f) / 12.0f);
}

static void rebuild_keyboard_layout(void)
{
    int outer_pad = clamp_i(g_fb_w / 24, 24, 56);
    int section_gap = clamp_i(g_fb_w / 80, 12, 24);
    int control_h = 56;
    int meter_h = 64;
    int exit_w = clamp_i(g_fb_w / 10, 116, 148);
    int exit_h = 52;
    int title_row_h = 64;
    int row_gap = 14;
    int controls_y;
    int key_area_x;
    int key_area_w;
    int key_area_y;
    int key_area_h;
    int white_w;
    int white_h;
    int black_w;
    int black_h;
    int root_midi = (g_octave + 1) * 12;

    g_header_inner_pad = clamp_i(g_fb_w / 64, 16, 28);
    g_header_rect.x = outer_pad;
    g_header_rect.y = 24;
    g_header_rect.w = g_fb_w - (outer_pad * 2);
    g_compact_header = g_header_rect.w < 980;

    g_exit_button.w = exit_w;
    g_exit_button.h = exit_h;
    g_exit_button.x = g_header_rect.x + g_header_rect.w - g_header_inner_pad - exit_w;
    g_exit_button.y = g_header_rect.y + g_header_inner_pad + 4;

    controls_y = g_header_rect.y + g_header_inner_pad + title_row_h + row_gap;

    if (g_compact_header) {
        int controls_w = g_header_rect.w - (g_header_inner_pad * 2);
        int button_w = clamp_i((controls_w - (section_gap * 2)) / 3, 104, 144);

        g_octave_down_button.x = g_header_rect.x + g_header_inner_pad;
        g_octave_down_button.y = controls_y;
        g_octave_down_button.w = button_w;
        g_octave_down_button.h = control_h;

        g_octave_up_button = g_octave_down_button;
        g_octave_up_button.x += button_w + section_gap;

        g_octave_badge_rect.x = g_octave_up_button.x + button_w + section_gap;
        g_octave_badge_rect.y = controls_y;
        g_octave_badge_rect.w = g_header_rect.x + g_header_rect.w - g_header_inner_pad - g_octave_badge_rect.x;
        g_octave_badge_rect.h = control_h;

        g_meter_rect.x = g_header_rect.x + g_header_inner_pad;
        g_meter_rect.y = controls_y + control_h + row_gap;
        g_meter_rect.w = g_header_rect.w - (g_header_inner_pad * 2);
        g_meter_rect.h = meter_h;

        g_header_rect.h = (g_meter_rect.y + g_meter_rect.h + g_header_inner_pad) - g_header_rect.y;
    } else {
        int meter_w = clamp_i(g_header_rect.w / 3, 280, 400);
        int controls_w = g_header_rect.w - (g_header_inner_pad * 2) - meter_w - section_gap;
        int button_w = clamp_i((controls_w - (section_gap * 2) - 180) / 2, 108, 148);
        int badge_w;

        badge_w = controls_w - (button_w * 2) - (section_gap * 2);
        if (badge_w < 160) {
            int shortage = 160 - badge_w;
            button_w = clamp_i(button_w - ((shortage + 1) / 2), 92, 148);
            badge_w = controls_w - (button_w * 2) - (section_gap * 2);
        }

        g_octave_down_button.x = g_header_rect.x + g_header_inner_pad;
        g_octave_down_button.y = controls_y;
        g_octave_down_button.w = button_w;
        g_octave_down_button.h = control_h;

        g_octave_up_button = g_octave_down_button;
        g_octave_up_button.x += button_w + section_gap;

        g_octave_badge_rect.x = g_octave_up_button.x + button_w + section_gap;
        g_octave_badge_rect.y = controls_y;
        g_octave_badge_rect.w = badge_w;
        g_octave_badge_rect.h = control_h;

        g_meter_rect.w = meter_w;
        g_meter_rect.h = meter_h;
        g_meter_rect.x = g_header_rect.x + g_header_rect.w - g_header_inner_pad - meter_w;
        g_meter_rect.y = controls_y - ((meter_h - control_h) / 2);

        g_header_rect.h = (controls_y + control_h + g_header_inner_pad) - g_header_rect.y;
    }

    key_area_x = outer_pad;
    key_area_w = g_fb_w - (outer_pad * 2);
    key_area_y = g_header_rect.y + g_header_rect.h + clamp_i(g_fb_h / 40, 18, 28);
    key_area_h = g_fb_h - key_area_y - clamp_i(g_fb_h / 12, 72, 104);
    if (key_area_h < 220)
        key_area_h = 220;

    white_w = key_area_w / WHITE_KEY_COUNT;
    white_h = key_area_h;
    black_w = (white_w * 58) / 100;
    black_h = (white_h * 62) / 100;

    if (black_h > white_h - 80)
        black_h = white_h - 80;
    if (black_h < 120)
        black_h = 120;

    g_white_count = WHITE_KEY_COUNT;
    g_black_count = BLACK_KEY_COUNT;

    for (int i = 0; i < WHITE_KEY_COUNT; i++) {
        piano_key_t *key = &g_white_keys[i];
        key->x = key_area_x + (i * white_w);
        key->y = key_area_y;
        key->w = white_w;
        key->h = white_h;
        key->semitone = kWhiteSemitones[i];
        key->midi = root_midi + key->semitone;
        key->is_black = false;
        snprintf(key->label, sizeof(key->label), "%s%d", kWhiteLabels[i], midi_to_octave(key->midi));
    }

    for (int i = 0; i < BLACK_KEY_COUNT; i++) {
        int left_index = kBlackAnchorWhite[i];
        piano_key_t *left = &g_white_keys[left_index];
        piano_key_t *right = &g_white_keys[left_index + 1];
        piano_key_t *key = &g_black_keys[i];

        key->w = black_w;
        key->h = black_h;
        key->x = ((left->x + left->w) + right->x) / 2 - (black_w / 2);
        key->y = key_area_y;
        key->semitone = kBlackSemitones[i];
        key->midi = root_midi + key->semitone;
        key->is_black = true;
        snprintf(key->label, sizeof(key->label), "%s%d", kBlackLabels[i], midi_to_octave(key->midi));
    }
}

static bool point_in_rect(int x, int y, int rx, int ry, int rw, int rh)
{
    return x >= rx && x < (rx + rw) && y >= ry && y < (ry + rh);
}

static int hit_test_key(int x, int y)
{
    for (int i = 0; i < g_black_count; i++) {
        piano_key_t *key = &g_black_keys[i];
        if (point_in_rect(x, y, key->x, key->y, key->w, key->h))
            return key->midi;
    }

    for (int i = 0; i < g_white_count; i++) {
        piano_key_t *key = &g_white_keys[i];
        if (point_in_rect(x, y, key->x, key->y, key->w, key->h))
            return key->midi;
    }

    return -1;
}

static touch_target_t hit_test_touch_target(int x, int y)
{
    touch_target_t target;

    target.type = TOUCH_TARGET_NONE;
    target.key_index = -1;

    if (point_in_rect(x, y, g_octave_down_button.x, g_octave_down_button.y,
                      g_octave_down_button.w, g_octave_down_button.h)) {
        target.type = TOUCH_TARGET_OCTAVE_DOWN;
        return target;
    }

    if (point_in_rect(x, y, g_octave_up_button.x, g_octave_up_button.y,
                      g_octave_up_button.w, g_octave_up_button.h)) {
        target.type = TOUCH_TARGET_OCTAVE_UP;
        return target;
    }

    if (point_in_rect(x, y, g_exit_button.x, g_exit_button.y, g_exit_button.w, g_exit_button.h)) {
        target.type = TOUCH_TARGET_EXIT;
        return target;
    }

    target.key_index = hit_test_key(x, y);
    if (target.key_index >= 0)
        target.type = TOUCH_TARGET_KEY;

    return target;
}

static void note_on(int midi)
{
    synth_note_t *note;

    if (midi < 0 || midi >= MAX_NOTES)
        return;

    note = &g_notes[midi];
    note->active = true;
    note->gate = true;
    note->phase = 0.0f;
    note->step = ((float)TABLE_SIZE * g_freq_table[midi]) / (float)AUDIO_RATE;
    note->level = 0.0f;
    note->peak = 1.0f;
    g_last_note = midi;
}

static void note_off(int midi)
{
    if (midi < 0 || midi >= MAX_NOTES)
        return;
    g_notes[midi].gate = false;
}

static void all_notes_off(void)
{
    for (int i = 0; i < MAX_NOTES; i++)
        g_notes[i].gate = false;
    g_touch_note = -1;
}

static void change_octave(int delta)
{
    int next_octave = clamp_i(g_octave + delta, MIN_OCTAVE, MAX_OCTAVE);

    if (next_octave == g_octave)
        return;

    all_notes_off();
    g_octave = next_octave;
    rebuild_keyboard_layout();
}

static void render_button(int x, int y, int w, int h, const char *text, bool active)
{
    uint32_t fill = active ? COLOR_ACCENT : COLOR_PANEL;
    uint32_t edge = active ? COLOR_ACCENT : COLOR_PANEL_BORDER;
    uint32_t text_color = active ? COLOR_BG : COLOR_TEXT;
    int text_scale = 2;
    int text_w = text_width(text, text_scale);
    int text_h = GEM_FONT_H * text_scale;

    gem_draw_fill_rounded_rect(g_fb, x, y, w, h, 16, fill);
    gem_draw_rounded_rect(g_fb, x, y, w, h, 16, edge);
    gem_draw_text_scaled(g_fb, x + (w - text_w) / 2, y + (h - text_h) / 2, text, text_color, text_scale);
}

static void render_info_badge(ui_rect_t rect, const char *label, const char *value)
{
    gem_draw_fill_rounded_rect(g_fb, rect.x, rect.y, rect.w, rect.h, 18, COLOR_PANEL);
    gem_draw_rounded_rect(g_fb, rect.x, rect.y, rect.w, rect.h, 18, COLOR_PANEL_BORDER);
    gem_draw_text(g_fb, rect.x + 16, rect.y + 10, label, COLOR_SUBTEXT);
    gem_draw_text_scaled(g_fb, rect.x + 16, rect.y + 24, value, COLOR_TEXT, 2);
}

static void render_meter(float level, const char *note_name)
{
    int label_w = text_width(note_name, 1);
    int bar_x = g_meter_rect.x + 16;
    int bar_y = g_meter_rect.y + 34;
    int bar_w = g_meter_rect.w - 32;

    gem_draw_fill_rounded_rect(g_fb, g_meter_rect.x, g_meter_rect.y, g_meter_rect.w, g_meter_rect.h, 18, COLOR_PANEL);
    gem_draw_rounded_rect(g_fb, g_meter_rect.x, g_meter_rect.y, g_meter_rect.w, g_meter_rect.h, 18, COLOR_PANEL_BORDER);
    gem_draw_text(g_fb, g_meter_rect.x + 16, g_meter_rect.y + 12, "OUTPUT", COLOR_SUBTEXT);
    gem_draw_text(g_fb, g_meter_rect.x + g_meter_rect.w - 16 - label_w, g_meter_rect.y + 12, note_name, COLOR_TEXT);
    gem_draw_bar(g_fb, bar_x, bar_y, bar_w, 14, clamp_f(level, 0.0f, 1.0f), COLOR_ACCENT, COLOR_PANEL_BORDER);
}

static void render_white_key(const piano_key_t *key)
{
    bool active = g_notes[key->midi].active;
    uint32_t fill = active ? COLOR_WHITE_KEY_ACTIVE : COLOR_WHITE_KEY;
    uint32_t border = active ? COLOR_ACCENT_DIM : COLOR_WHITE_KEY_EDGE;
    int label_y = key->y + key->h - 54;

    gem_draw_fill_rounded_rect(g_fb, key->x + 2, key->y, key->w - 4, key->h, 18, fill);
    gem_draw_rounded_rect(g_fb, key->x + 2, key->y, key->w - 4, key->h, 18, border);
    gem_draw_text_scaled(g_fb, key->x + 18, label_y, key->label, COLOR_BG, 2);
}

static void render_black_key(const piano_key_t *key)
{
    bool active = g_notes[key->midi].active;
    uint32_t fill = active ? COLOR_BLACK_KEY_ACTIVE : COLOR_BLACK_KEY;
    uint32_t border = active ? COLOR_ACCENT : COLOR_BLACK_KEY_EDGE;
    int label_w = (int)strlen(key->label) * GEM_FONT_W;

    gem_draw_fill_rounded_rect(g_fb, key->x, key->y, key->w, key->h, 16, fill);
    gem_draw_rounded_rect(g_fb, key->x, key->y, key->w, key->h, 16, border);
    gem_draw_text(g_fb, key->x + (key->w - label_w) / 2, key->y + key->h - 28, key->label, COLOR_TEXT);
}

static void render_ui(void)
{
    char note_name[16];
    char subtitle[96];
    char help_line[128];
    char octave_line[32];
    float active_level = g_notes[g_last_note].level;
    int title_x = g_header_rect.x + g_header_inner_pad;
    int title_y = g_header_rect.y + g_header_inner_pad;
    int footer_x = g_header_rect.x + g_header_inner_pad;

    gem_fb_clear(g_fb, COLOR_BG);

    gem_draw_fill_rounded_rect(g_fb, g_header_rect.x, g_header_rect.y, g_header_rect.w, g_header_rect.h, 24, COLOR_PANEL);
    gem_draw_rounded_rect(g_fb, g_header_rect.x, g_header_rect.y, g_header_rect.w, g_header_rect.h, 24, COLOR_PANEL_BORDER);
    gem_draw_text_scaled(g_fb, title_x, title_y, "Pocket Piano", COLOR_TEXT, 3);

    midi_to_name(g_last_note, note_name, sizeof(note_name));
    snprintf(subtitle, sizeof(subtitle), "Current note %s  %.2f Hz", note_name, g_freq_table[g_last_note]);
    gem_draw_text(g_fb, title_x, title_y + 46, subtitle, COLOR_SUBTEXT);

    snprintf(octave_line, sizeof(octave_line), "Octave %d", g_octave);
    render_button(g_octave_down_button.x, g_octave_down_button.y, g_octave_down_button.w, g_octave_down_button.h, "OCT -",
                  g_touch_down && g_touch_target.type == TOUCH_TARGET_OCTAVE_DOWN);
    render_button(g_octave_up_button.x, g_octave_up_button.y, g_octave_up_button.w, g_octave_up_button.h, "OCT +",
                  g_touch_down && g_touch_target.type == TOUCH_TARGET_OCTAVE_UP);
    render_info_badge(g_octave_badge_rect, "RANGE", octave_line);
    render_button(g_exit_button.x, g_exit_button.y, g_exit_button.w, g_exit_button.h, "EXIT",
                  g_touch_down && g_touch_target.type == TOUCH_TARGET_EXIT);
    render_meter(active_level, note_name);

    for (int i = 0; i < g_white_count; i++)
        render_white_key(&g_white_keys[i]);
    for (int i = 0; i < g_black_count; i++)
        render_black_key(&g_black_keys[i]);

    snprintf(help_line, sizeof(help_line), "Keys: A W S E D F T G Y H U J K  |  Octave: Z/X  |  Quit: ESC, Q, EXIT");
    gem_draw_text(g_fb, footer_x, g_fb_h - 36, help_line, COLOR_SUBTEXT);

    gem_fb_flip(g_fb);
}

static void synth_audio_chunk(int frames)
{
    for (int i = 0; i < frames; i++) {
        float mix = 0.0f;
        int sample;

        for (int midi = 0; midi < MAX_NOTES; midi++) {
            synth_note_t *note = &g_notes[midi];
            int idx;
            float voice;

            if (!note->active)
                continue;

            if (note->gate) {
                if (note->level < note->peak) {
                    note->level += 0.018f;
                    if (note->level > note->peak)
                        note->level = note->peak;
                } else if (note->level > 0.38f) {
                    note->level *= 0.9994f;
                } else {
                    note->level = 0.38f;
                }
            } else {
                note->level *= 0.991f;
                if (note->level < 0.001f) {
                    note->active = false;
                    note->level = 0.0f;
                    continue;
                }
            }

            idx = (int)note->phase;
            if (idx >= TABLE_SIZE)
                idx %= TABLE_SIZE;

            voice = ((float)g_wave_table[idx] / 32767.0f) * note->level;
            mix += voice;

            note->phase += note->step;
            while (note->phase >= (float)TABLE_SIZE)
                note->phase -= (float)TABLE_SIZE;
        }

        mix = clamp_f(mix * 0.22f, -0.98f, 0.98f);
        sample = (int)(mix * 32767.0f);
        g_audio_buffer[i * 2] = (int16_t)sample;
        g_audio_buffer[i * 2 + 1] = (int16_t)sample;
    }

    if (g_audio)
        gem_audio_write(g_audio, g_audio_buffer, frames * AUDIO_CHANNELS * (int)sizeof(int16_t));
}

static void update_audio(void)
{
    uint32_t now = gem_get_ticks_ms();
    uint32_t elapsed = now - g_last_audio_ms;

    g_last_audio_ms = now;
    g_pending_frames += ((double)elapsed * (double)AUDIO_RATE) / 1000.0;

    if (g_pending_frames < (double)AUDIO_CHUNK_FRAMES)
        return;

    while (g_pending_frames >= (double)AUDIO_CHUNK_FRAMES) {
        synth_audio_chunk(AUDIO_CHUNK_FRAMES);
        g_pending_frames -= (double)AUDIO_CHUNK_FRAMES;
    }
}

static int keycode_to_midi(int keycode)
{
    int root_midi = (g_octave + 1) * 12;

    switch (keycode) {
    case KEY_A: return root_midi + 0;
    case KEY_W: return root_midi + 1;
    case KEY_S: return root_midi + 2;
    case KEY_E: return root_midi + 3;
    case KEY_D: return root_midi + 4;
    case KEY_F: return root_midi + 5;
    case KEY_T: return root_midi + 6;
    case KEY_G: return root_midi + 7;
    case KEY_Y: return root_midi + 8;
    case KEY_H: return root_midi + 9;
    case KEY_U: return root_midi + 10;
    case KEY_J: return root_midi + 11;
    case KEY_K: return root_midi + 12;
    default:
        return -1;
    }
}

static void handle_touch_target(touch_target_t target, bool is_new_press)
{
    if (target.type == TOUCH_TARGET_KEY) {
        if (target.key_index != g_touch_note) {
            if (g_touch_note >= 0)
                note_off(g_touch_note);
            g_touch_note = target.key_index;
            note_on(g_touch_note);
        }
        return;
    }

    if (g_touch_note >= 0) {
        note_off(g_touch_note);
        g_touch_note = -1;
    }

    if (!is_new_press)
        return;

    if (target.type == TOUCH_TARGET_OCTAVE_DOWN)
        change_octave(-1);
    else if (target.type == TOUCH_TARGET_OCTAVE_UP)
        change_octave(1);
    else if (target.type == TOUCH_TARGET_EXIT)
        g_running = false;
}

static void process_input(void)
{
    gem_event_t ev;

    while (gem_input_poll(g_input, &ev)) {
        switch (ev.type) {
        case GEM_EVENT_KEY_DOWN: {
            int midi = keycode_to_midi(ev.key.code);

            if (ev.key.code == KEY_ESC || ev.key.code == KEY_Q) {
                g_running = false;
            } else if (ev.key.code == KEY_Z) {
                change_octave(-1);
            } else if (ev.key.code == KEY_X) {
                change_octave(1);
            } else if (midi >= 0) {
                note_on(midi);
            }
            break;
        }
        case GEM_EVENT_KEY_UP: {
            int midi = keycode_to_midi(ev.key.code);

            if (midi >= 0)
                note_off(midi);
            break;
        }
        case GEM_EVENT_TOUCH_DOWN:
            g_touch_down = true;
            g_touch_target = hit_test_touch_target(ev.touch.x, ev.touch.y);
            handle_touch_target(g_touch_target, true);
            break;
        case GEM_EVENT_TOUCH_MOVE:
            if (!g_touch_down)
                break;
            g_touch_target = hit_test_touch_target(ev.touch.x, ev.touch.y);
            handle_touch_target(g_touch_target, false);
            break;
        case GEM_EVENT_TOUCH_UP:
            g_touch_down = false;
            if (g_touch_note >= 0) {
                note_off(g_touch_note);
                g_touch_note = -1;
            }
            g_touch_target.type = TOUCH_TARGET_NONE;
            g_touch_target.key_index = -1;
            break;
        default:
            break;
        }
    }
}

int main(void)
{
    gem_log_init();
    gem_system_init(app_cleanup);

    g_fb = gem_fb_open();
    g_input = gem_input_open();
    g_audio = gem_audio_open(AUDIO_RATE, AUDIO_CHANNELS, AUDIO_BITS);

    if (!g_fb || !g_input) {
        gem_log(GEM_LOG_ERROR, "piano: failed to initialize video/input\n");
        app_cleanup();
        return 1;
    }

    g_fb_w = (int)gem_fb_width(g_fb);
    g_fb_h = (int)gem_fb_height(g_fb);
    g_last_note = (DEFAULT_OCTAVE + 1) * 12;

    build_wave_table();
    init_freq_table();
    rebuild_keyboard_layout();

    g_last_audio_ms = gem_get_ticks_ms();
    g_pending_frames = AUDIO_CHUNK_FRAMES * 2.0;

    while (g_running) {
        process_input();
        update_audio();
        render_ui();
        gem_sleep_ms(16);
    }

    app_cleanup();
    return 0;
}
