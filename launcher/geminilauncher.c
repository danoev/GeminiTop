#include "app_catalog.h"
#include "gemini.h"
#include "sysinfo.h"
#include "wifi_overlay.h"

#include <linux/input-event-codes.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define COL_BG              0xFF1B120D
#define COL_PANEL           0xFF2A1A11
#define COL_TILE            0xFF6C3A17
#define COL_TILE_SEL        0xFFD97706
#define COL_BUTTON          0xFFB85E1B
#define COL_BUTTON_OFF      0xFF7B4319
#define COL_BORDER          0xFFFFA54B
#define COL_TEXT            0xFFFFFFFF
#define COL_TEXT_DIM        0xFFD9C7B3
#define COL_MODAL           0xFF20130D
#define COL_MODAL_ROW       0xFF4A2A15
#define COL_MODAL_ROW_SEL   0xFF8A4A1B
#define COL_FIELD           0xFF130C08

#define OUTER_PAD           20
#define INNER_PAD           16
#define CARD_RADIUS         14
#define SIDEBAR_W           360
#define BUTTON_H            58
#define GRID_COLS           3
#define GRID_ROWS           3
#define MAX_VISIBLE_APPS    (GRID_COLS * GRID_ROWS)
#define STATS_POLL_MS       2000

enum {
    SSH_STATE_DISABLED = 0,
    SSH_STATE_LOADING,
    SSH_STATE_ENABLED,
    SSH_STATE_FAILED
};

typedef struct {
    int x;
    int y;
    int w;
    int h;
} rect_t;

static gem_fb_t *fb;
static gem_input_t *input;
static gem_app_catalog_t apps;
static sysinfo_t sysinfo_state;
static char usb_path[256];
static char request_path[64];
static char ssh_state_path[64];
static uint32_t *static_scene;
static size_t static_scene_bytes;
static int fb_w;
static int fb_h;
static int selected = -1;
static int running = 1;
static int stats_enabled = 0;
static int ssh_state = SSH_STATE_DISABLED;
static int sidebar_refresh_requested = 0;
static int full_repaint_requested = 0;

static rect_t sidebar_rect;
static rect_t stats_rect;
static rect_t stats_button_rect;
static rect_t ssh_button_rect;
static rect_t wifi_button_rect;
static rect_t exit_button_rect;
static rect_t grid_rect;

static wifi_overlay_t wifi_overlay;

static void cleanup(void);
static void paint_full_frame(void);

static void clamp_rect(rect_t *rect)
{
    if (rect->x < 0) {
        rect->w += rect->x;
        rect->x = 0;
    }
    if (rect->y < 0) {
        rect->h += rect->y;
        rect->y = 0;
    }
    if (rect->x + rect->w > fb_w)
        rect->w = fb_w - rect->x;
    if (rect->y + rect->h > fb_h)
        rect->h = fb_h - rect->y;
    if (rect->w < 0)
        rect->w = 0;
    if (rect->h < 0)
        rect->h = 0;
}

static void copy_string(char *dst, size_t dst_len, const char *src)
{
    size_t len;

    if (!dst || dst_len == 0)
        return;
    if (!src) {
        dst[0] = '\0';
        return;
    }

    len = strlen(src);
    if (len >= dst_len)
        len = dst_len - 1;
    memcpy(dst, src, len);
    dst[len] = '\0';
}

static void find_usb_path(void)
{
    const char *env_usb = getenv("GEMINI_USB");
    const char *candidates[] = {
        "/tmp/sp/mnt/sda1",
        "/tmp/sp/mnt/sdb1",
        "/tmp/sp/mnt/sdc1",
        "/mnt/sda1",
        "/mnt/sdb1",
        "/mnt/sdc1",
        NULL
    };
    int i;

    if (env_usb && env_usb[0]) {
        copy_string(usb_path, sizeof(usb_path), env_usb);
        return;
    }

    for (i = 0; candidates[i]; i++) {
        if (access(candidates[i], F_OK) == 0) {
            copy_string(usb_path, sizeof(usb_path), candidates[i]);
            return;
        }
    }

    copy_string(usb_path, sizeof(usb_path), ".");
}

