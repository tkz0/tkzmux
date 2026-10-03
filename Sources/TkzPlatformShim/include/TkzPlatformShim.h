// TkzPlatformShim — the C half of TkzPlatform (WOR-304 S5): kernel calls Swift cannot make.
//
// Swift's Glibc module has no <sys/pidfd.h>, and the variadic `syscall()` cannot be called from
// Swift, so the pidfd system calls are wrapped here. They go through `syscall()` rather than the
// glibc wrappers, which need glibc 2.36, above the 2.35 floor. pidfds need Linux 5.3 or later; on
// an older kernel the calls fail with ENOSYS. accept4 (glibc 2.10) is here because the Glibc module
// hides it: glibc declares it only under _GNU_SOURCE (WOR-306 S1).
//
// It also wraps `mallinfo2()` for `HeapStats` (WOR-311 S7): <malloc.h> is not part of Swift's Glibc
// module.
//
// Dependency-free: libc only. Everything here is Linux-only, so on macOS this target is empty.
// WOR-320 adds `tkz_spawn_clean` here.
#pragma once

#ifdef __linux__
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// pidfd_open(2): a file descriptor that refers to process `pid` and becomes readable when the
/// process exits (zombie or reaped). Close-on-exec. Returns -1 and sets errno on failure; ESRCH
/// means there is no such process, which for a pid we spawned means it has already been reaped.
int tkz_pidfd_open(pid_t pid, unsigned int flags);

/// pidfd_send_signal(2) with no siginfo: sends `sig` to the process `pidfd` refers to, which
/// cannot be a recycled pid. Returns 0, or -1 and sets errno (ESRCH once the process has exited).
int tkz_pidfd_send_signal(int pidfd, int sig, unsigned int flags);

/// accept4(2) without the peer address: accepts a connection on `fd` with `flags`
/// (SOCK_NONBLOCK, SOCK_CLOEXEC) set atomically. Swift's Glibc module does not see accept4,
/// which glibc declares only under _GNU_SOURCE. Returns the new fd, or -1 and sets errno.
int tkz_accept4(int fd, int flags);

/// mallinfo2(3) `uordblks + hblkhd`: bytes in allocated chunks in every arena plus bytes in chunks
/// served by mmap. A byte count, not a block count; glibc keeps no count of live blocks. Always 0
/// on a C library without mallinfo2 (musl).
size_t tkz_heap_bytes_in_use(void);

#ifdef __cplusplus
}
#endif
#endif
