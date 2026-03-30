#include "app_catalog.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <limits.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_LAUNCHERS 8
#define MAX_PATH_LEN 1024

typedef struct {
    char usb_root[MAX_PATH_LEN];
    char launcher_bin[MAX_PATH_LEN];
    char launch_file[MAX_PATH_LEN];
    char ssh_state_file[MAX_PATH_LEN];
    char log_dir[MAX_PATH_LEN];
    char heartbeat[MAX_PATH_LEN];
    char dropbear_src[MAX_PATH_LEN];
    char dropbear_tmp[MAX_PATH_LEN];
    char dropbear_key_tmp[MAX_PATH_LEN];
    char dropbear_host_key[MAX_PATH_LEN];
    char main_log[MAX_PATH_LEN];
    char dropbear_log[MAX_PATH_LEN];
} path_state_t;

static path_state_t g_paths;
static pid_t g_stock_pids[MAX_LAUNCHERS];
static size_t g_stock_count = 0;
static pid_t g_launcher_pid = -1;
static pid_t g_app_pid = -1;
static pid_t g_dropbear_pid = -1;
static volatile sig_atomic_t g_stop_requested = 0;
static int g_ssh_enabled = 0;
static gem_app_catalog_t g_catalog;
static char g_apps_path[MAX_PATH_LEN];
static char g_catalog_path[MAX_PATH_LEN];

static void stop_debug_services(void);
static bool read_launch_file(char *request, size_t request_len);
static int init_app_catalog_paths(void);
static int refresh_app_catalog(gem_app_catalog_t *catalog);

static int build_path(char *out, size_t out_len, const char *base, const char *leaf)
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

static void timestamp_now(char *buf, size_t len)
{
    time_t now = time(NULL);
    struct tm tm_now;
    if (localtime_r(&now, &tm_now) == NULL) {
        snprintf(buf, len, "00:00:00");
        return;
    }
    strftime(buf, len, "%H:%M:%S", &tm_now);
}

static void log_line(const char *fmt, ...)
{
    char ts[16];
    va_list ap;
    timestamp_now(ts, sizeof(ts));
    fprintf(stdout, "[%s] ", ts);
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);
}

static void write_heartbeat(const char *state)
{
    FILE *f = fopen(g_paths.heartbeat, "w");
    if (!f)
        return;
    fprintf(f, "%s %ld\n", state, (long)time(NULL));
    fclose(f);
}

static void write_ssh_state(const char *state)
{
    FILE *f = fopen(g_paths.ssh_state_file, "w");
    if (!f)
        return;
    fprintf(f, "%s\n", state ? state : "disabled");
    fclose(f);
}

static int init_app_catalog_paths(void)
{
    if (g_apps_path[0] != '\0' && g_catalog_path[0] != '\0')
        return 0;

    if (build_path(g_apps_path, sizeof(g_apps_path), g_paths.usb_root, "apps") != 0)
        return -1;
    if (build_path(g_catalog_path, sizeof(g_catalog_path),
                   g_apps_path, GEM_APP_CATALOG_INDEX) != 0)
        return -1;
    return 0;
}

static int refresh_app_catalog(gem_app_catalog_t *catalog)
{
    if (!catalog)
        return -1;
    if (init_app_catalog_paths() != 0)
        return -1;
    return gem_apps_load(catalog, g_apps_path, g_catalog_path);
}

static int mkdir_p(const char *path, mode_t mode)
{
    char tmp[MAX_PATH_LEN];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp))
        return -1;

    snprintf(tmp, sizeof(tmp), "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/')
            continue;
        *p = '\0';
        if (mkdir(tmp, mode) != 0 && errno != EEXIST)
            return -1;
        *p = '/';
    }

    if (mkdir(tmp, mode) != 0 && errno != EEXIST)
        return -1;
    return 0;
}

static int copy_file(const char *src, const char *dst, mode_t mode)
{
    int in_fd = open(src, O_RDONLY);
    int out_fd;
    char buf[8192];
    ssize_t nread;

    if (in_fd < 0)
        return -1;

    out_fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (out_fd < 0) {
        close(in_fd);
        return -1;
    }

    while ((nread = read(in_fd, buf, sizeof(buf))) > 0) {
        char *ptr = buf;
        ssize_t remaining = nread;
        while (remaining > 0) {
            ssize_t nw = write(out_fd, ptr, (size_t)remaining);
            if (nw < 0) {
                close(in_fd);
                close(out_fd);
                return -1;
            }
            ptr += nw;
            remaining -= nw;
        }
    }

    close(in_fd);
    close(out_fd);
    return (nread < 0) ? -1 : 0;
}