static void init_layout(void)
{
    sidebar_rect.x = OUTER_PAD;
    sidebar_rect.y = OUTER_PAD;
    sidebar_rect.w = SIDEBAR_W;
    sidebar_rect.h = fb_h - OUTER_PAD * 2;
    clamp_rect(&sidebar_rect);

    stats_rect.x = sidebar_rect.x + INNER_PAD;
    stats_rect.y = sidebar_rect.y + 88;
    stats_rect.w = sidebar_rect.w - INNER_PAD * 2;
    stats_rect.h = 138;

    stats_button_rect.x = sidebar_rect.x + INNER_PAD;
    stats_button_rect.y = stats_rect.y + stats_rect.h + 20;
    stats_button_rect.w = sidebar_rect.w - INNER_PAD * 2;
    stats_button_rect.h = BUTTON_H;

    ssh_button_rect.x = sidebar_rect.x + INNER_PAD;
    ssh_button_rect.y = stats_button_rect.y + BUTTON_H + 14;
    ssh_button_rect.w = sidebar_rect.w - INNER_PAD * 2;
    ssh_button_rect.h = BUTTON_H;

    wifi_button_rect.x = sidebar_rect.x + INNER_PAD;
    wifi_button_rect.y = ssh_button_rect.y + BUTTON_H + 14;
    wifi_button_rect.w = sidebar_rect.w - INNER_PAD * 2;
    wifi_button_rect.h = BUTTON_H;

    exit_button_rect.x = sidebar_rect.x + INNER_PAD;
    exit_button_rect.y = sidebar_rect.y + sidebar_rect.h - INNER_PAD - BUTTON_H;
    exit_button_rect.w = sidebar_rect.w - INNER_PAD * 2;
    exit_button_rect.h = BUTTON_H;

    grid_rect.x = sidebar_rect.x + sidebar_rect.w + OUTER_PAD;
    grid_rect.y = OUTER_PAD;
    grid_rect.w = fb_w - grid_rect.x - OUTER_PAD;
    grid_rect.h = fb_h - OUTER_PAD * 2;
    clamp_rect(&grid_rect);
}

static rect_t app_tile_rect(int index)
{
    rect_t rect;
    int gap = 18;
    int tile_w = (grid_rect.w - INNER_PAD * 2 - gap * (GRID_COLS - 1)) / GRID_COLS;
    int tile_h = (grid_rect.h - INNER_PAD * 2 - gap * (GRID_ROWS - 1)) / GRID_ROWS;
    int col = index % GRID_COLS;
    int row = index / GRID_COLS;

    rect.x = grid_rect.x + INNER_PAD + col * (tile_w + gap);
    rect.y = grid_rect.y + INNER_PAD + row * (tile_h + gap);
    rect.w = tile_w;
    rect.h = tile_h;
    clamp_rect(&rect);
    return rect;
}

static int point_in_rect(int x, int y, rect_t rect)
{
    return x >= rect.x && x < rect.x + rect.w &&
           y >= rect.y && y < rect.y + rect.h;
}

static void copy_full_static_scene(void)
{
    uint32_t *dst = gem_fb_pixels(fb);

    if (!dst || !static_scene)
        return;
    memcpy(dst, static_scene, static_scene_bytes);
}

static void draw_centered_label(rect_t rect, const char *text, int scale)
{
    int text_w = (int)strlen(text) * GEM_FONT_W * scale;
    int text_h = GEM_FONT_H * scale;
    int x = rect.x + (rect.w - text_w) / 2;
    int y = rect.y + (rect.h - text_h) / 2;

    if (x < rect.x + 8)
        x = rect.x + 8;
    if (y < rect.y + 8)
        y = rect.y + 8;
    gem_draw_text_scaled(fb, x, y, text, COL_TEXT, scale);
}

static void draw_button(rect_t rect, uint32_t fill, const char *label)
{
    gem_draw_fill_rounded_rect(fb, rect.x, rect.y, rect.w, rect.h, CARD_RADIUS, fill);
    gem_draw_rounded_rect(fb, rect.x, rect.y, rect.w, rect.h, CARD_RADIUS, COL_BORDER);
    draw_centered_label(rect, label, 2);
}

