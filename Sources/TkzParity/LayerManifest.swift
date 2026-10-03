// LayerManifest — `Tests/Parity/layers.json`, the state of every parity layer (WOR-322 S1).
//
// One row per layer and scale (ADR-0003 §3): L0 split into `L0-component` and `L0-window`, then
// L1–L6, each at 1.6 and 2.0. A row is `pending` (no producer gates it yet; the runner reports it
// and does not fail) or `enforced` (its producer runs and its threshold gates CI). Every row names
// the issue that owns it, and the issue that lands a producer switches its own rows. WOR-324 S5
// finally checks that every row is `enforced` or an approved ADR-0003 exception.
//
// `owner` is a Linear issue, `WOR-312`, optionally with its session, `WOR-318 S7`, or a range of
// issues that share the layer, `WOR-316–WOR-319` (an en dash, as the ADR writes it).

import Foundation

public struct LayerManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    /// The layers, in the ADR's order.
    public static let layers = ["L0-component", "L0-window", "L1", "L2", "L3", "L4", "L5", "L6"]
    /// The gated scales (ADR-0003 §1: both are gated).
    public static let scales = [1.6, 2.0]

    public enum State: String, Codable, Sendable {
        case pending
        case enforced
    }

    public struct Row: Codable, Equatable, Sendable {
        public var layer: String
        public var scale: Double
        public var state: State
        public var owner: String
        /// What the row compares, for a reader. Optional.
        public var what: String?

        public init(layer: String, scale: Double, state: State, owner: String, what: String? = nil) {
            self.layer = layer
            self.scale = scale
            self.state = state
            self.owner = owner
            self.what = what
        }
    }

    public var schema: Int
    public var about: String?
    public var rows: [Row]

    public init(rows: [Row], about: String? = nil) {
        self.schema = Self.schemaVersion
        self.about = about
        self.rows = rows
    }

    public static func decode(_ data: Data) throws -> LayerManifest {
        try JSONDecoder().decode(LayerManifest.self, from: data)
    }

    /// `WOR-n`, `WOR-n Sk` (an optional letter after the session: `S4b`) or `WOR-a–WOR-b`.
    static var ownerPattern: Regex<(Substring, Substring, Substring?)> {
        #/^WOR-([0-9]+)(?: S[0-9]+[a-z]?)?(?:–WOR-([0-9]+))?$/#
    }

    /// Whether `owner` names an issue. A range must ascend.
    public static func isValidOwner(_ owner: String) -> Bool {
        guard let match = owner.wholeMatch(of: ownerPattern), let first = Int(match.1) else { return false }
        if let last = match.2 { return Int(last).map { $0 > first } ?? false }
        return true
    }

    /// Everything wrong with the manifest, one line each; empty when it is valid.
    public func problems() -> [String] {
        var problems: [String] = []
        if schema != Self.schemaVersion {
            problems.append("schema \(schema), this build reads \(Self.schemaVersion)")
        }
        var seen: [String: Int] = [:]
        for row in rows {
            let key = "\(row.layer)@\(row.scale)"
            seen[key, default: 0] += 1
            if !Self.layers.contains(row.layer) { problems.append("\(key): unknown layer") }
            if !Self.scales.contains(row.scale) { problems.append("\(key): unknown scale") }
            if !Self.isValidOwner(row.owner) {
                problems.append("\(key): \(row.state.rawValue) row without an owner issue "
                                + "(owner \"\(row.owner)\"; expected WOR-n, WOR-n Sk or WOR-a–WOR-b)")
            }
        }
        for layer in Self.layers {
            for scale in Self.scales {
                let key = "\(layer)@\(scale)"
                switch seen[key] ?? 0 {
                case 0: problems.append("\(key): no row")
                case 1: break
                case let count: problems.append("\(key): \(count) rows")
                }
            }
        }
        return problems
    }

    public func row(_ layer: String, scale: Double) -> Row? {
        rows.first { $0.layer == layer && $0.scale == scale }
    }
}
