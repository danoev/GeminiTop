#include "SDL_config.h"

#include <linux/input.h>

#include "SDL.h"
#include "../../events/SDL_sysevents.h"
#include "../../events/SDL_events_c.h"

#include "SDL_nullvideo.h"
#include "SDL_nullevents_c.h"

typedef struct {
    int left;
    int right;
    int up;
    int down;
} gamepad_dir_state_t;

static gamepad_dir_state_t g_gamepad_dirs;

static SDLKey linux_key_to_sdl(int code)
{
    switch (code) {
    case KEY_ESC: return SDLK_ESCAPE;
    case KEY_1: return SDLK_1;
    case KEY_2: return SDLK_2;
    case KEY_3: return SDLK_3;
    case KEY_4: return SDLK_4;
    case KEY_5: return SDLK_5;
    case KEY_6: return SDLK_6;
    case KEY_7: return SDLK_7;
    case KEY_8: return SDLK_8;
    case KEY_9: return SDLK_9;
    case KEY_0: return SDLK_0;
    case KEY_MINUS: return SDLK_MINUS;
    case KEY_EQUAL: return SDLK_EQUALS;
    case KEY_BACKSPACE: return SDLK_BACKSPACE;
    case KEY_TAB: return SDLK_TAB;
    case KEY_Q: return SDLK_q;
    case KEY_W: return SDLK_w;
    case KEY_E: return SDLK_e;
    case KEY_R: return SDLK_r;
    case KEY_T: return SDLK_t;
    case KEY_Y: return SDLK_y;
    case KEY_U: return SDLK_u;
    case KEY_I: return SDLK_i;
    case KEY_O: return SDLK_o;
    case KEY_P: return SDLK_p;
    case KEY_LEFTBRACE: return SDLK_LEFTBRACKET;
    case KEY_RIGHTBRACE: return SDLK_RIGHTBRACKET;
    case KEY_ENTER: return SDLK_RETURN;
    case KEY_LEFTCTRL: return SDLK_LCTRL;
    case KEY_RIGHTCTRL: return SDLK_RCTRL;
    case KEY_A: return SDLK_a;
    case KEY_S: return SDLK_s;
    case KEY_D: return SDLK_d;
    case KEY_F: return SDLK_f;
    case KEY_G: return SDLK_g;
    case KEY_H: return SDLK_h;
    case KEY_J: return SDLK_j;
    case KEY_K: return SDLK_k;
    case KEY_L: return SDLK_l;
    case KEY_SEMICOLON: return SDLK_SEMICOLON;
    case KEY_APOSTROPHE: return SDLK_QUOTE;
    case KEY_GRAVE: return SDLK_BACKQUOTE;
    case KEY_LEFTSHIFT: return SDLK_LSHIFT;
    case KEY_BACKSLASH: return SDLK_BACKSLASH;
    case KEY_Z: return SDLK_z;
    case KEY_X: return SDLK_x;
    case KEY_C: return SDLK_c;
    case KEY_V: return SDLK_v;
    case KEY_B: return SDLK_b;
    case KEY_N: return SDLK_n;
    case KEY_M: return SDLK_m;
    case KEY_COMMA: return SDLK_COMMA;
    case KEY_DOT: return SDLK_PERIOD;
    case KEY_SLASH: return SDLK_SLASH;
    case KEY_RIGHTSHIFT: return SDLK_RSHIFT;
    case KEY_KPASTERISK: return SDLK_KP_MULTIPLY;
    case KEY_LEFTALT: return SDLK_LALT;
    case KEY_RIGHTALT: return SDLK_RALT;
    case KEY_SPACE: return SDLK_SPACE;
    case KEY_CAPSLOCK: return SDLK_CAPSLOCK;
    case KEY_F1: return SDLK_F1;
    case KEY_F2: return SDLK_F2;
    case KEY_F3: return SDLK_F3;
    case KEY_F4: return SDLK_F4;
    case KEY_F5: return SDLK_F5;
    case KEY_F6: return SDLK_F6;
    case KEY_F7: return SDLK_F7;
    case KEY_F8: return SDLK_F8;
    case KEY_F9: return SDLK_F9;
    case KEY_F10: return SDLK_F10;
    case KEY_F11: return SDLK_F11;
    case KEY_F12: return SDLK_F12;
    case KEY_NUMLOCK: return SDLK_NUMLOCK;
    case KEY_SCROLLLOCK: return SDLK_SCROLLOCK;
    case KEY_KP7: return SDLK_KP7;
    case KEY_KP8: return SDLK_KP8;
    case KEY_KP9: return SDLK_KP9;
    case KEY_KPMINUS: return SDLK_KP_MINUS;
    case KEY_KP4: return SDLK_KP4;
    case KEY_KP5: return SDLK_KP5;
    case KEY_KP6: return SDLK_KP6;
    case KEY_KPPLUS: return SDLK_KP_PLUS;
    case KEY_KP1: return SDLK_KP1;
    case KEY_KP2: return SDLK_KP2;
    case KEY_KP3: return SDLK_KP3;
    case KEY_KP0: return SDLK_KP0;
    case KEY_KPDOT: return SDLK_KP_PERIOD;
    case KEY_KPENTER: return SDLK_KP_ENTER;
    case KEY_KPSLASH: return SDLK_KP_DIVIDE;
    case KEY_HOME: return SDLK_HOME;
    case KEY_UP: return SDLK_UP;
    case KEY_PAGEUP: return SDLK_PAGEUP;
    case KEY_LEFT: return SDLK_LEFT;
    case KEY_RIGHT: return SDLK_RIGHT;
    case KEY_END: return SDLK_END;
    case KEY_DOWN: return SDLK_DOWN;
    case KEY_PAGEDOWN: return SDLK_PAGEDOWN;
    case KEY_INSERT: return SDLK_INSERT;
    case KEY_DELETE: return SDLK_DELETE;
    case KEY_SYSRQ: return SDLK_PRINT;
    case KEY_PAUSE: return SDLK_PAUSE;
    case KEY_LEFTMETA: return SDLK_LSUPER;
    case KEY_RIGHTMETA: return SDLK_RSUPER;
    default: return SDLK_UNKNOWN;
    }
}

