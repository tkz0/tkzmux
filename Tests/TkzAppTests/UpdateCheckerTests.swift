// UpdateCheckerTests — the release check, offline (TKZ-50).
//
// The transport is a closure, so every case here is a canned `(Data, status)` and no socket is
// ever opened. The three-way result is the contract: `available` shows the card, `upToDate`
// clears it, `unreachable` leaves whatever was known alone.

import Foundation
import Synchronization
import Testing
import TkzCore

@testable import TkzApp

@Suite struct UpdateCheckerTests {
    static let feed = URL(string: "https://example.invalid/latest")!

    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func checker(running: String = "0.7.0", status: Int? = 200, body: Data, sawRequest: (@Sendable (URLRequest) -> Void)? = nil) -> UpdateChecker {
        UpdateChecker(feedURL: feed, running: running, environment: [:]) { request in
            sawRequest?(request)
            return (body, status)
        }
    }

    @Test("A newer tag is available, with its release page and the `v` stripped")
    func newerTag() async {
        let body = Self.json(["tag_name": "v0.8.0", "html_url": "https://github.com/tkz0/tkzmux/releases/tag/v0.8.0"])
        let result = await Self.checker(body: body).check()
        #expect(result == .available(AvailableUpdate(
            version: "0.8.0", releaseURL: "https://github.com/tkz0/tkzmux/releases/tag/v0.8.0")))
    }

    @Test("The same or an older tag is up to date")
    func sameOrOlder() async {
        let same = await Self.checker(body: Self.json(["tag_name": "v0.7.0"])).check()
        #expect(same == .upToDate)
        let older = await Self.checker(body: Self.json(["tag_name": "v0.6.2"])).check()
        #expect(older == .upToDate)
        // A dev build is a prerelease of its tag, so the tag counts as newer (semver); a dev build
        // never checks unless pointed at a feed, so this only matters for the fixture path.
        let dev = await Self.checker(running: "0.7.0-dev.4+abc1234", body: Self.json(["tag_name": "v0.7.0"])).check()
        #expect(dev == .available(AvailableUpdate(version: "0.7.0", releaseURL: UpdateChecker.releasesPageURL)))
        let devOlder = await Self.checker(running: "0.7.0-dev.4+abc1234", body: Self.json(["tag_name": "v0.6.9"])).check()
        #expect(devOlder == .upToDate)
    }

    @Test("Errors, non-2xx and malformed bodies are unreachable — never a throw, never a card")
    func unreachable() async {
        let good = Self.json(["tag_name": "v9.9.9"])
        #expect(await Self.checker(status: 404, body: good).check() == .unreachable)
        #expect(await Self.checker(status: 500, body: good).check() == .unreachable)
        #expect(await Self.checker(body: Data("not json".utf8)).check() == .unreachable)
        #expect(await Self.checker(body: Self.json(["message": "Not Found"])).check() == .unreachable)
        struct Boom: Error {}
        let throwing = UpdateChecker(feedURL: Self.feed, running: "0.7.0", environment: [:]) { _ in throw Boom() }
        #expect(await throwing.check() == .unreachable)
    }

    @Test("A tag that is not a version is up to date, not available")
    func unparsableTagIsNotOffered() {
        // `isNewer` fails closed, so garbage can never raise the card.
        #expect(UpdateChecker.evaluate(Self.json(["tag_name": "latest"]), running: "0.7.0") == .upToDate)
    }

    @Test("A non-HTTP response (the file:// fixture) has no status and counts as success")
    func fileFixture() async {
        let body = Self.json(["tag_name": "v9.9.9"])
        let result = await Self.checker(status: nil, body: body).check()
        #expect(result == .available(AvailableUpdate(version: "9.9.9", releaseURL: UpdateChecker.releasesPageURL)))
    }

    @Test("The request carries only Accept and a tkzmux User-Agent, and never uses the cache")
    func headers() async throws {
        let body = Self.json(["tag_name": "v0.7.0"])
        let captured = Mutex<URLRequest?>(nil)
        let checker = UpdateChecker(feedURL: Self.feed, running: "0.7.0", environment: [:]) { request in
            captured.withLock { $0 = request }
            return (body, 200)
        }
        _ = await checker.check()
        let request = try #require(captured.withLock { $0 })
        #expect(request.url == Self.feed)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "tkzmux/0.7.0")
        #expect(request.allHTTPHeaderFields?.count == 2)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == UpdateChecker.timeout)
    }

    @Test("TKZMUX_UPDATE_URL overrides the feed and lets a dev build check")
    func environmentOverride() {
        let env = ["TKZMUX_UPDATE_URL": "file:///tmp/latest.json"]
        let checker = UpdateChecker(running: "0.0.0-dev", environment: env) { _ in (Data(), nil) }
        #expect(checker.feedURL == URL(string: "file:///tmp/latest.json"))
        #expect(UpdateChecker.hasFeedOverride(env))
        #expect(!UpdateChecker.hasFeedOverride([:]))
        #expect(!UpdateChecker.hasFeedOverride(["TKZMUX_UPDATE_URL": ""]))
        let plain = UpdateChecker(running: "0.7.0", environment: [:]) { _ in (Data(), nil) }
        #expect(plain.feedURL == UpdateChecker.defaultFeedURL)

        let release = AppVersion(marketingVersion: "0.7.0", build: "1", ghosttyCommit: "x")
        let dev = AppVersion(marketingVersion: "0.7.0-dev.4+abc", build: "1", ghosttyCommit: "x")
        #expect(UpdateIntegration.shouldRun(version: release, environment: [:]))
        #expect(!UpdateIntegration.shouldRun(version: dev, environment: [:]))
        #expect(UpdateIntegration.shouldRun(version: dev, environment: env))
    }
}
