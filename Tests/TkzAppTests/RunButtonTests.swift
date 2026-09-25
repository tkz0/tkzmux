// The toolbar's ▶ Run split button: its label, its ▾ menu, and which closure each part
// fires. Driven through the delegate like `MainToolbarTests` — no window, no real click.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
struct RunButtonTests {
    private func control(_ controller: MainToolbarController) throws -> NSSegmentedControl {
        let item = try #require(MainToolbarTests.item(controller, .tkzRun))
        return try #require(item.view as? NSSegmentedControl)
    }

    private static let tasks = [
        RunTask(name: "dev", command: "pnpm dev", source: .packageJSON),
        RunTask(name: "dev:web", command: "pnpm dev:web", source: .packageJSON),
        RunTask(name: "compose", command: "docker compose up", source: .compose),
    ]

    @Test func itSitsBeforeTheCluster() {
        let controller = MainToolbarController()
        let defaults = controller.toolbarDefaultItemIdentifiers(controller.toolbar)
        let run = defaults.firstIndex(of: .tkzRun)
        let cluster = defaults.firstIndex(of: .tkzViewCluster)
        #expect(run != nil && cluster != nil && run! < cluster!)
    }

    @Test func labelFollowsTheModel() throws {
        let controller = MainToolbarController()
        let control = try control(controller)

        controller.setRun(RunButtonModel(command: "pnpm dev", tasks: Self.tasks))
        #expect(control.label(forSegment: 0) == "\u{25B6} pnpm dev")
        #expect(control.label(forSegment: 1) == "\u{25BE}")

        controller.setRun(RunButtonModel(command: "pnpm dev", running: "pnpm dev", tasks: Self.tasks))
        #expect(control.label(forSegment: 0) == "\u{25A0} pnpm dev")

        // Nothing detected, nothing remembered: the button asks rather than guesses.
        controller.setRun(RunButtonModel(command: nil, tasks: []))
        #expect(control.label(forSegment: 0) == "\u{25B6} Run\u{2026}")
    }

    @Test func longCommandsAreShortened() throws {
        let controller = MainToolbarController()
        let control = try control(controller)
        controller.setRun(RunButtonModel(command: "dotnet watch run --project src/Some.Long.Api.Name", tasks: []))
        let label = try #require(control.label(forSegment: 0))
        #expect(label.count <= RunButtonModel.maxLabelLength + 2)
        #expect(label.hasSuffix("\u{2026}"))
        #expect(control.toolTip(forSegment: 0)?.contains("dotnet watch run --project src/Some.Long.Api.Name") == true)
    }

    /// Hidden for a row with nowhere to run — and a model set before the item exists still lands.
    @Test func nilHidesTheItem() throws {
        let controller = MainToolbarController()
        controller.setRun(nil)
        let item = try #require(MainToolbarTests.item(controller, .tkzRun))
        #expect(item.isHidden)
        controller.setRun(RunButtonModel(command: "pnpm dev", tasks: Self.tasks))
        #expect(!item.isHidden)
    }

    @Test func primaryFiresRunOrStopMenuWhenNothingToRun() throws {
        let controller = MainToolbarController()
        _ = try control(controller)
        var primary = 0
        var presented = 0
        controller.onRunPrimary = { primary += 1 }
        // Never a real pop-up in a test: `NSMenu.popUp` runs a modal tracking loop.
        controller.presentRunMenu = { _, _ in presented += 1 }

        controller.setRun(RunButtonModel(command: "pnpm dev", tasks: Self.tasks))
        #expect(controller.activateRun(.primary) == .ran)
        controller.setRun(RunButtonModel(command: "pnpm dev", running: "pnpm dev", tasks: Self.tasks))
        #expect(controller.activateRun(.primary) == .ran)
        #expect(primary == 2)

        // `▶ Run…` has no command: its click opens the menu instead.
        controller.setRun(RunButtonModel(command: nil, tasks: []))
        #expect(controller.activateRun(.primary) == .openedMenu)
        #expect(primary == 2)
        #expect(controller.activateRun(.menu) == .openedMenu)
        #expect(presented == 2)
    }

    @Test func menuListsTasksChecksTheCurrentOneAndOffersCustom() throws {
        let controller = MainToolbarController()
        controller.setRun(RunButtonModel(command: "pnpm dev:web", remembered: "pnpm dev:web", tasks: Self.tasks))
        let menu = controller.makeRunMenu()
        let titles = menu.items.map(\.title)
        #expect(titles.starts(with: ["pnpm dev", "pnpm dev:web", "docker compose up"]))
        #expect(titles.contains("Custom Command\u{2026}"))
        #expect(titles.contains("Reset to Detected"))
        #expect(menu.items.first { $0.title == "pnpm dev:web" }?.state == .on)
        #expect(menu.items.first { $0.title == "pnpm dev" }?.state == .off)
        #expect(menu.items.first { $0.title == "Reset to Detected" }?.isEnabled == true)
    }

    /// A remembered command detection cannot see (a `.sln`'s `--project` run) still gets its row, first.
    @Test func aRememberedCustomCommandIsListedFirst() {
        let controller = MainToolbarController()
        let custom = "dotnet watch run --project src/Api"
        controller.setRun(RunButtonModel(command: custom, remembered: custom, tasks: Self.tasks))
        let menu = controller.makeRunMenu()
        #expect(menu.items.first?.title == custom)
        #expect(menu.items.first?.state == .on)
    }

    @Test func nothingRememberedMeansNoReset() {
        let controller = MainToolbarController()
        controller.setRun(RunButtonModel(command: "pnpm dev", tasks: Self.tasks))
        let menu = controller.makeRunMenu()
        #expect(menu.items.first { $0.title == "Reset to Detected" }?.isEnabled == false)
        // The best guess is what ▶ runs, so it carries the check.
        #expect(menu.items.first { $0.title == "pnpm dev" }?.state == .on)
    }

    @Test func emptyMenuSaysSo() {
        let controller = MainToolbarController()
        controller.setRun(RunButtonModel(command: nil, tasks: []))
        let menu = controller.makeRunMenu()
        #expect(menu.items.first?.title == "No tasks found")
        #expect(menu.items.first?.isEnabled == false)
        #expect(menu.items.map(\.title).contains("Custom Command\u{2026}"))
    }

    @Test func menuItemsFireTheirClosures() throws {
        let controller = MainToolbarController()
        controller.setRun(RunButtonModel(command: "pnpm dev", remembered: "pnpm dev", tasks: Self.tasks))
        var ran: [String] = []
        var custom = 0
        var reset = 0
        controller.onRunTask = { ran.append($0) }
        controller.onCustomRunCommand = { custom += 1 }
        controller.onResetRunCommand = { reset += 1 }

        let menu = controller.makeRunMenu()
        func click(_ title: String) throws {
            let item = try #require(menu.items.first { $0.title == title })
            let target = try #require(item.target as? NSObject)
            target.perform(item.action, with: item)
        }
        try click("pnpm dev:web")
        try click("Custom Command\u{2026}")
        try click("Reset to Detected")
        #expect(ran == ["pnpm dev:web"])
        #expect(custom == 1)
        #expect(reset == 1)
    }
}
