// ShortcutsTable.swift — the app's key bindings as data (M2.4 / TKZ-20).
//
// design.md → Decisions → Shortcuts: the cmux bindings, workspace → session and tab → terminal:
//   ⌘N new session (picker), ⌘P go to session, ⇧⌘P command palette, ⌘B sidebar, ⇧⌘R rename session,
//   ⌘W close terminal / ⇧⌘W close session, ⌘1-9 select session, ⇧⌘U jump to needs-you,
//   ⌘I notifications, ⌘, settings, ⌘O open folder, ⇧⌘, reload config; ⌘T/⌘D reserved. User-editable.
//
// This file owns the **action-id vocabulary** that `AppState.shortcuts` keys against (AppState.swift
// says as much), and hands wave 3 a resolved `action → (keyEquivalent, modifierMask)` map for the
// main menu. It deliberately does *not* build a menu: `MainWindowController` owns that.
//
// Modifiers are parsed into our own `Sendable` option set and only converted to
// `NSEvent.ModifierFlags` at the edge, so the whole table stays a value type that tests can compare.

import AppKit
import TkzCore

/// One command the app can perform, identified by the string that `AppState.shortcuts` keys on.
///
/// `selectSession(n)` covers ⌘1–9. The ids match the vocabulary already present in
/// `AppState.fixture.shortcuts` (`newSession`, `closeSession`, `nextSession`, `previousSession`,
/// `searchSessions`, `commandPalette`, `toggleSidebar`).
public struct ShortcutAction: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let newSession = ShortcutAction("newSession")
    public static let searchSessions = ShortcutAction("searchSessions")
    public static let commandPalette = ShortcutAction("commandPalette")
    public static let toggleSidebar = ShortcutAction("toggleSidebar")
    public static let renameSession = ShortcutAction("renameSession")
    /// ⌘W — removes the selected session (row, shell, snapshot). The id is historical: it was
    /// "close terminal, keep the row" until 2026-09-08, when the kept row went away.
    public static let closeTerminal = ShortcutAction("closeTerminal")
    public static let jumpToNeedsYou = ShortcutAction("jumpToNeedsYou")
    public static let notifications = ShortcutAction("notifications")
    public static let settings = ShortcutAction("settings")
    public static let openFolder = ShortcutAction("openFolder")
    public static let reloadConfig = ShortcutAction("reloadConfig")
    /// No cmux default (⌘T/⌘D are reserved) — reachable only through an override or the palette.
    public static let nextSession = ShortcutAction("nextSession")
    public static let previousSession = ShortcutAction("previousSession")
    /// ⇧⌘C — copies the selected session's last Stop message (M3.4).
    public static let copyLastMessage = ShortcutAction("copyLastMessage")
    /// No key: deletes `bin/` and `zsh/` under Application Support so new shells are plain (M3.3).
    public static let removeShellIntegration = ShortcutAction("removeShellIntegration")
    /// ⌘R — `claude --resume` the selected row's conversation in its directory (M5.2).
    public static let resumeSession = ShortcutAction("resumeSession")
    /// No key: resume every resumable row in the selected session's group (M5.2).
    public static let resumeAllInGroup = ShortcutAction("resumeAllInGroup")
    /// No key: the presets sheet (M5.2).
    public static let managePresets = ShortcutAction("managePresets")
    /// No key: the "auto-resume on launch" preference, shown with a checkmark (M5.2).
    public static let toggleAutoResume = ShortcutAction("toggleAutoResume")

    /// ⌘1…⌘9 — `selectSession1` … `selectSession9`.
    public static func selectSession(_ n: Int) -> ShortcutAction { ShortcutAction("selectSession\(n)") }
}

/// The modifier half of a binding. Ours rather than `NSEvent.ModifierFlags` so the table is a
/// `Sendable` value; ``eventFlags`` converts at the AppKit edge.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)

    public var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }

    /// The reverse of ``eventFlags``, for reading a binding back off an `NSMenuItem` — the cheat
    /// sheet renders the menu the app already built rather than keeping a second table.
    public init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers: ShortcutModifiers = []
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }

    /// `⇧⌘` in menu order (control, option, shift, command) — for palette subtitles.
    public var displayString: String {
        var out = ""
        if contains(.control) { out += "\u{2303}" }
        if contains(.option) { out += "\u{2325}" }
        if contains(.shift) { out += "\u{21E7}" }
        if contains(.command) { out += "\u{2318}" }
        return out
    }
}

