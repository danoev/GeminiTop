// gemini_input.c — RetroArch input driver for Gemini SP7021
//
// Reads keyboard and gamepad input directly from /dev/input/event* (evdev).
// No libudev dependency — scans device nodes at init time.
//
// Supports:
//   - USB gamepads (buttons + analog sticks + D-pad)
//   - USB/virtual keyboards
//   - Capacitive touchscreen (event3) mapped as pointer
//
// Gamepad mapping follows standard Linux gamepad layout:
//   BTN_SOUTH=A, BTN_EAST=B, BTN_NORTH=X, BTN_WEST=Y
//   BTN_TL=L1, BTN_TR=R1, BTN_TL2=L2, BTN_TR2=R2
//   BTN_SELECT, BTN_START, BTN_THUMBL=L3, BTN_THUMBR=R3
//
// Target: RetroArch v1.17.0+

#ifdef HAVE_GEMINI

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/input.h>

#include "../../retroarch.h"
#include "../../verbosity.h"
#include "../input_driver.h"
#include "../../libretro.h"

#define MAX_DEVICES     8
#define MAX_KEYS        256   // KEY_MAX is 0x2FF but we only track first 256
#define AXIS_THRESHOLD  8000  // deadzone for analog → digital conversion
#define INPUT_RESCAN_INTERVAL_MS 750

typedef enum {
    DEV_KEYBOARD,
    DEV_GAMEPAD,
    DEV_TOUCH,
} gemini_dev_type_t;

typedef struct {
    int fd;
    gemini_dev_type_t type;
    int grabbed;
    int sync_lost;
    char path[512];
    int abs_min[ABS_MAX + 1];
    int abs_max[ABS_MAX + 1];
    char name[64];
} gemini_dev_t;

typedef struct {
    // keyboard state: bitfield of pressed keys (Linux KEY_* codes)
    uint8_t keys[MAX_KEYS / 8];

    // gamepad state (single player — port 0)
    uint16_t pad_buttons;      // bitmask of RETRO_DEVICE_ID_JOYPAD_*
    int16_t  pad_axes[4];      // [0]=LX [1]=LY [2]=RX [3]=RY (range -32767..32767)
    int16_t  hat_x, hat_y;    // raw HAT0X/HAT0Y state for dpad priority

    // touch state
    int touch_x, touch_y;
    bool touch_down;
    int touch_min_x, touch_max_x;
    int touch_min_y, touch_max_y;

    gemini_dev_t devs[MAX_DEVICES];
    int num_devs;
    uint64_t last_scan_ms;
} gemini_input_t;

static void key_set(uint8_t *keys, unsigned code, bool pressed)
{
    if (code >= MAX_KEYS) return;
    if (pressed)
        keys[code / 8] |=  (1u << (code & 7));
    else
        keys[code / 8] &= ~(1u << (code & 7));
}

static bool key_get(const uint8_t *keys, unsigned code)
{
    if (code >= MAX_KEYS) return false;
    return (keys[code / 8] >> (code & 7)) & 1;
}

static int test_bit(int bit, const unsigned long *array)
{
    return (array[bit / (sizeof(unsigned long) * 8)] >>
            (bit % (sizeof(unsigned long) * 8))) & 1;
}

static uint64_t monotonic_ms(void)
{
    struct timespec ts;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;

    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000u);
}

static int normalize_axis(int value, int min, int max)
{
    long centered;
    long range;

    if (max == min)
        return 0;

    range = max - min;
    centered = (long)(value - min) * 65535 / range - 32768;
    if (centered < -32768)
        centered = -32768;
    if (centered > 32767)
        centered = 32767;
    return (int)centered;
}

static int16_t normalize_pointer(int value, int min, int max)
{
    long scaled;

    if (max <= min)
        return 0;

    scaled = (long)(value - min) * 65534 / (max - min) - 32767;
    if (scaled < -32767)
        scaled = -32767;
    if (scaled > 32767)
        scaled = 32767;
    return (int16_t)scaled;
}

