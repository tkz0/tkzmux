import Testing
@testable import TkzTerminalCore

@Test func moduleLoads() {
    #expect(TkzTerminalCoreModule.name == "TkzTerminalCore")
}

@Test func ptyShimLinks() {
    #expect(TkzTerminalCoreModule.ptyShimVersion == 2)
}