/// A resolved binding: what an `NSMenuItem` needs.
public struct Shortcut: Hashable, Sendable {
    /// The `NSMenuItem.keyEquivalent` string. Always lower case for letters — the shift key lives in
    /// ``modifiers``, never in the case of the character.
    public let keyEquivalent: String
    public let modifiers: ShortcutModifiers

    public init(_ keyEquivalent: String, _ modifiers: ShortcutModifiers) {
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
    }

    public var modifierMask: NSEvent.ModifierFlags { modifiers.eventFlags }

    /// `⇧⌘P`, `⌘,`, `⌥⌘↓` — the palette's right-hand hint.
    public var displayString: String {
        modifiers.displayString + ShortcutsTable.displayKey(keyEquivalent)
    }
}

/// The cmux defaults, plus the `AppState.shortcuts` overrides applied on top.
public enum ShortcutsTable {

    /// Every action the app knows, in main-menu order. `selectSession1…9` are appended after the
    /// named ones.
    public static let allActions: [ShortcutAction] =
        [
            .newSession, .searchSessions, .commandPalette, .toggleSidebar, .renameSession,
            .closeTerminal, .jumpToNeedsYou, .notifications, .settings,
            .openFolder, .reloadConfig, .nextSession, .previousSession, .copyLastMessage,
            .removeShellIntegration, .resumeSession, .resumeAllInGroup, .managePresets,
            .toggleAutoResume,
        ] + (1...9).map { ShortcutAction.selectSession($0) }

    /// design.md → Decisions → Shortcuts, verbatim, plus ⇧⌘C (M3.4) and ⌘R (M5.2), which that
    /// list records as tkzmux additions. `nextSession`/`previousSession` are absent on purpose:
    /// cmux binds no default for them and ⌘T/⌘D are reserved.
    public static let defaults: [ShortcutAction: Shortcut] = {
        var table: [ShortcutAction: Shortcut] = [
            .newSession: Shortcut("n", .command),
            .searchSessions: Shortcut("p", .command),
            .commandPalette: Shortcut("p", [.shift, .command]),
            .toggleSidebar: Shortcut("b", .command),
            .renameSession: Shortcut("r", [.shift, .command]),
            .closeTerminal: Shortcut("w", .command),
            .jumpToNeedsYou: Shortcut("u", [.shift, .command]),
            .notifications: Shortcut("i", .command),
            .settings: Shortcut(",", .command),
            .openFolder: Shortcut("o", .command),
            .reloadConfig: Shortcut(",", [.shift, .command]),
            .copyLastMessage: Shortcut("c", [.shift, .command]),
            .resumeSession: Shortcut("r", .command),
        ]
        for n in 1...9 { table[.selectSession(n)] = Shortcut("\(n)", .command) }
        return table
    }()

    /// Human-readable titles, used by the main menu (wave 3) and by the command palette rows.
    public static func title(for action: ShortcutAction) -> String {
        switch action {
        case .newSession: "New Session\u{2026}"
        case .searchSessions: "Search Sessions\u{2026}"
        case .commandPalette: "Command Palette\u{2026}"
        case .toggleSidebar: "Toggle Sidebar"
        case .renameSession: "Rename Session\u{2026}"
        case .closeTerminal: "Close Session"
        case .jumpToNeedsYou: "Jump to Next Needs-You"
        case .notifications: "Notifications"
        case .settings: "Settings\u{2026}"
        case .openFolder: "Open Folder\u{2026}"
        case .reloadConfig: "Reload Config"
        case .nextSession: "Next Session"
        case .previousSession: "Previous Session"
        case .copyLastMessage: "Copy Last Message"
        case .removeShellIntegration: "Remove Shell Integration"
        case .resumeSession: "Resume Session"
        case .resumeAllInGroup: "Resume All in Group"
        case .managePresets: "Manage Presets\u{2026}"
        case .toggleAutoResume: "Auto-resume Sessions on Launch"
        default:
            if let n = selectSessionIndex(action) { "Select Session \(n)" } else { action.rawValue }
        }
    }

