#ifndef SYSINFO_H
#define SYSINFO_H

typedef struct {
    float cpu_usage;       // 0.0 - 100.0 percent
    int mem_total_kb;
    int mem_available_kb;
    int mem_used_kb;
    int tmp_free_kb;       // /tmp space
    int usb_free_kb;       // USB drive space (-1 if unknown)
} sysinfo_t;

// Read current system stats from /proc and df
void sysinfo_update_core(sysinfo_t *info);
void sysinfo_update_storage(sysinfo_t *info, const char *usb_path);
void sysinfo_update(sysinfo_t *info, const char *usb_path);

#endif // SYSINFO_H