static void kill_process_group(pid_t pid, int sig)
{
    if (pid > 0)
        kill(-pid, sig);
}

static void signal_handler(int sig)
{
    (void)sig;
    g_stop_requested = 1;
    kill_process_group(g_launcher_pid, SIGTERM);
    kill_process_group(g_app_pid, SIGTERM);
}

static int find_usb_root_from_argv(int argc, char **argv, char *out, size_t out_len)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--usb") == 0 && i + 1 < argc) {
            snprintf(out, out_len, "%s", argv[i + 1]);
            return 0;
        }
    }
    return -1;
}

static void resolve_paths(void)
{
    build_path(g_paths.launcher_bin, sizeof(g_paths.launcher_bin), g_paths.usb_root, "geminilauncher");
    snprintf(g_paths.launch_file, sizeof(g_paths.launch_file), "/tmp/gemini_launch");
    snprintf(g_paths.ssh_state_file, sizeof(g_paths.ssh_state_file), "/tmp/gemini_ssh_state");
    build_path(g_paths.log_dir, sizeof(g_paths.log_dir), g_paths.usb_root, "logs");
    build_path(g_paths.heartbeat, sizeof(g_paths.heartbeat), g_paths.usb_root, "gemn_heartbeat.txt");
    build_path(g_paths.dropbear_src, sizeof(g_paths.dropbear_src), g_paths.usb_root, "dropbear");
    snprintf(g_paths.dropbear_tmp, sizeof(g_paths.dropbear_tmp), "/tmp/dropbear");
    snprintf(g_paths.dropbear_key_tmp, sizeof(g_paths.dropbear_key_tmp), "/tmp/dropbearkey");
    snprintf(g_paths.dropbear_host_key, sizeof(g_paths.dropbear_host_key), "/tmp/dropbear_rsa_host_key");
    build_path(g_paths.main_log, sizeof(g_paths.main_log), g_paths.log_dir, "gemn_auto.txt");
    build_path(g_paths.dropbear_log, sizeof(g_paths.dropbear_log), g_paths.log_dir, "dropbear.txt");
}

