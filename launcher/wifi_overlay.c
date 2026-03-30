#include "wifi_overlay.h"

#include <linux/input-event-codes.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

#define WIFI_CARD_RADIUS       14
#define WIFI_BUTTON_H          58
#define WIFI_INNER_PAD         16
#define WIFI_POLL_MS           1500
#define WIFI_LIST_HEADER_H     64
#define WIFI_LIST_FOOTER_H     28
#define WIFI_LIST_ROW_H        62
#define WIFI_LIST_ROW_GAP      10
#define WIFI_SCROLL_RAIL_W     92
#define WIFI_SCROLL_BTN_H      52

#define COL_BG                 0xFF1B120D
#define COL_BORDER             0xFFFFA54B
#define COL_BUTTON             0xFFB85E1B
#define COL_BUTTON_OFF         0xFF7B4319
#define COL_FIELD              0xFF130C08
#define COL_MODAL              0xFF20130D
#define COL_MODAL_ROW          0xFF4A2A15
#define COL_MODAL_ROW_SEL      0xFF8A4A1B
#define COL_TEXT               0xFFFFFFFF
#define COL_TEXT_DIM           0xFFD9C7B3
#define COL_TILE               0xFF6C3A17

typedef struct {
    int x;
    int y;
    int w;
    int h;
} rect_t;

static void wifi_clamp_rect(const wifi_overlay_t *overlay, rect_t *rect)
{
    if (rect->x < 0) {
        rect->w += rect->x;
        rect->x = 0;
    }
    if (rect->y < 0) {
        rect->h += rect->y;
        rect->y = 0;
    }
    if (rect->x + rect->w > overlay->fb_w)
        rect->w = overlay->fb_w - rect->x;
    if (rect->y + rect->h > overlay->fb_h)
        rect->h = overlay->fb_h - rect->y;
    if (rect->w < 0)
        rect->w = 0;
    if (rect->h < 0)
        rect->h = 0;
}

static void wifi_copy_string(char *dst, size_t dst_len, const char *src)
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

static void wifi_trim_line(char *line)
{
    size_t len;

    if (!line)
        return;

    len = strlen(line);
    while (len > 0 && (line[len - 1] == '\r' || line[len - 1] == '\n' ||
                       line[len - 1] == ' ' || line[len - 1] == '\t')) {
        line[--len] = '\0';
    }
    while (*line == ' ' || *line == '\t')
        memmove(line, line + 1, strlen(line));
}

static int wifi_point_in_rect(int x, int y, rect_t rect)
{
    return x >= rect.x && x < rect.x + rect.w &&
           y >= rect.y && y < rect.y + rect.h;
}

static void wifi_draw_centered_label(wifi_overlay_t *overlay, rect_t rect, const char *text, int scale)
{
    int text_w = (int)strlen(text) * GEM_FONT_W * scale;
    int text_h = GEM_FONT_H * scale;
    int x = rect.x + (rect.w - text_w) / 2;
    int y = rect.y + (rect.h - text_h) / 2;

    if (x < rect.x + 8)
        x = rect.x + 8;
    if (y < rect.y + 8)
        y = rect.y + 8;
    gem_draw_text_scaled(overlay->fb, x, y, text, COL_TEXT, scale);
}

static void wifi_draw_button(wifi_overlay_t *overlay, rect_t rect, uint32_t fill, const char *label)
{
    gem_draw_fill_rounded_rect(overlay->fb, rect.x, rect.y, rect.w, rect.h, WIFI_CARD_RADIUS, fill);
    gem_draw_rounded_rect(overlay->fb, rect.x, rect.y, rect.w, rect.h, WIFI_CARD_RADIUS, COL_BORDER);
    wifi_draw_centered_label(overlay, rect, label, 2);
}

static void wifi_present_now(const wifi_overlay_t *overlay)
{
    if (overlay->present_now)
        overlay->present_now(overlay->userdata);
}

static rect_t wifi_modal_rect(const wifi_overlay_t *overlay)
{
    rect_t rect;

    rect.w = overlay->fb_w - 360;
    rect.h = overlay->fb_h - 72;
    if (rect.w > 1160)
        rect.w = 1160;
    if (rect.h > 640)
        rect.h = 640;
    if (rect.w < 980)
        rect.w = 980;
    if (rect.h < 560)
        rect.h = 560;
    rect.x = (overlay->fb_w - rect.w) / 2;
    rect.y = (overlay->fb_h - rect.h) / 2;
    wifi_clamp_rect(overlay, &rect);
    return rect;
}

static rect_t wifi_close_rect(const rect_t modal)
{
    rect_t rect;

    rect.w = 170;
    rect.h = WIFI_BUTTON_H;
    rect.x = modal.x + modal.w - WIFI_INNER_PAD - rect.w;
    rect.y = modal.y + WIFI_INNER_PAD;
    return rect;
}

static rect_t wifi_status_rect(const rect_t modal)
{
    rect_t rect;

    rect.x = modal.x + WIFI_INNER_PAD;
    rect.y = modal.y + 74;
    rect.w = modal.w - WIFI_INNER_PAD * 2;
    rect.h = 96;
    return rect;
}

static rect_t wifi_actions_rect(const rect_t modal)
{
    rect_t rect;
    rect_t status = wifi_status_rect(modal);

    rect.x = modal.x + WIFI_INNER_PAD;
    rect.y = status.y + status.h + 16;
    rect.w = modal.w - WIFI_INNER_PAD * 2;
    rect.h = WIFI_BUTTON_H;
    return rect;
}

