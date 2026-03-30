// gemini_log.c — Structured logging for libgemini
// Output goes to stderr (unbuffered). Controlled by GEM_LOG_LEVEL env var.
//
// Known-good logging path for the SP7021 USB app stack. Keep logs lightweight
// and stderr-based so launcher/app wrappers can capture them reliably.

#include "gemini.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <sys/time.h>

static int g_level = GEM_LOG_INFO;
static struct timeval g_start;
static int g_inited = 0;

void gem_log_init(void)
{
    if (g_inited) return;
    gettimeofday(&g_start, NULL);
    g_inited = 1;

    const char *env = getenv("GEM_LOG_LEVEL");
    if (!env) return;
    if (strcmp(env, "error") == 0 || strcmp(env, "0") == 0)      g_level = GEM_LOG_ERROR;
    else if (strcmp(env, "warn") == 0  || strcmp(env, "1") == 0) g_level = GEM_LOG_WARN;
    else if (strcmp(env, "info") == 0  || strcmp(env, "2") == 0) g_level = GEM_LOG_INFO;
    else if (strcmp(env, "debug") == 0 || strcmp(env, "3") == 0) g_level = GEM_LOG_DEBUG;
}

void gem_log_set_level(int level)
{
    g_level = level;
}

void gem_log(int level, const char *fmt, ...)
{
    if (level > g_level) return;
    if (!g_inited) gem_log_init();

    static const char tags[] = "EWID";
    int idx = (level >= 0 && level <= 3) ? level : 2;

    struct timeval now;
    gettimeofday(&now, NULL);
    long ms = (now.tv_sec - g_start.tv_sec) * 1000L +
              (now.tv_usec - g_start.tv_usec) / 1000;

    fprintf(stderr, "[%3ld.%03ld %c] ", ms / 1000, ms % 1000, tags[idx]);

    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}
