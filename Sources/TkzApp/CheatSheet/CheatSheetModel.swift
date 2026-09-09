// CheatSheetModel.swift — what the ⌘-hold cheat sheet lists, read out of the menu itself.
//
// The app already owns exactly one description of its shortcuts: `ShortcutsTable` supplies the
// bindings and `MainMenu` supplies the grouping and the order. Rather than add a third list that
// would drift from both (as `docs/shortcuts.md` already has), this walks the built `NSMenu`.
// `MainMenu.build` is pure and headless by design — "a test can build one and walk it without
// installing it" — and `MainMenu.command` stamps every item with its title, key equivalent and
// `representedObject`, so the menu carries everything a row needs.
//
// A pleasant side effect: ⌘Q, ⌘H, ⌥⌘H and ⌘M are ordinary menu items, so they are listed too,
// without anyone maintaining them here.
import AppKit
import TkzCore

/// One line of the cheat sheet: the keys on the left, what they do on the right.
public struct CheatSheetRow: Equatable, Sendable {
    public let keys: String
    public let title: String

    public init(keys: String, title: String) {
        self.keys = keys
        self.title = title
    }
}

/// One submenu's worth of rows, titled as the submenu is.
public struct CheatSheetSection: Equatable, Sendable {
    public let title: String
    public let rows: [CheatSheetRow]

    public init(title: String, rows: [CheatSheetRow]) {
        self.title = title
        self.rows = rows
    }
}

public enum CheatSheetModel {

    /// Every top-level submenu becomes a section; every item in it that has a key equivalent
    /// becomes a row. Items without one (`Next Session`, `Manage Presets…`, separators) drop out
    /// on their own, so there is no exclusion list to keep in step with the table.
    public static func sections(from menu: NSMenu) -> [CheatSheetSection] {
        menu.items.compactMap { item in
            guard let submenu = item.submenu else { return nil }
            let rows = self.rows(in: submenu)
            return rows.isEmpty ? nil : CheatSheetSection(title: submenu.title, rows: rows)
        }
    }

    private static func rows(in submenu: NSMenu) -> [CheatSheetRow] {
        let collapsed = collapsibleSelectSession(in: submenu)
        var rows: [CheatSheetRow] = []
        var emittedSelectSession = false

        for item in submenu.items where !item.isSeparatorItem && !item.keyEquivalent.isEmpty {
            if let collapsed, isSelectSession(item) {
                // ⌘1 … ⌘9 are nine items in the menu and one line here.
                guard !emittedSelectSession else { continue }
                emittedSelectSession = true
                rows.append(collapsed)
                continue
            }
            rows.append(CheatSheetRow(keys: keys(for: item), title: item.title))
        }
        return rows
    }

    /// `⌘1–9  Select Session n`, when all nine are present with one shared modifier set. Returns
    /// `nil` if an override has broken them apart, in which case they are listed individually.
    private static func collapsibleSelectSession(in submenu: NSMenu) -> CheatSheetRow? {
        let items = submenu.items.filter { !$0.keyEquivalent.isEmpty && isSelectSession($0) }
        guard items.count > 1 else { return nil }
        let masks = Set(items.map(\.keyEquivalentModifierMask.rawValue))
        guard masks.count == 1 else { return nil }
        guard items.allSatisfy({ $0.keyEquivalent.count == 1 && $0.keyEquivalent.first!.isNumber })
        else { return nil }

        let modifiers = ShortcutModifiers(eventFlags: items[0].keyEquivalentModifierMask)
        let first = items.first!.keyEquivalent
        let last = items.last!.keyEquivalent
        return CheatSheetRow(
            keys: "\(modifiers.displayString)\(first)\u{2013}\(last)",
            title: "Select Session n")
    }

    private static func isSelectSession(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? String else { return false }
        return ShortcutsTable.selectSessionIndex(ShortcutAction(id)) != nil
    }

    /// `⇧⌘P`, `⌘,`, `⌥⌘H` — the same rendering the palette uses for its trailing hint.
    private static func keys(for item: NSMenuItem) -> String {
        ShortcutModifiers(eventFlags: item.keyEquivalentModifierMask).displayString
            + ShortcutsTable.displayKey(item.keyEquivalent)
    }
}
