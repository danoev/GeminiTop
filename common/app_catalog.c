#include "app_catalog.h"

#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

static char *trim_whitespace(char *text)
{
    char *end;

    while (*text && isspace((unsigned char)*text))
        text++;

    end = text + strlen(text);
    while (end > text && isspace((unsigned char)end[-1]))
        *--end = '\0';

    return text;
}

static void copy_string(char *dst, size_t dst_len, const char *src)
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
    memmove(dst, src, len);
    dst[len] = '\0';
}

static int join_path(char *out, size_t out_len, const char *base, const char *leaf)
{
    size_t base_len;
    size_t leaf_len;

    if (!out || out_len == 0 || !base || !leaf)
        return -1;

    base_len = strlen(base);
    leaf_len = strlen(leaf);
    if (base_len + 1 + leaf_len >= out_len)
        return -1;

    memcpy(out, base, base_len);
    out[base_len] = '/';
    memcpy(out + base_len + 1, leaf, leaf_len);
    out[base_len + 1 + leaf_len] = '\0';
    return 0;
}

static int parse_bool_value(const char *value)
{
    if (!value || !value[0])
        return 0;
    if (strcmp(value, "1") == 0 || strcasecmp(value, "true") == 0 ||
        strcasecmp(value, "yes") == 0 || strcasecmp(value, "on") == 0)
        return 1;
    return 0;
}

static void resolve_child_path(char *out, size_t out_len, const char *base, const char *value)
{
    if (!value || !value[0]) {
        out[0] = '\0';
        return;
    }

    if (value[0] == '/')
        snprintf(out, out_len, "%s", value);
    else
        snprintf(out, out_len, "%s/%s", base, value);
}

static int parse_app_manifest(gem_app_t *app, const char *manifest_path)
{
    FILE *file = fopen(manifest_path, "r");
    char line[256];

    if (!file)
        return -1;

    app->argc = 0;
    app->requires_tty = 0;
    copy_string(app->title, sizeof(app->title), app->id);
    copy_string(app->cwd, sizeof(app->cwd), app->app_dir);
    app->exec_path[0] = '\0';

    while (fgets(line, sizeof(line), file)) {
        char *value;
        char *eq;
        char *text = trim_whitespace(line);

        if (text[0] == '\0' || text[0] == '#')
            continue;

        eq = strchr(text, '=');
        if (!eq)
            continue;

        *eq = '\0';
        value = trim_whitespace(eq + 1);
        text = trim_whitespace(text);

        if (strcmp(text, "title") == 0) {
            copy_string(app->title, sizeof(app->title), value);
        } else if (strcmp(text, "exec") == 0) {
            resolve_child_path(app->exec_path, sizeof(app->exec_path), app->app_dir, value);
        } else if (strcmp(text, "cwd") == 0) {
            resolve_child_path(app->cwd, sizeof(app->cwd), app->app_dir, value);
        } else if (strcmp(text, "arg") == 0) {
            if (app->argc < GEM_APP_MAX_ARGS) {
                copy_string(app->args[app->argc], sizeof(app->args[app->argc]), value);
                app->argc++;
            }
        } else if (strcmp(text, "requires_tty") == 0) {
            app->requires_tty = parse_bool_value(value);
        }
    }

    fclose(file);

    if (app->exec_path[0] == '\0')
        return -1;
    if (access(app->exec_path, F_OK) != 0)
        return -1;
    if (access(app->cwd, F_OK) != 0)
        copy_string(app->cwd, sizeof(app->cwd), app->app_dir);

    return 0;
}

static int compare_apps(const void *left, const void *right)
{
    const gem_app_t *a = (const gem_app_t *)left;
    const gem_app_t *b = (const gem_app_t *)right;
    int title_cmp = strcmp(a->title, b->title);

    if (title_cmp != 0)
        return title_cmp;
    return strcmp(a->id, b->id);
}

static void sort_catalog(gem_app_catalog_t *catalog)
{
    if (catalog->count > 1) {
        qsort(catalog->entries,
              (size_t)catalog->count,
              sizeof(catalog->entries[0]),
              compare_apps);
    }
}

