#include "TkzPlatformShim.h"

#ifdef __linux__
#include <stddef.h>
#include <sys/syscall.h>
#include <unistd.h>

// Older kernel headers (before Linux 5.1/5.3) do not name these; the numbers are the same on
// every architecture that uses the unified syscall table, x86_64 and aarch64 included.
#ifndef SYS_pidfd_send_signal
#define SYS_pidfd_send_signal 424
#endif
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

int tkz_pidfd_open(pid_t pid, unsigned int flags) {
    return (int)syscall(SYS_pidfd_open, pid, flags);
}

int tkz_pidfd_send_signal(int pidfd, int sig, unsigned int flags) {
    return (int)syscall(SYS_pidfd_send_signal, pidfd, sig, NULL, flags);
}
#else
// Nothing on macOS: kqueue covers what the pidfd calls do on Linux. An empty translation unit
// keeps the target in both manifest branches.
typedef int tkz_platform_shim_empty_unit;
#endif
