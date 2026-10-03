// ParityThresholds — the numbers of ADR-0003 §3 and §5, one named constant each (WOR-322 S1).
//
// docs/linux/adr-0003-parity.md is normative; this file mirrors it. A value here changes only in
// the same PR that amends the ADR, and never to make a run pass. `ParityThresholdTests` reads the
// ADR and fails when a name below is missing there, when the ADR names a constant this file lacks,
// or when a value the ADR spells out (`name = value`) differs from the one here.
//
// The "exact" layers have no number: their constant records that the comparison is byte for byte.

public enum ParityThresholds {
    // MARK: L0 layout

    /// L0: the layout JSON is byte-equal after canonical key order.
    public static let l0Exact = true
    /// L0: measured text-run widths may differ by this many points. Diagnostic only.
    public static let l0TextWidthTolerancePt = 0.5

    // MARK: L1 cell metrics, L2 FrameBuilder buffers

    /// L1: every `CellMetrics` field is equal.
    public static let l1Exact = true
    /// L2: the instance buffers are byte-identical.
    public static let l2Exact = true

    // MARK: L3 shaders

    /// L3: a pixel differs when any channel differs by more than this.
    public static let l3ChannelTolerance = 1
    /// L3: the fraction of pixels allowed to differ. None.
    public static let l3PixelTolerance = 0.0

    // MARK: L4 glyph atlas

    /// L4: each glyph bounding-box edge may move by this many device pixels.
    public static let l4BBoxTolerancePx = 1
    /// L4: a glyph's coverage sum may differ by this fraction, relative.
    public static let l4CoverageTolerance = 0.04
    /// L4: the minimum SSIM of one glyph.
    public static let l4GlyphMinSSIM = 0.90

    // MARK: L5 components

    /// L5 non-text pixels: a pixel differs when any channel differs by more than this. The same
    /// default as the golden comparator (`TerminalRendererTests.assertMatchesGolden`).
    public static let l5ChannelTolerance = 2
    /// L5 non-text pixels: the fraction allowed to differ. The golden comparator's default too.
    public static let l5PixelTolerance = 0.002
    /// L5: the minimum SSIM of each text-run box (boxes from the L0 dump).
    public static let l5TextMinSSIM = 0.90
    /// L5: the minimum SSIM of the whole component.
    public static let l5ComponentMinSSIM = 0.95
    /// L5 at 1.6: pixels this close to a fractional L0 edge are left out of the channel rule.
    public static let l5EdgeBandPx = 1

    // MARK: L6 window

    /// L6: the minimum SSIM of the full-window capture, with masks.
    public static let l6WindowMinSSIM = 0.97
    /// L6: the largest fraction of the window that masks may cover.
    public static let l6MaxMaskedFraction = 0.15

    // MARK: §5 reference budget

    /// The combined committed budget: `Tests/TkzAppTests/ComponentSnapshots/` plus
    /// `Tests/Parity/References/`, 9 MiB.
    public static let referenceBudgetBytes = 9 * 1024 * 1024
    /// WOR-307's share, `Tests/TkzAppTests/ComponentSnapshots/`: 4 MiB.
    public static let componentSnapshotShareBytes = 4 * 1024 * 1024
    /// WOR-322's share, `Tests/Parity/References/` (WOR-312's fonts and WOR-313's conformance
    /// outputs included): 5 MiB.
    public static let parityReferenceShareBytes = 5 * 1024 * 1024

    /// A constant's value as the ADR writes it: `exact` for the byte-for-byte layers.
    public enum Value: Equatable, Sendable {
        case exact
        case number(Double)
    }

