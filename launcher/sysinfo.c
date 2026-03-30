#include "sysinfo.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statvfs.h>
#include <unistd.h>

static int g_stat_fd = -1;
static int g_meminfo_fd = -1;
static unsigned long prev_total = 0;
static unsigned long prev_idle = 0;
static int cpu_initialized = 0;

static int read_proc_file_cached(int *fd_ptr, const char *path, char *buf, size_t len)
{
    ssize_t count;

    if (*fd_ptr < 0)
        *fd_ptr = open(path, O_RDONLY);
    if (*fd_ptr < 0)
        return -1;

    if (lseek(*fd_ptr, 0, SEEK_SET) < 0) {
        close(*fd_ptr);
        *fd_ptr = open(path, O_RDONLY);
        if (*fd_ptr < 0)
            return -1;
        if (lseek(*fd_ptr, 0, SEEK_SET) < 0)
            return -1;
    }

    count = read(*fd_ptr, buf, len - 1);
    if (count <= 0)
        return -1;

    buf[count] = '\0';
    return (int)count;
}

static float read_cpu_usage(void)
{
    char buf[256];
    unsigned long fields[7] = { 0 };
    unsigned long total;
    unsigned long total_diff;
    unsigned long idle_diff;
    char *cursor;
    char *end;
    int i;

    if (read_proc_file_cached(&g_stat_fd, "/proc/stat", buf, sizeof(buf)) < 0)
        return 0.0f;

    if (strncmp(buf, "cpu ", 4) != 0)
        return 0.0f;

    cursor = buf + 4;
    for (i = 0; i < 7; i++) {
        fields[i] = strtoul(cursor, &end, 10);
        if (cursor == end)
            break;
        cursor = end;
    }
    if (i < 4)
        return 0.0f;

    total = fields[0] + fields[1] + fields[2] + fields[3] +
            fields[4] + fields[5] + fields[6];
    total_diff = total - prev_total;
    idle_diff = fields[3] - prev_idle;

    prev_total = total;
    prev_idle = fields[3];

    if (!cpu_initialized) {
        cpu_initialized = 1;
        return 0.0f;
    }

    if (total_diff == 0)
        return 0.0f;
    return 100.0f * (1.0f - (float)idle_diff / (float)total_diff);
}

static void read_meminfo(sysinfo_t *info)
{
    char buf[1024];
    char *line;
    char *saveptr = NULL;

    if (read_proc_file_cached(&g_meminfo_fd, "/proc/meminfo", buf, sizeof(buf)) < 0)
        return;

    info->mem_total_kb = 0;
    info->mem_available_kb = 0;

    for (line = strtok_r(buf, "\n", &saveptr);
         line;
         line = strtok_r(NULL, "\n", &saveptr)) {
        if (strncmp(line, "MemTotal:", 9) == 0) {
            info->mem_total_kb = atoi(line + 9);
        } else if (strncmp(line, "MemAvailable:", 13) == 0) {
            info->mem_available_kb = atoi(line + 13);
        }

        if (info->mem_total_kb > 0 && info->mem_available_kb > 0)
            break;
    }

    if (info->mem_available_kb < 0)
        info->mem_available_kb = 0;
    if (info->mem_total_kb < info->mem_available_kb)
        info->mem_available_kb = info->mem_total_kb;

    info->mem_used_kb = info->mem_total_kb - info->mem_available_kb;
    if (info->mem_used_kb < 0)
        info->mem_used_kb = 0;
}

static int read_free_kb(const char *path)
{
    struct statvfs st;
    if (statvfs(path, &st) != 0) return -1;
    return (int)((unsigned long long)st.f_bavail * st.f_bsize / 1024);
}

void sysinfo_update_core(sysinfo_t *info)
{
    if (!info)
        return;
    info->cpu_usage = read_cpu_usage();
    read_meminfo(info);
}

void sysinfo_update_storage(sysinfo_t *info, const char *usb_path)
{
    info->tmp_free_kb = read_free_kb("/tmp");
    info->usb_free_kb = usb_path ? read_free_kb(usb_path) : -1;
}

void sysinfo_update(sysinfo_t *info, const char *usb_path)
{
    sysinfo_update_core(info);
    sysinfo_update_storage(info, usb_path);
}