    static func selectSessionIndex(_ action: ShortcutAction) -> Int? {
        guard action.rawValue.hasPrefix("selectSession") else { return nil }
        return Int(action.rawValue.dropFirst("selectSession".count))
    }

    // MARK: Resolution

    /// The defaults with `state.shortcuts` applied. An override that cannot be parsed is ignored
    /// (the default survives); an override for an unknown action id is kept, so a future action
    /// added to the config file is not silently dropped.
    public static func resolved(overrides: [String: String]) -> [ShortcutAction: Shortcut] {
        var table = defaults
        for (id, spec) in overrides {
            guard let shortcut = parse(spec) else { continue }
            table[ShortcutAction(id)] = shortcut
        }
        return table
    }

    /// Convenience over `AppState`.
    public static func resolved(state: AppState) -> [ShortcutAction: Shortcut] {
        resolved(overrides: state.shortcuts)
    }

    /// One binding, defaults + overrides.
    public static func shortcut(for action: ShortcutAction, overrides: [String: String] = [:]) -> Shortcut? {
        if let spec = overrides[action.rawValue], let parsed = parse(spec) { return parsed }
        return defaults[action]
    }

    // MARK: Parsing

    /// `"shift+cmd+p"`, `"alt+cmd+down"`, `"ctrl+cmd+s"`, `"cmd+,"` — the cmux config spelling.
    /// Returns `nil` for anything it cannot resolve to a single key equivalent.
    public static func parse(_ spec: String) -> Shortcut? {
        guard !spec.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let parts = spec.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1 || !parts[0].isEmpty else { return nil }

        var modifiers: ShortcutModifiers = []
        var keyToken: String?
        for (index, part) in parts.enumerated() {
            // A literal "+" arrives as an empty component between two separators.
            let token = part.isEmpty ? (index == parts.count - 1 ? "+" : "") : part.lowercased()
            if token.isEmpty { continue }
            switch token {
            case "cmd", "command", "meta", "super": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: keyToken = part.isEmpty ? "+" : part
            }
        }
        guard let keyToken, let key = keyEquivalent(for: keyToken) else { return nil }
        return Shortcut(key, modifiers)
    }

    /// Named keys → the string AppKit wants in `keyEquivalent`.
    static func keyEquivalent(for token: String) -> String? {
        switch token.lowercased() {
        case "up": return String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
        case "down": return String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)
        case "left": return String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!)
        case "right": return String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!)
        case "home": return String(UnicodeScalar(UInt32(NSHomeFunctionKey))!)
        case "end": return String(UnicodeScalar(UInt32(NSEndFunctionKey))!)
        case "pageup": return String(UnicodeScalar(UInt32(NSPageUpFunctionKey))!)
        case "pagedown": return String(UnicodeScalar(UInt32(NSPageDownFunctionKey))!)
        case "return", "enter": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "escape", "esc": return "\u{1B}"
        case "delete", "backspace": return String(UnicodeScalar(8))
        case "comma": return ","
        case "period", "dot": return "."
        case "slash": return "/"
        default: break
        }
        let lowered = token.lowercased()
        if lowered.count == 1 { return lowered }
        // f1…f20
        if lowered.hasPrefix("f"), let n = Int(lowered.dropFirst()), (1...20).contains(n) {
            return String(UnicodeScalar(UInt32(NSF1FunctionKey + n - 1))!)
        }
        return nil
    }

    /// The reverse, for display: `↓`, `⏎`, `⎋`, else the upper-cased character.
    public static func displayKey(_ keyEquivalent: String) -> String {
        switch keyEquivalent {
        case String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!): return "\u{2191}"
        case String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!): return "\u{2193}"
        case String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!): return "\u{2190}"
        case String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!): return "\u{2192}"
        case "\r": return "\u{23CE}"
        case "\t": return "\u{21E5}"
        case " ": return "\u{2423}"
        case "\u{1B}": return "\u{238B}"
        default: return keyEquivalent.uppercased()
        }
    }
}