static bool is_gamepad_device(const unsigned long *keybits, const unsigned long *absbits)
{
    bool has_gamepad_buttons =
        test_bit(BTN_GAMEPAD, keybits) ||
        test_bit(BTN_SOUTH, keybits) ||
        test_bit(BTN_EAST, keybits) ||
        test_bit(BTN_NORTH, keybits) ||
        test_bit(BTN_WEST, keybits) ||
        test_bit(BTN_A, keybits) ||
        test_bit(BTN_B, keybits) ||
        test_bit(BTN_X, keybits) ||
        test_bit(BTN_Y, keybits) ||
        test_bit(BTN_DPAD_UP, keybits) ||
        test_bit(BTN_DPAD_DOWN, keybits) ||
        test_bit(BTN_DPAD_LEFT, keybits) ||
        test_bit(BTN_DPAD_RIGHT, keybits);
    bool has_gamepad_axes =
        test_bit(ABS_X, absbits) ||
        test_bit(ABS_Y, absbits) ||
        test_bit(ABS_RX, absbits) ||
        test_bit(ABS_RY, absbits) ||
        test_bit(ABS_Z, absbits) ||
        test_bit(ABS_RZ, absbits) ||
        test_bit(ABS_HAT0X, absbits) ||
        test_bit(ABS_HAT0Y, absbits);
    bool has_dpad_buttons =
        test_bit(BTN_DPAD_UP, keybits) ||
        test_bit(BTN_DPAD_DOWN, keybits) ||
        test_bit(BTN_DPAD_LEFT, keybits) ||
        test_bit(BTN_DPAD_RIGHT, keybits);

    return has_gamepad_buttons && (has_gamepad_axes || has_dpad_buttons);
}

static uint16_t btn_to_retro_mask(unsigned code);

static void resync_keyboard(gemini_input_t *gi, gemini_dev_t *dev)
{
    unsigned long keybits[(KEY_MAX + 1) / (sizeof(unsigned long) * 8) + 1];

    memset(keybits, 0, sizeof(keybits));
    if (ioctl(dev->fd, EVIOCGKEY(sizeof(keybits)), keybits) < 0)
        return;

    for (unsigned code = 0; code < MAX_KEYS; code++)
        key_set(gi->keys, code, test_bit((int)code, keybits) != 0);
}

static void resync_gamepad(gemini_input_t *gi, gemini_dev_t *dev)
{
    static const unsigned buttons[] = {
        BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST,
        BTN_TL, BTN_TR, BTN_TL2, BTN_TR2,
        BTN_SELECT, BTN_START, BTN_THUMBL, BTN_THUMBR
    };
    unsigned long keybits[(KEY_MAX + 1) / (sizeof(unsigned long) * 8) + 1];
    struct input_absinfo absinfo;

    memset(keybits, 0, sizeof(keybits));
    if (ioctl(dev->fd, EVIOCGKEY(sizeof(keybits)), keybits) == 0) {
        gi->pad_buttons = 0;
        for (unsigned i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++) {
            if (test_bit((int)buttons[i], keybits))
                gi->pad_buttons |= btn_to_retro_mask(buttons[i]);
        }
    }

    if (ioctl(dev->fd, EVIOCGABS(ABS_X), &absinfo) == 0)
        gi->pad_axes[0] = (int16_t)normalize_axis(absinfo.value, dev->abs_min[ABS_X], dev->abs_max[ABS_X]);
    if (ioctl(dev->fd, EVIOCGABS(ABS_Y), &absinfo) == 0)
        gi->pad_axes[1] = (int16_t)normalize_axis(absinfo.value, dev->abs_min[ABS_Y], dev->abs_max[ABS_Y]);
    if (ioctl(dev->fd, EVIOCGABS(ABS_RX), &absinfo) == 0)
        gi->pad_axes[2] = (int16_t)normalize_axis(absinfo.value, dev->abs_min[ABS_RX], dev->abs_max[ABS_RX]);
    if (ioctl(dev->fd, EVIOCGABS(ABS_RY), &absinfo) == 0)
        gi->pad_axes[3] = (int16_t)normalize_axis(absinfo.value, dev->abs_min[ABS_RY], dev->abs_max[ABS_RY]);

    gi->hat_x = 0;
    gi->hat_y = 0;
    if (ioctl(dev->fd, EVIOCGABS(ABS_HAT0X), &absinfo) == 0)
        gi->hat_x = (int16_t)absinfo.value;
    if (ioctl(dev->fd, EVIOCGABS(ABS_HAT0Y), &absinfo) == 0)
        gi->hat_y = (int16_t)absinfo.value;

    gi->pad_buttons &= ~((1 << RETRO_DEVICE_ID_JOYPAD_LEFT) |
                         (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT) |
                         (1 << RETRO_DEVICE_ID_JOYPAD_UP) |
                         (1 << RETRO_DEVICE_ID_JOYPAD_DOWN));
    if (gi->hat_x < 0)
        gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_LEFT);
    else if (gi->hat_x > 0)
        gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT);
    if (gi->hat_y < 0)
        gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_UP);
    else if (gi->hat_y > 0)
        gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_DOWN);
}

