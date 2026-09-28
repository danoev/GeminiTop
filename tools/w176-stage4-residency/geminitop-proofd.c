#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#define STATUS_PATH "/tmp/geminitop-proofd.status"
#define TEMP_STATUS_PATH "/tmp/.geminitop-proofd.status.tmp"
#define BUILD_VERSION "w176-stage4b-proofd-v2"
#define SELF_STAT_PATH "/proc/self/stat"

static volatile sig_atomic_t stop_requested;

static int parse_unsigned(const char *begin, const char *end,
                          unsigned long *value)
{
    unsigned long result = 0UL;
    const char *cursor;

    if (begin == end) {
        return -1;
    }
    for (cursor = begin; cursor < end; ++cursor) {
        unsigned int digit;
        if (*cursor < '0' || *cursor > '9') {
            return -1;
        }
        digit = (unsigned int)(*cursor - '0');
        if (result > (ULONG_MAX - digit) / 10UL) {
            return -1;
        }
        result = result * 10UL + digit;
    }
    *value = result;
    return 0;
}

static int acquire_start_ticks(unsigned long *start_ticks)
{
    char data[1025];
    size_t used = 0U;
    int descriptor;
    ssize_t amount;
    const char *cursor;
    const char *end;
    const char *comm_close = NULL;
    unsigned long pid;
    unsigned int field;

    descriptor = open(SELF_STAT_PATH, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return -1;
    }
    while (used < sizeof(data) - 1U) {
        amount = read(descriptor, data + used, sizeof(data) - 1U - used);
        if (amount < 0 && errno == EINTR) {
            continue;
        }
        if (amount < 0) {
            (void)close(descriptor);
            return -1;
        }
        if (amount == 0) {
            break;
        }
        used += (size_t)amount;
    }
    if (used == sizeof(data) - 1U) {
        char extra;
        amount = read(descriptor, &extra, 1U);
        if (amount != 0) {
            (void)close(descriptor);
            return -1;
        }
    }
    if (close(descriptor) != 0 || used < 8U) {
        return -1;
    }
    data[used] = '\0';
    end = data + used;
    cursor = data;
    while (cursor < end && *cursor != ' ') {
        ++cursor;
    }
    if (cursor == end || parse_unsigned(data, cursor, &pid) != 0 ||
        pid != (unsigned long)getpid() || cursor + 2 >= end ||
        cursor[1] != '(') {
        return -1;
    }
    for (cursor += 2; cursor < end; ++cursor) {
        if (*cursor == ')') {
            comm_close = cursor;
        }
    }
    if (comm_close == NULL || comm_close + 3 >= end ||
        comm_close[1] != ' ' || comm_close[3] != ' ') {
        return -1;
    }
    cursor = comm_close + 2;
    for (field = 3U; field <= 22U; ++field) {
        const char *token_begin = cursor;
        while (cursor < end && *cursor != ' ' && *cursor != '\n') {
            ++cursor;
        }
        if (cursor == token_begin) {
            return -1;
        }
        if (field == 22U) {
            if (parse_unsigned(token_begin, cursor, start_ticks) != 0 ||
                *start_ticks == 0UL) {
                return -1;
            }
            return 0;
        }
        if (cursor == end || *cursor != ' ') {
            return -1;
        }
        ++cursor;
    }
    return -1;
}

static void request_stop(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static int write_all(int descriptor, const char *buffer, size_t length)
{
    size_t offset = 0U;

    while (offset < length) {
        const ssize_t result = write(descriptor, buffer + offset, length - offset);
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result <= 0) {
            return -1;
        }
        offset += (size_t)result;
    }
    return 0;
}

static int publish_status(const char *state, unsigned long sequence,
                          unsigned long start_ticks)
{
    char message[384];
    int descriptor;
    int length;

    descriptor = open(TEMP_STATUS_PATH,
                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                      0644);
    if (descriptor < 0) {
        return -1;
    }
    length = snprintf(message, sizeof(message),
                      "schema=2\n"
                      "process=geminitop-proofd\n"
                      "build=%s\n"
                      "pid=%ld\n"
                      "start_ticks=%lu\n"
                      "state=%s\n"
                      "sequence=%lu\n",
                      BUILD_VERSION, (long)getpid(), start_ticks, state,
                      sequence);
    if (length < 0 || (size_t)length >= sizeof(message) ||
        write_all(descriptor, message, (size_t)length) != 0 ||
        close(descriptor) != 0) {
        (void)close(descriptor);
        (void)unlink(TEMP_STATUS_PATH);
        return -1;
    }
    if (rename(TEMP_STATUS_PATH, STATUS_PATH) != 0) {
        (void)unlink(TEMP_STATUS_PATH);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    struct sigaction action;
    struct timespec delay;
    unsigned long sequence = 0UL;
    unsigned long start_ticks;

    if (argc != 1 || argv[0] == NULL) {
        return 2;
    }
    if (acquire_start_ticks(&start_ticks) != 0) {
        return 7;
    }
    memset(&action, 0, sizeof(action));
    action.sa_handler = request_stop;
    if (sigemptyset(&action.sa_mask) != 0 ||
        sigaction(SIGTERM, &action, NULL) != 0 ||
        sigaction(SIGINT, &action, NULL) != 0) {
        return 3;
    }
    delay.tv_sec = 2;
    delay.tv_nsec = 0;
    while (!stop_requested) {
        if (publish_status("running", sequence, start_ticks) != 0) {
            return 4;
        }
        ++sequence;
        while (!stop_requested && nanosleep(&delay, &delay) != 0) {
            if (errno != EINTR) {
                return 5;
            }
        }
        delay.tv_sec = 2;
        delay.tv_nsec = 0;
    }
    return publish_status("stopped", sequence, start_ticks) == 0 ? 0 : 6;
}
