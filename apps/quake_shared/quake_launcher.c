#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#ifndef QUAKE_TARGET_BINARY
#define QUAKE_TARGET_BINARY "tyr-quake"
#endif

static void die_errno(const char *message)
{
    fprintf(stderr, "%s: %s\n", message, strerror(errno));
    exit(127);
}

static void die_message(const char *message)
{
    fprintf(stderr, "%s\n", message);
    exit(127);
}

static void trim_to_dirname(char *path)
{
    char *slash = strrchr(path, '/');

    if (!slash) {
        strcpy(path, ".");
        return;
    }

    if (slash == path) {
        slash[1] = '\0';
        return;
    }

    *slash = '\0';
}

static void make_path(char *dst, size_t dst_len, const char *left, const char *right)
{
    int written = snprintf(dst, dst_len, "%s/%s", left, right);
    if (written < 0 || (size_t)written >= dst_len)
        die_message("path too long");
}

static void mkdir_p(const char *path)
{
    char tmp[PATH_MAX];
    size_t len;
    char *cursor;

    len = strlen(path);
    if (len == 0 || len >= sizeof(tmp))
        die_message("mkdir path too long");

    memcpy(tmp, path, len + 1);

    for (cursor = tmp + 1; *cursor; cursor++) {
        if (*cursor != '/')
            continue;
        *cursor = '\0';
        if (mkdir(tmp, 0775) != 0 && errno != EEXIST)
            die_errno(tmp);
        *cursor = '/';
    }

    if (mkdir(tmp, 0775) != 0 && errno != EEXIST)
        die_errno(tmp);
}

static int file_exists(const char *path)
{
    struct stat st;

    return stat(path, &st) == 0;
}

static int is_upper_alpha_string(const char *text, size_t len)
{
    size_t i;

    if (!text || len == 0)
        return 0;

    for (i = 0; i < len; i++) {
        if (text[i] < 'A' || text[i] > 'Z')
            return 0;
    }

    return 1;
}

static int normalize_bind_line(char *line)
{
    char *cursor = line;
    char *command_end;
    char *key_start;
    char *key_end;
    size_t key_len;

    while (*cursor == ' ' || *cursor == '\t')
        cursor++;

    if (strncmp(cursor, "bind", 4) != 0)
        return 0;
    command_end = cursor + 4;
    if (*command_end && *command_end != ' ' && *command_end != '\t')
        return 0;

    cursor = command_end;
    while (*cursor == ' ' || *cursor == '\t')
        cursor++;
    if (!*cursor || *cursor == '\n' || *cursor == '\r')
        return 0;

    if (*cursor == '"') {
        key_start = cursor + 1;
        key_end = strchr(key_start, '"');
        if (!key_end)
            return 0;
    } else {
        key_start = cursor;
        key_end = key_start;
        while (*key_end && *key_end != ' ' && *key_end != '\t' &&
               *key_end != '\n' && *key_end != '\r')
            key_end++;
    }

    key_len = (size_t)(key_end - key_start);
    if (key_len != 1 || !is_upper_alpha_string(key_start, key_len))
        return 0;

    key_start[0] = (char)(key_start[0] - 'A' + 'a');
    return 1;
}

static void normalize_legacy_bindings(const char *path)
{
    FILE *in;
    FILE *out;
    char tmp_path[PATH_MAX];
    char line[4096];
    int changed = 0;
    int written;

    if (!file_exists(path))
        return;

    in = fopen(path, "rb");
    if (!in)
        die_errno(path);

    written = snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", path);
    if (written < 0 || (size_t)written >= sizeof(tmp_path)) {
        fclose(in);
        die_message("config temp path too long");
    }

    out = fopen(tmp_path, "wb");
    if (!out) {
        fclose(in);
        die_errno(tmp_path);
    }

    while (fgets(line, sizeof(line), in)) {
        if (normalize_bind_line(line))
            changed = 1;

        if (fputs(line, out) == EOF) {
            fclose(in);
            fclose(out);
            unlink(tmp_path);
            die_errno(tmp_path);
        }
    }

    if (ferror(in)) {
        fclose(in);
        fclose(out);
        unlink(tmp_path);
        die_errno(path);
    }

    if (fclose(in) != 0) {
        fclose(out);
        unlink(tmp_path);
        die_errno(path);
    }
    if (fclose(out) != 0) {
        unlink(tmp_path);
        die_errno(tmp_path);
    }

    if (!changed) {
        unlink(tmp_path);
        return;
    }

    if (rename(tmp_path, path) != 0) {
        unlink(tmp_path);
        die_errno(path);
    }
}

