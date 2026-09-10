// UpdateState — what the sidebar's "Update available" card renders (design 2c.1, TKZ-50).
//
// Process state, not durable state: `PersistedState` deliberately leaves `update` out, the same
// way it leaves `usage` out — a fetched "latest release" restored from disk would be a stale
// answer dressed as a current one, and `StateAutosaver` compares projections on every delivery,
// so a durable copy would also rewrite the file on every poll. The one durable field is
// `AppState.dismissedUpdateVersion`, which lives in `PersistedPreferences`.
//
// The card is a pure function of `AppState.visibleUpdate`, `UpdateState.phase` and
// `UpdateState.canUpgradeInPlace`. The coordinator that fills these in is `TkzApp`'s
// `UpdateIntegration`; nothing here knows about GitHub, Homebrew or AppKit.

/// A release newer than the running build, as the release check reported it.
public struct AvailableUpdate: Hashable, Sendable {
    /// The marketing version, `v` stripped: `0.8.0`.
    public var version: String
    /// The GitHub release page ("What's new").
    public var releaseURL: String

    public init(version: String, releaseURL: String) {
        self.version = version
        self.releaseURL = releaseURL
    }
}

/// Where the in-app Homebrew upgrade is. Only ever advanced by an explicit click; the release
/// poller never starts brew on its own.
public enum UpgradePhase: Hashable, Sendable {
    case idle
    /// `brew update` / `brew upgrade` is running; `step` names which.
    case running(step: String)
    /// brew replaced the bundle on disk with `installed`; a restart finishes the update.
    case restartReady(installed: String)
    /// brew ran cleanly but the bundle did not change — the cask has not been bumped yet.
    case notInHomebrewYet
    /// brew failed; `reason` is the last line it printed, or a launch/timeout description.
    case failed(reason: String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// The transient half of the update feature.
public struct UpdateState: Hashable, Sendable {
    /// The newest release known to be newer than the running build, or `nil`.
    public var available: AvailableUpdate?
    public var phase: UpgradePhase
    /// `brew` is on this Mac, the cask is installed, and the running bundle is the cask's.
    /// Decided once at launch; `false` makes the card link-only.
    public var canUpgradeInPlace: Bool

    public init(
        available: AvailableUpdate? = nil,
        phase: UpgradePhase = .idle,
        canUpgradeInPlace: Bool = false
    ) {
        self.available = available
        self.phase = phase
        self.canUpgradeInPlace = canUpgradeInPlace
    }
}
