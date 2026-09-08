// tkzmux — the app's entry point (M0.1 / TKZ-5), plus the `--version` intercept (M6.1 / TKZ-37).
//
// `TkzAppMain.run()` touches `NSApplication.shared` on its first line, which connects to the window
// server and never returns. Anything that must work headlessly — a version banner piped into a bug
// report, or run over ssh — has to happen **above** that call, which is why the intercept lives
// here rather than in TkzApp.
//
// `swift run tkzmux --version` works as written (verified: SwiftPM forwards it rather than
// claiming it for itself); `swift run tkzmux -- --version` and `.build/debug/tkzmux --version` are
// equivalent. `-v` is accepted as the usual short spelling.
//
// A *scan* rather than a match on argv[1], so the flag still wins if the app ever grows options
// before it — printing a version is always safe, and never printing one is the confusing failure.

import Foundation
import TkzApp
import TkzCore

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
    print(AppVersion.current.description)
    exit(0)
}

TkzAppMain.run()
