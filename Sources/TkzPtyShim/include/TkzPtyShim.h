// TkzPtyShim — the only C code that runs in the forked child (no Swift runtime after fork()).
// Real implementation lands in M1.2 (TKZ-8): openpty → fork → setsid/TIOCSCTTY/dup2 → execve,
// exec failure reported over a FD_CLOEXEC pipe. See docs/design.md → Terminal engine → Pty.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Shim ABI version. Bumped when the spawn contract changes.
int32_t tkz_pty_shim_version(void);

#ifdef __cplusplus
}
#endif