static void draw_tile(int index, int is_selected)
{
    rect_t rect = app_tile_rect(index);
    const gem_app_t *app = &apps.entries[index];

    gem_draw_fill_rounded_rect(fb, rect.x, rect.y, rect.w, rect.h, CARD_RADIUS,
                               is_selected ? COL_TILE_SEL : COL_TILE);
    gem_draw_rounded_rect(fb, rect.x, rect.y, rect.w, rect.h, CARD_RADIUS, COL_BORDER);
    draw_centered_label(rect, app->title, 2);
}

static void render_static_scene(void)
{
    int i;

    gem_fb_clear(fb, COL_BG);

    gem_draw_fill_rounded_rect(fb, sidebar_rect.x, sidebar_rect.y, sidebar_rect.w, sidebar_rect.h, 18, COL_PANEL);
    gem_draw_rounded_rect(fb, sidebar_rect.x, sidebar_rect.y, sidebar_rect.w, sidebar_rect.h, 18, COL_BORDER);
    gem_draw_text_scaled(fb, sidebar_rect.x + INNER_PAD, sidebar_rect.y + 20, "Gemini Launcher", COL_TEXT, 2);

    gem_draw_fill_rounded_rect(fb, stats_rect.x, stats_rect.y, stats_rect.w, stats_rect.h, CARD_RADIUS, COL_TILE);
    gem_draw_rounded_rect(fb, stats_rect.x, stats_rect.y, stats_rect.w, stats_rect.h, CARD_RADIUS, COL_BORDER);

    gem_draw_fill_rounded_rect(fb, grid_rect.x, grid_rect.y, grid_rect.w, grid_rect.h, 18, COL_PANEL);
    gem_draw_rounded_rect(fb, grid_rect.x, grid_rect.y, grid_rect.w, grid_rect.h, 18, COL_BORDER);

    for (i = 0; i < apps.count && i < MAX_VISIBLE_APPS; i++)
        draw_tile(i, 0);

    if (apps.count <= 0) {
        rect_t rect = app_tile_rect(0);
        gem_draw_fill_rounded_rect(fb, rect.x, rect.y, rect.w, rect.h, CARD_RADIUS, COL_TILE);
        gem_draw_rounded_rect(fb, rect.x, rect.y, rect.w, rect.h, CARD_RADIUS, COL_BORDER);
        draw_centered_label(rect, "No Apps", 2);
    }

    draw_button(exit_button_rect, COL_BUTTON_OFF, "Exit");
}

static int cache_static_scene(void)
{
    render_static_scene();
    static_scene_bytes = (size_t)gem_fb_stride(fb) * (size_t)fb_h;
    static_scene = malloc(static_scene_bytes);
    if (!static_scene)
        return -1;
    memcpy(static_scene, gem_fb_pixels(fb), static_scene_bytes);
    return 0;
}

static void render_sidebar_dynamic(void)
{
    char line[96];
    const char *ssh_label = "Enable SSH";
    uint32_t ssh_fill = COL_BUTTON;

    if (stats_enabled) {
        snprintf(line, sizeof(line), "CPU: %5.1f%%", sysinfo_state.cpu_usage);
        gem_draw_text_scaled(fb, stats_rect.x + 16, stats_rect.y + 20, line, COL_TEXT, 2);
        snprintf(line, sizeof(line), "RAM: %d / %d MB",
                 sysinfo_state.mem_used_kb / 1024,
                 sysinfo_state.mem_total_kb / 1024);
        gem_draw_text_scaled(fb, stats_rect.x + 16, stats_rect.y + 70, line, COL_TEXT, 2);
    } else {
        gem_draw_text_scaled(fb, stats_rect.x + 16, stats_rect.y + 20, "CPU: OFF", COL_TEXT, 2);
        gem_draw_text_scaled(fb, stats_rect.x + 16, stats_rect.y + 70, "RAM: OFF", COL_TEXT, 2);
    }

    draw_button(stats_button_rect,
                stats_enabled ? COL_BUTTON_OFF : COL_BUTTON,
                stats_enabled ? "Disable Stats" : "Enable Stats");

    if (ssh_state == SSH_STATE_LOADING) {
        ssh_label = "Loading...";
        ssh_fill = COL_BUTTON_OFF;
    } else if (ssh_state == SSH_STATE_ENABLED) {
        ssh_label = "SSH Enabled";
        ssh_fill = COL_BUTTON_OFF;
    } else if (ssh_state == SSH_STATE_FAILED) {
        ssh_label = "SSH Failed";
        ssh_fill = COL_BUTTON_OFF;
    }
    draw_button(ssh_button_rect, ssh_fill, ssh_label);

    draw_button(wifi_button_rect,
                wifi_overlay_is_open(&wifi_overlay) ? COL_BUTTON_OFF : COL_BUTTON,
                "Wi-Fi");
}

