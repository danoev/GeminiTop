// gemini_input.c — unified evdev input (keyboard, touch, mouse, gamepad)
//
// Known-good libgemini input layer for the SP7021 launcher-hijack environment.
// Device probing and event normalization here match the hardware that was
// validated with the custom launcher, DOOM, and RetroArch.

#include "gemini.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/input.h>

#define MAX_INPUT_DEVS 16
#define EVENT_QUEUE_SIZE 64
#define INPUT_RESCAN_INTERVAL_MS 750

typedef enum {
    DEV_KEYBOARD = 0,
    DEV_TOUCH,
    DEV_MOUSE,
    DEV_GAMEPAD,
} dev_type_t;

typedef struct {
    int fd;
    dev_type_t type;
    int grabbed;
    char path[512];
    // Gamepad axis calibration
    int abs_min[ABS_MAX + 1];
    int abs_max[ABS_MAX + 1];
} input_dev_t;

struct gem_input {
    input_dev_t devs[MAX_INPUT_DEVS];
    int num_devs;
    int has_gamepad;
    // Internal event queue
    gem_event_t queue[EVENT_QUEUE_SIZE];
    int queue_read;
    int queue_write;
    // Touch tracking
    int touch_down;
    int touch_x, touch_y;
    uint64_t last_scan_ms;
};

static void enqueue_event(gem_input_t *in, const gem_event_t *ev)
{
    int next = (in->queue_write + 1) % EVENT_QUEUE_SIZE;
    if (next == in->queue_read)
        return; // queue full, drop
    in->queue[in->queue_write] = *ev;
    in->queue_write = next;
}

// Normalize a raw axis value to -32768..32767 range
static int normalize_axis(int value, int min, int max)
{
    if (max == min) return 0;
    // Map min..max to -32768..32767
    long range = max - min;
    long centered = (long)(value - min) * 65535 / range - 32768;
    if (centered < -32768) centered = -32768;
    if (centered > 32767) centered = 32767;
    return (int)centered;
}

// Check if a specific bit is set in a bitfield
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

static void refresh_has_gamepad(gem_input_t *in)
{
    in->has_gamepad = 0;
    for (int i = 0; i < in->num_devs; i++) {
        if (in->devs[i].type == DEV_GAMEPAD) {
            in->has_gamepad = 1;
            break;
        }
    }
}

static int is_gamepad_device(const unsigned long *keybits, const unsigned long *absbits)
{
    int has_gamepad_buttons =
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
    int has_gamepad_axes =
        test_bit(ABS_X, absbits) ||
        test_bit(ABS_Y, absbits) ||
        test_bit(ABS_RX, absbits) ||
        test_bit(ABS_RY, absbits) ||
        test_bit(ABS_Z, absbits) ||
        test_bit(ABS_RZ, absbits) ||
        test_bit(ABS_HAT0X, absbits) ||
        test_bit(ABS_HAT0Y, absbits);
    int has_dpad_buttons =
        test_bit(BTN_DPAD_UP, keybits) ||
        test_bit(BTN_DPAD_DOWN, keybits) ||
        test_bit(BTN_DPAD_LEFT, keybits) ||
        test_bit(BTN_DPAD_RIGHT, keybits);

    return has_gamepad_buttons && (has_gamepad_axes || has_dpad_buttons);
}

static void close_device(input_dev_t *dev)
{
    if (!dev)
        return;

    if (dev->grabbed)
        ioctl(dev->fd, EVIOCGRAB, 0);
    if (dev->fd >= 0)
        close(dev->fd);
}

static void remove_device(gem_input_t *in, int index)
{
    if (!in || index < 0 || index >= in->num_devs)
        return;

    gem_log(GEM_LOG_INFO, "input: removed %s type=%d\n",
            in->devs[index].path, in->devs[index].type);

    close_device(&in->devs[index]);

    for (int i = index; i + 1 < in->num_devs; i++)
        in->devs[i] = in->devs[i + 1];

    in->num_devs--;
    memset(&in->devs[in->num_devs], 0, sizeof(in->devs[in->num_devs]));
    refresh_has_gamepad(in);
}