static rect_t wifi_action_button_rect(const rect_t actions_rect, int index)
{
    rect_t rect;
    int gap = 16;
    int width = (actions_rect.w - gap * 2) / 3;

    rect.x = actions_rect.x + index * (width + gap);
    rect.y = actions_rect.y;
    rect.w = width;
    rect.h = actions_rect.h;
    return rect;
}

static rect_t wifi_content_rect(const rect_t modal)
{
    rect_t rect;
    rect_t actions = wifi_actions_rect(modal);

    rect.x = modal.x + WIFI_INNER_PAD;
    rect.y = actions.y + actions.h + 18;
    rect.w = modal.w - WIFI_INNER_PAD * 2;
    rect.h = modal.y + modal.h - rect.y - WIFI_INNER_PAD;
    return rect;
}

static rect_t wifi_password_panel_rect(const rect_t content_rect)
{
    rect_t rect;

    rect.x = content_rect.x;
    rect.w = content_rect.w;
    rect.h = 154;
    rect.y = content_rect.y + content_rect.h - rect.h;
    return rect;
}

static rect_t wifi_list_rect(const wifi_overlay_t *overlay, const rect_t modal)
{
    rect_t rect = wifi_content_rect(modal);

    if (overlay->password_mode)
        rect.h -= wifi_password_panel_rect(rect).h + 16;
    return rect;
}

static rect_t wifi_list_body_rect(const wifi_overlay_t *overlay, const rect_t modal)
{
    rect_t rect = wifi_list_rect(overlay, modal);

    rect.x += 12;
    rect.y += WIFI_LIST_HEADER_H;
    rect.w -= WIFI_SCROLL_RAIL_W + 24;
    rect.h -= WIFI_LIST_HEADER_H + WIFI_LIST_FOOTER_H;
    wifi_clamp_rect(overlay, &rect);
    return rect;
}

static rect_t wifi_list_scroll_rect(const wifi_overlay_t *overlay, const rect_t modal)
{
    rect_t list = wifi_list_rect(overlay, modal);
    rect_t rect;

    rect.w = WIFI_SCROLL_RAIL_W - 12;
    rect.h = list.h - WIFI_LIST_HEADER_H - WIFI_LIST_FOOTER_H;
    rect.x = list.x + list.w - rect.w - 12;
    rect.y = list.y + WIFI_LIST_HEADER_H;
    wifi_clamp_rect(overlay, &rect);
    return rect;
}

static rect_t wifi_scroll_button_rect(const wifi_overlay_t *overlay, const rect_t modal, int up)
{
    rect_t rail = wifi_list_scroll_rect(overlay, modal);
    rect_t rect;

    rect.x = rail.x;
    rect.w = rail.w;
    rect.h = WIFI_SCROLL_BTN_H;
    rect.y = up ? rail.y : rail.y + rail.h - rect.h;
    return rect;
}

static int wifi_visible_network_rows(const wifi_overlay_t *overlay, const rect_t modal)
{
    rect_t body = wifi_list_body_rect(overlay, modal);
    int slots;

    if (body.h <= 0)
        return 0;

    slots = (body.h + WIFI_LIST_ROW_GAP) / (WIFI_LIST_ROW_H + WIFI_LIST_ROW_GAP);
    if (slots < 1)
        slots = 1;
    return slots;
}

static void wifi_clamp_scroll(wifi_overlay_t *overlay, int visible_rows)
{
    int max_scroll;

    if (!overlay)
        return;

    if (visible_rows < 1)
        visible_rows = 1;

    max_scroll = overlay->network_count - visible_rows;
    if (max_scroll < 0)
        max_scroll = 0;

    if (overlay->scroll_index < 0)
        overlay->scroll_index = 0;
    if (overlay->scroll_index > max_scroll)
        overlay->scroll_index = max_scroll;
}

static void wifi_ensure_selection_visible(wifi_overlay_t *overlay)
{
    rect_t modal;
    int visible_rows;

    if (!overlay)
        return;

    modal = wifi_modal_rect(overlay);
    visible_rows = wifi_visible_network_rows(overlay, modal);
    wifi_clamp_scroll(overlay, visible_rows);

    if (overlay->selected_index < 0 || overlay->network_count <= 0)
        return;

    if (overlay->selected_index < overlay->scroll_index)
        overlay->scroll_index = overlay->selected_index;
    else if (overlay->selected_index >= overlay->scroll_index + visible_rows)
        overlay->scroll_index = overlay->selected_index - visible_rows + 1;

    wifi_clamp_scroll(overlay, visible_rows);
}

static void wifi_move_selection(wifi_overlay_t *overlay, int delta)
{
    int next;

    if (!overlay || overlay->network_count <= 0)
        return;

    if (overlay->selected_index < 0)
        overlay->selected_index = 0;

    next = overlay->selected_index + delta;
    if (next < 0)
        next = 0;
    if (next >= overlay->network_count)
        next = overlay->network_count - 1;

    overlay->selected_index = next;
    wifi_ensure_selection_visible(overlay);
}

static void wifi_page_selection(wifi_overlay_t *overlay, int direction)
{
    rect_t modal;
    int visible_rows;
    int step;

    if (!overlay || overlay->network_count <= 0)
        return;

    modal = wifi_modal_rect(overlay);
    visible_rows = wifi_visible_network_rows(overlay, modal);
    step = visible_rows > 1 ? visible_rows - 1 : 1;
    wifi_move_selection(overlay, direction * step);
}

static void wifi_jump_selection(wifi_overlay_t *overlay, int index)
{
    if (!overlay || overlay->network_count <= 0)
        return;

    if (index < 0)
        index = 0;
    if (index >= overlay->network_count)
        index = overlay->network_count - 1;

    overlay->selected_index = index;
    wifi_ensure_selection_visible(overlay);
}

