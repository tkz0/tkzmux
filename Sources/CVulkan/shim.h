// The Vulkan headers plus what Swift cannot import from them (WOR-313 S1).
//
// Object-like macros with a plain value (`VK_WHOLE_SIZE`, `VK_QUEUE_FAMILY_FOREIGN_EXT`, the
// extension-name strings) import as they are. Function-like macros, and the version constants
// built from them, do not; they are the static inlines below. `VK_NULL_HANDLE` imports as
// unavailable: every handle is an optional pointer in Swift, so `nil` replaces it.
//
// Only API that the oldest supported headers have (noble's 1.3.275) may be named here.
#pragma once

#include <stdint.h>
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
