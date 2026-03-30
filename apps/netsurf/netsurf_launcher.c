#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define RUNTIME_HOME "/tmp/gemini-netsurf-home"
#define CHOICES_DIR ".netsurf"
#define CHOICES_FILE "Choices"
#define TARGET_BIN "netsurf-bin"
#define RES_DIR "res"

static int get_app_dir(char *out, size_t out_size)
{
    ssize_t len = readlink("/proc/self/exe", out, out_size - 1);
    char *slash;

    if (len < 0 || (size_t)len >= out_size)
        return -1;

    out[len] = '\0';
    slash = strrchr(out, '/');
    if (!slash || slash == out)
        return -1;

    *slash = '\0';
    return 0;
}

static int join_path(char *out, size_t out_size, const char *base, const char *leaf)
{
    int written = snprintf(out, out_size, "%s/%s", base, leaf);
    return (written < 0 || (size_t)written >= out_size) ? -1 : 0;
}

static int mkdir_if_missing(const char *path)
{
    if (mkdir(path, 0755) == 0 || errno == EEXIST)
        return 0;
    return -1;
}

static int write_choices(const char *choices_path, const char *ca_bundle_path)
{
    FILE *file = fopen(choices_path, "w");

    if (!file)
        return -1;

    if (fprintf(file,
                "homepage_url:https://theoldnet.com/\n"
                "window_width:1920\n"
                "window_height:720\n"
                "ca_bundle:%s\n"
                "fb_toolbar_size:72\n"
                "fb_furniture_size:48\n"
                "fb_osk:0\n",
                ca_bundle_path) < 0) {
        fclose(file);
        return -1;
    }

    if (fclose(file) != 0)
        return -1;

    return 0;
}

int main(int argc, char **argv)
{
    char app_dir[PATH_MAX];
    char res_dir[PATH_MAX];
    char ca_bundle[PATH_MAX];
    char target_path[PATH_MAX];
    char choices_dir[PATH_MAX];
    char choices_path[PATH_MAX];
    char **child_argv;
    int i;

    if (get_app_dir(app_dir, sizeof(app_dir)) != 0) {
        fprintf(stderr, "netsurf launcher: failed to resolve app directory: %s\n",
                strerror(errno));
        return 127;
    }

    if (join_path(res_dir, sizeof(res_dir), app_dir, RES_DIR) != 0 ||
        join_path(ca_bundle, sizeof(ca_bundle), res_dir, "ca-bundle") != 0 ||
        join_path(target_path, sizeof(target_path), app_dir, TARGET_BIN) != 0 ||
        join_path(choices_dir, sizeof(choices_dir), RUNTIME_HOME, CHOICES_DIR) != 0 ||
        join_path(choices_path, sizeof(choices_path), choices_dir, CHOICES_FILE) != 0) {
        fprintf(stderr, "netsurf launcher: failed to build runtime paths\n");
        return 127;
    }

    if (mkdir_if_missing(RUNTIME_HOME) != 0 || mkdir_if_missing(choices_dir) != 0) {
        fprintf(stderr, "netsurf launcher: failed to create runtime directories: %s\n",
                strerror(errno));
        return 127;
    }

    if (write_choices(choices_path, ca_bundle) != 0) {
        fprintf(stderr, "netsurf launcher: failed to write Choices: %s\n",
                strerror(errno));
        return 127;
    }

    if (setenv("HOME", RUNTIME_HOME, 1) != 0 ||
        setenv("NETSURFRES", res_dir, 1) != 0) {
        fprintf(stderr, "netsurf launcher: failed to set environment: %s\n",
                strerror(errno));
        return 127;
    }

    child_argv = calloc((size_t)argc + 9, sizeof(*child_argv));
    if (!child_argv) {
        fprintf(stderr, "netsurf launcher: out of memory\n");
        return 127;
    }

    child_argv[0] = target_path;
    child_argv[1] = "-f";
    child_argv[2] = "linux";
    child_argv[3] = "-b";
    child_argv[4] = "32";
    child_argv[5] = "-w";
    child_argv[6] = "1920";
    child_argv[7] = "-h";
    child_argv[8] = "720";
    for (i = 1; i < argc; ++i)
        child_argv[i + 8] = argv[i];
    child_argv[argc + 8] = NULL;

    execv(child_argv[0], child_argv);
    fprintf(stderr, "netsurf launcher: exec failed for %s: %s\n",
            child_argv[0], strerror(errno));
    free(child_argv);
    return 127;
}