static void resync_touch(gemini_input_t *gi, gemini_dev_t *dev)
{
    unsigned long keybits[(KEY_MAX + 1) / (sizeof(unsigned long) * 8) + 1];
    struct input_absinfo absinfo;

    memset(keybits, 0, sizeof(keybits));
    if (ioctl(dev->fd, EVIOCGKEY(sizeof(keybits)), keybits) == 0)
        gi->touch_down = test_bit(BTN_TOUCH, keybits) != 0;

    if (ioctl(dev->fd, EVIOCGABS(ABS_MT_POSITION_X), &absinfo) == 0)
        gi->touch_x = absinfo.value;
    else if (ioctl(dev->fd, EVIOCGABS(ABS_X), &absinfo) == 0)
        gi->touch_x = absinfo.value;

    if (ioctl(dev->fd, EVIOCGABS(ABS_MT_POSITION_Y), &absinfo) == 0)
        gi->touch_y = absinfo.value;
    else if (ioctl(dev->fd, EVIOCGABS(ABS_Y), &absinfo) == 0)
        gi->touch_y = absinfo.value;
}

static void resync_device_state(gemini_input_t *gi, gemini_dev_t *dev)
{
    switch (dev->type) {
    case DEV_KEYBOARD:
        resync_keyboard(gi, dev);
        break;
    case DEV_GAMEPAD:
        resync_gamepad(gi, dev);
        break;
    case DEV_TOUCH:
        resync_touch(gi, dev);
        break;
    }
}

static void clear_gamepad_state(gemini_input_t *gi)
{
    gi->pad_buttons = 0;
    gi->pad_axes[0] = 0;
    gi->pad_axes[1] = 0;
    gi->pad_axes[2] = 0;
    gi->pad_axes[3] = 0;
    gi->hat_x = 0;
    gi->hat_y = 0;
}

static void resync_first_gamepad(gemini_input_t *gi)
{
    clear_gamepad_state(gi);

    for (int i = 0; i < gi->num_devs; i++) {
        if (gi->devs[i].type == DEV_GAMEPAD) {
            resync_gamepad(gi, &gi->devs[i]);
            break;
        }
    }
}

// map gamepad button to RetroArch joypad ID bit
static uint16_t btn_to_retro_mask(unsigned code)
{
    switch (code) {
    case BTN_SOUTH:  return (1 << RETRO_DEVICE_ID_JOYPAD_B);
    case BTN_EAST:   return (1 << RETRO_DEVICE_ID_JOYPAD_A);
    case BTN_NORTH:  return (1 << RETRO_DEVICE_ID_JOYPAD_X);
    case BTN_WEST:   return (1 << RETRO_DEVICE_ID_JOYPAD_Y);
    case BTN_TL:     return (1 << RETRO_DEVICE_ID_JOYPAD_L);
    case BTN_TR:     return (1 << RETRO_DEVICE_ID_JOYPAD_R);
    case BTN_TL2:    return (1 << RETRO_DEVICE_ID_JOYPAD_L2);
    case BTN_TR2:    return (1 << RETRO_DEVICE_ID_JOYPAD_R2);
    case BTN_SELECT: return (1 << RETRO_DEVICE_ID_JOYPAD_SELECT);
    case BTN_START:  return (1 << RETRO_DEVICE_ID_JOYPAD_START);
    case BTN_THUMBL: return (1 << RETRO_DEVICE_ID_JOYPAD_L3);
    case BTN_THUMBR: return (1 << RETRO_DEVICE_ID_JOYPAD_R3);
    case BTN_DPAD_UP: return (1 << RETRO_DEVICE_ID_JOYPAD_UP);
    case BTN_DPAD_DOWN: return (1 << RETRO_DEVICE_ID_JOYPAD_DOWN);
    case BTN_DPAD_LEFT: return (1 << RETRO_DEVICE_ID_JOYPAD_LEFT);
    case BTN_DPAD_RIGHT: return (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT);
    default:         return 0;
    }
}

