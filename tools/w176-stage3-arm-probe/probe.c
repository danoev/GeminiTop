#include <stddef.h>
#include <unistd.h>

int main(void)
{
    static const char result[] =
        "schema=1\n"
        "probe=w176-arm-loadability\n"
        "started=1\n"
        "result=PASS\n";
    const size_t length = sizeof(result) - 1U;
    const ssize_t written = write(STDOUT_FILENO, result, length);

    return written == (ssize_t)length ? 0 : 1;
}
