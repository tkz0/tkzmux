// The Vulkan headers plus what Swift cannot import from them (WOR-313 S1), and the dma-buf
// sync_file ioctls (S5a).
//
// Object-like macros with a plain value (`VK_WHOLE_SIZE`, `VK_QUEUE_FAMILY_FOREIGN_EXT`, the
// extension-name strings) import as they are. Function-like macros, and the version constants
// built from them, do not; they are the static inlines below. `VK_NULL_HANDLE` imports as
// unavailable: every handle is an optional pointer in Swift, so `nil` replaces it.
//
// Only API that the oldest supported headers have (noble's 1.3.275) may be named here; the
// dma-buf ioctls need the kernel headers of Linux 6.0 or later (noble has 6.8).
#pragma once

#include <errno.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <linux/dma-buf.h>
#include <vulkan/vulkan.h>

/// `VK_MAKE_API_VERSION(variant, major, minor, patch)`.
static inline uint32_t tkz_vk_make_api_version(uint32_t variant, uint32_t major, uint32_t minor, uint32_t patch) {
    return VK_MAKE_API_VERSION(variant, major, minor, patch);
}

/// `VK_API_VERSION_VARIANT`, `_MAJOR`, `_MINOR` and `_PATCH` of a packed version.
static inline uint32_t tkz_vk_api_version_variant(uint32_t version) { return VK_API_VERSION_VARIANT(version); }
static inline uint32_t tkz_vk_api_version_major(uint32_t version) { return VK_API_VERSION_MAJOR(version); }
static inline uint32_t tkz_vk_api_version_minor(uint32_t version) { return VK_API_VERSION_MINOR(version); }
static inline uint32_t tkz_vk_api_version_patch(uint32_t version) { return VK_API_VERSION_PATCH(version); }

/// `VK_API_VERSION_1_3`, the version tkzmux requires and asks the instance for.
static inline uint32_t tkz_vk_api_version_1_3(void) { return VK_API_VERSION_1_3; }

/// `VK_HEADER_VERSION_COMPLETE`, the headers this module was compiled against.
static inline uint32_t tkz_vk_header_version_complete(void) { return VK_HEADER_VERSION_COMPLETE; }

// MARK: - dma-buf sync_file (WOR-313 S5a)
//
// A dma-buf carries implicit fences; these two ioctls move a sync_file (an explicit fence) in and
// out of them. The request numbers are `_IOW`/`_IOWR` macros, so the calls live here. They are the
// only wrappers: WOR-314 calls these, never the ioctls themselves. EINTR and EAGAIN are retried.

/// `DMA_BUF_SYNC_READ` and `DMA_BUF_SYNC_WRITE`, the access the flags below describe.
static inline uint32_t tkz_dma_buf_sync_read(void) { return DMA_BUF_SYNC_READ; }
static inline uint32_t tkz_dma_buf_sync_write(void) { return DMA_BUF_SYNC_WRITE; }

/// `DMA_BUF_IOCTL_IMPORT_SYNC_FILE`: adds the fence in `sync_file` to `dmabuf`'s implicit fences,
/// as a write fence with `DMA_BUF_SYNC_WRITE` (every later reader and writer waits for it) or a
/// read fence with `DMA_BUF_SYNC_READ` (later writers wait). The caller keeps `sync_file`.
/// Returns 0, or -errno (-ENOTTY on a kernel without the ioctl).
static inline int tkz_dma_buf_import_sync_file(int dmabuf, int sync_file, uint32_t flags) {
    struct dma_buf_import_sync_file args = { .flags = flags, .fd = sync_file };
    while (ioctl(dmabuf, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &args) != 0) {
        if (errno != EINTR && errno != EAGAIN) return -errno;
    }
    return 0;
}

/// `DMA_BUF_IOCTL_EXPORT_SYNC_FILE`: a sync_file of the fences an access of kind `flags` must wait
/// for (`DMA_BUF_SYNC_WRITE`: every reader and writer; `DMA_BUF_SYNC_READ`: writers only), stored
/// in `*sync_file`, which the caller then owns. Returns 0, or -errno.
static inline int tkz_dma_buf_export_sync_file(int dmabuf, uint32_t flags, int *sync_file) {
    struct dma_buf_export_sync_file args = { .flags = flags, .fd = -1 };
    while (ioctl(dmabuf, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &args) != 0) {
        if (errno != EINTR && errno != EAGAIN) return -errno;
    }
    *sync_file = args.fd;
    return 0;
}
