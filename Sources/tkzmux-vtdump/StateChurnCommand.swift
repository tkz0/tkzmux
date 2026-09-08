// StateChurnCommand — the crash-safety harness for `state.json` (M5.1 / TKZ-29).
//
//   tkzmux-vtdump state-churn <dir> [--iterations n] [--seed n]
//
// The ticket's acceptance is "a loop that mutates and sends SIGKILL at random points 50 times never
// produces an unparsable state.json". That cannot be a unit test — it needs a process to kill —
// and it follows the precedent `SnapshotsTests` already set for the snapshot round trip: the real
// thing runs in a harness and the measured result goes into docs/.
//
// This subcommand *is* that process. It mutates an `AppState` and saves it as fast as it can, so a
// SIGKILL at a uniformly random moment is overwhelmingly likely to land inside a save. It prints
// nothing on the happy path; `scripts/state-crash-test.sh` kills it and inspects what survived.

import Foundation
import Persistence
import TkzCore

enum StateChurnCommand {
    static func run(_ argv: [String]) throws {
        let arguments = Arguments(argv, valueFlags: ["iterations", "seed"])
        guard let directory = arguments.positionals.first else {
            fail("tkzmux-vtdump state-churn: missing <dir>", code: 2)
        }
        let iterations = Int(arguments.value("iterations") ?? "") ?? Int.max
        var generator = SplitMix64(seed: UInt64(arguments.value("seed") ?? "") ?? 0x5EED)

        let base = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = StateFile(url: base.appending(path: "state.json", directoryHint: .notDirectory))

        var state = AppState()
        var groupIDs = [state.addGroup(name: "churn", repoRoot: "/tmp").id]

        // Whatever was already there is the starting point: the script uses that to set up the
        // recovery states that matter, in particular "primary missing, .bak present".
        file.load().document?.state.apply(to: &state)

        for step in 0..<iterations {
            switch Int(generator.next() % 6) {
            case 0:
                groupIDs.append(state.addGroup(name: "g\(step)", repoRoot: "/tmp/\(step)").id)
            case 1 where !groupIDs.isEmpty:
                let target = groupIDs[Int(generator.next() % UInt64(groupIDs.count))]
                _ = state.createSession(groupID: target, cwd: "/tmp/\(step)", title: "s\(step)")
            case 2:
                if let target = state.orderedSessions.first?.id { state.removeSession(target) }
            case 3:
                state.select(state.orderedSessions.last?.id)
            case 4:
                state.sidebarWidth = CGFloat(240 + step % 200)
                state.setSidebarVisible(step % 2 == 0)
            default:
                state.windowFrame = CGRect(
                    x: Double(step % 50), y: Double(step % 40),
                    width: 900 + Double(step % 300), height: 600 + Double(step % 200))
            }
            try file.save(StateDocument(state: PersistedState(state)))
        }
    }
}

/// Reproducible, and small enough to need no explanation: the seed is printed by the script so a
/// failure can be replayed exactly.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