static int init_logging(void)
{
    int fd;
    if (mkdir_p(g_paths.log_dir, 0755) != 0)
        return -1;

    fd = open(g_paths.main_log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        return -1;

    if (dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0) {
        close(fd);
        return -1;
    }
    close(fd);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    unlink("/tmp/gemn_auto.txt");
    symlink(g_paths.main_log, "/tmp/gemn_auto.txt");
    return 0;
}

static void export_runtime_env(void)
{
    setenv("LD_LIBRARY_PATH", "/lib:/usr/lib:/usr/local/lib:/usr/local/qt/lib:/system/lib:/system/qt/lib:/application/lib:/apps/lib:/application/lib/module/default:/application/lib/module:/media/flash/nvm/lib", 1);
    setenv("PATH", "/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:/usr/local/qt/bin:/application/bin:/apps/bin:/media/flash/nvm/bin", 1);
    setenv("HOME", "/tmp", 1);
    setenv("TERM", "xterm", 1);
    setenv("GEM_LOG_LEVEL", "info", 1);
    setenv("GEMINI_USB", g_paths.usb_root, 1);
    setenv("GEMINI_MANAGED", "1", 1);
    setenv("GEMINI_SSH_ENABLED", g_ssh_enabled ? "1" : "0", 1);
}

static void prepare_auth_files(void)
{
    FILE *f = fopen("/etc/shells", "w");
    if (f) {
        fputs("/bin/sh\n/bin/ash\n/bin/bash\n/bin/csh\n", f);
        fclose(f);
    }

    f = fopen("/etc/passwd", "r");
    if (f) {
        char temp_path[] = "/tmp/passwd.gemnXXXXXX";
        int temp_fd = mkstemp(temp_path);
        if (temp_fd >= 0) {
            FILE *out = fdopen(temp_fd, "w");
            char line[512];
            if (out) {
                while (fgets(line, sizeof(line), f)) {
                    if (strncmp(line, "root:", 5) == 0)
                        fputs("root:x:0:0:root:/root:/bin/sh\n", out);
                    else
                        fputs(line, out);
                }
                fclose(out);
                rename(temp_path, "/etc/passwd");
            } else {
                close(temp_fd);
                unlink(temp_path);
            }
        }
        fclose(f);
    }

    f = fopen("/etc/shadow", "w");
    if (f) {
        fputs("root:$1$ab$b5pPMR/PmBMGcPGBjWbaq1:0:0:99999:7:::\n", f);
        fclose(f);
        chmod("/etc/shadow", 0640);
    }

    mkdir("/root", 0700);
    chmod("/root", 0700);
}

static void collect_launcher_pids(void)
{
    DIR *dir = opendir("/proc");
    struct dirent *ent;
    g_stock_count = 0;
    if (!dir)
        return;

    while ((ent = readdir(dir)) != NULL) {
        char comm_path[64];
        char comm[64];
        FILE *f;
        pid_t pid;

        if (g_stock_count >= MAX_LAUNCHERS)
            break;
        pid = (pid_t)atoi(ent->d_name);
        if (pid <= 0)
            continue;

        snprintf(comm_path, sizeof(comm_path), "/proc/%d/comm", (int)pid);
        f = fopen(comm_path, "r");
        if (!f)
            continue;
        if (!fgets(comm, sizeof(comm), f)) {
            fclose(f);
            continue;
        }
        fclose(f);
        comm[strcspn(comm, "\r\n")] = '\0';
        if (strcmp(comm, "Launcher") == 0)
            g_stock_pids[g_stock_count++] = pid;
    }

    closedir(dir);
}

static void write_launcher_pid_files(void)
{
    FILE *f = fopen("/tmp/gemini_launcher_pid", "w");
    if (f) {
        if (g_stock_count > 0)
            fprintf(f, "%d\n", (int)g_stock_pids[0]);
        fclose(f);
    }

    f = fopen("/tmp/gemini_launcher_pids", "w");
    if (f) {
        for (size_t i = 0; i < g_stock_count; i++)
            fprintf(f, "%d\n", (int)g_stock_pids[i]);
        fclose(f);
    }
}

static void set_oom_adj(pid_t pid, int value)
{
    char path[64];
    FILE *f;
    snprintf(path, sizeof(path), "/proc/%d/oom_adj", (int)pid);
    f = fopen(path, "w");
    if (!f)
        return;
    fprintf(f, "%d\n", value);
    fclose(f);
}

static void freeze_stock_launcher(void)
{
    collect_launcher_pids();
    write_launcher_pid_files();
    for (size_t i = 0; i < g_stock_count; i++) {
        kill(g_stock_pids[i], SIGSTOP);
        set_oom_adj(g_stock_pids[i], 15);
    }
    if (g_stock_count > 0) {
        FILE *f = fopen("/proc/sys/vm/drop_caches", "w");
        if (f) {
            fputs("3\n", f);
            fclose(f);
        }
        log_line("stock Launcher frozen (%zu pid%s)", g_stock_count, g_stock_count == 1 ? "" : "s");
    } else {
        log_line("stock Launcher not found");
    }
}

static void resume_stock_launcher(void)
{
    for (size_t i = 0; i < g_stock_count; i++) {
        if (kill(g_stock_pids[i], 0) == 0) {
            set_oom_adj(g_stock_pids[i], 0);
            kill(g_stock_pids[i], SIGCONT);
        }
    }
}

static void chmod_usb_payloads(void)
{
    gem_app_catalog_t catalog;
    int i;

    chmod(g_paths.launcher_bin, 0755);
    chmod(g_paths.dropbear_src, 0755);

    if (refresh_app_catalog(&catalog) != 0)
        return;

    for (i = 0; i < catalog.count; i++)
        chmod(catalog.entries[i].exec_path, 0755);
}

static int prepare_dropbear_binary(void)
{
    if (copy_file(g_paths.dropbear_src, g_paths.dropbear_tmp, 0755) != 0) {
        log_line("dropbear copy failed: %s", strerror(errno));
        return -1;
    }

    unlink(g_paths.dropbear_key_tmp);
    if (symlink(g_paths.dropbear_tmp, g_paths.dropbear_key_tmp) != 0) {
        log_line("dropbearkey symlink failed: %s", strerror(errno));
        return -1;
    }

    return 0;
}

static int generate_host_key(void)
{
    pid_t pid;
    int status = 0;
    char *argv[] = { g_paths.dropbear_key_tmp, "-t", "rsa", "-f", g_paths.dropbear_host_key, "-s", "2048", NULL };

    if (access(g_paths.dropbear_host_key, R_OK) == 0)
        return 0;

    pid = fork();
    if (pid == 0) {
        int fd = open(g_paths.dropbear_log, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            close(fd);
        }
        execv(g_paths.dropbear_key_tmp, argv);
        _exit(127);
    }
    if (pid < 0)
        return -1;
    if (waitpid(pid, &status, 0) < 0)
        return -1;
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : -1;
}

static const char *wifi_ip_string(void)
{
    static char ip[INET_ADDRSTRLEN];
    struct ifaddrs *ifaddr = NULL;
    struct ifaddrs *ifa;
    const char *wanted[] = { "wlan0", "wlan1", "ra0", "ap0", NULL };

    ip[0] = '\0';
    if (getifaddrs(&ifaddr) != 0)
        return NULL;

    for (ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        if (!(ifa->ifa_flags & IFF_UP))
            continue;
        for (int i = 0; wanted[i]; i++) {
            if (strcmp(ifa->ifa_name, wanted[i]) == 0) {
                struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
                if (inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip)) != NULL) {
                    if (strcmp(ip, "127.0.0.1") != 0 && strcmp(ip, "0.0.0.0") != 0) {
                        freeifaddrs(ifaddr);
                        return ip;
                    }
                }
            }
        }
    }

    freeifaddrs(ifaddr);
    return NULL;
}

