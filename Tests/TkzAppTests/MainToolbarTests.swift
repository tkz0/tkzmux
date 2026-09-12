import AppKit
import Testing
import TkzCore
@testable import TkzApp

/// Headless tests for the main window toolbar (TKZ-18, M2.2).
///
/// The delegate is exercised directly — `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`
/// — rather than by inserting into a real toolbar, because there is no window in a test process.
@MainActor
struct MainToolbarTests {

    static func item(
        _ controller: MainToolbarController,
        _ id: NSToolbarItem.Identifier
    ) -> NSToolbarItem? {
        controller.toolbar(controller.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true)
    }

    @Test func vendsEveryExpectedItemIdentifier() {
        let controller = MainToolbarController()
        let expected: [NSToolbarItem.Identifier] = [.tkzNewSession, .tkzTitle, .tkzSearch, .tkzViewCluster]

        let defaults = controller.toolbarDefaultItemIdentifiers(controller.toolbar)
        for id in expected {
            #expect(defaults.contains(id), "default identifiers are missing \(id.rawValue)")
            #expect(controller.toolbarAllowedItemIdentifiers(controller.toolbar).contains(id))
            #expect(Self.item(controller, id) != nil, "no item vended for \(id.rawValue)")
        }
        #expect(defaults.filter { $0 == .flexibleSpace }.count == 2)
        #expect(Self.item(controller, NSToolbarItem.Identifier("tkzmux.nope")) == nil)
    }

    @Test func identifiersAreStableStrings() {
        // Wave 2 references these by name when assembling the window.
        #expect(NSToolbarItem.Identifier.tkzNewSession.rawValue == "tkzmux.newSession")
        #expect(NSToolbarItem.Identifier.tkzTitle.rawValue == "tkzmux.title")
        #expect(NSToolbarItem.Identifier.tkzSearch.rawValue == "tkzmux.search")
        #expect(NSToolbarItem.Identifier.tkzViewCluster.rawValue == "tkzmux.viewCluster")
    }

    @Test func titleItemUsesSessionAndGroup() {
        let controller = MainToolbarController(theme: .midnightIndigo)
        _ = Self.item(controller, .tkzTitle)
        controller.setTitle(session: "TKZ-18", group: "tkzmux")

        #expect(controller.plainTitle == "TKZ-18 \u{2014} tkzmux")
        let field = controller.titleLabel
        #expect(field?.attributedStringValue.string == "TKZ-18 \u{2014} tkzmux")

        // The group half is the muted subtitle style; the session half is the title style.
        let attributed = field?.attributedStringValue
        let sessionColor = attributed?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let groupColor = attributed?.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor
        #expect(sessionColor == Theme.midnightIndigo.foreground.nsColor)
        #expect(groupColor == Theme.midnightIndigo.foregroundMuted.nsColor)

        let sessionFont = attributed?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let groupFont = attributed?.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
        #expect(sessionFont.map { Double($0.pointSize) } == Theme.midnightIndigo.fontUI.title)
        #expect(groupFont.map { Double($0.pointSize) } == Theme.midnightIndigo.fontUI.body)
    }

    @Test func titleOmitsTheDashWhenThereIsNoGroup() {
        let controller = MainToolbarController()
        _ = Self.item(controller, .tkzTitle)
        controller.setTitle(session: "Scratch", group: nil)
        #expect(controller.plainTitle == "Scratch")
        #expect(controller.titleLabel?.attributedStringValue.string == "Scratch")
    }

    @Test func titleFollowsTheTheme() {
        let controller = MainToolbarController(theme: .midnightIndigo)
        _ = Self.item(controller, .tkzTitle)
        controller.setTitle(session: "A", group: "B")
        let dark = controller.titleLabel?.attributedStringValue
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        controller.theme = .light
        let light = controller.titleLabel?.attributedStringValue
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(dark != light)
        #expect(light == Theme.light.foreground.nsColor)
    }

    @Test func newSessionItemIsAMenuItemWithAStubMenu() throws {
        let controller = MainToolbarController()
        let item = try #require(Self.item(controller, .tkzNewSession) as? NSMenuToolbarItem)
        #expect(item.title == "\u{FF0B} New session\u{2026}")
        #expect(item.showsIndicator)
        // Stub for this wave: present, but nothing actionable until M2.4 replaces it.
        #expect(item.menu.items.count == 1)
        // AppKit rewrites the action to its own `_popUpItemAction:`; what matters is that the
        // placeholder is disabled, so the stub menu cannot do anything until M2.4 replaces it.
        #expect(!item.menu.items[0].isEnabled)
        #expect(item.menu.items[0].title == "New session\u{2026}")

        let real = NSMenu()
        real.addItem(NSMenuItem(title: "New worktree (claude -w)", action: nil, keyEquivalent: ""))
        controller.newSessionMenu = real
        #expect(item.menu === real)
    }

