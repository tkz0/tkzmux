// ParityMask — the regions a comparison leaves out (ADR-0003 §3, Masks; WOR-322 S1).
//
// Four kinds, no others: `fallbackGlyph` (symbols macOS draws from a fallback font), `cjkEmoji`
// (Apple Color Emoji and PingFang against Noto), `vibrancy` (NSVisualEffectView materials) and
// `windowControls` (traffic lights against ADR-0005's controls). A region is a pixel rect in the
// image's device pixels, or a cell rect on a terminal grid. Producers derive them from the L0 dump
// or the terminal grid; they are never drawn by hand for one run.
//
// The mask file (`tkzmux-vtdump compare --mask m.json`), schema 1:
//
//   {
//     "schema": 1,
//     "grid": {"cellWidth": 14, "cellHeight": 30, "originX": 0, "originY": 0},
//     "masks": [
//       {"kind": "vibrancy", "rect": {"x": 0, "y": 0, "width": 2112, "height": 84}, "source": "header"},
//       {"kind": "cjkEmoji", "cells": {"column": 3, "row": 1, "columns": 2, "rows": 1}}
//     ]
//   }
//
// `grid` is needed only by cell rects. A pixel rect may be fractional (a frame in points times a
// fractional scale); it then covers every pixel it touches, so a mask never leaves a partly covered
// pixel in the score. Rects are clipped to the image.

import Foundation

public enum MaskKind: String, Codable, CaseIterable, Sendable {
    case fallbackGlyph
    case cjkEmoji
    case vibrancy
    case windowControls

    /// The kind's bit in a `MaskBitmap`.
    var bit: UInt8 { 1 << UInt8(Self.allCases.firstIndex(of: self)!) }
}

/// A rect in device pixels, top-left origin.
public struct PixelRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A rect of terminal cells: `columns` × `rows` cells from (`column`, `row`), zero-based.
public struct CellRect: Codable, Equatable, Sendable {
    public var column: Int
    public var row: Int
    public var columns: Int
    public var rows: Int

    public init(column: Int, row: Int, columns: Int, rows: Int) {
        self.column = column
        self.row = row
        self.columns = columns
        self.rows = rows
    }
}

/// The terminal grid that cell rects are on: the cell size and the grid's top-left, in device pixels.
public struct CellGrid: Codable, Equatable, Sendable {
    public var cellWidth: Int
    public var cellHeight: Int
    public var originX: Int
    public var originY: Int

    public init(cellWidth: Int, cellHeight: Int, originX: Int = 0, originY: Int = 0) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.originX = originX
        self.originY = originY
    }

    enum CodingKeys: String, CodingKey { case cellWidth, cellHeight, originX, originY }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cellWidth = try container.decode(Int.self, forKey: .cellWidth)
        cellHeight = try container.decode(Int.self, forKey: .cellHeight)
        originX = try container.decodeIfPresent(Int.self, forKey: .originX) ?? 0
        originY = try container.decodeIfPresent(Int.self, forKey: .originY) ?? 0
    }
}

/// One masked region: exactly one of `rect` and `cells`.
public struct ParityMask: Codable, Equatable, Sendable {
    public var kind: MaskKind
    public var rect: PixelRect?
    public var cells: CellRect?
    /// Where the region came from (an L0 node, a grid cell's text), for the report. Optional.
    public var source: String?

    public init(kind: MaskKind, rect: PixelRect, source: String? = nil) {
        self.kind = kind
        self.rect = rect
        self.source = source
    }

    public init(kind: MaskKind, cells: CellRect, source: String? = nil) {
        self.kind = kind
        self.cells = cells
        self.source = source
    }
}

public struct MaskError: Error, CustomStringConvertible, Equatable {
    public let description: String
}

