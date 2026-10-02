// The Darwin facade is an alias, not a wrapper: `TkzLogger` *is* `os.Logger`, so the Mac's
// redaction and deferred formatting cannot have changed (WOR-304 S1). This file imports only
// TkzPlatform, so it also proves the `os` re-export reaches callers: `OSSignpostID` and the
// `privacy:` interpolation below would not compile without it.

#if canImport(Darwin)
import Testing
import TkzPlatform

@Suite struct LoggingFacadeTests {
    @Test func theFacadeAliasesTheOSTypes() {
        #expect(ObjectIdentifier(TkzLogger.self) == ObjectIdentifier(os.Logger.self))
        #expect(ObjectIdentifier(TkzSignposter.self) == ObjectIdentifier(OSSignposter.self))
    }

    /// The call shapes the app uses: a literal with `privacy:` fields, and a signpost interval.
    @Test func callSitesKeepTheirOSLogMessageShape() {
        let logger = TkzLogger(subsystem: "se.tkz.tkzmux", category: "tests")
        let count = 3
        logger.debug("facade test \(count, privacy: .public) \("secret")")

        let signposter = TkzSignposter(subsystem: "se.tkz.tkzmux", category: "tests")
        let id: OSSignpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("facade", id: id)
        signposter.endInterval("facade", interval)
    }
}
#endif
