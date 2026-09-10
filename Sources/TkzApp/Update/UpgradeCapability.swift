// UpgradeCapability — may the update card offer "Update via Homebrew"? (TKZ-50)
//
// Three facts, decided once at launch: `brew` exists, the cask is installed (its Caskroom
// directory is there), and the running bundle *is* the cask's `/Applications/tkzmux.app` — a
// `make app` build under `build/` or a `swift run` must never spawn brew against an app it is not.
// Any one false makes the card link-only.
//
// Paths are parameters rather than only the `FileManager`: an injected file manager alone cannot
// fake `/opt/homebrew/Caskroom`, and the tests lay the three things out in a temp directory.

import Foundation

public struct UpgradeCapability: Equatable, Sendable {
    public static let standardBundlePath = "/Applications/tkzmux.app"
    public static let standardCaskroomPath = "/opt/homebrew/Caskroom/tkzmux"
    /// The fully qualified cask token — `brew upgrade --cask` needs the tap for a third-party cask.
    public static let caskToken = "tkz0/tap/tkzmux"
    /// `TKZMUX_UPDATE_BREW=1` waives the bundle-path test so a dev build can drive the real brew
    /// path against an up-to-date cask.
    public static let forceKey = "TKZMUX_UPDATE_BREW"

    public var brewPath: String?
    public var caskroomPresent: Bool
    public var isStandardInstall: Bool

    public init(brewPath: String?, caskroomPresent: Bool, isStandardInstall: Bool) {
        self.brewPath = brewPath
        self.caskroomPresent = caskroomPresent
        self.isStandardInstall = isStandardInstall
    }

    public var canUpgradeInPlace: Bool {
        brewPath != nil && caskroomPresent && isStandardInstall
    }

    public static func detect(
        bundlePath: String = Bundle.main.bundlePath,
        caskroomPath: String = standardCaskroomPath,
        standardBundlePath: String = standardBundlePath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> UpgradeCapability {
        var isDirectory: ObjCBool = false
        let caskroom = fileManager.fileExists(atPath: caskroomPath, isDirectory: &isDirectory) && isDirectory.boolValue
        let standardized = (bundlePath as NSString).standardizingPath
        let forced = environment[forceKey].map { !$0.isEmpty && $0 != "0" } ?? false
        return UpgradeCapability(
            brewPath: resolveBrewPath(searchPath: environment["PATH"], fileManager: fileManager),
            caskroomPresent: caskroom,
            isStandardInstall: forced || standardized == (standardBundlePath as NSString).standardizingPath)
    }

    /// Where `brew` is: `PATH`, then the two Homebrew prefixes. A GUI app launched from Finder has
    /// a `PATH` without `/opt/homebrew/bin`, hence the fallbacks — the same shape as
    /// `PRLookup.resolveGhPath`.
    public static func resolveBrewPath(searchPath: String?, fileManager: FileManager = .default) -> String? {
        var candidates: [String] = []
        if let searchPath {
            candidates.append(contentsOf: searchPath.split(separator: ":").map(String.init))
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        for dir in candidates where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent("brew")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                fileManager.isExecutableFile(atPath: candidate)
            {
                return candidate
            }
        }
        return nil
    }
}