// map Linux KEY_* to RETROK_*
static unsigned linux_key_to_retrok(unsigned key)
{
    if (key >= KEY_1 && key <= KEY_9)
        return RETROK_1 + (key - KEY_1);
    if (key == KEY_0)        return RETROK_0;
    if (key >= KEY_A && key <= KEY_Z)
        return RETROK_a + (key - KEY_A);
    if (key >= KEY_F1 && key <= KEY_F12)
        return RETROK_F1 + (key - KEY_F1);

    switch (key) {
    case KEY_ESC:        return RETROK_ESCAPE;
    case KEY_ENTER:      return RETROK_RETURN;
    case KEY_SPACE:      return RETROK_SPACE;
    case KEY_BACKSPACE:  return RETROK_BACKSPACE;
    case KEY_TAB:        return RETROK_TAB;
    case KEY_UP:         return RETROK_UP;
    case KEY_DOWN:       return RETROK_DOWN;
    case KEY_LEFT:       return RETROK_LEFT;
    case KEY_RIGHT:      return RETROK_RIGHT;
    case KEY_LEFTSHIFT:  return RETROK_LSHIFT;
    case KEY_RIGHTSHIFT: return RETROK_RSHIFT;
    case KEY_LEFTCTRL:   return RETROK_LCTRL;
    case KEY_RIGHTCTRL:  return RETROK_RCTRL;
    case KEY_LEFTALT:    return RETROK_LALT;
    case KEY_RIGHTALT:   return RETROK_RALT;
    case KEY_INSERT:     return RETROK_INSERT;
    case KEY_DELETE:     return RETROK_DELETE;
    case KEY_HOME:       return RETROK_HOME;
    case KEY_END:        return RETROK_END;
    case KEY_PAGEUP:     return RETROK_PAGEUP;
    case KEY_PAGEDOWN:   return RETROK_PAGEDOWN;
    case KEY_MINUS:      return RETROK_MINUS;
    case KEY_EQUAL:      return RETROK_EQUALS;
    case KEY_COMMA:      return RETROK_COMMA;
    case KEY_DOT:        return RETROK_PERIOD;
    case KEY_SLASH:      return RETROK_SLASH;
    case KEY_SEMICOLON:  return RETROK_SEMICOLON;
    default:             return RETROK_UNKNOWN;
    }
}

// reverse lookup: RETROK_* → Linux KEY_* (built once at init)
static unsigned retrok_to_linux[RETROK_LAST];
static bool retrok_table_built = false;

static void build_retrok_table(void)
{
    memset(retrok_to_linux, 0, sizeof(retrok_to_linux));
    for (unsigned k = 0; k < MAX_KEYS; k++) {
        unsigned rk = linux_key_to_retrok(k);
        if (rk != RETROK_UNKNOWN && rk < RETROK_LAST)
            retrok_to_linux[rk] = k;
    }
    retrok_table_built = true;
}

static void close_device(gemini_dev_t *dev)
{
    if (!dev)
        return;

    if (dev->grabbed)
        ioctl(dev->fd, EVIOCGRAB, 0);
    if (dev->fd >= 0)
        close(dev->fd);
}

static void remove_device(gemini_input_t *gi, int index)
{
    bool removed_gamepad;

    if (!gi || index < 0 || index >= gi->num_devs)
        return;

    removed_gamepad = gi->devs[index].type == DEV_GAMEPAD;
    RARCH_LOG("[Gemini] Input: removed %s (%s)\n",
              gi->devs[index].path, gi->devs[index].name);
    close_device(&gi->devs[index]);

    for (int i = index; i + 1 < gi->num_devs; i++)
        gi->devs[i] = gi->devs[i + 1];

    gi->num_devs--;
    memset(&gi->devs[gi->num_devs], 0, sizeof(gi->devs[gi->num_devs]));

    if (removed_gamepad)
        resync_first_gamepad(gi);
}

static int find_device_by_path(gemini_input_t *gi, const char *path)
{
    for (int i = 0; i < gi->num_devs; i++) {
        if (strcmp(gi->devs[i].path, path) == 0)
            return i;
    }

    return -1;
}