static rect_t wifi_network_row_rect(const wifi_overlay_t *overlay, const rect_t modal, int visible_index)
{
    rect_t body = wifi_list_body_rect(overlay, modal);
    rect_t rect;

    rect.x = body.x;
    rect.y = body.y + visible_index * (WIFI_LIST_ROW_H + WIFI_LIST_ROW_GAP);
    rect.w = body.w;
    rect.h = WIFI_LIST_ROW_H;
    return rect;
}

static rect_t wifi_password_field_rect(const rect_t panel_rect)
{
    rect_t rect;

    rect.x = panel_rect.x + 16;
    rect.y = panel_rect.y + 48;
    rect.w = panel_rect.w - 32;
    rect.h = 48;
    return rect;
}

static rect_t wifi_password_connect_rect(const rect_t panel_rect)
{
    rect_t rect;

    rect.w = 176;
    rect.h = WIFI_BUTTON_H;
    rect.x = panel_rect.x + panel_rect.w - rect.w * 2 - 14 - 16;
    rect.y = panel_rect.y + panel_rect.h - rect.h - 16;
    return rect;
}

static rect_t wifi_password_cancel_rect(const rect_t panel_rect)
{
    rect_t rect = wifi_password_connect_rect(panel_rect);

    rect.x += rect.w + 14;
    return rect;
}

static int wifi_run_capture(wifi_overlay_t *overlay, const char *action, char *buffer, size_t buffer_len)
{
    FILE *pipe;
    char cmd[768];
    size_t used = 0;
    int status;

    if (!overlay || !overlay->usb_path || !buffer || buffer_len == 0)
        return -1;

    buffer[0] = '\0';
    snprintf(cmd, sizeof(cmd), "sh \"%s/gemini_wifi.sh\" %s", overlay->usb_path, action);
    pipe = popen(cmd, "r");
    if (!pipe)
        return -1;

    while (fgets(buffer + used, (int)(buffer_len - used), pipe)) {
        used = strlen(buffer);
        if (used + 1 >= buffer_len)
            break;
    }

    status = pclose(pipe);
    if (status == -1)
        return -1;
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
        return 0;
    return -1;
}

static int wifi_write_temp_file(const char *name, const char *value)
{
    char path[128];
    FILE *file;

    snprintf(path, sizeof(path), "/tmp/gemini_wifi/%s", name);
    file = fopen(path, "w");
    if (!file)
        return -1;
    fputs(value ? value : "", file);
    fclose(file);
    return 0;
}

static void wifi_clear_networks(wifi_overlay_t *overlay)
{
    memset(overlay->networks, 0, sizeof(overlay->networks));
    overlay->network_count = 0;
    overlay->selected_index = -1;
    overlay->scroll_index = 0;
}

static void wifi_set_message(wifi_overlay_t *overlay, const char *message)
{
    wifi_copy_string(overlay->status.message, sizeof(overlay->status.message), message);
}

static void wifi_parse_status_buffer(wifi_overlay_t *overlay, const char *buffer)
{
    char line[256];
    const char *cursor = buffer;

    memset(&overlay->status, 0, sizeof(overlay->status));

    while (cursor && *cursor) {
        const char *next = strchr(cursor, '\n');
        size_t len = next ? (size_t)(next - cursor) : strlen(cursor);
        const char *value;

        if (len >= sizeof(line))
            len = sizeof(line) - 1;
        memcpy(line, cursor, len);
        line[len] = '\0';
        wifi_trim_line(line);

        value = strchr(line, '=');
        if (value) {
            size_t key_len = (size_t)(value - line);

            value++;
            if (strncmp(line, "reconfigured", key_len) == 0 && key_len == strlen("reconfigured"))
                overlay->status.reconfigured = atoi(value);
            else if (strncmp(line, "internet", key_len) == 0 && key_len == strlen("internet"))
                overlay->status.internet = atoi(value);
            else if (strncmp(line, "wpa_state", key_len) == 0 && key_len == strlen("wpa_state"))
                wifi_copy_string(overlay->status.wpa_state, sizeof(overlay->status.wpa_state), value);
            else if (strncmp(line, "ssid", key_len) == 0 && key_len == strlen("ssid"))
                wifi_copy_string(overlay->status.ssid, sizeof(overlay->status.ssid), value);
            else if (strncmp(line, "ip", key_len) == 0 && key_len == strlen("ip"))
                wifi_copy_string(overlay->status.ip, sizeof(overlay->status.ip), value);
            else if (strncmp(line, "message", key_len) == 0 && key_len == strlen("message"))
                wifi_copy_string(overlay->status.message, sizeof(overlay->status.message), value);
        }

        cursor = next ? next + 1 : NULL;
    }
}

static void wifi_refresh_status(wifi_overlay_t *overlay)
{
    char output[1024];

    if (wifi_run_capture(overlay, "status", output, sizeof(output)) == 0)
        wifi_parse_status_buffer(overlay, output);
}

static int wifi_network_compare(const void *lhs, const void *rhs)
{
    const wifi_overlay_network_t *left = lhs;
    const wifi_overlay_network_t *right = rhs;

    return right->signal_dbm - left->signal_dbm;
}

