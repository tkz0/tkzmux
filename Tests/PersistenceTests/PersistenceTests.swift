import Testing
@testable import Persistence

@Test func moduleLoads() {
    #expect(PersistenceModule.name == "Persistence")
}
