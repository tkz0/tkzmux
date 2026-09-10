// InstalledVersion — what is on disk at the bundle path *right now* (TKZ-50).
//
// After `brew upgrade` the question is "did the bundle actually change?", and neither
// `Bundle.main.infoDictionary` (read once, frozen — `AppVersion.current` already froze it) nor a
// fresh `Bundle(url:)` (CFBundle caches by path and can hand back the old dictionary) can answer
// it. So the plist is read as a file. brew removes the old bundle and copies the new one to the
// same path, so `Bundle.main.bundleURL` captured before the run names the new bundle after it.

import Foundation
import TkzCore

public struct InstalledVersion: Equatable, Sendable {
    public var marketingVersion: String
    public var build: String

    public init(marketingVersion: String, build: String) {
        self.marketingVersion = marketingVersion
        self.build = build
    }

    /// `nil` when the plist is missing or unreadable — mid-copy, or not a bundle at all.
    public static func read(bundleURL: URL) -> InstalledVersion? {
        let plist = bundleURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any]
        else { return nil }
        let version = AppVersion(infoDictionary: dictionary)
        return InstalledVersion(marketingVersion: version.marketingVersion, build: version.build)
    }

    /// Either key differing counts: a re-tagged build can keep its marketing string.
    public func differs(from running: AppVersion) -> Bool {
        marketingVersion != running.marketingVersion || build != running.build
    }
}
