#ifndef WIFI_OVERLAY_H
#define WIFI_OVERLAY_H

#include "gemini.h"

#include <stdint.h>

#define WIFI_OVERLAY_MAX_NETWORKS 24
#define WIFI_OVERLAY_PASSWORD_MAX 63

typedef struct {
    char ssid[96];
    char flags[96];
    int signal_dbm;
    int secure;
} wifi_overlay_network_t;

typedef struct {
    int reconfigured;
    int internet;
    char wpa_state[32];
    char ssid[96];
    char ip[64];
    char message[160];
} wifi_overlay_status_t;

typedef struct {
    gem_fb_t *fb;
    const char *usb_path;
    int fb_w;
    int fb_h;
    void (*present_now)(void *userdata);
    void *userdata;
    int modal_open;
    int password_mode;
    int shift_down;
    int network_count;
    int selected_index;
    int scroll_index;
    uint32_t last_poll_ms;
    wifi_overlay_network_t networks[WIFI_OVERLAY_MAX_NETWORKS];
    wifi_overlay_status_t status;
    char password[WIFI_OVERLAY_PASSWORD_MAX + 1];
    char pending_ssid[96];
    char pending_flags[96];
} wifi_overlay_t;

void wifi_overlay_init(wifi_overlay_t *overlay,
                       gem_fb_t *fb,
                       int fb_w,
                       int fb_h,
                       const char *usb_path,
                       void (*present_now)(void *userdata),
                       void *userdata);
void wifi_overlay_open(wifi_overlay_t *overlay);
void wifi_overlay_close(wifi_overlay_t *overlay);
int wifi_overlay_is_open(const wifi_overlay_t *overlay);
void wifi_overlay_render(wifi_overlay_t *overlay);
int wifi_overlay_handle_touch(wifi_overlay_t *overlay, int x, int y);
int wifi_overlay_handle_key_down(wifi_overlay_t *overlay, int keycode);
int wifi_overlay_handle_key_up(wifi_overlay_t *overlay, int keycode);
int wifi_overlay_handle_gamepad_button(wifi_overlay_t *overlay, int button, int pressed);
int wifi_overlay_handle_gamepad_axis(wifi_overlay_t *overlay, int axis, int value);
int wifi_overlay_tick(wifi_overlay_t *overlay, uint32_t now_ms);

#endif
