// SemanticVersion — the ordering behind "is there a newer release than the one running?" (TKZ-50).
//
// `AppVersion.isReleaseVersion` answers *what kind* of build this is; nothing answered *which is
// newer* until the sidebar's update card needed to compare a GitHub tag (`v0.8.0`) against
// `CFBundleShortVersionString` (`0.7.0`, or `0.7.0-dev.4+abc1234`). This is a plain semver 2.0
// ordering: `major.minor.patch`, then prerelease identifiers (a prerelease sorts *below* its
// release, `1.0.0-rc1 < 1.0.0`), with build metadata after `+` ignored — so every `-dev.N+sha`
// form `scripts/make-app.sh` produces sorts below the tag it was built from and above the one
// before it, which is exactly the order the update check wants.
//
// TkzCore is Foundation-only (`SourceHygieneTests`); this type needs nothing but the standard library.

/// A parsed `major.minor.patch[-prerelease][+build]` version. Build metadata is dropped on parse.
public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Dot-separated prerelease identifiers (`["rc1"]`, `["dev", "4"]`); empty for a release.
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses `1.2.3`, `v1.2.3`, `1.2.3-rc1`, `1.2.3-dev.4+abc1234.dirty`. A leading `v`/`V` (a git
    /// tag) is tolerated, as is a missing minor or patch (`1.2` → `1.2.0`). Anything else — an
    /// empty string, a non-numeric core, `0.0.0-dev` is fine but `latest` is not — is `nil`.
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        guard !rest.isEmpty else { return nil }

        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var pre: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let tail = rest[rest.index(after: dash)...]
            guard !tail.isEmpty else { return nil }
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isSemverIdentifierCharacter) })
            else { return nil }
            rest = rest[..<dash]
        }

        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// `1.2.3` or `1.2.3-rc1` — never a `v`, never build metadata.
    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    // MARK: Ordering (semver 2.0 §11)

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Same core: a release outranks any prerelease of it.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (.some, .none): return true    // numeric identifiers sort below alphanumeric ones
            case (.none, .some): return false
            case (.none, .none): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

extension AppVersion {
    /// Whether `candidate` (a release tag, with or without its `v`) is strictly newer than
    /// `running`. Unparsable input on either side is `false`: the update card must never appear
    /// because a string could not be read.
    public static func isNewer(_ candidate: String, than running: String) -> Bool {
        guard let candidate = SemanticVersion(candidate), let running = SemanticVersion(running)
        else { return false }
        return candidate > running
    }

    /// `isNewer(candidate, than: marketingVersion)`.
    public func isOlder(than candidate: String) -> Bool {
        Self.isNewer(candidate, than: marketingVersion)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isSemverIdentifierCharacter: Bool {
        isASCIIDigit || ("a"..."z").contains(self) || ("A"..."Z").contains(self) || self == "-"
    }
}
