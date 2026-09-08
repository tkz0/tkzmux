// AppVersionTests — M6.1 / TKZ-37 acceptance.
//
// Two halves: the pure `git describe` → marketing-version derivation, and the Info.plist reading,
// exercised through `init(infoDictionary:)` so nothing here depends on a real bundle.
//
// The derivation table below is the **shared contract with `version_from_describe` in
// `scripts/make-app.sh`** — the script is what actually stamps `CFBundleShortVersionString`, and
// these cases are copied from its documented rule table. Change one side, change both.

import Foundation
import Testing

@testable import TkzCore

@Suite struct AppVersionTests {

    // MARK: - Derivation from `git describe`

    /// The rule table from `scripts/make-app.sh`, verbatim.
    /// `<sha>` in the script's table is `git rev-parse --short HEAD`, passed in as `headSHA`.
    static let derivationTable: [(describe: String, expected: String)] = [
        ("v1.2.3", "1.2.3"),
        ("v1.2.3-dirty", "1.2.3-dev.0+72e78a1.dirty"),
        ("v1.2.3-4-gabc1234", "1.2.3-dev.4+abc1234"),
        ("v1.2.3-4-gabc1234-dirty", "1.2.3-dev.4+abc1234.dirty"),
        ("v1.0.0-rc1-2-gdeadbee", "1.0.0-rc1-dev.2+deadbee"),
        ("v1.0.0-rc1-2-gdeadbee-dirty", "1.0.0-rc1-dev.2+deadbee.dirty"),
    ]

    @Test("The whole `git describe` rule table matches scripts/make-app.sh")
    func derivationTable() {
        for (describe, expected) in Self.derivationTable {
            let actual = AppVersion.marketingVersion(fromGitDescribe: describe, headSHA: "72e78a1")
            #expect(actual == expected, "\(describe) → \(actual), expected \(expected)")
        }
    }

    @Test("An exact, clean tag loses its `v` and nothing else")
    func exactTag() {
        #expect(AppVersion.marketingVersion(fromGitDescribe: "v1.2.3") == "1.2.3")
        #expect(AppVersion.marketingVersion(fromGitDescribe: "v0.1.0") == "0.1.0")
        // A prerelease tag survives intact — its dashes are part of the tag, not a describe suffix.
        #expect(AppVersion.marketingVersion(fromGitDescribe: "v1.0.0-rc1") == "1.0.0-rc1")
        // Already `v`-less: nothing to strip.
        #expect(AppVersion.marketingVersion(fromGitDescribe: "1.2.3") == "1.2.3")
        #expect(AppVersion.isReleaseVersion("1.2.3"))
        #expect(AppVersion.isReleaseVersion("1.0.0-rc1"))
    }

    @Test("Commits since the tag become a `-dev.<N>+<sha>` prerelease")
    func afterTheTag() {
        let version = AppVersion.marketingVersion(fromGitDescribe: "v1.2.3-4-gabc1234")
        #expect(version == "1.2.3-dev.4+abc1234")
        #expect(!AppVersion.isReleaseVersion(version))
    }

