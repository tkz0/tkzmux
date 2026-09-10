// SemanticVersionTests — the ordering behind the sidebar's update card (TKZ-50).
//
// The interesting rows are the ones `scripts/make-app.sh` can produce (`1.2.3-dev.4+abc1234`)
// against the tags GitHub reports (`v1.2.3`): a dev build must sort *below* the tag it was built
// from and *above* the previous one, and build metadata must never affect the answer.

import Testing

@testable import TkzCore

@Suite struct SemanticVersionTests {

    static let ordered: [String] = [
        "0.7.0",
        "0.7.1-dev.3+abc1234",
        "0.7.1-rc1",
        "0.7.1",
        "0.7.9",
        "0.10.0",
        "1.0.0-alpha",
        "1.0.0-alpha.1",
        "1.0.0-alpha.beta",
        "1.0.0-beta",
        "1.0.0-beta.2",
        "1.0.0-beta.11",
        "1.0.0-rc.1",
        "1.0.0",
        "1.0.1-dev.0+deadbee.dirty",
        "1.0.1",
        "2.0.0",
    ]

    @Test("Every adjacent pair in the table is strictly ascending")
    func tableIsAscending() throws {
        let parsed = try Self.ordered.map { try #require(SemanticVersion($0), "\($0) should parse") }
        for (lower, higher) in zip(parsed, parsed.dropFirst()) {
            #expect(lower < higher, "\(lower) should be below \(higher)")
            #expect(!(higher < lower))
            #expect(lower != higher)
        }
    }

    @Test("Parsing tolerates a tag's `v`, a missing minor/patch, and drops build metadata")
    func parsing() throws {
        #expect(SemanticVersion("v0.8.0") == SemanticVersion(major: 0, minor: 8, patch: 0))
        #expect(SemanticVersion("V0.8.0") == SemanticVersion(major: 0, minor: 8, patch: 0))
        #expect(SemanticVersion(" 1.2 \n") == SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(SemanticVersion("3") == SemanticVersion(major: 3, minor: 0, patch: 0))
        let dev = try #require(SemanticVersion("1.2.3-dev.4+abc1234.dirty"))
        #expect(dev.prerelease == ["dev", "4"])
        #expect(dev.description == "1.2.3-dev.4")
        // Build metadata is ignored: the two compare equal.
        #expect(SemanticVersion("1.2.3+aaa") == SemanticVersion("1.2.3+bbb"))
        #expect(SemanticVersion("0.0.0-dev")?.isPrerelease == true)
        #expect(SemanticVersion("1.0.0")?.isPrerelease == false)
    }

    @Test("Garbage is nil, never a plausible version")
    func garbage() {
        for text in ["", "latest", "v", "1.2.3.4", "1..2", "1.x.3", "1.2.3-", "1.2.3-rc 1", "-1.2.3"] {
            #expect(SemanticVersion(text) == nil, "\(text) should not parse")
        }
    }

    @Test("AppVersion.isNewer is the update check's one question")
    func isNewer() {
        #expect(AppVersion.isNewer("v0.8.0", than: "0.7.0"))
        #expect(AppVersion.isNewer("0.8.0", than: "0.8.0-dev.4+abc1234"))
        #expect(!AppVersion.isNewer("v0.7.0", than: "0.7.0"))
        #expect(!AppVersion.isNewer("v0.6.9", than: "0.7.0"))
        // A `-dev.N` build is a prerelease of the tag it was built from (docs/release.md §2), so
        // the tag *is* newer by semver. Harmless: dev builds never check (`AppVersion.isRelease`).
        #expect(AppVersion.isNewer("v0.7.0", than: "0.7.0-dev.4+abc1234"))
        #expect(!AppVersion.isNewer("v0.6.9", than: "0.7.0-dev.4+abc1234"))
        // Unreadable input on either side fails closed.
        #expect(!AppVersion.isNewer("latest", than: "0.7.0"))
        #expect(!AppVersion.isNewer("v9.9.9", than: ""))
        let running = AppVersion(marketingVersion: "0.7.0", build: "300", ghosttyCommit: "x")
        #expect(running.isOlder(than: "v0.7.1"))
        #expect(!running.isOlder(than: "v0.7.0"))
    }
}
