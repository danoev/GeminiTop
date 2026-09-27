#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
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
#define BUILD_VERSION "w176-stage4b-proofd-v1"

static volatile sig_atomic_t stop_requested;

static void request_stop(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static int valid_sha256(const char *value)
{
    size_t index;

    if (strlen(value) != 64U) {
        return 0;
    }
    for (index = 0U; index < 64U; ++index) {
        const char character = value[index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) {
            return 0;
        }
    }
    return 1;
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
                          const char *binary_sha256)
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
                      "schema=1\n"
                      "process=geminitop-proofd\n"
                      "version=%s\n"
                      "pid=%ld\n"
                      "started=1\n"
                      "state=%s\n"
                      "heartbeat_sequence=%lu\n"
                      "binary_sha256=%s\n",
                      BUILD_VERSION, (long)getpid(), state, sequence,
                      binary_sha256);
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

    if (argc != 2 || !valid_sha256(argv[1])) {
        return 2;
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
        if (publish_status("running", sequence, argv[1]) != 0) {
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
    return publish_status("stopped", sequence, argv[1]) == 0 ? 0 : 6;
}