static int load_app_from_id(gem_app_catalog_t *catalog,
                            const char *apps_dir,
                            const char *app_id)
{
    char app_dir[GEM_APP_PATH_LEN];
    char manifest_path[GEM_APP_PATH_LEN];
    struct stat st;
    gem_app_t *app;

    if (!catalog || !apps_dir || !app_id || !app_id[0])
        return -1;
    if (catalog->count >= GEM_MAX_APPS)
        return -1;
    if (strlen(app_id) >= GEM_APP_ID_LEN)
        return -1;
    if (gem_apps_find_by_id(catalog, app_id))
        return -1;

    if (join_path(app_dir, sizeof(app_dir), apps_dir, app_id) != 0)
        return -1;
    if (stat(app_dir, &st) != 0 || !S_ISDIR(st.st_mode))
        return -1;

    if (join_path(manifest_path, sizeof(manifest_path), app_dir, "app.cfg") != 0)
        return -1;
    if (stat(manifest_path, &st) != 0 || !S_ISREG(st.st_mode))
        return -1;

    app = &catalog->entries[catalog->count];
    memset(app, 0, sizeof(*app));
    copy_string(app->id, sizeof(app->id), app_id);
    copy_string(app->app_dir, sizeof(app->app_dir), app_dir);

    if (parse_app_manifest(app, manifest_path) != 0)
        return -1;

    catalog->count++;
    return 0;
}

static int load_catalog_index(gem_app_catalog_t *catalog,
                              const char *apps_dir,
                              const char *catalog_path)
{
    FILE *file;
    char line[256];

    if (!catalog || !apps_dir || !catalog_path || !catalog_path[0])
        return -1;

    file = fopen(catalog_path, "r");
    if (!file)
        return -1;

    catalog->count = 0;
    while (fgets(line, sizeof(line), file)) {
        char *text = trim_whitespace(line);

        if (text[0] == '\0' || text[0] == '#')
            continue;

        load_app_from_id(catalog, apps_dir, text);
    }

    fclose(file);
    sort_catalog(catalog);
    return 0;
}

int gem_apps_scan(gem_app_catalog_t *catalog, const char *apps_dir)
{
    DIR *dir;
    struct dirent *entry;

    if (!catalog)
        return -1;

    catalog->count = 0;
    if (!apps_dir || !apps_dir[0])
        return -1;

    dir = opendir(apps_dir);
    if (!dir)
        return -1;

    while ((entry = readdir(dir)) != NULL && catalog->count < GEM_MAX_APPS) {
        char app_dir[GEM_APP_PATH_LEN];
        char manifest_path[GEM_APP_PATH_LEN];
        struct stat st;
        gem_app_t *app;

        if (entry->d_name[0] == '.')
            continue;
        if (strlen(entry->d_name) >= sizeof(app->id))
            continue;

        if (join_path(app_dir, sizeof(app_dir), apps_dir, entry->d_name) != 0)
            continue;
        if (stat(app_dir, &st) != 0 || !S_ISDIR(st.st_mode))
            continue;

        if (join_path(manifest_path, sizeof(manifest_path), app_dir, "app.cfg") != 0)
            continue;
        if (stat(manifest_path, &st) != 0 || !S_ISREG(st.st_mode))
            continue;

        app = &catalog->entries[catalog->count];
        memset(app, 0, sizeof(*app));
        copy_string(app->id, sizeof(app->id), entry->d_name);
        copy_string(app->app_dir, sizeof(app->app_dir), app_dir);

        if (parse_app_manifest(app, manifest_path) != 0)
            continue;

        catalog->count++;
    }

    closedir(dir);
    sort_catalog(catalog);

    return 0;
}

int gem_apps_load(gem_app_catalog_t *catalog, const char *apps_dir,
                  const char *catalog_path)
{
    if (!catalog)
        return -1;
    if (catalog_path && catalog_path[0] &&
        load_catalog_index(catalog, apps_dir, catalog_path) == 0)
        return 0;
    return gem_apps_scan(catalog, apps_dir);
}

const gem_app_t *gem_apps_find_by_id(const gem_app_catalog_t *catalog, const char *id)
{
    int i;

    if (!catalog || !id)
        return NULL;

    for (i = 0; i < catalog->count; i++) {
        if (strcmp(catalog->entries[i].id, id) == 0)
            return &catalog->entries[i];
    }

    return NULL;
}