static void present_wifi_overlay(void *userdata)
{
    (void)userdata;
    paint_full_frame();
}

static void paint_full_frame(void)
{
    copy_full_static_scene();
    render_sidebar_dynamic();
    if (selected >= 0 && selected < apps.count && selected < MAX_VISIBLE_APPS)
        draw_tile(selected, 1);
    if (wifi_overlay_is_open(&wifi_overlay))
        wifi_overlay_render(&wifi_overlay);
    gem_fb_flip(fb);
}

static int write_request(const char *request)
{
    FILE *file;
    char temp_path[96];
    int fd;

    snprintf(temp_path, sizeof(temp_path), "/tmp/gemini_launch.XXXXXX");
    fd = mkstemp(temp_path);
    if (fd < 0)
        return -1;

    file = fdopen(fd, "w");
    if (!file) {
        close(fd);
        unlink(temp_path);
        return -1;
    }

    fprintf(file, "%s\n", request);
    fclose(file);
    unlink(request_path);
    if (rename(temp_path, request_path) != 0) {
        unlink(temp_path);
        return -1;
    }

    return 0;
}

static void launch_selected(void)
{
    char request[128];

    if (selected < 0 || selected >= apps.count)
        return;

    snprintf(request, sizeof(request), "launch:%s", apps.entries[selected].id);
    if (write_request(request) == 0)
        running = 0;
}

static void request_ssh_toggle(void)
{
    if (ssh_state == SSH_STATE_ENABLED || ssh_state == SSH_STATE_LOADING)
        return;
    if (write_request("control:ssh:enable") == 0) {
        ssh_state = SSH_STATE_LOADING;
        sidebar_refresh_requested = 1;
    }
}

static void update_stats_snapshot(void)
{
    if (stats_enabled)
        sysinfo_update_core(&sysinfo_state);
}

static int hit_app_tile(int x, int y)
{
    int i;

    for (i = 0; i < apps.count && i < MAX_VISIBLE_APPS; i++) {
        if (point_in_rect(x, y, app_tile_rect(i)))
            return i;
    }
    return -1;
}

static void open_wifi_modal(void)
{
    wifi_overlay_open(&wifi_overlay);
    full_repaint_requested = 1;
}

static void handle_touch_main(int x, int y)
{
    int hit;

    if (point_in_rect(x, y, exit_button_rect)) {
        running = 0;
        return;
    }

    if (point_in_rect(x, y, stats_button_rect)) {
        stats_enabled = !stats_enabled;
        update_stats_snapshot();
        sidebar_refresh_requested = 1;
        return;
    }

    if (point_in_rect(x, y, ssh_button_rect)) {
        request_ssh_toggle();
        return;
    }

    if (point_in_rect(x, y, wifi_button_rect)) {
        open_wifi_modal();
        return;
    }

    hit = hit_app_tile(x, y);
    if (hit >= 0) {
        selected = hit;
        launch_selected();
    }
}

