// RunTaskDetector — what the toolbar's ▶ Run button offers for a project root.
//
// The fixtures are trimmed copies of real projects: a pnpm monorepo root whose `dev` orchestrates
// the rest, an npm app with no `packageManager`, a Create React App with no `dev` at all, and a
// justfile whose dev entry point is `up`. The best guess for each is what a person would type.

import Foundation
import Testing

@testable import TkzCore

@Suite struct RunTasksTests {
    // MARK: Fixtures

    static let pnpmMonorepo = """
        {
          "name": "coreinvest",
          "packageManager": "pnpm@11.13.1",
          "scripts": {
            "dev": "node scripts/dev.mjs",
            "dev:api": "dotnet watch run --project api/src/CoreInvest.Api",
            "dev:web": "pnpm --dir web dev",
            "setup": "pnpm install",
            "db:up": "node scripts/dev-db.mjs up",
            "loadtest": "node scripts/loadtest.mjs"
          }
        }
        """

    static let npmElectron = """
        {
          "name": "dash",
          "scripts": {
            "dev": "electron-vite dev",
            "build": "electron-vite build",
            "preview": "electron-vite preview"
          }
        }
        """

    static let createReactApp = """
        {
          "name": "web",
          "scripts": {
            "start": "react-scripts start",
            "build": "react-scripts build",
            "test": "react-scripts test",
            "postbuild": "cp a b",
            "postinstall": "cp a b"
          }
        }
        """

    static let justfile = """
        # Development orchestration
        set dotenv-load
        set shell := ["bash", "-cu"]
        project := "workamo"

        # Default: show available recipes
        default:
            @just --list

        # Start the full stack
        up: _clear-pids db _wait-db _api-bg _worker-bg
            cd workamo-web && npm start

        down:
            docker compose down

        db:
            docker compose up -d db

        api: db _wait-db _build
            cd workamo-api && dotnet run

        test filter='':
            dotnet test --filter '{{filter}}'

        [private]
        hidden:
            echo no

        _clear-pids:
            rm -f .pids
        """

    // MARK: package.json

    @Test func pnpmMonorepoRunsDevAndListsEveryScript() {
        let tasks = RunTaskDetector.detect(files: ["package.json": Self.pnpmMonorepo])
        #expect(RunTaskDetector.bestGuess(in: tasks) == "pnpm dev")
        #expect(tasks.map(\.command).contains("pnpm dev:web"))
        #expect(tasks.map(\.command).contains("pnpm dev:api"))
        #expect(tasks.map(\.command).contains("pnpm db:up"))
        #expect(tasks.allSatisfy { $0.source == .packageJSON })
    }

    /// No `packageManager` and no lockfile: npm, which needs `run` for anything but its built-ins.
    @Test func noPackageManagerFallsBackToNpmRun() {
        let tasks = RunTaskDetector.detect(files: ["package.json": Self.npmElectron])
        #expect(RunTaskDetector.bestGuess(in: tasks) == "npm run dev")
        #expect(tasks.map(\.command).contains("npm run preview"))
    }

    /// CRA has no `dev`; `start` is next, and npm spells that one without `run`. Lifecycle hooks
    /// (`postbuild`, `postinstall`) are noise nobody runs by hand.
    @Test func createReactAppStartsWithNpmStart() {
        let tasks = RunTaskDetector.detect(files: ["package.json": Self.createReactApp])
        #expect(RunTaskDetector.bestGuess(in: tasks) == "npm start")
        #expect(tasks.map(\.command).contains("npm test"))
        #expect(tasks.map(\.name).contains("postbuild") == false)
        #expect(tasks.map(\.name).contains("postinstall") == false)
    }

    @Test(arguments: [
        ("pnpm-lock.yaml", "pnpm dev"),
        ("yarn.lock", "yarn dev"),
        ("bun.lock", "bun run dev"),
        ("bun.lockb", "bun run dev"),
        ("package-lock.json", "npm run dev"),
    ])
    func lockfilePicksTheRunner(lockfile: String, expected: String) {
        let tasks = RunTaskDetector.detect(files: ["package.json": Self.npmElectron, lockfile: ""])
        #expect(RunTaskDetector.bestGuess(in: tasks) == expected)
    }

    /// `packageManager` outranks a stray lockfile: it is the project's own declaration.
    @Test func packageManagerFieldBeatsLockfile() {
        let tasks = RunTaskDetector.detect(files: [
            "package.json": Self.pnpmMonorepo, "package-lock.json": "",
        ])
        #expect(RunTaskDetector.bestGuess(in: tasks) == "pnpm dev")
    }

    /// `pnpm up` is `pnpm update`, not the `up` script — names that collide with a built-in get `run`.
    @Test func builtinCollisionsGetRun() {
        let json = #"{"packageManager":"pnpm@9","scripts":{"up":"docker compose up","install":"x"}}"#
        let tasks = RunTaskDetector.detect(files: ["package.json": json])
        #expect(tasks.map(\.command).contains("pnpm run up"))
        #expect(RunTaskDetector.bestGuess(in: tasks) == "pnpm run up")
    }

    @Test func scriptNamesWithShellCharactersAreQuoted() {
        let json = #"{"scripts":{"dev web":"x","ok:name/with-@.+_":"y"}}"#
        let tasks = RunTaskDetector.detect(files: ["package.json": json])
        #expect(tasks.map(\.command).contains("npm run 'dev web'"))
        #expect(tasks.map(\.command).contains("npm run ok:name/with-@.+_"))
    }

