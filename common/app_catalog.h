#ifndef GEM_APP_CATALOG_H
#define GEM_APP_CATALOG_H

#define GEM_MAX_APPS 16
#define GEM_APP_ID_LEN 64
#define GEM_APP_TITLE_LEN 48
#define GEM_APP_PATH_LEN 512
#define GEM_APP_MAX_ARGS 16
#define GEM_APP_ARG_LEN 128
#define GEM_APP_CATALOG_INDEX "catalog.txt"

typedef struct {
    char id[GEM_APP_ID_LEN];
    char title[GEM_APP_TITLE_LEN];
    char app_dir[GEM_APP_PATH_LEN];
    char cwd[GEM_APP_PATH_LEN];
    char exec_path[GEM_APP_PATH_LEN];
    int requires_tty;
    int argc;
    char args[GEM_APP_MAX_ARGS][GEM_APP_ARG_LEN];
} gem_app_t;

typedef struct {
    gem_app_t entries[GEM_MAX_APPS];
    int count;
} gem_app_catalog_t;

int gem_apps_scan(gem_app_catalog_t *catalog, const char *apps_dir);
int gem_apps_load(gem_app_catalog_t *catalog, const char *apps_dir,
                  const char *catalog_path);
const gem_app_t *gem_apps_find_by_id(const gem_app_catalog_t *catalog, const char *id);

#endif
