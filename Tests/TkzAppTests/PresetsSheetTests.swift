// PresetsSheetTests — the presets CRUD (M5.2 / TKZ-30). The draft is the testable half; the sheet
// is driven through its test hooks without ever being ordered front.

import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

@Suite struct PresetDraftTests {

    @Test func roundTripsEveryCwdMode() {
        let presets = [
            Preset(name: "root", command: "claude", cwdMode: .repoRoot, accountKey: nil, env: [:]),
            Preset(name: "wt", command: "claude -w", cwdMode: .worktree(name: nil), accountKey: "claude-work", env: ["A": "1"]),
            Preset(name: "named", command: "claude -w", cwdMode: .worktree(name: "review"), env: ["URL": "http://x?a=b"]),
            Preset(name: "fixed", command: "claude", cwdMode: .fixed(path: "~/dev/other")),
        ]
        for preset in presets {
            let draft = PresetDraft(preset)
            #expect(draft.problem == nil)
            #expect(draft.preset == preset)
        }
    }

    @Test func envTextParsing() {
        #expect(PresetDraft.parseEnv("") == .success([:]))
        #expect(PresetDraft.parseEnv("A=1\n\n# comment\nB=x=y\nC=") == .success(["A": "1", "B": "x=y", "C": ""]))
        // Whitespace around the key is trimmed; the value keeps its leading space.
        #expect(PresetDraft.parseEnv("  C = 3 ") == .success(["C": " 3"]))
        #expect(PresetDraft.parseEnv("A=1\nnot an assignment\n") == .failure(line: "not an assignment"))
        #expect(PresetDraft.parseEnv("=1") == .failure(line: "=1"))
        #expect(PresetDraft.parseEnv("A B=1") == .failure(line: "A B=1"))
        #expect(PresetDraft.envText(["B": "2", "A": "1"]) == "A=1\nB=2")
    }

    @Test func problemsAreNamed() {
        var draft = PresetDraft(name: "", command: "claude")
        #expect(draft.problem == "A preset needs a name.")
        #expect(draft.preset == nil)
        draft.name = "x"
        draft.command = "  "
        #expect(draft.problem == "A preset needs a command.")
        draft.command = "claude"
        draft.start = .fixedPath
        #expect(draft.problem == "A fixed-path preset needs a path.")
        draft.argument = "/tmp"
        draft.envText = "oops"
        #expect(draft.problem?.contains("oops") == true)
        draft.envText = "K=V"
        #expect(draft.problem == nil)
        #expect(draft.preset?.cwdMode == .fixed(path: "/tmp"))
        #expect(draft.preset?.env == ["K": "V"])
        // A worktree name is optional, and whitespace means none.
        draft.start = .worktree
        draft.argument = "  "
        #expect(draft.preset?.cwdMode == .worktree(name: nil))
    }
}

@MainActor
@Suite(.serialized)
struct PresetsSheetControllerTests {

    @Test("add, edit, remove through the sheet; Done hands back only valid presets")
    func editingFlow() {
        _ = NSApplication.shared
        let existing = Preset(name: "Plan", command: "claude --permission-mode plan")
        let sheet = PresetsSheetController(
            presets: [existing],
            accounts: [Account(key: "claude-work", configDir: "/x/.claude-work", label: "Work")],
            theme: .default)
        #expect(sheet.drafts.count == 1)
        #expect(sheet.selectedIndex == 0)

        sheet.addDraft()
        #expect(sheet.drafts.count == 2)
        #expect(sheet.selectedIndex == 1)
        sheet.setDraft(PresetDraft(
            id: sheet.drafts[1].id, name: "Review", command: "claude -w", start: .worktree,
            argument: "review", accountKey: "claude-work", envText: "TKZ=1"))
        #expect(sheet.canFinish)
        #expect(sheet.drafts.compactMap(\.preset).map(\.name) == ["Plan", "Review"])
        #expect(sheet.drafts[1].preset?.cwdMode == .worktree(name: "review"))
        #expect(sheet.drafts[1].preset?.accountKey == "claude-work")
        #expect(sheet.drafts[1].preset?.env == ["TKZ": "1"])

        // A broken draft blocks Done until it is fixed or removed.
        sheet.setDraft(PresetDraft(id: sheet.drafts[1].id, name: "", command: "claude"))
        #expect(sheet.canFinish == false)
        sheet.removeSelectedDraft()
        #expect(sheet.drafts.count == 1)
        #expect(sheet.selectedIndex == 0)
        #expect(sheet.canFinish)

        sheet.select(nil)
        #expect(sheet.selectedIndex == nil)
        sheet.removeSelectedDraft()
        #expect(sheet.drafts.count == 1, "nothing selected, nothing removed")
    }

    @Test("the window controller commits the whole list on Done and nothing on Cancel")
    func windowCommitsPresets() {
        let (harness, _) = MainWindowLaunchTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        harness.mutate { _ = $0.addPreset(Preset(name: "old", command: "claude")) }

        controller.presetsPrompt = { current in
            #expect(current.map(\.name) == ["old"])
            return [Preset(name: "new", command: "claude -w")]
        }
        controller.dispatcher.perform(.managePresets)
        harness.store.flush()
        #expect(harness.store.state.presets.map(\.name) == ["new"])
        #expect(controller.newSessionMenu.presets.map(\.name) == ["new"], "the menu follows the store")

        controller.presetsPrompt = { _ in nil }
        controller.dispatcher.perform(.managePresets)
        harness.store.flush()
        #expect(harness.store.state.presets.map(\.name) == ["new"])
    }
}
