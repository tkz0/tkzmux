// UpdateChecker — "is there a newer tkzmux release?" (design 2c.1, TKZ-50).
//
// One GET to GitHub's *latest release* endpoint — the same source the Homebrew cask's `livecheck`
// reads, so a draft or a prerelease is invisible to both — decoded in the forgiving
// `PRLookup.parsePR` style and compared with `AppVersion.isNewer`. Nothing about the user or the
// session leaves the machine: the request carries `Accept` and a `User-Agent` of
// `tkzmux/<version>`, which docs/privacy.md states verbatim.
//
// The transport is injected (`fetch`), so the tests never open a socket, and the URL can be
// overridden with `TKZMUX_UPDATE_URL` — a `file://` fixture works, because a non-HTTP response
// simply has no status code and counts as success. The answer is three-way on purpose: the card
// must *clear* when the server says the running build is current (a withdrawn release) but
// *hold* when the network is down, and one optional cannot say both.

import Foundation
import TkzCore

public final class UpdateChecker: Sendable {

    public enum CheckResult: Sendable, Equatable {
        /// The latest release is not newer than the running build.
        case upToDate
        case available(AvailableUpdate)
        /// Network error, non-200 status, unreadable JSON: keep whatever was known before.
        case unreachable
    }

    /// `(body, HTTP status)`; the status is `nil` for a non-HTTP response such as a `file://` URL.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int?)

    public static let defaultFeedURL = URL(string: "https://api.github.com/repos/tkz0/tkzmux/releases/latest")!
    /// Where "What's new" goes when the feed carried no `html_url`.
    public static let releasesPageURL = "https://github.com/tkz0/tkzmux/releases"
    public static let feedURLKey = "TKZMUX_UPDATE_URL"
    public static let timeout: TimeInterval = 15

    public let feedURL: URL
    public let running: String
    private let fetch: Fetch

    public init(
        feedURL: URL? = nil,
        running: String = AppVersion.current.marketingVersion,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fetch: @escaping Fetch = UpdateChecker.urlSessionFetch
    ) {
        self.feedURL = feedURL
            ?? environment[Self.feedURLKey].flatMap { URL(string: $0) }
            ?? Self.defaultFeedURL
        self.running = running
        self.fetch = fetch
    }

    /// `TKZMUX_UPDATE_URL` is set: a dev build is allowed to check, against whatever it names.
    public static func hasFeedOverride(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[feedURLKey].map { !$0.isEmpty } ?? false
    }

    public func check() async -> CheckResult {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("tkzmux/\(running)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let status: Int?
        do {
            (data, status) = try await fetch(request)
        } catch {
            return .unreachable
        }
        if let status, !(200..<300).contains(status) { return .unreachable }
        return Self.evaluate(data, running: running)
    }

    /// The pure part: bytes in, verdict out.
    public static func evaluate(_ data: Data, running: String) -> CheckResult {
        guard let latest = parseLatest(data) else { return .unreachable }
        guard AppVersion.isNewer(latest.tag, than: running) else { return .upToDate }
        var version = latest.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return .available(AvailableUpdate(version: version, releaseURL: latest.url ?? releasesPageURL))
    }

    /// `tag_name` and `html_url` out of a GitHub release object; `nil` unless it is one.
    public static func parseLatest(_ data: Data) -> (tag: String, url: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let url = (json["html_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (tag, url)
    }

    /// The real transport: an ephemeral session — no cookies, no cache, nothing on disk.
    public static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode)
    }

    private static let session = URLSession(configuration: .ephemeral)
}