static int find_device_by_path(gem_input_t *in, const char *path)
{
    for (int i = 0; i < in->num_devs; i++) {
        if (strcmp(in->devs[i].path, path) == 0)
            return i;
    }

    return -1;
}

static void add_device(gem_input_t *in, const char *path)
{
    unsigned long evbits[(EV_MAX + 1) / (sizeof(unsigned long) * 8) + 1];
    unsigned long keybits[(KEY_MAX + 1) / (sizeof(unsigned long) * 8) + 1];
    unsigned long absbits[(ABS_MAX + 1) / (sizeof(unsigned long) * 8) + 1];
    struct input_absinfo absinfo;
    input_dev_t *dev;
    char name[128] = "unknown";
    int fd;
    int has_keys;
    int has_abs;
    int has_rel;

    if (!in || !path || in->num_devs >= MAX_INPUT_DEVS)
        return;
    if (find_device_by_path(in, path) >= 0)
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
    has_abs  = test_bit(EV_ABS, evbits);
    has_rel  = test_bit(EV_REL, evbits);

    if (!has_keys && !has_abs && !has_rel) {
        close(fd);
        return;
    }

    dev = &in->devs[in->num_devs];
    memset(dev, 0, sizeof(*dev));
    dev->fd = fd;
    strncpy(dev->path, path, sizeof(dev->path) - 1);

    if (has_abs) {
        if (is_gamepad_device(keybits, absbits)) {
            dev->type = DEV_GAMEPAD;
            for (int a = 0; a <= ABS_MAX; a++) {
                if (test_bit(a, absbits) && ioctl(fd, EVIOCGABS(a), &absinfo) == 0) {
                    dev->abs_min[a] = absinfo.minimum;
                    dev->abs_max[a] = absinfo.maximum;
                }
            }
        } else if (test_bit(ABS_MT_POSITION_X, absbits) || test_bit(BTN_TOUCH, keybits)) {
            dev->type = DEV_TOUCH;
        } else {
            dev->type = DEV_KEYBOARD;
        }
    } else if (has_rel) {
        dev->type = DEV_MOUSE;
    } else {
        dev->type = DEV_KEYBOARD;
    }

    if (ioctl(fd, EVIOCGRAB, 1) == 0) {
        dev->grabbed = 1;
    } else {
        gem_log(GEM_LOG_WARN, "input: EVIOCGRAB failed on %s: %s\n",
                path, strerror(errno));
    }

    in->num_devs++;
    refresh_has_gamepad(in);
    gem_log(GEM_LOG_INFO, "input: added %s [%s] type=%d\n", path, name, dev->type);
}

static void rescan_devices(gem_input_t *in)
{
    DIR *dir;
    struct dirent *ent;

    if (!in)
        return;

    dir = opendir("/dev/input");
    if (!dir) {
        gem_log(GEM_LOG_WARN, "input: cannot rescan /dev/input: %s\n", strerror(errno));
        return;
    }

    while ((ent = readdir(dir)) != NULL) {
        char path[512];

        if (strncmp(ent->d_name, "event", 5) != 0)
            continue;

        snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);
        add_device(in, path);
    }

    closedir(dir);
    in->last_scan_ms = monotonic_ms();
}

gem_input_t *gem_input_open(void)
{
    gem_input_t *in = calloc(1, sizeof(gem_input_t));
    if (!in) return NULL;

    rescan_devices(in);

    gem_log(GEM_LOG_INFO, "input: %d device(s), gamepad=%s\n",
            in->num_devs, in->has_gamepad ? "yes" : "no");

    return in;
}

void gem_input_close(gem_input_t *in)
{
    if (!in) return;
    for (int i = 0; i < in->num_devs; i++)
        close_device(&in->devs[i]);
    free(in);
}