static void add_device(gemini_input_t *gi, const char *path)
{
    unsigned long evbits[(EV_MAX + 1) / (sizeof(unsigned long) * 8) + 1];
    unsigned long keybits[(KEY_MAX + 1) / (sizeof(unsigned long) * 8) + 1];
    unsigned long absbits[(ABS_MAX + 1) / (sizeof(unsigned long) * 8) + 1];
    struct input_absinfo absinfo;
    gemini_dev_t *d;
    char name[64] = "Unknown";
    int has_keys;
    int has_abs;
    int has_rel;
    int fd;

    if (!gi || !path || gi->num_devs >= MAX_DEVICES)
        return;
    if (find_device_by_path(gi, path) >= 0)
        return;

    fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0)
        return;

    ioctl(fd, EVIOCGNAME(sizeof(name)), name);
    memset(evbits, 0, sizeof(evbits));
    memset(keybits, 0, sizeof(keybits));
    memset(absbits, 0, sizeof(absbits));
    ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits);
    ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits);
    ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits);

    has_keys = test_bit(EV_KEY, evbits);
    has_abs = test_bit(EV_ABS, evbits);
    has_rel = test_bit(EV_REL, evbits);
    if (!has_keys && !has_abs && !has_rel) {
        close(fd);
        return;
    }

    d = &gi->devs[gi->num_devs];
    memset(d, 0, sizeof(*d));
    d->fd = fd;
    strncpy(d->name, name, sizeof(d->name) - 1);
    strncpy(d->path, path, sizeof(d->path) - 1);

    if (has_abs) {
        if (is_gamepad_device(keybits, absbits)) {
            d->type = DEV_GAMEPAD;
            for (int a = 0; a <= ABS_MAX; a++) {
                if (test_bit(a, absbits) && ioctl(fd, EVIOCGABS(a), &absinfo) == 0) {
                    d->abs_min[a] = absinfo.minimum;
                    d->abs_max[a] = absinfo.maximum;
                }
            }
        } else if (test_bit(ABS_MT_POSITION_X, absbits) || test_bit(BTN_TOUCH, keybits)) {
            d->type = DEV_TOUCH;
            if (test_bit(ABS_MT_POSITION_X, absbits) && ioctl(fd, EVIOCGABS(ABS_MT_POSITION_X), &absinfo) == 0) {
                gi->touch_min_x = absinfo.minimum;
                gi->touch_max_x = absinfo.maximum;
            } else if (test_bit(ABS_X, absbits) && ioctl(fd, EVIOCGABS(ABS_X), &absinfo) == 0) {
                gi->touch_min_x = absinfo.minimum;
                gi->touch_max_x = absinfo.maximum;
            }
            if (test_bit(ABS_MT_POSITION_Y, absbits) && ioctl(fd, EVIOCGABS(ABS_MT_POSITION_Y), &absinfo) == 0) {
                gi->touch_min_y = absinfo.minimum;
                gi->touch_max_y = absinfo.maximum;
            } else if (test_bit(ABS_Y, absbits) && ioctl(fd, EVIOCGABS(ABS_Y), &absinfo) == 0) {
                gi->touch_min_y = absinfo.minimum;
                gi->touch_max_y = absinfo.maximum;
            }
        } else {
            d->type = DEV_KEYBOARD;
        }
    } else if (has_keys) {
        d->type = DEV_KEYBOARD;
    } else {
        close(fd);
        return;
    }

    if (ioctl(fd, EVIOCGRAB, 1) == 0)
        d->grabbed = 1;

    RARCH_LOG("[Gemini] Input: %s = %s (%s)\n", path, d->name,
              d->type == DEV_GAMEPAD ? "gamepad" :
              d->type == DEV_TOUCH   ? "touch"   : "keyboard");

    gi->num_devs++;
    resync_device_state(gi, d);
}

static void rescan_devices(gemini_input_t *gi)
{
    DIR *dir;
    struct dirent *ent;

    if (!gi)
        return;

    dir = opendir("/dev/input");
    if (!dir) {
        RARCH_ERR("[Gemini] Input: cannot open /dev/input: %s\n", strerror(errno));
        return;
    }

    while ((ent = readdir(dir)) != NULL) {
        char path[512];

        if (strncmp(ent->d_name, "event", 5) != 0)
            continue;

        snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);
        add_device(gi, path);
    }

    closedir(dir);
    gi->last_scan_ms = monotonic_ms();
}

