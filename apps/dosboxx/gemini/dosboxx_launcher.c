#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef LAUNCH_TARGET
#error "LAUNCH_TARGET must be defined"
#endif

#ifndef LAUNCH_PRIMARY_CONF
#error "LAUNCH_PRIMARY_CONF must be defined"
#endif

#ifndef LAUNCH_FALLBACK_CONF
#define LAUNCH_FALLBACK_CONF ""
#endif

#ifndef LAUNCH_MEDIA_CHECK
#define LAUNCH_MEDIA_CHECK ""
#endif

static int get_app_dir(char *out, size_t out_size) {
    ssize_t len = readlink("/proc/self/exe", out, out_size - 1);
    if (len < 0 || (size_t)len >= out_size) {
        return -1;
    }

    out[len] = '\0';

    char *slash = strrchr(out, '/');
    if (!slash || slash == out) {
        return -1;
    }

    *slash = '\0';
    return 0;
}

static int join_path(char *out, size_t out_size, const char *base, const char *leaf) {
    int written = snprintf(out, out_size, "%s/%s", base, leaf);
    return (written < 0 || (size_t)written >= out_size) ? -1 : 0;
}

static int path_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

int main(int argc, char **argv) {
    char app_dir[PATH_MAX];
    char target_path[PATH_MAX];
    char primary_conf[PATH_MAX];
    char fallback_conf[PATH_MAX];
    char media_path[PATH_MAX];
    const char *config_path = NULL;
    char **child_argv = NULL;
    int i;

    if (get_app_dir(app_dir, sizeof(app_dir)) != 0) {
        fprintf(stderr, "launcher: failed to resolve app directory: %s\n", strerror(errno));
        return 127;
    }

    if (join_path(target_path, sizeof(target_path), app_dir, LAUNCH_TARGET) != 0 ||
        join_path(primary_conf, sizeof(primary_conf), app_dir, LAUNCH_PRIMARY_CONF) != 0) {
        fprintf(stderr, "launcher: failed to build target paths\n");
        return 127;
    }

    config_path = primary_conf;
    if (LAUNCH_MEDIA_CHECK[0] != '\0') {
        if (join_path(media_path, sizeof(media_path), app_dir, LAUNCH_MEDIA_CHECK) != 0 ||
            join_path(fallback_conf, sizeof(fallback_conf), app_dir, LAUNCH_FALLBACK_CONF) != 0) {
            fprintf(stderr, "launcher: failed to build media paths\n");
            return 127;
        }

        if (!path_exists(media_path)) {
            config_path = fallback_conf;
        }
    }

    if (setenv("SDL_AUDIODRIVER", "dummy", 1) != 0) {
        fprintf(stderr, "launcher: failed to set SDL_AUDIODRIVER: %s\n", strerror(errno));
        return 127;
    }

    child_argv = calloc((size_t)argc + 3, sizeof(*child_argv));
    if (!child_argv) {
        fprintf(stderr, "launcher: out of memory\n");
        return 127;
    }

    child_argv[0] = target_path;
    child_argv[1] = "-conf";
    child_argv[2] = (char *)config_path;
    for (i = 1; i < argc; ++i) {
        child_argv[i + 2] = argv[i];
    }
    child_argv[argc + 2] = NULL;

    execv(child_argv[0], child_argv);
    fprintf(stderr, "launcher: exec failed for %s: %s\n", child_argv[0], strerror(errno));
    free(child_argv);
    return 127;
}