    @Test func searchItemIsASearchFieldWithThePlaceholder() throws {
        let controller = MainToolbarController()
        let item = try #require(Self.item(controller, .tkzSearch) as? NSSearchToolbarItem)
        #expect(item.searchField.placeholderString == "Search sessions\u{2026}")
        #expect(controller.searchField === item.searchField)

        var seen: [String] = []
        controller.onSearchChanged = { seen.append($0) }
        item.searchField.stringValue = "tkz"
        _ = item.searchField.target?.perform(item.searchField.action, with: item.searchField)
        #expect(seen == ["tkz"])
    }

    @Test func everyClusterButtonIsEnabled() throws {
        let controller = MainToolbarController()
        let item = try #require(Self.item(controller, .tkzViewCluster))
        let control = try #require(item.view as? NSSegmentedControl)

        // TKZ-57 dropped the disabled ◍ browser placeholder; the ☾/☀ theme toggle then took the
        // fourth slot. Four buttons, all live.
        #expect(control.segmentCount == 4)
        #expect(control.segmentCount == MainToolbarController.ViewButton.allCases.count)
        for button in MainToolbarController.ViewButton.allCases {
            #expect(control.isEnabled(forSegment: button.rawValue))
            #expect(control.toolTip(forSegment: button.rawValue) == button.label(isDark: true))
        }

        // The glyphs are the design's, drawn at the cluster size rather than the sidebar's.
        #expect((0..<control.segmentCount).map { control.label(forSegment: $0) }
                == MainToolbarController.ViewButton.allCases.map { $0.glyph(isDark: true) })
        #expect(control.font.map { Double($0.pointSize) } == MainToolbarController.clusterGlyphSize)
    }

    @Test func terminalButtonInvokesTheClosure() throws {
        let controller = MainToolbarController()
        let item = try #require(Self.item(controller, .tkzViewCluster))
        let control = try #require(item.view as? NSSegmentedControl)

        // The control is wired to the controller; the click handler funnels into `activate`.
        #expect(control.target === controller)
        #expect(control.action != nil)

        var fired = 0
        controller.onNewTerminal = { fired += 1 }

        controller.activate(.terminal)
        #expect(fired == 1)

        // Buttons with no closure assigned fire nothing.
        for button in MainToolbarController.ViewButton.allCases where button != .terminal {
            controller.activate(button)
        }
        #expect(fired == 1)
    }

    /// The glyph shows the theme that is *on* — 2c draws the moon, its light twin draws the sun —
    /// so it has to follow a live theme change, not only the build-time value.
    @Test func themeSegmentGlyphAndTooltipFollowTheTheme() throws {
        let controller = MainToolbarController()
        let item = try #require(Self.item(controller, .tkzViewCluster))
        let control = try #require(item.view as? NSSegmentedControl)
        let slot = MainToolbarController.ViewButton.theme.rawValue

        #expect(control.label(forSegment: slot) == "\u{263E}")            // moon
        #expect(control.toolTip(forSegment: slot)?.contains("light") == true)

        controller.theme = .light
        #expect(control.label(forSegment: slot) == "\u{2600}")            // sun
        #expect(control.toolTip(forSegment: slot)?.contains("dark") == true)

        // The other three glyphs are constants and must not have moved.
        #expect(control.label(forSegment: MainToolbarController.ViewButton.terminal.rawValue) == ">_")
    }

    @Test func themeButtonInvokesTheClosure() throws {
        let controller = MainToolbarController()
        _ = try #require(Self.item(controller, .tkzViewCluster))

        var fired = 0
        controller.onToggleTheme = { fired += 1 }

        controller.activate(.theme)
        #expect(fired == 1)

        for button in MainToolbarController.ViewButton.allCases where button != .theme {
            controller.activate(button)
        }
        #expect(fired == 1)
    }

    @Test func toolbarIsNotUserCustomisableAndCentresTheTitle() {
        let controller = MainToolbarController()
        #expect(!controller.toolbar.allowsUserCustomization)
        #expect(controller.toolbar.centeredItemIdentifiers == [.tkzTitle])
    }
}
