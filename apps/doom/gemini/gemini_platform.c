// gemini_platform.c — DOOM platform layer for Gemini, all hw via libgemini

#include "doomkeys.h"
#include "m_argv.h"
#include "doomgeneric.h"

// Collision workaround: Linux input-event-codes.h and doomkeys.h both define these
#undef KEY_TAB
#undef KEY_ENTER
#undef KEY_BACKSPACE
#undef KEY_MINUS
#undef KEY_F1
#undef KEY_F2
#undef KEY_F3
#undef KEY_F4
#undef KEY_F5
#undef KEY_F6
#undef KEY_F7
#undef KEY_F8
#undef KEY_F9
#undef KEY_F10
#undef KEY_F11
#define DOOM_KEY_TAB       9
#define DOOM_KEY_ENTER     13
#define DOOM_KEY_MINUS     0x2d
#define DOOM_KEY_BACKSPACE 0x7f
#define DOOM_KEY_F1        (0x80+0x3b)
#define DOOM_KEY_F2        (0x80+0x3c)
#define DOOM_KEY_F3        (0x80+0x3d)
#define DOOM_KEY_F4        (0x80+0x3e)
#define DOOM_KEY_F5        (0x80+0x3f)
#define DOOM_KEY_F6        (0x80+0x40)
#define DOOM_KEY_F7        (0x80+0x41)
#define DOOM_KEY_F8        (0x80+0x42)
#define DOOM_KEY_F9        (0x80+0x43)
#define DOOM_KEY_F10       (0x80+0x44)
#define DOOM_KEY_F11       (0x80+0x57)
#define DOOM_KEY_F12       (0x80+0x58)

#include "gemini.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <linux/input-event-codes.h>

// configuration
#define KEYQUEUE_SIZE   32

// Touch zones (relative to framebuffer dimensions)
// Left 40%: movement   Right 40%: look/strafe   Center 20%: menu confirm
#define TOUCH_ZONE_LEFT_FRAC  40
#define TOUCH_ZONE_RIGHT_FRAC 60

// globals

// libgemini handles
static gem_fb_t    *fb;
static gem_input_t *input;

// Display dimensions (queried from fb at init)
static int disp_w, disp_h;

// Key queue (DOOM's DG_GetKey interface)
static unsigned short s_KeyQueue[KEYQUEUE_SIZE];
static unsigned int s_KeyQueueWrite = 0;
static unsigned int s_KeyQueueRead = 0;

// Touch state
static int touchDown = 0;
static int touchX = 0, touchY = 0;
static int touchKeysFired[4]; // up, down, left, right currently held from touch

// evdev key tables
static char evdevKeys1[10] = { '1','2','3','4','5','6','7','8','9','0' };
static char evdevKeys2[12] = { 'q','w','e','r','t','y','u','i','o','p','[',']' };
static char evdevKeys3[11] = { 'a','s','d','f','g','h','j','k','l',';','\'' };
static char evdevKeys4[11] = { '\\','z','x','c','v','b','n','m',',','.','/' };

