// ByteComparison — the exact layers' compare: JSON dumps and binary buffers (WOR-322 S1).
//
// L1 (cell metrics) and L2 (FrameBuilder buffers) are byte for byte. L0's layout JSON is byte-equal
// "after canonical key order" (ADR-0003 §3): when the raw bytes differ and both sides are JSON,
// both are re-serialised with sorted keys and compared again, so a key-order difference alone
// passes and is reported as such. Any other difference fails, and the report names the first
// differing byte and, for JSON, the first differing paths.

import Foundation

public struct ByteComparisonReport: Codable, Equatable, Sendable {
    public var schema = 1
    public var kind = "bytes"
    public var a: String?
    public var b: String?
    public let sizeA: Int
    public let sizeB: Int
    /// The raw bytes are identical.
    public let identical: Bool
    /// The offset of the first differing byte (the shorter length when one is a prefix of the other).
    public let firstDifference: Int?
    /// For text: the 1-based line and column of `firstDifference` in `a`.
    public let firstDifferenceLine: Int?
    public let firstDifferenceColumn: Int?
    /// Set when both sides were compared as JSON: whether they are equal after canonical key order.
    public let canonicalJSONEqual: Bool?
    /// Up to `maxReportedPaths` JSON paths whose values differ (`$.root.children[2].frame.x`).
    public let differingPaths: [String]?
    public let pass: Bool
    public let failures: [String]
}

public enum ByteComparison {
    public static let maxReportedPaths = 20

    /// Compares two dumps. With `json`, a raw difference is checked again after canonical key order.
    public static func compare(_ a: [UInt8], _ b: [UInt8], json: Bool) -> ByteComparisonReport {
        let shared = min(a.count, b.count)
        let firstDifference = (0..<shared).first { a[$0] != b[$0] } ?? (a.count == b.count ? nil : shared)
        var line: Int?
        var column: Int?
        if let offset = firstDifference {
            var l = 1, c = 1
            for byte in a.prefix(offset) {
                if byte == 0x0A { l += 1; c = 1 } else { c += 1 }
            }
            line = l
            column = c
        }

        var canonicalEqual: Bool?
        var paths: [String]?
        var failures: [String] = []
        if firstDifference != nil {
            if json {
                switch (parse(a), parse(b)) {
                case (let objectA?, let objectB?):
                    canonicalEqual = canonical(objectA) == canonical(objectB)
                    if canonicalEqual == false {
                        var found: [String] = []
                        differences(objectA, objectB, path: "$", into: &found)
                        paths = found
                        failures.append("JSON differs after canonical key order"
                                        + (found.first.map { ", first at \($0)" } ?? ""))
                    }
                case (nil, _):
                    failures.append("a is not valid JSON")
                case (_, nil):
                    failures.append("b is not valid JSON")
                }
            } else {
                failures.append("bytes differ at offset \(firstDifference!) (sizes \(a.count) and \(b.count))")
            }
        }
        return ByteComparisonReport(
            sizeA: a.count, sizeB: b.count, identical: firstDifference == nil,
            firstDifference: firstDifference, firstDifferenceLine: line, firstDifferenceColumn: column,
            canonicalJSONEqual: canonicalEqual, differingPaths: paths, pass: failures.isEmpty,
            failures: failures)
    }

    static func parse(_ bytes: [UInt8]) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])
    }

    /// One JSON value re-serialised with sorted keys: the comparison key for canonical equality.
    static func canonical(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value,
                                    options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }

    static func differences(_ a: Any, _ b: Any, path: String, into found: inout [String]) {
        guard found.count < maxReportedPaths else { return }
        switch (a, b) {
        case (let da as [String: Any], let db as [String: Any]):
            for key in Set(da.keys).union(db.keys).sorted() {
                let child = "\(path).\(key)"
                switch (da[key], db[key]) {
                case (let va?, let vb?): differences(va, vb, path: child, into: &found)
                default: if found.count < maxReportedPaths { found.append(child) }
                }
            }
        case (let aa as [Any], let ab as [Any]):
            for index in 0..<max(aa.count, ab.count) {
                let child = "\(path)[\(index)]"
                if index < aa.count, index < ab.count {
                    differences(aa[index], ab[index], path: child, into: &found)
                } else if found.count < maxReportedPaths {
                    found.append(child)
                }
            }
        default:
            if canonical(a) != canonical(b) { found.append(path) }
        }
    }
}
