// AppIdentity — the application id, and whether this process runs from an installed copy.
// WOR-303 S4; ADR-0002 D6.
//
// One id for every place that names the app to the OS:
//
//   macOS   `CFBundleIdentifier` in `Resources/Info.plist`, always `releaseID`
//   Linux   the GApplication id and xdg_toplevel app_id (WOR-314 S3), the `.desktop` basename and
//           the notification `desktop-entry` hint (WOR-320). Hyprland rules match
//           `^se\.tkz\.tkzmux(\.Devel)?$` (ADR-0005)
//
// A Linux debug build (`swift run`, `swift build`) is `se.tkz.tkzmux.Devel`. GApplication forwards
// a second process's activation to whichever instance owns the bus name, so a dev build sharing the
// installed app's id would never start: it would only raise the installed window. The Mac keeps one
// id in every configuration, because its bundle identifier comes from the committed Info.plist.
//
// TkzCore: Foundation only.

import Foundation

public enum AppIdentity {
    /// The release id: the Mac's `CFBundleIdentifier`, and the Linux id of a release build.
    public static let releaseID = "se.tkz.tkzmux"

    /// The Linux debug-build id.
    public static let develID = releaseID + ".Devel"

    /// This build's id: `develID` in a Linux debug build, `releaseID` otherwise.
    public static var id: String { id(for: .current, isDebugBuild: isDebugBuild) }

    /// Whether this binary was compiled without optimisation (SwiftPM defines `DEBUG` for `-c debug`).
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The id rule as a function, so both platforms and both configurations are tested everywhere.
    public static func id(for platform: ResourceLocator.Platform, isDebugBuild: Bool) -> String {
        platform == .linux && isDebugBuild ? develID : releaseID
    }

    /// Whether this process runs from an installed copy rather than from `.build` or `swift test`.
    ///
    /// - macOS: it has a bundle identifier, i.e. it is inside a `.app`. This is the guard in front of
    ///   `UNUserNotificationCenter`, which traps without one (`Sources/TkzApp/SessionSeams.swift`).
    /// - Linux: `<prefix>/lib/tkzmux` exists beside the executable's `<prefix>/bin`
    ///   (`ResourceLocator.installDirectoryExists`).
    public static var isInstalled: Bool {
        #if os(Linux)
        return ResourceLocator.current.installDirectoryExists
        #else
        return Bundle.main.bundleIdentifier != nil
        #endif
    }
}