static int start_dropbear(void)
{
    pid_t pid;
    int status;
    char *argv[] = { g_paths.dropbear_tmp, "-r", g_paths.dropbear_host_key, "-p", "2222", "-E", "-F", NULL };

    pid = fork();
    if (pid < 0)
        return -1;
    if (pid != 0) {
        sleep(1);
        if (waitpid(pid, &status, WNOHANG) == pid) {
            log_line("dropbear exited immediately (status=%d)", status);
            g_dropbear_pid = -1;
            return -1;
        }
        g_dropbear_pid = pid;
        return 0;
    }

    setsid();
    {
        int fd = open(g_paths.dropbear_log, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            close(fd);
        }
    }
    execv(g_paths.dropbear_tmp, argv);
    _exit(127);
}

static int verify_dropbear_ready(void)
{
    int attempt;

    for (attempt = 0; attempt < 25; attempt++) {
        int fd;
        struct sockaddr_in addr;

        if (g_dropbear_pid <= 0 || kill(g_dropbear_pid, 0) != 0)
            return -1;

        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd >= 0) {
            char banner[32];
            ssize_t nread;
            struct pollfd pfd;

            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(2222);
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

            if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
                pfd.fd = fd;
                pfd.events = POLLIN;
                if (poll(&pfd, 1, 500) > 0 && (pfd.revents & POLLIN)) {
                    nread = read(fd, banner, sizeof(banner) - 1);
                    if (nread > 0) {
                        banner[nread] = '\0';
                        close(fd);
                        if (strncmp(banner, "SSH-", 4) == 0)
                            return 0;
                    }
                }
            }

            close(fd);
        }

        usleep(200000);
    }

    return -1;
}

static void kill_by_name(const char *name)
{
    DIR *dir = opendir("/proc");
    struct dirent *ent;
    if (!dir)
        return;
    while ((ent = readdir(dir)) != NULL) {
        char comm_path[64];
        char comm[64];
        FILE *f;
        pid_t pid = (pid_t)atoi(ent->d_name);
        if (pid <= 0)
            continue;
        snprintf(comm_path, sizeof(comm_path), "/proc/%d/comm", (int)pid);
        f = fopen(comm_path, "r");
        if (!f)
            continue;
        if (fgets(comm, sizeof(comm), f)) {
            comm[strcspn(comm, "\r\n")] = '\0';
            if (strcmp(comm, name) == 0)
                kill(pid, SIGKILL);
        }
        fclose(f);
    }
    closedir(dir);
}

