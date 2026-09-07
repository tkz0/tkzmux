import Testing
@testable import GitStatus

@Test func moduleLoads() {
    #expect(GitStatusModule.name == "GitStatus")
}