// key conversion: Linux evdev KEY_* -> DOOM key codes
static unsigned char convertToDoomKey(unsigned int key)
{
    switch (key) {
    case KEY_ENTER:      return DOOM_KEY_ENTER;
    case KEY_ESC:        return KEY_ESCAPE;
    case KEY_LEFT:       return KEY_LEFTARROW;
    case KEY_RIGHT:      return KEY_RIGHTARROW;
    case KEY_UP:         return KEY_UPARROW;
    case KEY_DOWN:       return KEY_DOWNARROW;
    case KEY_LEFTCTRL:
    case KEY_RIGHTCTRL:  return KEY_FIRE;
    case KEY_SPACE:      return KEY_USE;
    case KEY_LEFTSHIFT:
    case KEY_RIGHTSHIFT: return KEY_RSHIFT;
    case KEY_LEFTALT:
    case KEY_RIGHTALT:   return KEY_LALT;
    case KEY_F1:         return DOOM_KEY_F1;
    case KEY_F2:         return DOOM_KEY_F2;
    case KEY_F3:         return DOOM_KEY_F3;
    case KEY_F4:         return DOOM_KEY_F4;
    case KEY_F5:         return DOOM_KEY_F5;
    case KEY_F6:         return DOOM_KEY_F6;
    case KEY_F7:         return DOOM_KEY_F7;
    case KEY_F8:         return DOOM_KEY_F8;
    case KEY_F9:         return DOOM_KEY_F9;
    case KEY_F10:        return DOOM_KEY_F10;
    case KEY_F11:        return DOOM_KEY_F11;
    case KEY_F12:        return DOOM_KEY_F12;
    case KEY_EQUAL:      return KEY_EQUALS;
    case KEY_MINUS:      return DOOM_KEY_MINUS;
    case KEY_BACKSPACE:  return DOOM_KEY_BACKSPACE;
    case KEY_TAB:        return DOOM_KEY_TAB;
    // Number row
    case KEY_1: case KEY_2: case KEY_3: case KEY_4: case KEY_5:
    case KEY_6: case KEY_7: case KEY_8: case KEY_9: case KEY_0:
        return evdevKeys1[key - KEY_1];
    // Letters
    case KEY_Q: case KEY_W: case KEY_E: case KEY_R: case KEY_T:
    case KEY_Y: case KEY_U: case KEY_I: case KEY_O: case KEY_P:
    case KEY_LEFTBRACE: case KEY_RIGHTBRACE:
        return evdevKeys2[key - KEY_Q];
    case KEY_A: case KEY_S: case KEY_D: case KEY_F: case KEY_G:
    case KEY_H: case KEY_J: case KEY_K: case KEY_L:
    case KEY_SEMICOLON: case KEY_APOSTROPHE:
        return evdevKeys3[key - KEY_A];
    case KEY_BACKSLASH:
    case KEY_Z: case KEY_X: case KEY_C: case KEY_V: case KEY_B:
    case KEY_N: case KEY_M: case KEY_COMMA: case KEY_DOT: case KEY_SLASH:
        return evdevKeys4[key - KEY_BACKSLASH];
    default:
        return 0xFF;
    }
}

static void enqueueKey(int pressed, unsigned char doomKey)
{
    if (doomKey == 0xFF || pressed < 0 || pressed > 1)
        return;
    unsigned short data = (pressed << 8) | doomKey;
    s_KeyQueue[s_KeyQueueWrite] = data;
    s_KeyQueueWrite = (s_KeyQueueWrite + 1) % KEYQUEUE_SIZE;
}

// touch -> DOOM key mapping
static void processTouchZones(void)
{
    int zone_left  = disp_w * TOUCH_ZONE_LEFT_FRAC / 100;
    int zone_right = disp_w * TOUCH_ZONE_RIGHT_FRAC / 100;
    int mid_y      = disp_h / 2;

    if (!touchDown) {
        for (int i = 0; i < 4; i++) {
            if (touchKeysFired[i]) {
                unsigned char keys[] = { KEY_UPARROW, KEY_DOWNARROW,
                                         KEY_LEFTARROW, KEY_RIGHTARROW };
                enqueueKey(0, keys[i]);
                touchKeysFired[i] = 0;
            }
        }
        return;
    }

    if (touchX < zone_left) {
        // Left zone: D-pad movement
        int centerX = zone_left / 2;
        int centerY = disp_h / 2;
        int dx = touchX - centerX;
        int dy = touchY - centerY;

        int wantUp    = (dy < -60);
        int wantDown  = (dy > 60);
        int wantLeft  = (dx < -60);
        int wantRight = (dx > 60);

        if (wantUp != touchKeysFired[0]) {
            enqueueKey(wantUp, KEY_UPARROW);
            touchKeysFired[0] = wantUp;
        }
        if (wantDown != touchKeysFired[1]) {
            enqueueKey(wantDown, KEY_DOWNARROW);
            touchKeysFired[1] = wantDown;
        }
        if (wantLeft != touchKeysFired[2]) {
            enqueueKey(wantLeft, KEY_LEFTARROW);
            touchKeysFired[2] = wantLeft;
        }
        if (wantRight != touchKeysFired[3]) {
            enqueueKey(wantRight, KEY_RIGHTARROW);
            touchKeysFired[3] = wantRight;
        }
    } else if (touchX >= zone_right) {
        // Right zone: fire (upper) / use (lower)
        if (touchY < mid_y) {
            enqueueKey(1, KEY_FIRE);
            enqueueKey(0, KEY_FIRE);
        } else {
            enqueueKey(1, KEY_USE);
            enqueueKey(0, KEY_USE);
        }
    } else {
        // Center zone: Enter (menus)
        enqueueKey(1, DOOM_KEY_ENTER);
        enqueueKey(0, DOOM_KEY_ENTER);
    }
}

