// UnavailableCommands — the Linux stand-ins for the subcommands that draw through Metal (WOR-311 S7).
//
// `render` and `bench-frame` need a GPU renderer (Vulkan, WOR-313); `atlas` needs the FreeType
// glyph source wired to TkzPNG (WOR-312, whose `AtlasDumper` already produces the pages). Until
// then each exits 1 with a pointer, before parsing anything, so a script cannot mistake a missing
// renderer for a bad argument. RenderCommands.swift and FrameBenchCommand.swift are the macOS
// implementations of the same entry points.

#if !canImport(Metal)
enum RenderCommands {
    static func runRender(_ argv: [String]) throws { unavailableOnLinux("render") }
    static func runAtlas(_ argv: [String]) throws { unavailableOnLinux("atlas") }
}

enum FrameBenchCommand {
    static func run(_ argv: [String]) throws { unavailableOnLinux("bench-frame") }
}

private func unavailableOnLinux(_ command: String) -> Never {
    fail("tkzmux-vtdump \(command): not yet available on Linux (see WOR-312/WOR-313)", code: 1)
}
#endif