static void wifi_parse_scan_line(wifi_overlay_t *overlay, char *line)
{
    char *signal;
    char *secure;
    char *flags;
    char *ssid;
    int i;
    int best_index = -1;

    signal = strtok(line, "\t");
    secure = strtok(NULL, "\t");
    flags = strtok(NULL, "\t");
    ssid = strtok(NULL, "");

    if (!signal || !secure || !flags || !ssid || !ssid[0])
        return;

    for (i = 0; i < overlay->network_count; i++) {
        if (strcmp(overlay->networks[i].ssid, ssid) == 0) {
            best_index = i;
            break;
        }
    }

    if (best_index < 0) {
        if (overlay->network_count >= WIFI_OVERLAY_MAX_NETWORKS)
            return;
        best_index = overlay->network_count++;
    } else if (atoi(signal) < overlay->networks[best_index].signal_dbm) {
        return;
    }

    wifi_copy_string(overlay->networks[best_index].ssid, sizeof(overlay->networks[best_index].ssid), ssid);
    wifi_copy_string(overlay->networks[best_index].flags, sizeof(overlay->networks[best_index].flags), flags);
    overlay->networks[best_index].signal_dbm = atoi(signal);
    overlay->networks[best_index].secure = atoi(secure);
}

static void wifi_scan_networks(wifi_overlay_t *overlay)
{
    char output[8192];
    char *cursor;

    wifi_clear_networks(overlay);
    wifi_set_message(overlay, "Scanning nearby networks...");
    wifi_present_now(overlay);

    if (wifi_run_capture(overlay, "scan", output, sizeof(output)) != 0) {
        wifi_refresh_status(overlay);
        if (!overlay->status.message[0])
            wifi_set_message(overlay, "Scan failed.");
        return;
    }

    cursor = output;
    while (cursor && *cursor) {
        char line[256];
        const char *next = strchr(cursor, '\n');
        size_t len = next ? (size_t)(next - cursor) : strlen(cursor);

        if (len >= sizeof(line))
            len = sizeof(line) - 1;
        memcpy(line, cursor, len);
        line[len] = '\0';
        wifi_trim_line(line);
        if (line[0])
            wifi_parse_scan_line(overlay, line);
        cursor = next ? (char *)(next + 1) : NULL;
    }

    qsort(overlay->networks, overlay->network_count, sizeof(overlay->networks[0]), wifi_network_compare);

    if (overlay->network_count > 0) {
        overlay->selected_index = 0;
        overlay->scroll_index = 0;
        wifi_set_message(overlay, "Choose a network to connect.");
    } else {
        wifi_set_message(overlay, "No visible SSIDs were found.");
    }
    wifi_refresh_status(overlay);
    if (overlay->network_count > 0)
        wifi_set_message(overlay, "Choose a network to connect.");
}

static void wifi_reconfigure(wifi_overlay_t *overlay)
{
    char output[1024];

    wifi_set_message(overlay, "Taking over the Wi-Fi radio...");
    wifi_present_now(overlay);

    if (wifi_run_capture(overlay, "reconfigure", output, sizeof(output)) == 0) {
        wifi_parse_status_buffer(overlay, output);
        if (!overlay->status.message[0])
            wifi_set_message(overlay, "Station mode is ready for scanning.");
    } else {
        wifi_refresh_status(overlay);
        if (!overlay->status.message[0])
            wifi_set_message(overlay, "Wi-Fi reconfigure failed.");
    }
}

static void wifi_disconnect(wifi_overlay_t *overlay)
{
    char output[1024];

    if (wifi_run_capture(overlay, "disconnect", output, sizeof(output)) == 0)
        wifi_parse_status_buffer(overlay, output);
    else
        wifi_refresh_status(overlay);
}

static void wifi_connect_pending(wifi_overlay_t *overlay)
{
    char output[1024];

    if (wifi_write_temp_file("ssid", overlay->pending_ssid) != 0 ||
        wifi_write_temp_file("pass", overlay->password) != 0 ||
        wifi_write_temp_file("flags", overlay->pending_flags) != 0) {
        wifi_set_message(overlay, "Unable to prepare Wi-Fi request.");
        return;
    }

    wifi_set_message(overlay, "Connecting...");
    wifi_present_now(overlay);

    if (wifi_run_capture(overlay, "connect", output, sizeof(output)) == 0) {
        wifi_parse_status_buffer(overlay, output);
        overlay->password_mode = 0;
        memset(overlay->password, 0, sizeof(overlay->password));
    } else {
        wifi_refresh_status(overlay);
        if (!overlay->status.message[0])
            wifi_set_message(overlay, "Connection failed.");
    }
}

static void wifi_begin_connect(wifi_overlay_t *overlay, int index)
{
    if (index < 0 || index >= overlay->network_count)
        return;

    overlay->selected_index = index;
    wifi_ensure_selection_visible(overlay);
    wifi_copy_string(overlay->pending_ssid, sizeof(overlay->pending_ssid), overlay->networks[index].ssid);
    wifi_copy_string(overlay->pending_flags, sizeof(overlay->pending_flags), overlay->networks[index].flags);
    memset(overlay->password, 0, sizeof(overlay->password));

    if (overlay->networks[index].secure) {
        overlay->password_mode = 1;
        wifi_set_message(overlay, "Type the network password, then press Enter.");
    } else {
        overlay->password_mode = 0;
        wifi_connect_pending(overlay);
    }
}