static void *gemini_input_init(const char *joypad_driver)
{
    (void)joypad_driver;

    gemini_input_t *gi = calloc(1, sizeof(*gi));
    if (!gi) return NULL;

    if (!retrok_table_built)
        build_retrok_table();

    gi->touch_min_x = 0;
    gi->touch_max_x = 1919;
    gi->touch_min_y = 0;
    gi->touch_max_y = 719;
    rescan_devices(gi);

    RARCH_LOG("[Gemini] Input: %d devices opened\n", gi->num_devs);
    return gi;
}

static void gemini_input_poll(void *data)
{
    gemini_input_t *gi = (gemini_input_t *)data;
    if (!gi) return;

    struct input_event ev;
    uint64_t now = monotonic_ms();

    if (now - gi->last_scan_ms >= INPUT_RESCAN_INTERVAL_MS)
        rescan_devices(gi);

    for (int d = 0; d < gi->num_devs; d++) {
        gemini_dev_t *dev = &gi->devs[d];
        ssize_t rd = -1;

        while ((rd = read(dev->fd, &ev, sizeof(ev))) == sizeof(ev)) {
            if (dev->sync_lost) {
                if (ev.type == EV_SYN && ev.code == SYN_REPORT)
                    dev->sync_lost = 0;
                continue;
            }

            if (ev.type == EV_SYN && ev.code == SYN_DROPPED) {
                resync_device_state(gi, dev);
                dev->sync_lost = 1;
                continue;
            }

            switch (dev->type) {
            case DEV_KEYBOARD:
                if (ev.type == EV_KEY && ev.code < MAX_KEYS)
                    key_set(gi->keys, ev.code, ev.value != 0);
                break;

            case DEV_GAMEPAD:
                if (ev.type == EV_KEY && ev.value <= 1) {
                    uint16_t mask = btn_to_retro_mask(ev.code);
                    if (ev.value)
                        gi->pad_buttons |= mask;
                    else
                        gi->pad_buttons &= ~mask;
                } else if (ev.type == EV_ABS) {
                    switch (ev.code) {
                    case ABS_X:
                        gi->pad_axes[0] = (int16_t)normalize_axis(ev.value, dev->abs_min[ABS_X], dev->abs_max[ABS_X]);
                        break;
                    case ABS_Y:
                        gi->pad_axes[1] = (int16_t)normalize_axis(ev.value, dev->abs_min[ABS_Y], dev->abs_max[ABS_Y]);
                        break;
                    case ABS_RX:
                        gi->pad_axes[2] = (int16_t)normalize_axis(ev.value, dev->abs_min[ABS_RX], dev->abs_max[ABS_RX]);
                        break;
                    case ABS_RY:
                        gi->pad_axes[3] = (int16_t)normalize_axis(ev.value, dev->abs_min[ABS_RY], dev->abs_max[ABS_RY]);
                        break;
                    case ABS_HAT0X:
                        gi->hat_x = (int16_t)ev.value;
                        gi->pad_buttons &= ~((1 << RETRO_DEVICE_ID_JOYPAD_LEFT) |
                                             (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT));
                        if (ev.value < 0)
                            gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_LEFT);
                        else if (ev.value > 0)
                            gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT);
                        break;
                    case ABS_HAT0Y:
                        gi->hat_y = (int16_t)ev.value;
                        gi->pad_buttons &= ~((1 << RETRO_DEVICE_ID_JOYPAD_UP) |
                                             (1 << RETRO_DEVICE_ID_JOYPAD_DOWN));
                        if (ev.value < 0)
                            gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_UP);
                        else if (ev.value > 0)
                            gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_DOWN);
                        break;
                    }
                }
                break;

            case DEV_TOUCH:
                if (ev.type == EV_ABS) {
                    if (ev.code == ABS_MT_POSITION_X || ev.code == ABS_X)
                        gi->touch_x = ev.value;
                    else if (ev.code == ABS_MT_POSITION_Y || ev.code == ABS_Y)
                        gi->touch_y = ev.value;
                } else if (ev.type == EV_KEY && ev.code == BTN_TOUCH) {
                    gi->touch_down = (ev.value != 0);
                }
                break;
            }
        }

        if (rd == 0 || (rd < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
            RARCH_WARN("[Gemini] Input: lost %s: %s\n",
                       dev->path, rd == 0 ? "device closed" : strerror(errno));
            remove_device(gi, d);
            d--;
        }
    }

    // analog stick → digital d-pad (only when HAT d-pad is centered)
    if (gi->hat_x == 0) {
        gi->pad_buttons &= ~((1 << RETRO_DEVICE_ID_JOYPAD_LEFT) |
                             (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT));
        if (gi->pad_axes[0] < -AXIS_THRESHOLD)
            gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_LEFT);
        else if (gi->pad_axes[0] > AXIS_THRESHOLD)
            gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT);
    }
    if (gi->hat_y == 0) {
        gi->pad_buttons &= ~((1 << RETRO_DEVICE_ID_JOYPAD_UP) |
                             (1 << RETRO_DEVICE_ID_JOYPAD_DOWN));
        if (gi->pad_axes[1] < -AXIS_THRESHOLD)
            gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_UP);
        else if (gi->pad_axes[1] > AXIS_THRESHOLD)
            gi->pad_buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_DOWN);
    }
}