/// A mask file.
public struct ParityMaskSet: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    public var grid: CellGrid?
    public var masks: [ParityMask]

    public init(grid: CellGrid? = nil, masks: [ParityMask]) {
        self.schema = Self.schemaVersion
        self.grid = grid
        self.masks = masks
    }

    /// Decodes and validates a mask file.
    public static func decode(_ data: Data) throws -> ParityMaskSet {
        let set: ParityMaskSet
        do {
            set = try JSONDecoder().decode(ParityMaskSet.self, from: data)
        } catch {
            throw MaskError(description: "not a mask file: \(error)")
        }
        try set.validate()
        return set
    }

    public func validate() throws {
        guard schema == Self.schemaVersion else {
            throw MaskError(description: "mask schema \(schema), this build reads \(Self.schemaVersion)")
        }
        if let grid, grid.cellWidth <= 0 || grid.cellHeight <= 0 {
            throw MaskError(description: "grid cell size \(grid.cellWidth)×\(grid.cellHeight) is not positive")
        }
        for (index, mask) in masks.enumerated() {
            switch (mask.rect, mask.cells) {
            case (let rect?, nil):
                guard rect.width >= 0, rect.height >= 0, rect.x.isFinite, rect.y.isFinite,
                      rect.width.isFinite, rect.height.isFinite
                else { throw MaskError(description: "mask \(index): rect \(rect) is not a finite, non-negative rect") }
            case (nil, let cells?):
                guard grid != nil else { throw MaskError(description: "mask \(index): cell rect without a grid") }
                guard cells.column >= 0, cells.row >= 0, cells.columns >= 0, cells.rows >= 0 else {
                    throw MaskError(description: "mask \(index): cell rect \(cells) has a negative field")
                }
            default:
                throw MaskError(description: "mask \(index): needs exactly one of rect and cells")
            }
        }
    }

    /// The half-open pixel bounds `[x0, x1) × [y0, y1)` of one mask, clipped to the image.
    func pixelBounds(_ mask: ParityMask, width: Int, height: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        // Clamped as Doubles first, so no rect converts out of Int's range.
        func clamp(_ value: Double, _ limit: Int) -> Int { Int(min(max(value, 0), Double(limit))) }
        var bounds: (x0: Double, y0: Double, x1: Double, y1: Double) = (0, 0, 0, 0)
        if let rect = mask.rect {
            bounds = (rect.x.rounded(.down), rect.y.rounded(.down),
                      (rect.x + rect.width).rounded(.up), (rect.y + rect.height).rounded(.up))
        } else if let cells = mask.cells, let grid {
            let x0 = Double(grid.originX) + Double(cells.column) * Double(grid.cellWidth)
            let y0 = Double(grid.originY) + Double(cells.row) * Double(grid.cellHeight)
            bounds = (x0, y0, x0 + Double(cells.columns) * Double(grid.cellWidth),
                      y0 + Double(cells.rows) * Double(grid.cellHeight))
        }
        return (clamp(bounds.x0, width), clamp(bounds.y0, height),
                clamp(bounds.x1, width), clamp(bounds.y1, height))
    }

    /// The masks rasterised for a `width` × `height` image.
    public func bitmap(width: Int, height: Int) -> MaskBitmap {
        var bits = [UInt8](repeating: 0, count: width * height)
        for mask in masks {
            let bounds = pixelBounds(mask, width: width, height: height)
            guard bounds.x0 < bounds.x1, bounds.y0 < bounds.y1 else { continue }
            let bit = mask.kind.bit
            for y in bounds.y0..<bounds.y1 {
                let row = y * width
                for x in bounds.x0..<bounds.x1 { bits[row + x] |= bit }
            }
        }
        return MaskBitmap(width: width, height: height, bits: bits)
    }
}

/// A mask rasterised to one byte per pixel: 0 is compared, any other value is left out. Each bit is
/// one `MaskKind`, so overlapping kinds are all recorded.
public struct MaskBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bits: [UInt8]

    /// A bitmap built by a producer for a region that is not one of the four parity masks (an L5
    /// text-run box, the 1.6 edge band), for `SSIM.compute` and `SSIMMap.mean`.
    public init(width: Int, height: Int, bits: [UInt8]) {
        precondition(width >= 0 && height >= 0 && bits.count == width * height,
                     "MaskBitmap: \(bits.count) bytes for \(width)×\(height)")
        self.width = width
        self.height = height
        self.bits = bits
    }

    /// No pixel masked.
    public static func none(width: Int, height: Int) -> MaskBitmap {
        MaskBitmap(width: width, height: height, bits: [UInt8](repeating: 0, count: width * height))
    }

    public func isMasked(_ index: Int) -> Bool { bits[index] != 0 }

    public var maskedCount: Int { bits.reduce(0) { $0 + ($1 != 0 ? 1 : 0) } }

    /// Masked pixels per kind; a pixel under two kinds counts for both.
    public var countByKind: [MaskKind: Int] {
        var counts: [MaskKind: Int] = [:]
        for kind in MaskKind.allCases {
            let bit = kind.bit
            let count = bits.reduce(0) { $0 + ($1 & bit != 0 ? 1 : 0) }
            if count > 0 { counts[kind] = count }
        }
        return counts
    }
}