static void post_virtual_key(Uint8 state, SDLKey key)
{
    SDL_keysym keysym;

    if (key == SDLK_UNKNOWN)
        return;

    SDL_memset(&keysym, 0, sizeof(keysym));
    keysym.sym = key;
    SDL_PrivateKeyboard(state, &keysym);
}

static void set_virtual_key(int *slot, int pressed, SDLKey key)
{
    if (!slot || key == SDLK_UNKNOWN || *slot == pressed)
        return;

    *slot = pressed;
    post_virtual_key(pressed ? SDL_PRESSED : SDL_RELEASED, key);
}

static void map_gamepad_button(int button, int pressed)
{
    switch (button) {
    case BTN_DPAD_LEFT:
        set_virtual_key(&g_gamepad_dirs.left, pressed, SDLK_LEFT);
        break;
    case BTN_DPAD_RIGHT:
        set_virtual_key(&g_gamepad_dirs.right, pressed, SDLK_RIGHT);
        break;
    case BTN_DPAD_UP:
        set_virtual_key(&g_gamepad_dirs.up, pressed, SDLK_UP);
        break;
    case BTN_DPAD_DOWN:
        set_virtual_key(&g_gamepad_dirs.down, pressed, SDLK_DOWN);
        break;
    case BTN_SOUTH:
    case BTN_START:
        post_virtual_key(pressed ? SDL_PRESSED : SDL_RELEASED, SDLK_RETURN);
        break;
    case BTN_EAST:
        post_virtual_key(pressed ? SDL_PRESSED : SDL_RELEASED, SDLK_ESCAPE);
        break;
    case BTN_WEST:
        post_virtual_key(pressed ? SDL_PRESSED : SDL_RELEASED, SDLK_SPACE);
        break;
    case BTN_NORTH:
        post_virtual_key(pressed ? SDL_PRESSED : SDL_RELEASED, SDLK_LCTRL);
        break;
    case BTN_SELECT:
        post_virtual_key(pressed ? SDL_PRESSED : SDL_RELEASED, SDLK_BACKSPACE);
        break;
    default:
        break;
    }
}

static void map_gamepad_hat(int axis, int value)
{
    if (axis == ABS_HAT0X) {
        set_virtual_key(&g_gamepad_dirs.left, value < -8000, SDLK_LEFT);
        set_virtual_key(&g_gamepad_dirs.right, value > 8000, SDLK_RIGHT);
    } else if (axis == ABS_HAT0Y) {
        set_virtual_key(&g_gamepad_dirs.up, value < -8000, SDLK_UP);
        set_virtual_key(&g_gamepad_dirs.down, value > 8000, SDLK_DOWN);
    }
}

