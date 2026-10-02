// GhosttyVtSmokeTests — the Linux artifact bundle links into a test binary and works (Linux only;
// on the Mac, TkzTerminalCoreTests exercise the xcframework through the real wrappers).
//
// The same create/write/format round trip as `tkzmux --vt-smoke`, against the C API directly:
// TkzTerminalCore's `GhosttyTerminalHandle` is not in the Linux graph until WOR-305.

import GhosttyVt
import Testing

@Suite struct GhosttyVtSmokeTests {
    @Test func writesAndFormatsHello() throws {
        var terminal: GhosttyTerminal?
        #expect(ghostty_terminal_new(nil, &terminal, 80, 24) == GHOSTTY_SUCCESS)
        let raw = try #require(terminal)
        defer { ghostty_terminal_free(raw) }

        let input: [UInt8] = Array("hello".utf8)
        input.withUnsafeBufferPointer { ghostty_terminal_vt_write(raw, $0.baseAddress, $0.count) }

        // Sized-struct ABI: C `sizeof` is Swift's `stride`.
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.stride
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = true

        var formatter: GhosttyFormatter?
        #expect(ghostty_formatter_terminal_new(nil, &formatter, raw, options) == GHOSTTY_SUCCESS)
        let rawFormatter = try #require(formatter)
        defer { ghostty_formatter_free(rawFormatter) }

        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        #expect(ghostty_formatter_format_alloc(rawFormatter, nil, &buffer, &length) == GHOSTTY_SUCCESS)
        let bytes = try #require(buffer)
        defer { ghostty_free(nil, bytes, length) }
        #expect(String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self) == "hello")
    }
}
