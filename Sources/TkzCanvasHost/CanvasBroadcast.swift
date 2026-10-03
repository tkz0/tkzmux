// CanvasBroadcast — one value stream, any number of subscribers (WOR-314 S4).
//
// A host's visibility and input streams: each `subscribe()` returns its own `AsyncStream`, and
// `send` yields to all of them. A subscriber that stops iterating is forgotten; `finish` (and the
// broadcast going away) ends every stream. Main actor, like the hosts.

@MainActor
public final class CanvasBroadcast<Element: Sendable> {
    private var continuations: [Int: AsyncStream<Element>.Continuation] = [:]
    private var nextID = 0

    public init() {}

    /// How many subscribers are listening.
    public var subscriberCount: Int { continuations.count }

    /// A stream of every element sent from now on. Up to `buffer` unread elements are kept, the
    /// newest first.
    public func subscribe(buffer: Int = 64) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(buffer))
        let id = nextID
        nextID += 1
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    public func send(_ element: Element) {
        for continuation in continuations.values { continuation.yield(element) }
    }

    /// Ends every stream.
    public func finish() {
        let ending = continuations.values
        continuations = [:]
        for continuation in ending { continuation.finish() }
    }

    isolated deinit {
        for continuation in continuations.values { continuation.finish() }
    }
}
