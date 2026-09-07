// GhosttyVt+Swift.swift — RAII wrappers over the libghostty-vt C API (vendor/ghostty-vt; pinned commit in COMMIT).
// Raw C calls are confined to this file plus KeyEncoder / MouseEncoder / SelectionController / FrameBuilder
// (docs/design.md → Spike checklist). Handles are deliberately *not* Sendable: TerminalSession (M1.3)
// serialises every access with a lock, and the C objects are not thread-safe.
import GhosttyVt

/// A libghostty-vt call returned something other than `GHOSTTY_SUCCESS`.
public struct GhosttyError: Error, Equatable, Sendable {
    public let result: GhosttyResult
    public let operation: String
}

@inline(__always)
func ghosttyCheck(_ result: GhosttyResult, _ operation: String) throws {
    guard result == GHOSTTY_SUCCESS else { throw GhosttyError(result: result, operation: operation) }
}

/// Owns a `GhosttyTerminal` (full headless terminal: parser, screens, scrollback).
public final class GhosttyTerminalHandle {
    package let raw: GhosttyTerminal

    public init(cols: UInt16, rows: UInt16) throws {
        var terminal: GhosttyTerminal?
        try ghosttyCheck(ghostty_terminal_new(nil, &terminal, cols, rows), "ghostty_terminal_new")
        guard let terminal else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_terminal_new") }
        raw = terminal
    }

    deinit { ghostty_terminal_free(raw) }

    /// Feed raw pty bytes to the VT parser.
    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        ghostty_terminal_vt_write(raw, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    public func write(_ text: String) {
        var copy = text
        copy.withUTF8 { write(UnsafeRawBufferPointer($0)) }
    }

    public func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32 = 0, cellHeightPx: UInt32 = 0) throws {
        try ghosttyCheck(ghostty_terminal_resize(raw, cols, rows, cellWidthPx, cellHeightPx), "ghostty_terminal_resize")
    }

    /// The active screen rendered through libghostty's formatter (plain text by default).
    public func formatted(_ format: GhosttyFormatterFormat = GHOSTTY_FORMATTER_FORMAT_PLAIN, trim: Bool = true) throws -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = format
        options.trim = trim

        var formatter: GhosttyFormatter?
        try ghosttyCheck(ghostty_formatter_terminal_new(nil, &formatter, raw, options), "ghostty_formatter_terminal_new")
        guard let formatter else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_formatter_terminal_new") }
        defer { ghostty_formatter_free(formatter) }

        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        try ghosttyCheck(ghostty_formatter_format_alloc(formatter, nil, &buffer, &length), "ghostty_formatter_format_alloc")
        guard let buffer else { return "" }
        defer { ghostty_free(nil, buffer, length) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }
}

/// Owns a `GhosttyRenderState` (incremental dirty-row view of a terminal; used by FrameBuilder in M1.5).
public final class GhosttyRenderStateHandle {
    package let raw: GhosttyRenderState

    public init() throws {
        var state: GhosttyRenderState?
        try ghosttyCheck(ghostty_render_state_new(nil, &state), "ghostty_render_state_new")
        guard let state else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_render_state_new") }
        raw = state
    }

    deinit { ghostty_render_state_free(raw) }
}

/// Owns a `GhosttyKeyEncoder` (keyboard events → bytes; wired up in M1.7).
public final class GhosttyKeyEncoderHandle {
    package let raw: GhosttyKeyEncoder

    public init() throws {
        var encoder: GhosttyKeyEncoder?
        try ghosttyCheck(ghostty_key_encoder_new(nil, &encoder), "ghostty_key_encoder_new")
        guard let encoder else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_key_encoder_new") }
        raw = encoder
    }

    deinit { ghostty_key_encoder_free(raw) }
}

/// Owns a `GhosttyMouseEncoder` (mouse events → bytes; wired up in M1.8).
public final class GhosttyMouseEncoderHandle {
    package let raw: GhosttyMouseEncoder

    public init() throws {
        var encoder: GhosttyMouseEncoder?
        try ghosttyCheck(ghostty_mouse_encoder_new(nil, &encoder), "ghostty_mouse_encoder_new")
        guard let encoder else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_mouse_encoder_new") }
        raw = encoder
    }

    deinit { ghostty_mouse_encoder_free(raw) }
}

/// Compile-time facts about the vendored library (`ghostty_build_info`, `ghostty_type_json`).
public enum GhosttyVtInfo {
    /// e.g. "1.3.2-dev+82232ec".
    public static var versionString: String { string(GHOSTTY_BUILD_INFO_VERSION_STRING) }
    public static var simd: Bool { bool(GHOSTTY_BUILD_INFO_SIMD) }
    public static var kittyGraphics: Bool { bool(GHOSTTY_BUILD_INFO_KITTY_GRAPHICS) }
    public static var tmuxControlMode: Bool { bool(GHOSTTY_BUILD_INFO_TMUX_CONTROL_MODE) }

    public static var optimizeName: String {
        var mode = GHOSTTY_OPTIMIZE_DEBUG
        _ = ghostty_build_info(GHOSTTY_BUILD_INFO_OPTIMIZE, &mode)
        switch mode {
        case GHOSTTY_OPTIMIZE_DEBUG: return "Debug"
        case GHOSTTY_OPTIMIZE_RELEASE_SAFE: return "ReleaseSafe"
        case GHOSTTY_OPTIMIZE_RELEASE_SMALL: return "ReleaseSmall"
        case GHOSTTY_OPTIMIZE_RELEASE_FAST: return "ReleaseFast"
        default: return "unknown(\(mode.rawValue))"
        }
    }

    /// The ABI manifest (struct layouts, enum values, offsets) as a JSON document.
    /// Snapshotted in `vendor/ghostty-vt/abi-types.json`; diffed on every upgrade.
    public static var abiManifestJSON: String { String(cString: ghostty_type_json()) }

    private static func bool(_ key: GhosttyBuildInfo) -> Bool {
        var value = false
        _ = ghostty_build_info(key, &value)
        return value
    }

    private static func string(_ key: GhosttyBuildInfo) -> String {
        var value = GhosttyString()
        _ = ghostty_build_info(key, &value)
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
    }
}