static void start_debug_services_native(void)
{
    int start_ok = 0;

    if (!g_ssh_enabled) {
        log_line("ssh disabled");
        return;
    }

    prepare_auth_files();
    kill_by_name("dropbear");
    unlink(g_paths.dropbear_log);
    if (access(g_paths.dropbear_src, R_OK) == 0 &&
        prepare_dropbear_binary() == 0 &&
        generate_host_key() == 0 &&
        start_dropbear() == 0)
        start_ok = 1;
    if (start_ok && g_dropbear_pid > 0 && verify_dropbear_ready() == 0) {
        const char *ip = wifi_ip_string();
        if (ip)
            log_line("ssh ready: ssh root@%s -p 2222", ip);
        else
            log_line("ssh ready on port 2222");
    } else {
        stop_debug_services();
        log_line("dropbear failed to start");
    }
}

static void apply_ssh_state(void)
{
    stop_debug_services();
    if (g_ssh_enabled) {
        write_ssh_state("loading");
        start_debug_services_native();
        write_ssh_state(g_dropbear_pid > 0 ? "enabled" : "failed");
    } else {
        write_ssh_state("disabled");
        log_line("ssh disabled");
    }
}

static int spawn_child_logged(char *const argv[])
{
    pid_t pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0) {
        setsid();
        execv(argv[0], argv);
        _exit(127);
    }
    return pid;
}

static int run_launcher_once(char *request, size_t request_len)
{
    char *argv[] = { g_paths.launcher_bin, NULL };
    int status = 0;

    unlink(g_paths.launch_file);
    setenv("GEMINI_SSH_ENABLED", g_ssh_enabled ? "1" : "0", 1);
    g_launcher_pid = spawn_child_logged(argv);
    if (g_launcher_pid < 0)
        return -1;

    // watch /tmp for launch file creation/modification
    int inofd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    int wd = -1;
    if (inofd >= 0)
        wd = inotify_add_watch(inofd, "/tmp", IN_CREATE | IN_MODIFY | IN_MOVED_TO);

    for (;;) {
        pid_t rc = waitpid(g_launcher_pid, &status, WNOHANG);

        if (rc == g_launcher_pid)
            break;
        if (rc < 0) {
            status = 1 << 8;
            break;
        }

        if (request && request[0] == '\0' && read_launch_file(request, request_len)) {
            if (strcmp(request, "control:ssh:enable") == 0) {
                unlink(g_paths.launch_file);
                if (!g_ssh_enabled) {
                    g_ssh_enabled = 1;
                    log_line("launcher requested ssh enable");
                    apply_ssh_state();
                } else {
                    write_ssh_state("enabled");
                }
                request[0] = '\0';
            }
        }

        // block until inotify event or timeout (for waitpid recheck)
        if (inofd >= 0) {
            struct pollfd pfd = { .fd = inofd, .events = POLLIN };
            poll(&pfd, 1, 100);
            // drain inotify events
            if (pfd.revents & POLLIN) {
                char evbuf[256];
                while (read(inofd, evbuf, sizeof(evbuf)) > 0)
                    ;
            }
        } else {
            usleep(50000);
        }
    }

    if (wd >= 0)
        inotify_rm_watch(inofd, wd);
    if (inofd >= 0)
        close(inofd);

    g_launcher_pid = -1;

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return 128 + WTERMSIG(status);
    return -1;
}

static int build_exec_argv(const gem_app_t *app, char *argv[], size_t argv_len)
{
    size_t i;

    if (!app || argv_len < 2)
        return -1;

    argv[0] = (char *)app->exec_path;
    for (i = 0; i < (size_t)app->argc && i + 2 < argv_len; i++)
        argv[i + 1] = (char *)app->args[i];
    argv[i + 1] = NULL;
    return 0;
}

