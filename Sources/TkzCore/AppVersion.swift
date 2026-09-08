// AppVersion.swift — the app's version identity (M6.1 / TKZ-37).
//
// One value type answers "which tkzmux is this, and which libghostty-vt is inside it" for every
// consumer: `tkzmux --version`, the About panel, and anything a bug report needs to quote.
//
// The numbers are **stamped into `Contents/Info.plist` by `scripts/make-app.sh`**, not compiled in,
// so a rebuild of the same sources at a different commit reports a different version without
// touching a Swift file. The committed `Resources/Info.plist` carries placeholders (0.1.0 / 1) and
// no ghostty key at all; the build script overwrites the copy inside the `.app` with:
//
//   CFBundleShortVersionString  marketing version, from `git describe --tags --match 'v*' --dirty`
//   CFBundleVersion             `git rev-list --count HEAD` — monotonic, what the App Store calls
//                               the build number
//   TkzGhosttyCommit            the 40-char commit in `vendor/ghostty-vt/COMMIT`
//
// `swift run tkzmux` has no bundle at all (`Bundle.main.infoDictionary` is nil or empty), so every
// field falls back to a *visibly* non-release form rather than lying with a plausible number.
//
// TkzCore is the headless half of the app (`SourceHygieneTests`): Foundation only, no AppKit. The
// reading is injectable — `init(infoDictionary:)` — so the tests never depend on the real bundle.

import Foundation

/// Which build of tkzmux this is, and which libghostty-vt is linked into it.
public struct AppVersion: Sendable, Equatable, CustomStringConvertible {

    // MARK: Fallbacks

    /// Marketing version reported when there is no bundle to read (`swift run tkzmux`) and the
    /// stem of the no-tag form. Deliberately not a plausible release number.
    public static let devMarketingVersion = "0.0.0-dev"
    /// Build number reported when `CFBundleVersion` is missing. Sorts below every real build.
    public static let unknownBuild = "0"
    /// Reported when `TkzGhosttyCommit` is missing — the un-stamped `Resources/Info.plist` has no
    /// such key, so this is what a `swift run` or a hand-assembled bundle shows.
    public static let unknownGhosttyCommit = "unknown"

    /// The product name in ``description``. Not read from the bundle: it must not change between
    /// `swift run` and the `.app`.
    public static let productName = "tkzmux"

    // MARK: Info.plist keys

    public static let marketingVersionKey = "CFBundleShortVersionString"
    public static let buildKey = "CFBundleVersion"
    /// tkzmux's own key — `scripts/make-app.sh` adds it; the committed plist does not have it.
    public static let ghosttyCommitKey = "TkzGhosttyCommit"

    // MARK: Fields

    /// `1.2.3` for a release, `1.2.3-dev.4+abc1234` for anything after the tag,
    /// `0.0.0-dev+<sha>` when there is no tag, ``devMarketingVersion`` when there is no bundle.
    public let marketingVersion: String
    /// `CFBundleVersion` — the commit count. A string, because that is what a plist holds and what
    /// AppKit's About panel wants.
    public let build: String
    /// The 40-char libghostty-vt commit, or ``unknownGhosttyCommit``.
    public let ghosttyCommit: String

    public init(marketingVersion: String, build: String, ghosttyCommit: String) {
        self.marketingVersion = marketingVersion
        self.build = build
        self.ghosttyCommit = ghosttyCommit
    }

