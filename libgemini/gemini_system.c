// gemini_system.c — system lifecycle (launcher freeze/resume, signals, timing)
//
// Known-good process and signal handling for the SP7021 launcher-hijack flow.
// Freeze/resume behavior here matches the environment used to validate audio,
// video, and input together on hardware.

#include "gemini.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/time.h>

static int g_launcher_pid = 0;
static struct timeval g_start_time;
static void (*g_user_cleanup)(void) = NULL;

static int find_launcher_pid(void)
{
    FILE *f = fopen("/tmp/gemini_launcher_pid", "r");
    if (f) {
        int pid = 0;
        if (fscanf(f, "%d", &pid) == 1) {
            fclose(f);
            return pid;
        }
        fclose(f);
    }
    // Fallback: find by name
    FILE *p = popen("pidof Launcher 2>/dev/null", "r");
    if (p) {
        int pid = 0;
        if (fscanf(p, "%d", &pid) == 1) {
            pclose(p);
            return pid;
        }
        pclose(p);
    }
    return 0;
}

static void resume_launcher(void)
{
    if (g_launcher_pid > 0) {
        gem_log(GEM_LOG_INFO, "system: SIGCONT launcher pid=%d\n", g_launcher_pid);
        kill(g_launcher_pid, SIGCONT);
    }
}

static void signal_handler(int sig)
{
    // Only async-signal-safe calls here
    const char msg[] = "[gem] fatal signal, cleaning up\n";
    (void)write(STDERR_FILENO, msg, sizeof(msg) - 1);
    if (g_user_cleanup)
        g_user_cleanup();
    resume_launcher();
    _exit(128 + sig);
}

void gem_system_init(void (*cleanup_fn)(void))
{
    gem_log_init();
    g_user_cleanup = cleanup_fn;

    // Check if gemn_auto.sh is managing the stock Launcher for us.
    // When GEMINI_MANAGED=1, we skip SIGSTOP/SIGCONT — the orchestrator handles it.
    const char *managed = getenv("GEMINI_MANAGED");
    if (managed && managed[0] == '1') {
        gem_log(GEM_LOG_INFO, "system: managed mode (launcher loop handles stock Launcher)\n");
        g_launcher_pid = 0;
    } else {
        // Standalone mode — we manage the stock Launcher ourselves
        g_launcher_pid = find_launcher_pid();
        if (g_launcher_pid > 0) {
            gem_log(GEM_LOG_INFO, "system: launcher pid=%d, sending SIGSTOP\n", g_launcher_pid);
            kill(g_launcher_pid, SIGSTOP);

            // Reclaim Launcher's file-backed pages (code, shared libs).
            FILE *dc = fopen("/proc/sys/vm/drop_caches", "w");
            if (dc) { fprintf(dc, "3\n"); fclose(dc); }
            gem_log(GEM_LOG_DEBUG, "system: drop_caches sent\n");
        } else {
            gem_log(GEM_LOG_WARN, "system: stock launcher not found\n");
        }
    }

    // Install signal handlers for clean exit
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGSEGV, signal_handler);
    signal(SIGABRT, signal_handler);

    // Init timer
    gettimeofday(&g_start_time, NULL);
    gem_log(GEM_LOG_INFO, "system: initialized\n");
}

void gem_system_shutdown(void)
{
    resume_launcher();
    g_launcher_pid = 0;
}

uint32_t gem_get_ticks_ms(void)
{
    struct timeval cur;
    gettimeofday(&cur, NULL);
    long sec = cur.tv_sec - g_start_time.tv_sec;
    long usec = cur.tv_usec - g_start_time.tv_usec;
    return (uint32_t)(sec * 1000 + usec / 1000);
}

void gem_sleep_ms(uint32_t ms)
{
    usleep((useconds_t)ms * 1000);
}
