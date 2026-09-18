// ModelPricing — USD-per-million-token rates for the token usage/spend-per-session feature.
// Anthropic does not publish prices anywhere on disk or over an API, so there is nothing to fetch:
// this table is hand-maintained against https://www.anthropic.com/pricing and only ever as current
// as its last edit. A model id with no entry costs nothing rather than a guessed number — callers
// show tokens with no `$` figure in that case.
//
// **No OpenAI rates were added here for TKZ-86 part 2.** The model id a real Codex capture named
// (`gpt-5.6-terra`, off `turn_context.payload.model` in `Tests/ClaudeBridgeTests/Fixtures/codex/
// rollout-exec.jsonl`) is not a publicly documented id with a published per-token rate as of this
// writing, so inventing one would be exactly the guessed number the paragraph above rules out. The
// chain this leaves in place, verified rather than assumed: `cost(modelId:)` returns `nil` for it →
// `TranscriptUsageReader.Cache.sessionUsage` sees `allSatisfy { $0.costUSD != nil }` fail and sets
// `totalCostUSD` to `nil` → `SidebarRowAdapter.spendBadge` requires `totalCostUSD` to unwrap before
// it will show anything, so a Codex row's badge is absent rather than reading `$0.00` for a session
// that plainly cost something. An absent badge is the honest answer; a wrong one would not be.
//
// `cacheWrite` prices the 5-minute ephemeral cache, the common case. A turn that used the 1-hour
// cache instead (`cache_creation.ephemeral_1h_input_tokens`, priced roughly 2x input rather than
// ~1.25x) is undercounted by this estimate — `TranscriptUsageReader` does not currently split the
// two, so this is a known approximation, not a bug.
public enum ModelPricing {
    struct Rates {
        var input: Double
        var output: Double
        var cacheWrite: Double
        var cacheRead: Double
    }

    /// USD per million tokens, keyed by the model id as it appears in a transcript's
    /// `message.model` (the same id `SessionSidecar.model.id` carries). Last updated 2026-09-13.
    private static let rates: [String: Rates] = [
        "claude-opus-5": Rates(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.50),
        "claude-sonnet-5": Rates(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-haiku-4-5-20251001": Rates(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.10),
        "claude-haiku-4-5": Rates(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.10),
    ]

    /// `nil` for a model id not in ``rates`` — never a guessed rate.
    public static func cost(
        modelId: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) -> Double? {
        guard let rates = rates[modelId] else { return nil }
        let perToken = 1.0 / 1_000_000
        return Double(inputTokens) * rates.input * perToken
            + Double(outputTokens) * rates.output * perToken
            + Double(cacheCreationTokens) * rates.cacheWrite * perToken
            + Double(cacheReadTokens) * rates.cacheRead * perToken
    }
}
