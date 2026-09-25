// RunTasks — what the toolbar's ▶ Run button can start in a project root.
//
// Detection reads only the root of the row's own checkout — for a worktree, the worktree, never
// the main checkout — and never recurses: a monorepo's root script is what orchestrates the rest
// (`pnpm dev` → turbo, `just up` → db + api + web). The parsers are line scans and
// `JSONSerialization`, not full grammars; a manifest they cannot read contributes nothing rather
// than failing the whole detection.
//
// `detect(files:)` is pure — a map of root entry names to contents — so the tests need no disk;
// `detect(inDirectory:)` is the thin reader the app calls.

import Foundation

/// One runnable thing in a project root: a `package.json` script, a `just` recipe, `cargo run`.
public struct RunTask: Hashable, Sendable, Identifiable {
    public enum Source: String, Hashable, Sendable {
        case packageJSON, deno, just, make, taskfile
        case cargo, go, swift, dotnet, django, binDev, compose
    }

    /// The script, recipe or target name — the menu's left column. One-liners use their tool.
    public var name: String
    /// The line typed into the shell, e.g. `pnpm dev`. Unique within one detection.
    public var command: String
    public var source: Source

    public var id: String { command }

    public init(name: String, command: String, source: Source) {
        self.name = name
        self.command = command
        self.source = source
    }
}

public enum RunTaskDetector {
    /// Root entries whose *contents* detection reads. Everything else only has to exist.
    public static let manifestNames: Set<String> = [
        "package.json", "deno.json", "deno.jsonc", "justfile", "Justfile", ".justfile",
        "Makefile", "makefile", "GNUmakefile", "Taskfile.yml", "Taskfile.yaml",
    ]

    /// A manifest bigger than this is not read. Real ones are a few KB.
    static let maxManifestBytes = 256 * 1024

    // MARK: Detection

    /// Every task found in a root, grouped by source in a fixed order, each source's entries in
    /// file order (JSON objects: alphabetical, since `JSONSerialization` keeps no order).
    ///
    /// `files` maps a root entry name to its contents; entries detection only needs to *see*
    /// (lockfiles, `Cargo.toml`, `*.csproj`) can map to `""`. `bin/dev` is the one nested path.
    public static func detect(files: [String: String]) -> [RunTask] {
        var out: [RunTask] = []
        if let json = files["package.json"] { out += packageScripts(json, files: files) }
        if let json = files["deno.json"] ?? files["deno.jsonc"] { out += denoTasks(json) }
        if let text = files["justfile"] ?? files["Justfile"] ?? files[".justfile"] {
            out += justRecipes(text)
        }
        if let text = files["Makefile"] ?? files["makefile"] ?? files["GNUmakefile"] {
            out += makeTargets(text)
        }
        if let text = files["Taskfile.yml"] ?? files["Taskfile.yaml"] { out += taskfileTasks(text) }

        func oneLiner(_ name: String, _ command: String, _ source: RunTask.Source) {
            out.append(RunTask(name: name, command: command, source: source))
        }
        if files["bin/dev"] != nil { oneLiner("bin/dev", "bin/dev", .binDev) }
        if files["Cargo.toml"] != nil { oneLiner("cargo", "cargo run", .cargo) }
        if files["go.mod"] != nil { oneLiner("go", "go run .", .go) }
        if files["Package.swift"] != nil { oneLiner("swift", "swift run", .swift) }
        if files.keys.contains(where: { $0.hasSuffix(".csproj") }) {
            oneLiner("dotnet", "dotnet watch run", .dotnet)
        }
        if files["manage.py"] != nil { oneLiner("django", "python manage.py runserver", .django) }
        let composeFiles = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
        if composeFiles.contains(where: { files[$0] != nil }) {
            oneLiner("compose", "docker compose up", .compose)
        }

        var seen = Set<String>()
        return out.filter { seen.insert($0.command).inserted }
    }