static void handle_key_down_main(int keycode)
{
    if (keycode == KEY_ESC) {
        running = 0;
    } else if (keycode == KEY_UP && selected - GRID_COLS >= 0) {
        selected -= GRID_COLS;
    } else if (keycode == KEY_DOWN &&
               selected + GRID_COLS < apps.count &&
               selected + GRID_COLS < MAX_VISIBLE_APPS) {
        selected += GRID_COLS;
    } else if (keycode == KEY_LEFT && selected > 0) {
        selected--;
    } else if (keycode == KEY_RIGHT &&
               selected >= 0 &&
               selected + 1 < apps.count &&
               selected + 1 < MAX_VISIBLE_APPS) {
        selected++;
    } else if (keycode == KEY_ENTER) {
        launch_selected();
    }
}

static void handle_input(void)
{
    gem_event_t ev;

    while (input && gem_input_poll(input, &ev)) {
        switch (ev.type) {
        case GEM_EVENT_KEY_DOWN:
            if (wifi_overlay_is_open(&wifi_overlay)) {
                if (wifi_overlay_handle_key_down(&wifi_overlay, ev.key.code))
                    full_repaint_requested = 1;
            } else {
                handle_key_down_main(ev.key.code);
            }
            break;

        case GEM_EVENT_KEY_UP:
            if (wifi_overlay_is_open(&wifi_overlay) &&
                wifi_overlay_handle_key_up(&wifi_overlay, ev.key.code))
                full_repaint_requested = 1;
            break;

        case GEM_EVENT_TOUCH_DOWN:
            if (wifi_overlay_is_open(&wifi_overlay)) {
                if (wifi_overlay_handle_touch(&wifi_overlay, ev.touch.x, ev.touch.y))
                    full_repaint_requested = 1;
            } else {
                handle_touch_main(ev.touch.x, ev.touch.y);
            }
            break;

        case GEM_EVENT_GAMEPAD_BUTTON:
            if (ev.gamepad_button.pressed &&
                (ev.gamepad_button.button == BTN_DPAD_UP ||
                 ev.gamepad_button.button == BTN_DPAD_DOWN ||
                 ev.gamepad_button.button == BTN_DPAD_LEFT ||
                 ev.gamepad_button.button == BTN_DPAD_RIGHT)) {
                int keycode = 0;

                if (ev.gamepad_button.button == BTN_DPAD_UP)
                    keycode = KEY_UP;
                else if (ev.gamepad_button.button == BTN_DPAD_DOWN)
                    keycode = KEY_DOWN;
                else if (ev.gamepad_button.button == BTN_DPAD_LEFT)
                    keycode = KEY_LEFT;
                else if (ev.gamepad_button.button == BTN_DPAD_RIGHT)
                    keycode = KEY_RIGHT;

                if (wifi_overlay_is_open(&wifi_overlay)) {
                    if (wifi_overlay_handle_key_down(&wifi_overlay, keycode))
                        full_repaint_requested = 1;
                } else {
                    handle_key_down_main(keycode);
                }
                break;
            }

            if (wifi_overlay_is_open(&wifi_overlay)) {
                if (wifi_overlay_handle_gamepad_button(&wifi_overlay,
                                                       ev.gamepad_button.button,
                                                       ev.gamepad_button.pressed))
                    full_repaint_requested = 1;
            } else if (ev.gamepad_button.pressed) {
                if (ev.gamepad_button.button == BTN_SOUTH)
                    launch_selected();
                else if (ev.gamepad_button.button == BTN_EAST)
                    running = 0;
            }
            break;

        case GEM_EVENT_GAMEPAD_AXIS:
            if (wifi_overlay_is_open(&wifi_overlay)) {
                if (wifi_overlay_handle_gamepad_axis(&wifi_overlay,
                                                     ev.gamepad_axis.axis,
                                                     ev.gamepad_axis.value))
                    full_repaint_requested = 1;
                break;
            }
            if (apps.count <= 0)
                break;
            if (ev.gamepad_axis.axis == ABS_HAT0X) {
                if (ev.gamepad_axis.value > 8000 && selected + 1 < apps.count && selected + 1 < MAX_VISIBLE_APPS)
                    selected++;
                else if (ev.gamepad_axis.value < -8000 && selected > 0)
                    selected--;
            } else if (ev.gamepad_axis.axis == ABS_HAT0Y) {
                if (ev.gamepad_axis.value > 8000 && selected + GRID_COLS < apps.count && selected + GRID_COLS < MAX_VISIBLE_APPS)
                    selected += GRID_COLS;
                else if (ev.gamepad_axis.value < -8000 && selected - GRID_COLS >= 0)
                    selected -= GRID_COLS;
            }
            break;

        default:
            break;
        }

        if (!running)
            return;
    }
}