static void update_touch_position(_THIS, int fb_x, int fb_y, int *out_x, int *out_y)
{
    int x;
    int y;

    if (this->hidden->blit_w <= 0 || this->hidden->blit_h <= 0) {
        *out_x = 0;
        *out_y = 0;
        return;
    }

    x = fb_x - this->hidden->blit_x;
    y = fb_y - this->hidden->blit_y;

    if (x < 0)
        x = 0;
    if (y < 0)
        y = 0;
    if (x >= this->hidden->blit_w)
        x = this->hidden->blit_w - 1;
    if (y >= this->hidden->blit_h)
        y = this->hidden->blit_h - 1;

    *out_x = (x * this->hidden->w) / this->hidden->blit_w;
    *out_y = (y * this->hidden->h) / this->hidden->blit_h;
}

static void post_touch_motion(_THIS, int fb_x, int fb_y)
{
    int x;
    int y;

    update_touch_position(this, fb_x, fb_y, &x, &y);
    SDL_PrivateMouseMotion(0, 0, x, y);
}

void DUMMY_PumpEvents(_THIS)
{
    gem_event_t ev;
    SDL_keysym keysym;
    static int focus_ready = 0;

    if (!focus_ready) {
        SDL_PrivateAppActive(1, SDL_APPACTIVE | SDL_APPINPUTFOCUS | SDL_APPMOUSEFOCUS);
        focus_ready = 1;
    }

    if (!this->hidden || !this->hidden->input)
        return;

    while (gem_input_poll(this->hidden->input, &ev)) {
        switch (ev.type) {
        case GEM_EVENT_KEY_DOWN:
        case GEM_EVENT_KEY_UP:
            SDL_memset(&keysym, 0, sizeof(keysym));
            /* DOSBox-X's Linux SDL1 mapper expects XKB-style codes, which are
               the evdev KEY_* values offset by +8. */
            keysym.scancode = (Uint8)(ev.key.code + 8);
            keysym.sym = linux_key_to_sdl(ev.key.code);
            SDL_PrivateKeyboard(ev.type == GEM_EVENT_KEY_DOWN ? SDL_PRESSED : SDL_RELEASED,
                                &keysym);
            break;

        case GEM_EVENT_MOUSE_MOVE:
            SDL_PrivateMouseMotion(0, 1, ev.mouse_move.dx, ev.mouse_move.dy);
            break;

        case GEM_EVENT_MOUSE_BUTTON:
            if (ev.mouse_button.button == BTN_LEFT) {
                SDL_PrivateMouseButton(ev.mouse_button.pressed ? SDL_PRESSED : SDL_RELEASED,
                                       SDL_BUTTON_LEFT, 0, 0);
            } else if (ev.mouse_button.button == BTN_RIGHT) {
                SDL_PrivateMouseButton(ev.mouse_button.pressed ? SDL_PRESSED : SDL_RELEASED,
                                       SDL_BUTTON_RIGHT, 0, 0);
            } else if (ev.mouse_button.button == BTN_MIDDLE) {
                SDL_PrivateMouseButton(ev.mouse_button.pressed ? SDL_PRESSED : SDL_RELEASED,
                                       SDL_BUTTON_MIDDLE, 0, 0);
            }
            break;

        case GEM_EVENT_TOUCH_DOWN:
            this->hidden->touch_active = 1;
            this->hidden->touch_button_down = 1;
            post_touch_motion(this, ev.touch.x, ev.touch.y);
            SDL_PrivateMouseButton(SDL_PRESSED, SDL_BUTTON_LEFT, 0, 0);
            break;

        case GEM_EVENT_TOUCH_MOVE:
            if (this->hidden->touch_active)
                post_touch_motion(this, ev.touch.x, ev.touch.y);
            break;

        case GEM_EVENT_TOUCH_UP:
            if (this->hidden->touch_active)
                post_touch_motion(this, ev.touch.x, ev.touch.y);
            if (this->hidden->touch_button_down) {
                SDL_PrivateMouseButton(SDL_RELEASED, SDL_BUTTON_LEFT, 0, 0);
                this->hidden->touch_button_down = 0;
            }
            this->hidden->touch_active = 0;
            break;

        case GEM_EVENT_GAMEPAD_BUTTON:
            map_gamepad_button(ev.gamepad_button.button, ev.gamepad_button.pressed);
            break;

        case GEM_EVENT_GAMEPAD_AXIS:
            map_gamepad_hat(ev.gamepad_axis.axis, ev.gamepad_axis.value);
            break;

        default:
            break;
        }
    }
}

void DUMMY_InitOSKeymap(_THIS)
{
    (void)this;
}