    /// `detect(files:)` over a directory on disk. A missing or unreadable directory has no tasks.
    public static func detect(inDirectory directory: String) -> [RunTask] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var files: [String: String] = [:]
        for name in names {
            guard manifestNames.contains(name) else {
                files[name] = ""
                continue
            }
            let path = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                (attributes[.size] as? Int ?? 0) <= maxManifestBytes,
                let text = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }
            files[name] = text
        }
        if fm.fileExists(atPath: (directory as NSString).appendingPathComponent("bin/dev")) {
            files["bin/dev"] = ""
        }
        return detect(files: files)
    }

    // MARK: Best guess

    /// What ▶ runs: the group's remembered command when there is one, else the most dev-server-like
    /// task, else `nil` — a root with only `build`/`test` gets a menu, not a guess.
    public static func bestGuess(in tasks: [RunTask], remembered: String? = nil) -> String? {
        if let remembered = remembered?.trimmingCharacters(in: .whitespaces), !remembered.isEmpty {
            return remembered
        }
        return tasks.enumerated()
            .compactMap { index, task in rank(task).map { (rank: $0, index: index, task: task) } }
            .min { ($0.rank, $0.index) < ($1.rank, $1.index) }?
            .task.command
    }

    /// Lower is better; `nil` = never a guess. Ties go to source order, then file order.
    static func rank(_ task: RunTask) -> Int? {
        switch task.source {
        case .packageJSON, .deno, .just, .make, .taskfile:
            ["dev", "start", "serve", "up", "run"].firstIndex(of: task.name)
        case .binDev: 0
        case .cargo, .go, .swift, .dotnet, .django: 5
        case .compose: 6
        }
    }

    // MARK: package.json

    /// Lifecycle hooks npm runs by itself; nobody starts them by hand.
    static let lifecycleScripts: Set<String> = [
        "preinstall", "install", "postinstall", "prepare", "prepublish", "prepublishOnly",
        "prepack", "postpack", "preversion", "version", "postversion", "dependencies",
    ]

    /// Names the runner treats as its own command, so `pnpm up` would *update*. These get `run`.
    static let runnerBuiltins: Set<String> = [
        "add", "audit", "bin", "cache", "config", "create", "dedupe", "deploy", "dlx", "env", "exec",
        "fetch", "help", "i", "import", "info", "init", "install", "link", "list", "ls", "outdated",
        "pack", "patch", "prune", "publish", "rebuild", "remove", "rm", "root", "run", "server",
        "setup", "store", "unlink", "up", "update", "upgrade", "version", "why", "workspace",
        "workspaces",
    ]

    enum Runner: String { case npm, pnpm, yarn, bun }

    static func runner(packageManager: String?, files: [String: String]) -> Runner {
        if let packageManager, let name = packageManager.split(separator: "@").first,
            let runner = Runner(rawValue: String(name))
        {
            return runner
        }
        if files["pnpm-lock.yaml"] != nil { return .pnpm }
        if files["yarn.lock"] != nil { return .yarn }
        if files["bun.lock"] != nil || files["bun.lockb"] != nil { return .bun }
        return .npm
    }

    static func command(runner: Runner, script: String) -> String {
        let quoted = shellWord(script)
        switch runner {
        case .npm:
            // npm runs only these without `run`; everything else would be an npm subcommand.
            return ["start", "test", "stop", "restart"].contains(script)
                ? "npm \(script)" : "npm run \(quoted)"
        case .bun:
            return "bun run \(quoted)"
        case .pnpm, .yarn:
            return runnerBuiltins.contains(script)
                ? "\(runner.rawValue) run \(quoted)" : "\(runner.rawValue) \(quoted)"
        }
    }

    static func packageScripts(_ json: String, files: [String: String]) -> [RunTask] {
        guard let object = jsonObject(json),
            let scripts = object["scripts"] as? [String: Any]
        else { return [] }
        let runner = runner(packageManager: object["packageManager"] as? String, files: files)
        let names = scripts.keys.sorted()
        let present = Set(names)
        return names.compactMap { name in
            guard !lifecycleScripts.contains(name), !isPrePostHook(name, of: present) else { return nil }
            return RunTask(name: name, command: command(runner: runner, script: name), source: .packageJSON)
        }
    }

    /// `prebuild`/`postbuild` run around `build` automatically.
    static func isPrePostHook(_ name: String, of names: Set<String>) -> Bool {
        for prefix in ["pre", "post"] where name.hasPrefix(prefix) {
            if names.contains(String(name.dropFirst(prefix.count))) { return true }
        }
        return false
    }

    // MARK: deno.json

    static func denoTasks(_ json: String) -> [RunTask] {
        guard let tasks = jsonObject(json)?["tasks"] as? [String: Any] else { return [] }
        return tasks.keys.sorted().map {
            RunTask(name: $0, command: "deno task \(shellWord($0))", source: .deno)
        }
    }

    // MARK: justfile

    /// Recipes are unindented `name [params…]:` lines. Skipped: `_private` names, recipes under a
    /// `[private]` attribute, `default` (conventionally `just --list`), settings, aliases and
    /// `:=` assignments.
    static func justRecipes(_ text: String) -> [RunTask] {
        let recipe = justRecipe
        var out: [RunTask] = []
        var privateNext = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard let first = line.first, first != " ", first != "\t", first != "#" else { continue }
            if line.hasPrefix("[") {
                if line.contains("private") { privateNext = true }
                continue
            }
            let keyword = line.prefix { $0 != " " }
            if ["set", "alias", "export", "import", "mod"].contains(String(keyword)) { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = recipe.firstMatch(in: line, range: range),
                let nameRange = Range(match.range(at: 1), in: line)
            else { continue }
            let name = String(line[nameRange])
            defer { privateNext = false }
            guard !privateNext, !name.hasPrefix("_"), name != "default" else { continue }
            out.append(RunTask(name: name, command: "just \(name)", source: .just))
        }
        return out
    }

    // MARK: Makefile

    /// Plain unindented `target:` rules. Skipped: `.PHONY` and other dot-specials, pattern rules,
    /// file targets (a `/` or `.` in the name), multi-target rules and variable assignments.
    static func makeTargets(_ text: String) -> [RunTask] {
        let rule = makeRule
        var out: [RunTask] = []
        var seen = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = rule.firstMatch(in: line, range: range),
                let nameRange = Range(match.range(at: 1), in: line)
            else { continue }
            let name = String(line[nameRange])
            guard seen.insert(name).inserted else { continue }
            out.append(RunTask(name: name, command: "make \(name)", source: .make))
        }
        return out
    }

    // MARK: Taskfile.yml

    /// The keys directly under the top-level `tasks:` mapping, at whatever indent the first one uses.
    static func taskfileTasks(_ text: String) -> [RunTask] {
        var out: [RunTask] = []
        var inTasks = false
        var indent: Int?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let leading = line.prefix { $0 == " " }.count
            if leading == 0 {
                inTasks = trimmed == "tasks:"
                continue
            }
            guard inTasks else { continue }
            if indent == nil { indent = leading }
            guard leading == indent else { continue }
            let name: String
            if let quote = trimmed.first, quote == "\"" || quote == "'" {
                // A quoted key keeps its own colons: `"build:web":`.
                let body = trimmed.dropFirst()
                guard let close = body.firstIndex(of: quote) else { continue }
                name = String(body[..<close])
            } else {
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                name = String(trimmed[..<colon])
            }
            guard !name.isEmpty else { continue }
            out.append(RunTask(name: name, command: "task \(shellWord(name))", source: .taskfile))
        }
        return out
    }

    // MARK: Helpers

    // Constant patterns, so `try!` can only fail on a typo the tests would catch at once.
    static let justRecipe = try! NSRegularExpression(
        pattern: #"^([A-Za-z_][A-Za-z0-9_-]*)(\s[^:]*)?:(?!=)"#)
    static let makeRule = try! NSRegularExpression(
        pattern: #"^([A-Za-z0-9][A-Za-z0-9_-]*)\s*:(?![:=])"#)

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `name` as one shell word: as-is when it is made only of characters no shell treats
    /// specially, else single-quoted.
    static func shellWord(_ name: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:._-/@+")
        if !name.isEmpty, name.unicodeScalars.allSatisfy(safe.contains) { return name }
        return "'" + name.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