// process input via libgemini -> DOOM key queue
static void processInput(void)
{
    gem_event_t ev;
    while (gem_input_poll(input, &ev)) {
        switch (ev.type) {
        case GEM_EVENT_KEY_DOWN: {
            unsigned char dk = convertToDoomKey(ev.key.code);
            if (dk != 0xFF) enqueueKey(1, dk);
            break;
        }
        case GEM_EVENT_KEY_UP: {
            unsigned char dk = convertToDoomKey(ev.key.code);
            if (dk != 0xFF) enqueueKey(0, dk);
            break;
        }
        case GEM_EVENT_TOUCH_DOWN:
            touchDown = 1;
            touchX = ev.touch.x;
            touchY = ev.touch.y;
            processTouchZones();
            break;
        case GEM_EVENT_TOUCH_UP:
            touchDown = 0;
            processTouchZones();
            break;
        case GEM_EVENT_TOUCH_MOVE:
            touchX = ev.touch.x;
            touchY = ev.touch.y;
            processTouchZones();
            break;
        case GEM_EVENT_MOUSE_BUTTON:
            // Mouse: left=fire, right=use, middle=run
            if (ev.mouse_button.button == BTN_LEFT)
                enqueueKey(ev.mouse_button.pressed, KEY_FIRE);
            else if (ev.mouse_button.button == BTN_RIGHT)
                enqueueKey(ev.mouse_button.pressed, KEY_USE);
            else if (ev.mouse_button.button == BTN_MIDDLE)
                enqueueKey(ev.mouse_button.pressed, KEY_RSHIFT);
            break;
        case GEM_EVENT_GAMEPAD_BUTTON:
            // Gamepad: SOUTH=fire, EAST=use, WEST=run, NORTH=map
            if (ev.gamepad_button.button == BTN_SOUTH)
                enqueueKey(ev.gamepad_button.pressed, KEY_FIRE);
            else if (ev.gamepad_button.button == BTN_EAST)
                enqueueKey(ev.gamepad_button.pressed, KEY_USE);
            else if (ev.gamepad_button.button == BTN_WEST)
                enqueueKey(ev.gamepad_button.pressed, KEY_RSHIFT);
            else if (ev.gamepad_button.button == BTN_NORTH)
                enqueueKey(ev.gamepad_button.pressed, KEY_TAB);
            else if (ev.gamepad_button.button == BTN_START)
                enqueueKey(ev.gamepad_button.pressed, KEY_ESCAPE);
            else if (ev.gamepad_button.button == BTN_DPAD_LEFT)
                enqueueKey(ev.gamepad_button.pressed, KEY_LEFTARROW);
            else if (ev.gamepad_button.button == BTN_DPAD_RIGHT)
                enqueueKey(ev.gamepad_button.pressed, KEY_RIGHTARROW);
            else if (ev.gamepad_button.button == BTN_DPAD_UP)
                enqueueKey(ev.gamepad_button.pressed, KEY_UPARROW);
            else if (ev.gamepad_button.button == BTN_DPAD_DOWN)
                enqueueKey(ev.gamepad_button.pressed, KEY_DOWNARROW);
            break;
        case GEM_EVENT_GAMEPAD_AXIS:
            // D-pad via HAT axes
            if (ev.gamepad_axis.axis == ABS_HAT0X) {
                if (ev.gamepad_axis.value > 8000)
                    { enqueueKey(0, KEY_LEFTARROW); enqueueKey(1, KEY_RIGHTARROW); }
                else if (ev.gamepad_axis.value < -8000)
                    { enqueueKey(0, KEY_RIGHTARROW); enqueueKey(1, KEY_LEFTARROW); }
                else
                    { enqueueKey(0, KEY_LEFTARROW); enqueueKey(0, KEY_RIGHTARROW); }
            } else if (ev.gamepad_axis.axis == ABS_HAT0Y) {
                if (ev.gamepad_axis.value > 8000)
                    { enqueueKey(0, KEY_UPARROW); enqueueKey(1, KEY_DOWNARROW); }
                else if (ev.gamepad_axis.value < -8000)
                    { enqueueKey(0, KEY_DOWNARROW); enqueueKey(1, KEY_UPARROW); }
                else
                    { enqueueKey(0, KEY_UPARROW); enqueueKey(0, KEY_DOWNARROW); }
            }
            // Left stick Y for forward/back
            else if (ev.gamepad_axis.axis == ABS_Y) {
                if (ev.gamepad_axis.value > 8000)
                    { enqueueKey(0, KEY_UPARROW); enqueueKey(1, KEY_DOWNARROW); }
                else if (ev.gamepad_axis.value < -8000)
                    { enqueueKey(0, KEY_DOWNARROW); enqueueKey(1, KEY_UPARROW); }
                else
                    { enqueueKey(0, KEY_UPARROW); enqueueKey(0, KEY_DOWNARROW); }
            }
            // Left stick X for strafe
            else if (ev.gamepad_axis.axis == ABS_X) {
                if (ev.gamepad_axis.value > 8000)
                    { enqueueKey(0, KEY_LEFTARROW); enqueueKey(1, KEY_RIGHTARROW); }
                else if (ev.gamepad_axis.value < -8000)
                    { enqueueKey(0, KEY_RIGHTARROW); enqueueKey(1, KEY_LEFTARROW); }
                else
                    { enqueueKey(0, KEY_LEFTARROW); enqueueKey(0, KEY_RIGHTARROW); }
            }
            break;
        default:
            break;
        }
    }
}