    @Test("A dirty tree on the exact tag borrows HEAD's sha and N=0")
    func dirtyOnTheTag() {
        // `git describe --dirty` reports no sha in this form, so the caller supplies HEAD's.
        #expect(AppVersion.marketingVersion(fromGitDescribe: "v1.2.3-dirty", headSHA: "72e78a1")
                == "1.2.3-dev.0+72e78a1.dirty")
        #expect(!AppVersion.isReleaseVersion("1.2.3-dev.0+72e78a1.dirty"))
    }

    @Test("No tag at all: dev plus HEAD's sha")
    func noTag() {
        // `git describe` exits non-zero with no matching tag, so its output is empty.
        #expect(AppVersion.marketingVersion(fromGitDescribe: "", headSHA: "72e78a1")
                == "0.0.0-dev+72e78a1")
        #expect(AppVersion.marketingVersion(fromGitDescribe: nil, headSHA: "72e78a1")
                == "0.0.0-dev+72e78a1")
        // Empty describe cannot report dirtiness; the caller asks git and passes it in.
        #expect(AppVersion.marketingVersion(fromGitDescribe: nil, headSHA: "72e78a1", isDirty: true)
                == "0.0.0-dev+72e78a1.dirty")
        // No sha either → no dangling `+`.
        #expect(AppVersion.marketingVersion(fromGitDescribe: nil) == "0.0.0-dev")
        #expect(AppVersion.marketingVersion(fromGitDescribe: "   \n ") == "0.0.0-dev")
        #expect(!AppVersion.isReleaseVersion("0.0.0-dev+72e78a1"))
    }

    @Test("`isDirty` is ignored when describe reported for itself")
    func describeIsTheAuthorityOnDirtiness() {
        #expect(AppVersion.marketingVersion(
            fromGitDescribe: "v1.2.3", headSHA: "72e78a1", isDirty: true) == "1.2.3")
    }

    @Test("A suffix that only looks like `-<N>-g<sha>` is left as part of the tag")
    func suffixIsNotOverEager() {
        // `gamma` is not hex, `x9` is not a number, and two components are too few.
        #expect(AppVersion.marketingVersion(fromGitDescribe: "v1.0.0-1-gamma") == "1.0.0-1-gamma")
        #expect(AppVersion.marketingVersion(fromGitDescribe: "v1.0.0-x9-gabc") == "1.0.0-x9-gabc")
        #expect(AppVersion.marketingVersion(fromGitDescribe: "v1.0.0-gabc1234") == "1.0.0-gabc1234")
        // Uppercase hex is not what git emits, and the shell regex is `[0-9a-f]`.
        #expect(AppVersion.marketingVersion(fromGitDescribe: "v1.0.0-2-gABC1234") == "1.0.0-2-gABC1234")
    }

    @Test("Git's trailing newline and stray whitespace are trimmed")
    func trimsWhitespace() {
        #expect(AppVersion.marketingVersion(fromGitDescribe: "v1.2.3\n") == "1.2.3")
        #expect(AppVersion.marketingVersion(fromGitDescribe: "  v1.2.3-4-gabc1234  ")
                == "1.2.3-dev.4+abc1234")
    }

    // MARK: - Release vs not

    @Test("Only the exact-clean-tag form counts as a release")
    func isRelease() {
        #expect(AppVersion.isReleaseVersion("1.2.3"))
        #expect(AppVersion.isReleaseVersion("10.0.0-beta.1"))
        #expect(!AppVersion.isReleaseVersion("1.2.3-dev.4+abc1234"))
        #expect(!AppVersion.isReleaseVersion("1.2.3-dev.0+abc1234.dirty"))
        #expect(!AppVersion.isReleaseVersion("0.0.0-dev"))
        #expect(!AppVersion.isReleaseVersion("0.0.0-dev+abc1234"))
        #expect(!AppVersion.isReleaseVersion(""))
    }

    @Test("Every non-release form the derivation can produce is reported as one")
    func derivedFormsAgreeWithIsRelease() {
        for (describe, expected) in Self.derivationTable {
            let isTag = describe == "v1.2.3" || describe == "v1.0.0-rc1"
            #expect(AppVersion.isReleaseVersion(expected) == isTag, "\(expected)")
        }
    }

    @Test("`isRelease` reads the instance's own marketing version")
    func isReleaseOnTheValue() {
        #expect(AppVersion(marketingVersion: "1.2.3", build: "9", ghosttyCommit: "x").isRelease)
        #expect(!AppVersion(marketingVersion: "1.2.3-dev.1+abc", build: "9", ghosttyCommit: "x")
            .isRelease)
    }

    // MARK: - Reading Info.plist

    /// A function, not a `static let`: `[String: Any]` is not `Sendable`, and strict concurrency
    /// rejects a non-Sendable static.
    static func stampedPlist() -> [String: Any] { [
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "287",
        "TkzGhosttyCommit": "82232ecde55405559dec29c5466cb9e39938cb41",
    ] }

    @Test("A stamped bundle yields all three fields")
    func readsStampedPlist() {
        let version = AppVersion(infoDictionary: Self.stampedPlist())
        #expect(version.marketingVersion == "1.2.3")
        #expect(version.build == "287")
        #expect(version.ghosttyCommit == "82232ecde55405559dec29c5466cb9e39938cb41")
        #expect(version.shortGhosttyCommit == "82232ecde554")
        #expect(version.isRelease)
    }

    @Test("No bundle at all — `swift run tkzmux` — falls back visibly")
    func noBundle() {
        for dictionary: [String: Any]? in [nil, [:]] {
            let version = AppVersion(infoDictionary: dictionary)
            #expect(version.marketingVersion == AppVersion.devMarketingVersion)
            #expect(version.build == AppVersion.unknownBuild)
            #expect(version.ghosttyCommit == AppVersion.unknownGhosttyCommit)
            #expect(version.shortGhosttyCommit == AppVersion.unknownGhosttyCommit)
            #expect(!version.isRelease)
        }
    }

    @Test("The committed placeholder plist has no ghostty key, and says so")
    func unstampedPlist() {
        // Resources/Info.plist as committed: placeholders, no TkzGhosttyCommit.
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
        ])
        #expect(version.marketingVersion == "0.1.0")
        #expect(version.build == "1")
        #expect(version.ghosttyCommit == AppVersion.unknownGhosttyCommit)
    }

    @Test("Empty, blank and non-string values fall back rather than surfacing")
    func rejectsJunkValues() {
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "",
            "CFBundleVersion": "  \n ",
            "TkzGhosttyCommit": 42,
        ])
        #expect(version.marketingVersion == AppVersion.devMarketingVersion)
        #expect(version.build == AppVersion.unknownBuild)
        #expect(version.ghosttyCommit == AppVersion.unknownGhosttyCommit)
    }

    @Test("Values are trimmed — a plist edited by a script can carry a newline")
    func trimsPlistValues() {
        let version = AppVersion(infoDictionary: ["CFBundleShortVersionString": " 1.2.3\n"])
        #expect(version.marketingVersion == "1.2.3")
    }

    // MARK: - The `--version` banner

    @Test("`description` is exactly what `tkzmux --version` prints")
    func banner() {
        let version = AppVersion(infoDictionary: Self.stampedPlist())
        #expect(version.description
                == "tkzmux 1.2.3 (287) libghostty-vt 82232ecde55405559dec29c5466cb9e39938cb41")
    }

    @Test("The banner is still well-formed with no bundle")
    func bannerWithoutBundle() {
        #expect(AppVersion(infoDictionary: nil).description
                == "tkzmux 0.0.0-dev (0) libghostty-vt unknown")
    }

    @Test("`current` reads the process's own bundle without crashing")
    func currentIsReadable() {
        // Under `swift test` there is a test-runner bundle, so the values are not asserted — only
        // that reading `Bundle.main` produces a complete, non-empty identity.
        let version = AppVersion.current
        #expect(!version.marketingVersion.isEmpty)
        #expect(!version.build.isEmpty)
        #expect(version.ghosttyCommit == AppVersion.unknownGhosttyCommit)
    }
}