    /// Reads the three keys out of an Info dictionary. A missing, empty or non-string value falls
    /// back rather than throwing: a version banner must never be the reason the app fails to start.
    public init(infoDictionary: [String: Any]?) {
        func string(_ key: String) -> String? {
            guard let value = infoDictionary?[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.init(
            marketingVersion: string(Self.marketingVersionKey) ?? Self.devMarketingVersion,
            build: string(Self.buildKey) ?? Self.unknownBuild,
            ghosttyCommit: string(Self.ghosttyCommitKey) ?? Self.unknownGhosttyCommit)
    }

    /// This process's identity. Reads `Bundle.main` once, lazily.
    public static let current = AppVersion(infoDictionary: Bundle.main.infoDictionary)

    // MARK: Derived

    /// The one-line banner: `tkzmux 1.2.3 (287) libghostty-vt 82232ecd…` (full 40-char commit —
    /// this is what a bug report quotes). `tkzmux --version` prints exactly this.
    public var description: String {
        "\(Self.productName) \(marketingVersion) (\(build)) libghostty-vt \(ghosttyCommit)"
    }

    /// The first 12 characters of ``ghosttyCommit`` — enough to identify it, short enough for a UI.
    public var shortGhosttyCommit: String {
        ghosttyCommit == Self.unknownGhosttyCommit ? ghosttyCommit : String(ghosttyCommit.prefix(12))
    }

    /// True when ``marketingVersion`` came from an exact, clean tag. See ``isReleaseVersion(_:)``.
    public var isRelease: Bool { Self.isReleaseVersion(marketingVersion) }

    // MARK: - Version derivation

    /// Turns `git describe --tags --match 'v*' --dirty` output into a marketing version.
    ///
    /// **This mirrors `version_from_describe` in `scripts/make-app.sh`, which is what actually
    /// stamps `CFBundleShortVersionString`.** The Swift copy exists so the rules are pinned by
    /// tests and so anything on this side (a release check, a distribution filename) derives the
    /// same string. The two must be changed together; `AppVersionTests` is the shared table.
    ///
    /// Parsed **right-to-left**, because a prerelease tag (`v1.0.0-rc1`) contains dashes of its
    /// own and splitting on the first `-` would mangle it:
    ///
    ///     git describe               marketing version
    ///     ------------------------   ---------------------------
    ///     (empty — no tag)           0.0.0-dev+<sha>
    ///     (empty, dirty tree)        0.0.0-dev+<sha>.dirty
    ///     v1.2.3                     1.2.3
    ///     v1.2.3-dirty               1.2.3-dev.0+<sha>.dirty
    ///     v1.2.3-4-gabc1234          1.2.3-dev.4+abc1234
    ///     v1.2.3-4-gabc1234-dirty    1.2.3-dev.4+abc1234.dirty
    ///     v1.0.0-rc1-2-gdeadbee      1.0.0-rc1-dev.2+deadbee
    ///
    /// In words: strip a trailing `-dirty`; strip a trailing `-<N>-g<hex>` for the commit distance
    /// N and the abbreviated sha; strip the leading `v` from what is left. A **clean exact tag is
    /// released verbatim**; everything else becomes `<tag>-dev.<N>+<sha>[.dirty]`, where a dirty
    /// exact tag uses N=0 and `HEAD`'s sha (describe reports none in that case). Only the
    /// exact-clean-tag form lacks `-dev`, so ``isReleaseVersion(_:)`` is a substring test, and
    /// every other form is a semver prerelease that sorts *below* the release it is built on.
    ///
    /// - Parameters:
    ///   - describe: raw `git describe` output; trailing newline and whitespace are trimmed.
    ///     `nil`/empty is the ordinary no-tag case — describe *exits non-zero* with no matching
    ///     tag, so the caller has nothing to hand over.
    ///   - headSHA: `git rev-parse --short HEAD`, needed for the two forms describe cannot supply
    ///     a sha for. Empty yields a bare ``devMarketingVersion`` rather than a dangling `+`.
    ///   - isDirty: consulted **only** when `describe` is empty; otherwise describe's own
    ///     `-dirty` suffix is the authority.
    public static func marketingVersion(
        fromGitDescribe describe: String?,
        headSHA: String = "",
        isDirty: Bool = false
    ) -> String {
        var raw = describe?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sha = headSHA.trimmingCharacters(in: .whitespacesAndNewlines)

        var dirty = false
        if raw.hasSuffix("-dirty") {
            dirty = true
            raw.removeLast("-dirty".count)
        }

        guard !raw.isEmpty else {
            let base = sha.isEmpty ? devMarketingVersion : "\(devMarketingVersion)+\(sha)"
            return (dirty || isDirty) ? "\(base).dirty" : base
        }

        var tag = raw
        var distance: String?
        var describeSHA = ""
        if let suffix = describeSuffix(raw) {
            tag = suffix.tag
            distance = suffix.distance
            describeSHA = suffix.sha
        }
        if tag.hasPrefix("v") { tag.removeFirst() }

        guard let distance else {
            // Exactly on the tag. Clean → the one and only release form; dirty → N=0 and HEAD.
            guard dirty else { return tag }
            return "\(tag)-dev.0+\(sha).dirty"
        }
        let out = "\(tag)-dev.\(distance)+\(describeSHA)"
        return dirty ? "\(out).dirty" : out
    }

    /// Splits a `-<commits>-g<sha>` describe suffix off the right-hand end, or nil if there is
    /// none. Right-to-left so a prerelease tag's own dashes survive (`v1.0.0-rc1-2-gdeadbee`).
    private static func describeSuffix(
        _ text: String
    ) -> (tag: String, distance: String, sha: String)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let last = parts[parts.count - 1], distance = parts[parts.count - 2]
        let hex = last.dropFirst()
        guard last.first == "g", !hex.isEmpty, hex.allSatisfy(\.isLowercaseHexDigit),
              !distance.isEmpty, distance.allSatisfy(\.isASCIIDigit) else { return nil }
        return (parts.dropLast(2).joined(separator: "-"), String(distance), String(hex))
    }

    /// Whether a marketing version denotes an exact, clean release tag.
    ///
    /// Every non-release form produced above carries `-dev` — `1.2.3-dev.4+abc1234`,
    /// `0.0.0-dev+abc1234`, or the bare ``devMarketingVersion`` fallback — so one substring test
    /// covers them all. (A tag literally named `v1.2.3-dev` would be reported as not-a-release.
    /// That is the trade the shared `-dev` marker buys, and it fails in the safe direction.)
    public static func isReleaseVersion(_ version: String) -> Bool {
        !version.isEmpty && !version.contains("-dev")
    }
}

private extension Character {
    /// `git describe` abbreviates with lowercase hex, and the shell script matches `[0-9a-f]`;
    /// `isHexDigit` would also accept `A`-`F`, widening the Swift side past the script's rule.
    var isLowercaseHexDigit: Bool { ("0"..."9").contains(self) || ("a"..."f").contains(self) }
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
