// Logging on Linux — the facade's Linux half (WOR-304 S2).
//
// `TkzLogger` has the call shape of `os.Logger` (Darwin/Logging.swift aliases that type on the
// Mac), so the same call sites compile on both OSes: `init(subsystem:category:)`, the six levels,
// and string interpolation that takes `privacy: .public`/`.private`/`.auto`. Redaction follows the
// Mac's defaults, so a line reads the same in `journalctl` as in `log stream`: with `.auto`,
// integers, floating-point numbers and booleans are shown and strings and other dynamic values
// print as `<private>`. `TKZMUX_LOG_PRIVATE=1` reveals them, as a Mac with private data enabled
// would. A redacted value's autoclosure is never evaluated.
//
// Lines go to the journal through the native protocol and to stderr; Journal.swift picks the
// sinks.

#if os(Linux)
import Glibc

/// The privacy of one interpolated value, written `privacy: .public` at the call site like
/// `OSLogPrivacy`.
public enum TkzLogPrivacy: Sendable, Equatable {
    /// Always shown.
    case `public`
    /// Shown only when `TKZMUX_LOG_PRIVATE=1`.
    case `private`
    /// `os.Logger`'s default: scalars are shown, strings and other dynamic values are private.
    case auto
}

/// How `.auto` treats a value: scalars (integers, floating point, booleans) are public, everything
/// else is private.
enum TkzLogValueKind: Sendable, Equatable {
    case scalar
    case dynamic
}

/// The redaction table: whether a value of `kind` interpolated with `privacy` is printed.
/// `revealPrivate` is `TKZMUX_LOG_PRIVATE=1`.
func tkzLogReveals(_ kind: TkzLogValueKind, _ privacy: TkzLogPrivacy, revealPrivate: Bool) -> Bool {
    switch privacy {
    case .public: true
    case .private: revealPrivate
    case .auto: kind == .scalar || revealPrivate
    }
}

/// What a redacted value prints as, as on the Mac.
let tkzLogRedacted = "<private>"

/// A log message: the literal text plus each interpolated value with its privacy. The values stay
/// unevaluated until the line is rendered, and a redacted one is never evaluated.
public struct TkzLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    enum Segment {
        case literal(String)
        case value(() -> String, TkzLogValueKind, TkzLogPrivacy)
    }

    var segments: [Segment]

    public init(stringLiteral value: String) {
        segments = [.literal(value)]
    }

    public init(stringInterpolation: TkzLogInterpolation) {
        segments = stringInterpolation.segments
    }

    /// The text of the line, with values redacted per ``tkzLogReveals(_:_:revealPrivate:)``.
    func rendered(revealPrivate: Bool) -> String {
        var text = ""
        for segment in segments {
            switch segment {
            case .literal(let literal):
                text += literal
            case .value(let value, let kind, let privacy):
                text += tkzLogReveals(kind, privacy, revealPrivate: revealPrivate) ? value() : tkzLogRedacted
            }
        }
        return text
    }
}

/// The interpolation behind ``TkzLogMessage``. The overloads mirror `OSLogInterpolation`'s:
/// concrete ones for `String`, `Int`, `Double`, `Float` and `Bool`, generic ones for other integers
/// and for any `CustomStringConvertible`.
public struct TkzLogInterpolation: StringInterpolationProtocol {
    var segments: [TkzLogMessage.Segment]

    public init(literalCapacity: Int, interpolationCount: Int) {
        segments = []
        segments.reserveCapacity(2 * interpolationCount + 1)
    }

    public mutating func appendLiteral(_ literal: String) {
        guard !literal.isEmpty else { return }
        segments.append(.literal(literal))
    }

    public mutating func appendInterpolation(
        _ value: @autoclosure @escaping () -> String, privacy: TkzLogPrivacy = .auto
    ) {
        segments.append(.value(value, .dynamic, privacy))
    }

    public mutating func appendInterpolation<T: CustomStringConvertible>(
        _ value: @autoclosure @escaping () -> T, privacy: TkzLogPrivacy = .auto
    ) {
        segments.append(.value({ value().description }, .dynamic, privacy))
    }

    public mutating func appendInterpolation(
        _ value: @autoclosure @escaping () -> Int, privacy: TkzLogPrivacy = .auto
    ) {
        segments.append(.value({ String(value()) }, .scalar, privacy))
    }

    public mutating func appendInterpolation<T: BinaryInteger>(
        _ value: @autoclosure @escaping () -> T, privacy: TkzLogPrivacy = .auto
    ) {
        segments.append(.value({ String(value()) }, .scalar, privacy))
    }

    public mutating func appendInterpolation(
        _ value: @autoclosure @escaping () -> Double, privacy: TkzLogPrivacy = .auto
    ) {
        segments.append(.value({ String(value()) }, .scalar, privacy))
    }

    public mutating func appendInterpolation(
        _ value: @autoclosure @escaping () -> Float, privacy: TkzLogPrivacy = .auto
    ) {
        segments.append(.value({ String(value()) }, .scalar, privacy))
    }

    public mutating func appendInterpolation(
        _ value: @autoclosure @escaping () -> Bool, privacy: TkzLogPrivacy = .auto
    ) {
        segments.append(.value({ value() ? "true" : "false" }, .scalar, privacy))
    }
}

/// A log level and its syslog priority (the journal's `PRIORITY` field), matching how the Mac's
/// levels are ordered.
enum TkzLogLevel: Sendable, CaseIterable {
    case debug, info, notice, warning, error, fault

    var priority: Int {
        switch self {
        case .debug: 7  // LOG_DEBUG
        case .info: 6  // LOG_INFO
        case .notice: 5  // LOG_NOTICE
        case .warning: 4  // LOG_WARNING
        case .error: 3  // LOG_ERR
        case .fault: 2  // LOG_CRIT
        }
    }

    var name: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .warning: "warning"
        case .error: "error"
        case .fault: "fault"
        }
    }
}

/// `TKZMUX_LOG_PRIVATE=1`, read once.
let tkzLogRevealsPrivate: Bool = {
    guard let raw = getenv("TKZMUX_LOG_PRIVATE") else { return false }
    return String(cString: raw) == "1"
}()

/// The logger every tkzmux module uses: a journald-backed struct with `os.Logger`'s API on Linux.
public struct TkzLogger: Sendable {
    public let subsystem: String
    public let category: String
    private let sink: LogSink

    public init(subsystem: String, category: String) {
        self.init(subsystem: subsystem, category: category, sink: .shared)
    }

    /// A logger writing to `sink`, for tests.
    init(subsystem: String, category: String, sink: LogSink) {
        self.subsystem = subsystem
        self.category = category
        self.sink = sink
    }

    public func debug(_ message: TkzLogMessage) { log(.debug, message) }
    public func info(_ message: TkzLogMessage) { log(.info, message) }
    public func notice(_ message: TkzLogMessage) { log(.notice, message) }
    public func warning(_ message: TkzLogMessage) { log(.warning, message) }
    public func error(_ message: TkzLogMessage) { log(.error, message) }
    public func fault(_ message: TkzLogMessage) { log(.fault, message) }

    private func log(_ level: TkzLogLevel, _ message: TkzLogMessage) {
        sink.write(level: level, category: category, message: message.rendered(revealPrivate: tkzLogRevealsPrivate))
    }
}
#endif
