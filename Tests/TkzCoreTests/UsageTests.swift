// Token usage / spend per session: `ModelPricing`'s lookup rule, and that `ModelUsage`/`SessionUsage`
// round-trip through `Codable` the way every other sidecar-shaped type here does.

import Foundation
import Testing

@testable import TkzCore

@Suite struct ModelPricingTests {
    @Test("A priced model returns a cost computed from its own rates")
    func pricedModelComputesCost() {
        let cost = ModelPricing.cost(
            modelId: "claude-sonnet-5",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheCreationTokens: 1_000_000,
            cacheReadTokens: 1_000_000)
        // Sonnet 5: $3 input + $15 output + $3.75 cache write + $0.30 cache read, per million.
        let expected: Double = 3 + 15 + 3.75 + 0.30
        #expect(cost == expected)
    }

    @Test("A model with no pricing entry costs nothing, never a guess")
    func unknownModelCostsNil() {
        let cost = ModelPricing.cost(
            modelId: "claude-some-future-model",
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheCreationTokens: 0, cacheReadTokens: 0)
        #expect(cost == nil)
    }

    @Test("Zero tokens against a priced model cost zero, not nil")
    func zeroTokensCostsZero() {
        let cost = ModelPricing.cost(
            modelId: "claude-haiku-4-5-20251001",
            inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        #expect(cost == 0)
    }

    /// TKZ-86 part 2's own deliberate absence: `gpt-5.6-terra` is the model id a real Codex capture
    /// named, and no rate was added for it (see this file's header) rather than guess one.
    @Test("Codex's observed model id has no pricing entry, on purpose")
    func codexModelIdCostsNil() {
        let cost = ModelPricing.cost(
            modelId: "gpt-5.6-terra",
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheCreationTokens: 0, cacheReadTokens: 0)
        #expect(cost == nil)
    }
}

@Suite struct SessionUsageCodableTests {
    @Test("ModelUsage round-trips, including a nil cost for an unpriced model")
    func modelUsageRoundTrips() throws {
        let usage = ModelUsage(
            modelId: "claude-sonnet-5", inputTokens: 120, outputTokens: 340,
            cacheCreationTokens: 50, cacheReadTokens: 900, thinkingTokens: 20, costUSD: 0.0123)
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(ModelUsage.self, from: data)
        #expect(decoded == usage)

        let unpriced = ModelUsage(modelId: "claude-future-model", inputTokens: 10)
        let unpricedData = try JSONEncoder().encode(unpriced)
        let decodedUnpriced = try JSONDecoder().decode(ModelUsage.self, from: unpricedData)
        #expect(decodedUnpriced.costUSD == nil)
    }

    @Test("SessionUsage round-trips a multi-model breakdown and a nil total")
    func sessionUsageRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let usage = SessionUsage(
            perModel: [
                ModelUsage(modelId: "claude-sonnet-5", inputTokens: 100, costUSD: 0.01),
                ModelUsage(modelId: "claude-unpriced-model", inputTokens: 50, costUSD: nil),
            ],
            totalCostUSD: nil,  // one model unpriced — see TranscriptUsageReaderTests for the rule
            lastUpdatedAt: now)
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(SessionUsage.self, from: data)
        #expect(decoded == usage)
        #expect(decoded.totalCostUSD == nil)
        #expect(decoded.perModel.count == 2)
    }
}