static void resolve_app_dir(char *app_dir, size_t app_dir_len, const char *argv0)
{
    ssize_t len = readlink("/proc/self/exe", app_dir, app_dir_len - 1);
    if (len > 0) {
        app_dir[len] = '\0';
        trim_to_dirname(app_dir);
        return;
    }

    if (argv0 && strchr(argv0, '/')) {
        char resolved[PATH_MAX];

        if (!realpath(argv0, resolved))
            die_errno("realpath(argv0)");
        if (strlen(resolved) >= app_dir_len)
            die_message("resolved app path too long");
        strcpy(app_dir, resolved);
        trim_to_dirname(app_dir);
        return;
    }

    if (!getcwd(app_dir, app_dir_len))
        die_errno("getcwd");
}

int main(int argc, char **argv)
{
    char app_dir[PATH_MAX];
    char apps_dir[PATH_MAX];
    char base_dir[PATH_MAX];
    char binary_path[PATH_MAX];
    char config_root[PATH_MAX];
    char config_id1[PATH_MAX];
    char config_qw[PATH_MAX];
    char user_id1_cfg[PATH_MAX];
    char user_qw_cfg[PATH_MAX];
    char id1_dir[PATH_MAX];
    char qw_dir[PATH_MAX];
    char **child_argv;
    int child_argc;
    int i;

    resolve_app_dir(app_dir, sizeof(app_dir), argv[0]);
    if (strlen(app_dir) >= sizeof(apps_dir))
        die_message("app directory path too long");
    strcpy(apps_dir, app_dir);
    trim_to_dirname(apps_dir);

    make_path(base_dir, sizeof(base_dir), apps_dir, "quake-data");
    make_path(binary_path, sizeof(binary_path), base_dir, "bin/" QUAKE_TARGET_BINARY);
    make_path(config_root, sizeof(config_root), base_dir, ".tyrquake");
    make_path(config_id1, sizeof(config_id1), config_root, "id1");
    make_path(config_qw, sizeof(config_qw), config_root, "qw");
    make_path(user_id1_cfg, sizeof(user_id1_cfg), config_id1, "config.cfg");
    make_path(user_qw_cfg, sizeof(user_qw_cfg), config_qw, "config.cfg");
    make_path(id1_dir, sizeof(id1_dir), base_dir, "id1");
    make_path(qw_dir, sizeof(qw_dir), base_dir, "qw");

    mkdir_p(base_dir);
    mkdir_p(id1_dir);
    mkdir_p(qw_dir);
    mkdir_p(config_root);
    mkdir_p(config_id1);
    mkdir_p(config_qw);

    normalize_legacy_bindings(user_id1_cfg);
    normalize_legacy_bindings(user_qw_cfg);

    if (setenv("HOME", base_dir, 1) != 0)
        die_errno("setenv(HOME)");

    child_argc = argc + 10;
    child_argv = calloc((size_t)child_argc, sizeof(*child_argv));
    if (!child_argv)
        die_errno("calloc");

    i = 0;
    child_argv[i++] = binary_path;
    child_argv[i++] = "-basedir";
    child_argv[i++] = base_dir;
    child_argv[i++] = "-heapsize";
    child_argv[i++] = "32768";
    child_argv[i++] = "-nocdaudio";
    child_argv[i++] = "-sndmono";
    child_argv[i++] = "-sndspeed";
    child_argv[i++] = "22050";

    for (int argi = 1; argi < argc; argi++)
        child_argv[i++] = argv[argi];
    child_argv[i] = NULL;

    execv(binary_path, child_argv);
    die_errno(binary_path);
    return 127;
}