static char wifi_keycode_to_ascii(int keycode, int shift)
{
    if (keycode >= KEY_1 && keycode <= KEY_9) {
        static const char shifted[] = { '!', '@', '#', '$', '%', '^', '&', '*', '(' };

        return shift ? shifted[keycode - KEY_1] : (char)('1' + (keycode - KEY_1));
    }
    if (keycode >= KEY_KP1 && keycode <= KEY_KP9)
        return (char)('1' + (keycode - KEY_KP1));
    if (keycode == KEY_0 || keycode == KEY_KP0)
        return shift ? ')' : '0';

    switch (keycode) {
    case KEY_A: return shift ? 'A' : 'a';
    case KEY_B: return shift ? 'B' : 'b';
    case KEY_C: return shift ? 'C' : 'c';
    case KEY_D: return shift ? 'D' : 'd';
    case KEY_E: return shift ? 'E' : 'e';
    case KEY_F: return shift ? 'F' : 'f';
    case KEY_G: return shift ? 'G' : 'g';
    case KEY_H: return shift ? 'H' : 'h';
    case KEY_I: return shift ? 'I' : 'i';
    case KEY_J: return shift ? 'J' : 'j';
    case KEY_K: return shift ? 'K' : 'k';
    case KEY_L: return shift ? 'L' : 'l';
    case KEY_M: return shift ? 'M' : 'm';
    case KEY_N: return shift ? 'N' : 'n';
    case KEY_O: return shift ? 'O' : 'o';
    case KEY_P: return shift ? 'P' : 'p';
    case KEY_Q: return shift ? 'Q' : 'q';
    case KEY_R: return shift ? 'R' : 'r';
    case KEY_S: return shift ? 'S' : 's';
    case KEY_T: return shift ? 'T' : 't';
    case KEY_U: return shift ? 'U' : 'u';
    case KEY_V: return shift ? 'V' : 'v';
    case KEY_W: return shift ? 'W' : 'w';
    case KEY_X: return shift ? 'X' : 'x';
    case KEY_Y: return shift ? 'Y' : 'y';
    case KEY_Z: return shift ? 'Z' : 'z';
    case KEY_SPACE: return ' ';
    case KEY_MINUS: return shift ? '_' : '-';
    case KEY_EQUAL: return shift ? '+' : '=';
    case KEY_LEFTBRACE: return shift ? '{' : '[';
    case KEY_RIGHTBRACE: return shift ? '}' : ']';
    case KEY_SEMICOLON: return shift ? ':' : ';';
    case KEY_APOSTROPHE: return shift ? '"' : '\'';
    case KEY_GRAVE: return shift ? '~' : '`';
    case KEY_BACKSLASH: return shift ? '|' : '\\';
    case KEY_COMMA: return shift ? '<' : ',';
    case KEY_DOT: return shift ? '>' : '.';
    case KEY_SLASH: return shift ? '?' : '/';
    case KEY_KPASTERISK: return '*';
    case KEY_KPMINUS: return '-';
    case KEY_KPPLUS: return '+';
    case KEY_KPDOT: return '.';
    case KEY_KPSLASH: return '/';
    default:
        return '\0';
    }
}

static int wifi_key_is_enter(int keycode)
{
    return keycode == KEY_ENTER || keycode == KEY_KPENTER;
}

static int wifi_key_is_backspace(int keycode)
{
    return keycode == KEY_BACKSPACE || keycode == KEY_DELETE;
}

static void wifi_password_backspace(wifi_overlay_t *overlay)
{
    size_t len = strlen(overlay->password);

    if (len > 0)
        overlay->password[len - 1] = '\0';
}

static void wifi_password_append(wifi_overlay_t *overlay, char ch)
{
    size_t len = strlen(overlay->password);

    if (len >= WIFI_OVERLAY_PASSWORD_MAX)
        return;
    overlay->password[len] = ch;
    overlay->password[len + 1] = '\0';
}

static void wifi_field_text(char *dst, size_t dst_len, const char *text, int max_chars)
{
    size_t len;

    if (!dst || dst_len == 0) {
        return;
    }
    if (!text || !text[0]) {
        dst[0] = '\0';
        return;
    }

    len = strlen(text);
    if ((int)len <= max_chars || max_chars < 4) {
        wifi_copy_string(dst, dst_len, text);
        return;
    }

    snprintf(dst, dst_len, "...%s", text + len - (size_t)(max_chars - 3));
}

void wifi_overlay_init(wifi_overlay_t *overlay,
                       gem_fb_t *fb,
                       int fb_w,
                       int fb_h,
                       const char *usb_path,
                       void (*present_now)(void *userdata),
                       void *userdata)
{
    if (!overlay)
        return;

    memset(overlay, 0, sizeof(*overlay));
    overlay->fb = fb;
    overlay->fb_w = fb_w;
    overlay->fb_h = fb_h;
    overlay->usb_path = usb_path;
    overlay->present_now = present_now;
    overlay->userdata = userdata;
    overlay->selected_index = -1;
    overlay->scroll_index = 0;
}

void wifi_overlay_open(wifi_overlay_t *overlay)
{
    if (!overlay)
        return;

    overlay->modal_open = 1;
    overlay->password_mode = 0;
    overlay->shift_down = 0;
    memset(overlay->password, 0, sizeof(overlay->password));
    wifi_ensure_selection_visible(overlay);
    wifi_refresh_status(overlay);
}

void wifi_overlay_close(wifi_overlay_t *overlay)
{
    if (!overlay)
        return;

    overlay->modal_open = 0;
    overlay->password_mode = 0;
    overlay->shift_down = 0;
    memset(overlay->password, 0, sizeof(overlay->password));
}

int wifi_overlay_is_open(const wifi_overlay_t *overlay)
{
    return overlay && overlay->modal_open;
}