static int16_t gemini_input_state(
      void *data,
      const input_device_driver_t *joypad,
      const input_device_driver_t *sec_joypad,
      rarch_joypad_info_t *joypad_info,
      const retro_keybind_set *binds,
      bool keyboard_mapping_blocked,
      unsigned port,
      unsigned device,
      unsigned idx,
      unsigned id)
{
    gemini_input_t *gi = (gemini_input_t *)data;
    int16_t state = 0;
    if (!gi) return 0;

    (void)joypad; (void)sec_joypad; (void)joypad_info;

    switch (device) {
    case RETRO_DEVICE_JOYPAD:
        if (port != 0) return 0;
        if (id < 16)
            state = (gi->pad_buttons >> id) & 1;

        if (!state && !keyboard_mapping_blocked && binds) {
            unsigned keycode = binds[port][id].key;
            if (keycode != RETROK_UNKNOWN && keycode < RETROK_LAST) {
                unsigned linux_key = retrok_to_linux[keycode];
                if (linux_key)
                    state = key_get(gi->keys, linux_key) ? 1 : 0;
            }
        }
        return state;

    case RETRO_DEVICE_KEYBOARD:
        // id is a RETROK_* value — O(1) reverse lookup
        if (id != RETROK_UNKNOWN && id < RETROK_LAST) {
            unsigned linux_key = retrok_to_linux[id];
            if (linux_key)
                return key_get(gi->keys, linux_key) ? 1 : 0;
        }
        return 0;

    case RETRO_DEVICE_ANALOG:
        if (port != 0) return 0;
        switch (idx) {
        case RETRO_DEVICE_INDEX_ANALOG_LEFT:
            return (id == RETRO_DEVICE_ID_ANALOG_X) ? gi->pad_axes[0] : gi->pad_axes[1];
        case RETRO_DEVICE_INDEX_ANALOG_RIGHT:
            return (id == RETRO_DEVICE_ID_ANALOG_X) ? gi->pad_axes[2] : gi->pad_axes[3];
        }
        return 0;

    case RETRO_DEVICE_POINTER:
        if (port != 0) return 0;
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED)
            return gi->touch_down ? 1 : 0;
        if (id == RETRO_DEVICE_ID_POINTER_X)
            return gi->touch_down ? normalize_pointer(gi->touch_x, gi->touch_min_x, gi->touch_max_x) : 0;
        if (id == RETRO_DEVICE_ID_POINTER_Y)
            return gi->touch_down ? normalize_pointer(gi->touch_y, gi->touch_min_y, gi->touch_max_y) : 0;
        return 0;
    }

    return 0;
}

static void gemini_input_free(void *data)
{
    gemini_input_t *gi = (gemini_input_t *)data;
    if (!gi) return;

    for (int i = 0; i < gi->num_devs; i++)
        close_device(&gi->devs[i]);
    free(gi);
}

static uint64_t gemini_input_get_capabilities(void *data)
{
    (void)data;
    return (1 << RETRO_DEVICE_JOYPAD)
         | (1 << RETRO_DEVICE_KEYBOARD)
         | (1 << RETRO_DEVICE_ANALOG)
         | (1 << RETRO_DEVICE_POINTER);
}

input_driver_t input_gemini = {
    gemini_input_init,
    gemini_input_poll,
    gemini_input_state,
    gemini_input_free,
    NULL,  /* set_sensor_state */
    NULL,  /* get_sensor_input */
    gemini_input_get_capabilities,
    "gemini",
    NULL,  /* grab_mouse */
    NULL,  /* grab_stdin */
};

#endif /* HAVE_GEMINI */