    /// Every constant above, by its Swift name, for the ADR cross-check.
    public static let all: [(name: String, value: Value)] = [
        ("l0Exact", .exact),
        ("l0TextWidthTolerancePt", .number(l0TextWidthTolerancePt)),
        ("l1Exact", .exact),
        ("l2Exact", .exact),
        ("l3ChannelTolerance", .number(Double(l3ChannelTolerance))),
        ("l3PixelTolerance", .number(l3PixelTolerance)),
        ("l4BBoxTolerancePx", .number(Double(l4BBoxTolerancePx))),
        ("l4CoverageTolerance", .number(l4CoverageTolerance)),
        ("l4GlyphMinSSIM", .number(l4GlyphMinSSIM)),
        ("l5ChannelTolerance", .number(Double(l5ChannelTolerance))),
        ("l5PixelTolerance", .number(l5PixelTolerance)),
        ("l5TextMinSSIM", .number(l5TextMinSSIM)),
        ("l5ComponentMinSSIM", .number(l5ComponentMinSSIM)),
        ("l5EdgeBandPx", .number(Double(l5EdgeBandPx))),
        ("l6WindowMinSSIM", .number(l6WindowMinSSIM)),
        ("l6MaxMaskedFraction", .number(l6MaxMaskedFraction)),
        ("referenceBudgetBytes", .number(Double(referenceBudgetBytes))),
        ("componentSnapshotShareBytes", .number(Double(componentSnapshotShareBytes))),
        ("parityReferenceShareBytes", .number(Double(parityReferenceShareBytes))),
    ]
}

/// The pass rule for one image comparison: which of ADR-0003's image thresholds apply. A nil field
/// is not checked. Built only from `ParityThresholds`, so there is no way to loosen one per run.
public struct ParityGate: Codable, Equatable, Sendable {
    public let name: String
    /// A pixel differs when any premultiplied channel differs by more than this.
    public let channelTolerance: Int?
    /// The largest fraction of compared (unmasked) pixels that may differ.
    public let pixelTolerance: Double?
    /// The smallest global SSIM that passes.
    public let minSSIM: Double?
    /// The largest fraction of the image that masks may cover.
    public let maxMaskedFraction: Double?

    /// The golden comparator's rule (`assertMatchesGolden`: channel tolerance 2, pixel tolerance
    /// 0.002), which ADR-0003 reuses for L5's non-text pixels. The default of `compare`.
    public static let golden = ParityGate(
        name: "golden", channelTolerance: ParityThresholds.l5ChannelTolerance,
        pixelTolerance: ParityThresholds.l5PixelTolerance, minSSIM: nil, maxMaskedFraction: nil)

    /// Every pixel identical.
    public static let exact = ParityGate(
        name: "exact", channelTolerance: 0, pixelTolerance: 0, minSSIM: nil, maxMaskedFraction: nil)

    /// L3 shader conformance: every pixel within ±1 per channel.
    public static let l3 = ParityGate(
        name: "L3", channelTolerance: ParityThresholds.l3ChannelTolerance,
        pixelTolerance: ParityThresholds.l3PixelTolerance, minSSIM: nil, maxMaskedFraction: nil)

    /// L4, one glyph image: the SSIM rule. The bbox and coverage rules need the atlas glyph table
    /// and belong to WOR-312's producer.
    public static let l4Glyph = ParityGate(
        name: "L4", channelTolerance: nil, pixelTolerance: nil,
        minSSIM: ParityThresholds.l4GlyphMinSSIM, maxMaskedFraction: nil)

    /// L5, one component: the channel rule and the whole-component SSIM. Restricting the channel
    /// rule to non-text pixels, the text-run SSIM and the 1.6 edge band need the L0 dump's boxes
    /// and edges, so the L5 producers (WOR-316–WOR-319) apply them on top of this gate (their own
    /// `MaskBitmap`s and per-box `SSIMMap.mean`); they are not parity masks.
    public static let l5Component = ParityGate(
        name: "L5", channelTolerance: ParityThresholds.l5ChannelTolerance,
        pixelTolerance: ParityThresholds.l5PixelTolerance,
        minSSIM: ParityThresholds.l5ComponentMinSSIM, maxMaskedFraction: nil)

    /// L6, the full window: SSIM with masks, and a cap on how much the masks may hide.
    public static let l6Window = ParityGate(
        name: "L6", channelTolerance: nil, pixelTolerance: nil,
        minSSIM: ParityThresholds.l6WindowMinSSIM,
        maxMaskedFraction: ParityThresholds.l6MaxMaskedFraction)

    public static let all: [ParityGate] = [.golden, .exact, .l3, .l4Glyph, .l5Component, .l6Window]

    /// A gate by its name, case-insensitively (`L6`, `l6`, `golden`).
    public static func named(_ name: String) -> ParityGate? {
        all.first { $0.name.lowercased() == name.lowercased() }
    }
}