void wifi_overlay_render(wifi_overlay_t *overlay)
{
    rect_t modal;
    rect_t close_rect;
    rect_t status_rect;
    rect_t actions_rect;
    rect_t list_rect;
    rect_t list_body_rect;
    rect_t scroll_rect;
    rect_t scroll_up_rect;
    rect_t scroll_down_rect;
    int visible_rows;
    int first_visible;
    int last_visible;
    int i;
    char line[196];

    if (!overlay || !overlay->fb || !overlay->modal_open)
        return;

    modal = wifi_modal_rect(overlay);
    close_rect = wifi_close_rect(modal);
    status_rect = wifi_status_rect(modal);
    actions_rect = wifi_actions_rect(modal);
    list_rect = wifi_list_rect(overlay, modal);
    list_body_rect = wifi_list_body_rect(overlay, modal);
    scroll_rect = wifi_list_scroll_rect(overlay, modal);
    scroll_up_rect = wifi_scroll_button_rect(overlay, modal, 1);
    scroll_down_rect = wifi_scroll_button_rect(overlay, modal, 0);
    visible_rows = wifi_visible_network_rows(overlay, modal);
    wifi_clamp_scroll(overlay, visible_rows);
    first_visible = overlay->network_count > 0 ? overlay->scroll_index + 1 : 0;
    last_visible = overlay->scroll_index + visible_rows;
    if (last_visible > overlay->network_count)
        last_visible = overlay->network_count;

    gem_draw_fill_rect(overlay->fb, modal.x - 12, modal.y - 12, modal.w + 24, modal.h + 24, COL_BG);
    gem_draw_fill_rounded_rect(overlay->fb, modal.x, modal.y, modal.w, modal.h, 18, COL_MODAL);
    gem_draw_rounded_rect(overlay->fb, modal.x, modal.y, modal.w, modal.h, 18, COL_BORDER);
    gem_draw_text_scaled(overlay->fb, modal.x + WIFI_INNER_PAD, modal.y + 20, "Wi-Fi Control", COL_TEXT, 2);
    wifi_draw_button(overlay, close_rect, COL_BUTTON_OFF, "Close");

    gem_draw_fill_rounded_rect(overlay->fb, status_rect.x, status_rect.y, status_rect.w, status_rect.h, 14, COL_TILE);
    gem_draw_rounded_rect(overlay->fb, status_rect.x, status_rect.y, status_rect.w, status_rect.h, 14, COL_BORDER);

    snprintf(line, sizeof(line), "Mode: %s",
             overlay->status.reconfigured ? "Temporary client mode" : "Stock AP mode");
    gem_draw_text(overlay->fb, status_rect.x + 14, status_rect.y + 14, line, COL_TEXT);

    snprintf(line, sizeof(line), "State: %s",
             overlay->status.wpa_state[0] ? overlay->status.wpa_state : "IDLE");
    gem_draw_text(overlay->fb, status_rect.x + 14, status_rect.y + 38, line, COL_TEXT);

    snprintf(line, sizeof(line), "SSID: %s",
             overlay->status.ssid[0] ? overlay->status.ssid : "(not connected)");
    gem_draw_text(overlay->fb, status_rect.x + 14, status_rect.y + 62, line, COL_TEXT);

    snprintf(line, sizeof(line), "IP: %s  Internet: %s",
             overlay->status.ip[0] ? overlay->status.ip : "(none)",
             overlay->status.internet ? "yes" : "no");
    gem_draw_text(overlay->fb, status_rect.x + 14, status_rect.y + 74, line, COL_TEXT);

    wifi_draw_button(overlay, wifi_action_button_rect(actions_rect, 0), COL_BUTTON, "Reconfigure");
    wifi_draw_button(overlay, wifi_action_button_rect(actions_rect, 1), COL_BUTTON, "Scan Networks");
    wifi_draw_button(overlay, wifi_action_button_rect(actions_rect, 2), COL_BUTTON_OFF, "Disconnect");

    gem_draw_fill_rounded_rect(overlay->fb, list_rect.x, list_rect.y, list_rect.w, list_rect.h, 14, COL_FIELD);
    gem_draw_rounded_rect(overlay->fb, list_rect.x, list_rect.y, list_rect.w, list_rect.h, 14, COL_BORDER);
    snprintf(line, sizeof(line), "Visible Networks (%d)", overlay->network_count);
    gem_draw_text_scaled(overlay->fb, list_rect.x + 16, list_rect.y + 14, line, COL_TEXT, 2);
    gem_draw_text(overlay->fb, list_rect.x + 16, list_rect.y + 48,
                  overlay->status.message[0] ? overlay->status.message : "Scan to find nearby SSIDs.",
                  COL_TEXT_DIM);
    gem_draw_fill_rounded_rect(overlay->fb, scroll_rect.x, scroll_rect.y, scroll_rect.w, scroll_rect.h, 12, COL_TILE);
    gem_draw_rounded_rect(overlay->fb, scroll_rect.x, scroll_rect.y, scroll_rect.w, scroll_rect.h, 12, COL_BORDER);
    wifi_draw_button(overlay, scroll_up_rect,
                     overlay->scroll_index > 0 ? COL_BUTTON : COL_BUTTON_OFF,
                     "Up");
    wifi_draw_button(overlay, scroll_down_rect,
                     last_visible < overlay->network_count ? COL_BUTTON : COL_BUTTON_OFF,
                     "Down");
    if (overlay->network_count > 0) {
        snprintf(line, sizeof(line), "%d-%d", first_visible, last_visible);
        wifi_draw_centered_label(overlay,
                                 (rect_t){ scroll_rect.x, scroll_rect.y + scroll_up_rect.h + 10,
                                           scroll_rect.w, scroll_rect.h - scroll_up_rect.h - scroll_down_rect.h - 20 },
                                 line, 2);
    } else {
        wifi_draw_centered_label(overlay, scroll_rect, "--", 2);
    }

    if (overlay->network_count <= 0) {
        gem_draw_text_scaled(overlay->fb, list_body_rect.x + 8, list_body_rect.y + 8,
                             "No scan results yet.", COL_TEXT_DIM, 2);
    }

    for (i = 0; i < visible_rows && overlay->scroll_index + i < overlay->network_count; i++) {
        int network_index = overlay->scroll_index + i;
        rect_t row = wifi_network_row_rect(overlay, modal, i);
        const char *lock = overlay->networks[network_index].secure ? "[LOCK]" : "[OPEN]";

        if (row.y + row.h > list_body_rect.y + list_body_rect.h)
            break;

        gem_draw_fill_rounded_rect(overlay->fb, row.x, row.y, row.w, row.h, 12,
                                   network_index == overlay->selected_index ? COL_MODAL_ROW_SEL : COL_MODAL_ROW);
        gem_draw_rounded_rect(overlay->fb, row.x, row.y, row.w, row.h, 12, COL_BORDER);
        gem_draw_text_scaled(overlay->fb, row.x + 16, row.y + 10, overlay->networks[network_index].ssid, COL_TEXT, 2);
        snprintf(line, sizeof(line), "%s  %d dBm  %s",
                 lock, overlay->networks[network_index].signal_dbm, overlay->networks[network_index].flags);
        gem_draw_text(overlay->fb, row.x + 16, row.y + 38, line, COL_TEXT_DIM);
    }

    gem_draw_text(overlay->fb, list_rect.x + 16, list_rect.y + list_rect.h - 22,
                  "Tap a network to connect. Arrow keys, D-pad, or the buttons scroll the list.",
                  COL_TEXT_DIM);

    if (overlay->password_mode) {
        rect_t panel_rect = wifi_password_panel_rect(wifi_content_rect(modal));
        rect_t field_rect = wifi_password_field_rect(panel_rect);
        rect_t connect_rect = wifi_password_connect_rect(panel_rect);
        rect_t cancel_rect = wifi_password_cancel_rect(panel_rect);
        char field_value[WIFI_OVERLAY_PASSWORD_MAX + 5];
        int max_chars = (field_rect.w - 32) / (GEM_FONT_W * 2);

        gem_draw_fill_rounded_rect(overlay->fb, panel_rect.x, panel_rect.y, panel_rect.w, panel_rect.h, 14, COL_TILE);
        gem_draw_rounded_rect(overlay->fb, panel_rect.x, panel_rect.y, panel_rect.w, panel_rect.h, 14, COL_BORDER);
        snprintf(line, sizeof(line), "Password for %s", overlay->pending_ssid);
        gem_draw_text_scaled(overlay->fb, panel_rect.x + 16, panel_rect.y + 14, line, COL_TEXT, 2);

        gem_draw_fill_rounded_rect(overlay->fb, field_rect.x, field_rect.y, field_rect.w, field_rect.h, 12, COL_FIELD);
        gem_draw_rounded_rect(overlay->fb, field_rect.x, field_rect.y, field_rect.w, field_rect.h, 12, COL_BORDER);

        if (overlay->password[0]) {
            wifi_field_text(field_value, sizeof(field_value), overlay->password, max_chars - 1);
            if ((int)strlen(field_value) < max_chars - 1 && strlen(field_value) + 1 < sizeof(field_value)) {
                size_t len = strlen(field_value);

                field_value[len] = '|';
                field_value[len + 1] = '\0';
            }
            gem_draw_text_scaled(overlay->fb, field_rect.x + 14, field_rect.y + 8, field_value, COL_TEXT, 2);
        } else {
            gem_draw_text_scaled(overlay->fb, field_rect.x + 14, field_rect.y + 8,
                                 "(type password here)", COL_TEXT_DIM, 2);
        }

        gem_draw_text(overlay->fb, panel_rect.x + 18, panel_rect.y + panel_rect.h - 36,
                      "Plaintext is shown so you can verify it before connecting.",
                      COL_TEXT_DIM);
        wifi_draw_button(overlay, connect_rect, COL_BUTTON, "Connect");
        wifi_draw_button(overlay, cancel_rect, COL_BUTTON_OFF, "Cancel");
    }
}