    @Test func malformedPackageJSONIsIgnored() {
        #expect(RunTaskDetector.detect(files: ["package.json": "{ not json"]).isEmpty)
        #expect(RunTaskDetector.detect(files: ["package.json": #"{"name":"x"}"#]).isEmpty)
    }

    // MARK: Task runners

    @Test func justfileRecipesSkipPrivateAndDefault() {
        let tasks = RunTaskDetector.detect(files: ["justfile": Self.justfile])
        #expect(tasks.map(\.name) == ["up", "down", "db", "api", "test"])
        #expect(tasks.first?.command == "just up")
        #expect(RunTaskDetector.bestGuess(in: tasks) == "just up")
    }

    @Test func makefileTargetsSkipSpecialsFilesAndVariables() {
        let makefile = """
            SIGN_IDENTITY ?= -
            VERSION := $(shell git describe)
            .PHONY: app clean dev

            app: build/tkzmux.app
            build/tkzmux.app: Package.swift
            \tswift build
            dev:
            \tswift run
            clean:
            \trm -rf .build
            %.o: %.c
            \tcc $<
            """
        let tasks = RunTaskDetector.detect(files: ["Makefile": makefile])
        #expect(tasks.map(\.name) == ["app", "dev", "clean"])
        #expect(RunTaskDetector.bestGuess(in: tasks) == "make dev")
    }

    @Test func taskfileTopLevelTasks() {
        let taskfile = """
            version: '3'
            vars:
              NAME: x
            tasks:
              dev:
                cmds:
                  - go run .
              "build:web":
                cmds: [npm run build]
            includes:
              docs: ./docs
            """
        let tasks = RunTaskDetector.detect(files: ["Taskfile.yml": taskfile])
        #expect(tasks.map(\.command) == ["task dev", "task build:web"])
    }

    @Test func denoTasks() {
        let tasks = RunTaskDetector.detect(files: [
            "deno.json": #"{"tasks":{"dev":"deno run -A main.ts","check":"deno check"}}"#,
        ])
        #expect(RunTaskDetector.bestGuess(in: tasks) == "deno task dev")
    }

    // MARK: One-liners

    @Test(arguments: [
        ("Cargo.toml", "cargo run"),
        ("go.mod", "go run ."),
        ("Package.swift", "swift run"),
        ("Api.csproj", "dotnet watch run"),
        ("manage.py", "python manage.py runserver"),
        ("bin/dev", "bin/dev"),
        ("compose.yaml", "docker compose up"),
        ("docker-compose.yml", "docker compose up"),
    ])
    func oneLiners(file: String, expected: String) {
        let tasks = RunTaskDetector.detect(files: [file: ""])
        #expect(tasks.map(\.command) == [expected])
        #expect(RunTaskDetector.bestGuess(in: tasks) == expected)
    }

    // MARK: Ranking

    /// A `dev` script beats the language default and compose; `up` beats compose.
    @Test func rankingAcrossSources() {
        let both = RunTaskDetector.detect(files: [
            "package.json": Self.npmElectron, "docker-compose.yml": "", "Cargo.toml": "",
        ])
        #expect(RunTaskDetector.bestGuess(in: both) == "npm run dev")

        let justAndCompose = RunTaskDetector.detect(files: [
            "justfile": Self.justfile, "docker-compose.yml": "",
        ])
        #expect(RunTaskDetector.bestGuess(in: justAndCompose) == "just up")

        let swiftAndMake = RunTaskDetector.detect(files: [
            "Package.swift": "", "Makefile": "app:\n\tswift build\nclean:\n\trm -rf .build\n",
        ])
        #expect(RunTaskDetector.bestGuess(in: swiftAndMake) == "swift run")
    }

    /// Only build/test-style scripts: nothing is a dev server, so there is no guess — the button
    /// opens its menu instead of running `pnpm build`.
    @Test func noDevLikeTaskMeansNoGuess() {
        let json = #"{"packageManager":"pnpm@9","scripts":{"build":"tsc","test":"vitest"}}"#
        let tasks = RunTaskDetector.detect(files: ["package.json": json])
        #expect(tasks.count == 2)
        #expect(RunTaskDetector.bestGuess(in: tasks) == nil)
    }

    /// The group's remembered command always wins, even when it is not a detected task.
    @Test func rememberedCommandWins() {
        let tasks = RunTaskDetector.detect(files: ["package.json": Self.pnpmMonorepo])
        #expect(RunTaskDetector.bestGuess(in: tasks, remembered: "pnpm dev:web") == "pnpm dev:web")
        #expect(RunTaskDetector.bestGuess(in: [], remembered: "dotnet watch run --project Api") ==
            "dotnet watch run --project Api")
        #expect(RunTaskDetector.bestGuess(in: tasks, remembered: "  ") == "pnpm dev")
    }

    @Test func emptyDirectoryHasNothing() {
        #expect(RunTaskDetector.detect(files: [:]).isEmpty)
        #expect(RunTaskDetector.bestGuess(in: []) == nil)
    }

    // MARK: Disk

    /// The disk reader lists the root, loads only manifests and treats the rest as presence.
    @Test func readsADirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkz-runtasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.npmElectron.write(
            to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("yarn.lock"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("bin/dev"), atomically: true, encoding: .utf8)

        let tasks = RunTaskDetector.detect(inDirectory: root.path)
        #expect(tasks.map(\.command).contains("yarn dev"))
        #expect(tasks.map(\.command).contains("bin/dev"))
        #expect(RunTaskDetector.detect(inDirectory: root.path + "/missing").isEmpty)
    }
}