static void process_events(gem_input_t *in)
{
    struct input_event ev;

    for (int i = 0; i < in->num_devs; i++) {
        input_dev_t *dev = &in->devs[i];
        ssize_t rd = -1;

        while ((rd = read(dev->fd, &ev, sizeof(ev))) == sizeof(ev)) {
            gem_event_t gem_ev;
            memset(&gem_ev, 0, sizeof(gem_ev));

            switch (dev->type) {
            case DEV_KEYBOARD:
                if (ev.type == EV_KEY && ev.value <= 1) {
                    gem_ev.type = ev.value ? GEM_EVENT_KEY_DOWN : GEM_EVENT_KEY_UP;
                    gem_ev.key.code = ev.code;
                    enqueue_event(in, &gem_ev);
                }
                break;

            case DEV_TOUCH:
                if (ev.type == EV_KEY && ev.code == BTN_TOUCH) {
                    in->touch_down = ev.value;
                    gem_ev.type = ev.value ? GEM_EVENT_TOUCH_DOWN : GEM_EVENT_TOUCH_UP;
                    gem_ev.touch.x = in->touch_x;
                    gem_ev.touch.y = in->touch_y;
                    enqueue_event(in, &gem_ev);
                } else if (ev.type == EV_ABS) {
                    if (ev.code == ABS_X || ev.code == ABS_MT_POSITION_X)
                        in->touch_x = ev.value;
                    else if (ev.code == ABS_Y || ev.code == ABS_MT_POSITION_Y)
                        in->touch_y = ev.value;

                    if (in->touch_down && ev.type == EV_ABS) {
                        gem_ev.type = GEM_EVENT_TOUCH_MOVE;
                        gem_ev.touch.x = in->touch_x;
                        gem_ev.touch.y = in->touch_y;
                        enqueue_event(in, &gem_ev);
                    }
                }
                break;

            case DEV_MOUSE:
                if (ev.type == EV_REL) {
                    gem_ev.type = GEM_EVENT_MOUSE_MOVE;
                    if (ev.code == REL_X) gem_ev.mouse_move.dx = ev.value;
                    if (ev.code == REL_Y) gem_ev.mouse_move.dy = ev.value;
                    enqueue_event(in, &gem_ev);
                } else if (ev.type == EV_KEY && ev.value <= 1) {
                    gem_ev.type = GEM_EVENT_MOUSE_BUTTON;
                    gem_ev.mouse_button.button = ev.code;
                    gem_ev.mouse_button.pressed = ev.value;
                    enqueue_event(in, &gem_ev);
                }
                break;

            case DEV_GAMEPAD:
                if (ev.type == EV_KEY && ev.value <= 1) {
                    gem_ev.type = GEM_EVENT_GAMEPAD_BUTTON;
                    gem_ev.gamepad_button.button = ev.code;
                    gem_ev.gamepad_button.pressed = ev.value;
                    enqueue_event(in, &gem_ev);
                } else if (ev.type == EV_ABS) {
                    gem_ev.type = GEM_EVENT_GAMEPAD_AXIS;
                    gem_ev.gamepad_axis.axis = ev.code;
                    gem_ev.gamepad_axis.value = normalize_axis(
                        ev.value, dev->abs_min[ev.code], dev->abs_max[ev.code]);
                    enqueue_event(in, &gem_ev);
                }
                break;
            }
        }

        if (rd == 0 || (rd < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
            gem_log(GEM_LOG_WARN, "input: lost %s: %s\n",
                    dev->path, rd == 0 ? "device closed" : strerror(errno));
            remove_device(in, i);
            i--;
        }
    }
}

bool gem_input_poll(gem_input_t *in, gem_event_t *ev)
{
    if (!in || !ev) return false;

    // If queue is empty, read from all devices
    if (in->queue_read == in->queue_write) {
        uint64_t now = monotonic_ms();

        if (now - in->last_scan_ms >= INPUT_RESCAN_INTERVAL_MS)
            rescan_devices(in);
        process_events(in);
    }

    // Dequeue one event
    if (in->queue_read != in->queue_write) {
        *ev = in->queue[in->queue_read];
        in->queue_read = (in->queue_read + 1) % EVENT_QUEUE_SIZE;
        return true;
    }

    return false;
}

bool gem_input_has_gamepad(gem_input_t *in)
{
    if (!in) return false;
    return in->has_gamepad;
}