int wifi_overlay_handle_touch(wifi_overlay_t *overlay, int x, int y)
{
    rect_t modal;
    rect_t close_rect;
    rect_t actions_rect;
    rect_t list_body_rect;
    rect_t scroll_up_rect;
    rect_t scroll_down_rect;
    int visible_rows;
    int i;

    if (!overlay || !overlay->modal_open)
        return 0;

    modal = wifi_modal_rect(overlay);
    close_rect = wifi_close_rect(modal);
    actions_rect = wifi_actions_rect(modal);
    list_body_rect = wifi_list_body_rect(overlay, modal);
    scroll_up_rect = wifi_scroll_button_rect(overlay, modal, 1);
    scroll_down_rect = wifi_scroll_button_rect(overlay, modal, 0);
    visible_rows = wifi_visible_network_rows(overlay, modal);

    if (wifi_point_in_rect(x, y, close_rect)) {
        wifi_overlay_close(overlay);
        return 1;
    }

    if (overlay->password_mode) {
        rect_t panel_rect = wifi_password_panel_rect(wifi_content_rect(modal));
        rect_t connect_rect = wifi_password_connect_rect(panel_rect);
        rect_t cancel_rect = wifi_password_cancel_rect(panel_rect);

        if (wifi_point_in_rect(x, y, connect_rect)) {
            wifi_connect_pending(overlay);
            return 1;
        }
        if (wifi_point_in_rect(x, y, cancel_rect)) {
            overlay->password_mode = 0;
            memset(overlay->password, 0, sizeof(overlay->password));
            wifi_set_message(overlay, "Password entry canceled.");
            return 1;
        }
        return 0;
    }

    if (wifi_point_in_rect(x, y, wifi_action_button_rect(actions_rect, 0))) {
        wifi_reconfigure(overlay);
        return 1;
    }
    if (wifi_point_in_rect(x, y, wifi_action_button_rect(actions_rect, 1))) {
        wifi_scan_networks(overlay);
        return 1;
    }
    if (wifi_point_in_rect(x, y, wifi_action_button_rect(actions_rect, 2))) {
        wifi_disconnect(overlay);
        return 1;
    }

    if (wifi_point_in_rect(x, y, scroll_up_rect)) {
        wifi_page_selection(overlay, -1);
        return 1;
    }
    if (wifi_point_in_rect(x, y, scroll_down_rect)) {
        wifi_page_selection(overlay, 1);
        return 1;
    }

    for (i = 0; i < visible_rows && overlay->scroll_index + i < overlay->network_count; i++) {
        int network_index = overlay->scroll_index + i;
        rect_t row = wifi_network_row_rect(overlay, modal, i);

        if (row.y + row.h > list_body_rect.y + list_body_rect.h)
            break;
        if (wifi_point_in_rect(x, y, row)) {
            wifi_begin_connect(overlay, network_index);
            return 1;
        }
    }
    return 0;
}

