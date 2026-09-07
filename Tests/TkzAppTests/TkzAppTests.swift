import Testing
@testable import TkzApp

@Test @MainActor func appDelegateInstantiates() {
    let delegate = AppDelegate()
    #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
}