// doomgeneric interface
static void app_cleanup(void)
{
    if (fb) { gem_fb_close(fb); fb = NULL; }
    if (input) { gem_input_close(input); input = NULL; }
    gem_system_shutdown();
}

void DG_Init()
{
    gem_log(GEM_LOG_INFO, "doom: initializing via libgemini\n");

    // SIGSTOP Launcher, install signal handlers
    gem_system_init(app_cleanup);

    // Open framebuffer
    fb = gem_fb_open();
    if (!fb) {
        gem_log(GEM_LOG_ERROR, "doom: cannot open framebuffer\n");
        _exit(1);
    }
    disp_w = (int)gem_fb_width(fb);
    disp_h = (int)gem_fb_height(fb);

    // Open input devices (keyboard, touchscreen, gamepad)
    input = gem_input_open();
    if (!input)
        gem_log(GEM_LOG_WARN, "doom: no input devices\n");

    gem_log(GEM_LOG_INFO, "doom: rendering %dx%d -> %dx%d\n",
            DOOMGENERIC_RESX, DOOMGENERIC_RESY, disp_w, disp_h);
}

void DG_DrawFrame()
{
    // Scale DOOM's framebuffer to the display (centered, aspect-correct)
    gem_fb_blit_scaled(fb, DG_ScreenBuffer, DOOMGENERIC_RESX, DOOMGENERIC_RESY);
    gem_fb_flip(fb);

    // Process input every frame
    processInput();
}

void DG_SleepMs(uint32_t ms)
{
    gem_sleep_ms(ms);
}

uint32_t DG_GetTicksMs()
{
    return gem_get_ticks_ms();
}

int DG_GetKey(int *pressed, unsigned char *doomKey)
{
    if (s_KeyQueueRead == s_KeyQueueWrite)
        return 0;

    unsigned short data = s_KeyQueue[s_KeyQueueRead];
    s_KeyQueueRead = (s_KeyQueueRead + 1) % KEYQUEUE_SIZE;

    *pressed = data >> 8;
    *doomKey = data & 0xFF;
    return 1;
}

void DG_SetWindowTitle(const char *title)
{
    gem_log(GEM_LOG_DEBUG, "doom: %s\n", title);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    gem_log(GEM_LOG_INFO, "doom: starting on Gemini\n");

    doomgeneric_Create(argc, argv);

    for (;;) {
        doomgeneric_Tick();
    }

    return 0;
}