static void cleanup(void)
{
    if (input) {
        gem_input_close(input);
        input = NULL;
    }
    if (fb) {
        gem_fb_close(fb);
        fb = NULL;
    }
    free(static_scene);
    static_scene = NULL;
    static_scene_bytes = 0;
}

static void refresh_ssh_state(void)
{
    FILE *file = fopen(ssh_state_path, "r");
    char state[32];
    int new_ssh_state = SSH_STATE_DISABLED;

    if (!file)
        return;
    if (!fgets(state, sizeof(state), file)) {
        fclose(file);
        return;
    }
    fclose(file);
    state[strcspn(state, "\r\n")] = '\0';
    if (strcmp(state, "loading") == 0)
        new_ssh_state = SSH_STATE_LOADING;
    else if (strcmp(state, "enabled") == 0)
        new_ssh_state = SSH_STATE_ENABLED;
    else if (strcmp(state, "failed") == 0)
        new_ssh_state = SSH_STATE_FAILED;

    if (new_ssh_state != ssh_state) {
        ssh_state = new_ssh_state;
        sidebar_refresh_requested = 1;
    }
}

int main(void)
{
    char apps_dir[512];
    char catalog_path[512];
    uint32_t last_stats_ms = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    find_usb_path();
    snprintf(request_path, sizeof(request_path), "/tmp/gemini_launch");
    snprintf(ssh_state_path, sizeof(ssh_state_path), "/tmp/gemini_ssh_state");

    gem_system_init(cleanup);

    fb = gem_fb_open();
    if (!fb) {
        gem_system_shutdown();
        return 1;
    }

    fb_w = (int)gem_fb_width(fb);
    fb_h = (int)gem_fb_height(fb);
    init_layout();
    wifi_overlay_init(&wifi_overlay, fb, fb_w, fb_h, usb_path, present_wifi_overlay, NULL);

    input = gem_input_open();
    snprintf(apps_dir, sizeof(apps_dir), "%s/apps", usb_path);
    snprintf(catalog_path, sizeof(catalog_path), "%s/apps/%s",
             usb_path, GEM_APP_CATALOG_INDEX);
    gem_apps_load(&apps, apps_dir, catalog_path);
    selected = apps.count > 0 ? 0 : -1;
    unlink(request_path);

    if (cache_static_scene() != 0) {
        cleanup();
        gem_system_shutdown();
        return 1;
    }

    paint_full_frame();

    while (running) {
        uint32_t now_ms = gem_get_ticks_ms();
        int old_selected = selected;

        refresh_ssh_state();

        if (stats_enabled && now_ms - last_stats_ms >= STATS_POLL_MS) {
            update_stats_snapshot();
            last_stats_ms = now_ms;
            sidebar_refresh_requested = 1;
        }

        if (wifi_overlay_tick(&wifi_overlay, now_ms))
            full_repaint_requested = 1;

        handle_input();
        if (!running)
            break;

        if (selected != old_selected)
            full_repaint_requested = 1;
        if (sidebar_refresh_requested) {
            full_repaint_requested = 1;
            sidebar_refresh_requested = 0;
        }
        if (stats_enabled && last_stats_ms == 0) {
            update_stats_snapshot();
            last_stats_ms = now_ms;
            full_repaint_requested = 1;
        }

        if (full_repaint_requested) {
            paint_full_frame();
            full_repaint_requested = 0;
            gem_sleep_ms(16);
        } else {
            gem_sleep_ms(60);
        }
    }

    cleanup();
    if (access(request_path, F_OK) != 0)
        gem_system_shutdown();
    return 0;
}