int wifi_overlay_handle_key_down(wifi_overlay_t *overlay, int keycode)
{
    if (!overlay || !overlay->modal_open)
        return 0;

    if (keycode == KEY_LEFTSHIFT || keycode == KEY_RIGHTSHIFT) {
        overlay->shift_down = 1;
        return 0;
    }

    if (keycode == KEY_ESC) {
        if (overlay->password_mode) {
            overlay->password_mode = 0;
            memset(overlay->password, 0, sizeof(overlay->password));
            wifi_set_message(overlay, "Password entry canceled.");
        } else {
            wifi_overlay_close(overlay);
        }
        return 1;
    }

    if (keycode == KEY_F5) {
        wifi_refresh_status(overlay);
        return 1;
    }

    if (overlay->password_mode) {
        if (wifi_key_is_backspace(keycode)) {
            wifi_password_backspace(overlay);
        } else if (wifi_key_is_enter(keycode)) {
            wifi_connect_pending(overlay);
        } else {
            char ch = wifi_keycode_to_ascii(keycode, overlay->shift_down);

            if (ch)
                wifi_password_append(overlay, ch);
            else
                return 0;
        }
        return 1;
    }

    if (keycode == KEY_R) {
        wifi_reconfigure(overlay);
    } else if (keycode == KEY_S) {
        wifi_scan_networks(overlay);
    } else if (keycode == KEY_D) {
        wifi_disconnect(overlay);
    } else if (keycode == KEY_UP && overlay->selected_index > 0) {
        wifi_move_selection(overlay, -1);
    } else if (keycode == KEY_DOWN && overlay->selected_index + 1 < overlay->network_count) {
        wifi_move_selection(overlay, 1);
    } else if (keycode == KEY_PAGEUP) {
        wifi_page_selection(overlay, -1);
    } else if (keycode == KEY_PAGEDOWN) {
        wifi_page_selection(overlay, 1);
    } else if (keycode == KEY_HOME) {
        wifi_jump_selection(overlay, 0);
    } else if (keycode == KEY_END) {
        wifi_jump_selection(overlay, overlay->network_count - 1);
    } else if (wifi_key_is_enter(keycode) && overlay->selected_index >= 0) {
        wifi_begin_connect(overlay, overlay->selected_index);
    } else {
        return 0;
    }

    return 1;
}

int wifi_overlay_handle_key_up(wifi_overlay_t *overlay, int keycode)
{
    if (!overlay)
        return 0;

    if (keycode == KEY_LEFTSHIFT || keycode == KEY_RIGHTSHIFT) {
        overlay->shift_down = 0;
        return 0;
    }
    return 0;
}

int wifi_overlay_handle_gamepad_button(wifi_overlay_t *overlay, int button, int pressed)
{
    if (!overlay || !overlay->modal_open || !pressed)
        return 0;

    if (button == BTN_EAST) {
        if (overlay->password_mode) {
            overlay->password_mode = 0;
            memset(overlay->password, 0, sizeof(overlay->password));
            wifi_set_message(overlay, "Password entry canceled.");
        } else {
            wifi_overlay_close(overlay);
        }
        return 1;
    }

    if (button == BTN_SOUTH) {
        if (overlay->password_mode)
            wifi_connect_pending(overlay);
        else if (overlay->selected_index >= 0)
            wifi_begin_connect(overlay, overlay->selected_index);
        return 1;
    }

    return 0;
}

int wifi_overlay_handle_gamepad_axis(wifi_overlay_t *overlay, int axis, int value)
{
    if (!overlay || !overlay->modal_open || overlay->password_mode)
        return 0;

    if (axis != ABS_HAT0Y)
        return 0;

    if (value > 8000 && overlay->selected_index + 1 < overlay->network_count) {
        wifi_move_selection(overlay, 1);
        return 1;
    }
    if (value < -8000 && overlay->selected_index > 0) {
        wifi_move_selection(overlay, -1);
        return 1;
    }
    return 0;
}

int wifi_overlay_tick(wifi_overlay_t *overlay, uint32_t now_ms)
{
    if (!overlay || !overlay->modal_open || overlay->password_mode)
        return 0;

    if (now_ms - overlay->last_poll_ms < WIFI_POLL_MS)
        return 0;

    wifi_refresh_status(overlay);
    overlay->last_poll_ms = now_ms;
    return 1;
}