static int run_app(const gem_app_t *app)
{
    char log_path[MAX_PATH_LEN];
    char *argv[GEM_APP_MAX_ARGS + 2];
    int fd;
    int status = 0;
    pid_t pid;

    if (!app)
        return -1;
    if (build_exec_argv(app, argv, sizeof(argv) / sizeof(argv[0])) != 0)
        return -1;

    if (build_path(log_path, sizeof(log_path), g_paths.log_dir, app->id) != 0)
        return -1;
    strncat(log_path, ".txt", sizeof(log_path) - strlen(log_path) - 1);
    pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0) {
        fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            close(fd);
        }
        fprintf(stdout, "=== %s started at %ld ===\n", app->id, (long)time(NULL));
        if (app->requires_tty && !isatty(STDIN_FILENO) && !isatty(STDOUT_FILENO)) {
            fprintf(stdout, "%s requires a terminal session.\n", app->title);
            _exit(0);
        }
        if (chdir(app->cwd) != 0)
            fprintf(stdout, "warning: chdir failed for %s: %s\n", app->cwd, strerror(errno));
        setsid();
        execv(app->exec_path, argv);
        fprintf(stdout, "exec failed for %s: %s\n", app->exec_path, strerror(errno));
        _exit(127);
    }

    g_app_pid = pid;
    if (waitpid(pid, &status, 0) < 0)
        status = 1 << 8;
    g_app_pid = -1;

    fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        int rc = WIFEXITED(status) ? WEXITSTATUS(status) :
                 (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1);
        dprintf(fd, "\n=== %s exited with code %d ===\n", app->id, rc);
        close(fd);
    }

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return 128 + WTERMSIG(status);
    return -1;
}

static bool read_launch_file(char *request, size_t request_len)
{
    FILE *f = fopen(g_paths.launch_file, "r");
    if (!f)
        return false;
    if (!fgets(request, (int)request_len, f)) {
        fclose(f);
        return false;
    }
    fclose(f);
    request[strcspn(request, "\r\n")] = '\0';
    return request[0] != '\0';
}

static void stop_debug_services(void)
{
    kill_process_group(g_dropbear_pid, SIGTERM);
    if (g_dropbear_pid > 0)
        waitpid(g_dropbear_pid, NULL, WNOHANG);
    g_dropbear_pid = -1;
}

static void cleanup(void)
{
    kill_process_group(g_launcher_pid, SIGTERM);
    kill_process_group(g_app_pid, SIGTERM);
    stop_debug_services();
    resume_stock_launcher();
    write_heartbeat("done");
}

int main(int argc, char **argv)
{
    char request[MAX_PATH_LEN];
    int fail_count = 0;

    if (find_usb_root_from_argv(argc, argv, g_paths.usb_root, sizeof(g_paths.usb_root)) != 0) {
        fprintf(stderr, "geminiorchestrator: missing --usb\n");
        return 1;
    }

    resolve_paths();
    if (init_logging() != 0) {
        fprintf(stderr, "geminiorchestrator: logging setup failed\n");
        return 1;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGHUP, signal_handler);

    export_runtime_env();
    write_heartbeat("started");
    write_ssh_state("disabled");
    log_line("orchestrator start");
    log_line("usb root: %s", g_paths.usb_root);
    log_line("ssh default: disabled");

    chmod_usb_payloads();
    freeze_stock_launcher();

    // load the current app catalog from the packaged index when available
    if (refresh_app_catalog(&g_catalog) == 0) {
        log_line("app catalog: %d apps", g_catalog.count);
    }

    apply_ssh_state();

    while (!g_stop_requested) {
        int rc;
        request[0] = '\0';
        rc = run_launcher_once(request, sizeof(request));
        if (g_stop_requested)
            break;

        if (request[0] == '\0' && read_launch_file(request, sizeof(request)))
            unlink(g_paths.launch_file);

        if (strncmp(request, "launch:", 7) == 0) {
            const char *app_id = request + 7;
            refresh_app_catalog(&g_catalog);
            const gem_app_t *app = gem_apps_find_by_id(&g_catalog, app_id);
            int app_rc;

            if (!app) {
                log_line("launch request not found: %s", app_id);
                continue;
            }

            log_line("launching app: %s", app->id);
            app_rc = run_app(app);
            log_line("app finished: %s (exit=%d)", app->id, app_rc);
            freeze_stock_launcher();
            fail_count = 0;
            continue;
        }

        if (request[0] != '\0') {
            log_line("unknown launcher request: %s", request);
            continue;
        }

        if (rc != 0) {
            fail_count++;
            log_line("launcher failed (%d/5), exit=%d", fail_count, rc);
            if (fail_count >= 5)
                break;
            sleep(1);
        } else {
            log_line("launcher exited cleanly");
            break;
        }
    }

    cleanup();
    return 0;
}
