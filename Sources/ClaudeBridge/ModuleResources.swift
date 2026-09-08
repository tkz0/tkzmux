// ModuleResources.swift — how this module finds its resource bundle in every context.
//
// **Do not replace this with `Bundle.module`.** SwiftPM's generated accessor looks in exactly two
// places: `Bundle.main.bundleURL/<name>.bundle` — the *root* of the `.app`, not `Contents/Resources`
// — and an absolute `.build/…` path that masks the bug on the machine that built it. But
// `codesign --strict` rejects anything except `Contents` at an app-bundle root ("unsealed contents
// present in the bundle root"), and that was confirmed for a bundle at the root, a symlink at the
// root, and a pre-signed bundle carrying its own Info.plist. The two rules are irreconcilable, so
// `Bundle.module` **fatalErrors inside build/tkzmux.app** (verified M1.9 / TKZ-15). See
// `Sources/TkzTerminalCore/ModuleResources.swift`, which this mirrors exactly.
//
// `Bundle.main.resourceURL` is `Contents/Resources` in an `.app` and the executable's own directory
// under `swift run`, so it covers both. `Bundle.module` is evaluated **last** and only as the
// `swift test` path — note that anything written *after* it is dead code, because it is a
// `static let` that traps rather than returning nil.
import Foundation

enum ModuleResources {
    static let bundle: Bundle = {
        let name = "tkzmux_ClaudeBridge.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
}
