// CodexUsageExtractor — Codex's half of the `UsageStrategy` seam declared in
// `TranscriptUsageReader.swift` (TKZ-86 part 2).
//
// The trap: Codex's rollout reports token usage as a running **thread total**, not a per-line
// delta. Every `token_usage_record` line carries `thread_token_usage`, and every `token_count`
// event (nested under `event_msg.payload.info`) carries `total_token_usage` — both are "everything
// spent in this thread so far", re-stated in full on every turn, and sometimes re-emitted unchanged
// on a rate-limit refresh. Folding these the way the other agent's assistant lines fold (`+=` per
// line) would count the same tokens once per line that ever mentions them — the exact bug the
// ticket names three other open-source usage trackers as having shipped. The fix is not a delta: it
// is to treat the newest total in the lines just read as a **replacement** for whatever was cached,
// never an addend.
//
// The `Fixtures/codex/rollout-token-count.jsonl` README spells out the
// concrete numbers this is checked against: turn two's own usage is 1100 tokens, but the thread
// total by then is 2600 (1500 from turn one, 1100 from turn two), and a third line repeats 2600
// unchanged. A correct reader reports 2600 for the whole session; one that sums every line's total
// reports 6700 (1500 + 2600 + 2600).
import Foundation
import TkzCore

struct CodexUsageExtractor: UsageStrategy {
    func fold(_ lines: [Data], into cache: inout TranscriptUsageReader.Cache) {
        var latestSnapshot: TranscriptUsageReader.RawModelUsage?

        for line in lines {
            guard let object = TranscriptReader.decode(line),
                let payload = object["payload"] as? [String: Any]
            else { continue }
            let type = object["type"] as? String

            // `turn_context` is the cheapest place a model id shows up on its own line (a top-level
            // field, not buried under a state blob) — captured off the real 0.155.0 run, where its
            // value was `gpt-5.6-terra`. Remembered on the cache so a later call that only reads new
            // usage lines, with no repeated `turn_context` in the window, still knows the key.
            if type == "turn_context", let model = (payload["model"] as? String)?.trimmed, !model.isEmpty
            {
                cache.codexModelId = model
                continue
            }

            if type == "token_usage_record", let totals = payload["thread_token_usage"] as? [String: Any],
                let snapshot = Self.snapshot(from: totals)
            {
                latestSnapshot = snapshot
                continue
            }

            if type == "event_msg", payload["type"] as? String == "token_count",
                let info = payload["info"] as? [String: Any],
                let totals = info["total_token_usage"] as? [String: Any],
                let snapshot = Self.snapshot(from: totals)
            {
                latestSnapshot = snapshot
                continue
            }
        }

        // No recognisable total anywhere in this window: leave the cached total exactly as it was.
        // This is the "never guess" rule from the file header applied here — an unparsed line must
        // not reset a real total back toward zero, and it does not, because nothing below runs.
        guard let latestSnapshot else { return }

        // Replace, never add: the snapshot just parsed already *is* "everything this thread has
        // spent so far", so writing it over the cached value is the whole fix. It also answers the
        // ticket's restart concern on its own — the persisted `perModel` entry a restart reads back
        // is that same absolute total, not a partial sum a delta could be (mis)derived from, so
        // there is no zero baseline for a restart to compute a bogus delta against.
        let modelId = cache.codexModelId ?? "unknown"
        cache.perModel = [modelId: latestSnapshot]
    }

    /// One usage block (`thread_token_usage` or `info.total_token_usage`) into the shared raw-usage
    /// shape.
    ///
    /// Measured from the fixtures, not documented anywhere: `input_tokens` already *includes*
    /// `cached_input_tokens` rather than sitting beside it (turn one of the hand-written capture is
    /// `input_tokens: 1200, cached_input_tokens: 800`, and `total_tokens: 1500` only reconciles as
    /// `input_tokens + output_tokens`, not `input_tokens + cached_input_tokens + output_tokens`).
    /// That is the opposite convention from the other agent, whose `input_tokens` counts only the
    /// uncached portion with `cache_read_input_tokens` billed separately — so this subtracts the
    /// cached amount out of `input_tokens` before storing it, to land on the same "new input, apart
    /// from what was served from cache" meaning `ModelPricing.cost` already assumes for that field.
    /// `cache_write_input_tokens` was `0` in every capture, so whether it is additive or already
    /// included could not be confirmed the same way; it is stored as a separate cache-write pool,
    /// matching the other convention, on the assumption it means the same thing there.
    private static func snapshot(from totals: [String: Any]) -> TranscriptUsageReader.RawModelUsage? {
        // `total_tokens` is what marks this as a real usage block rather than some other dictionary
        // that happens to share a key name; every genuine capture carries it.
        guard totals["total_tokens"] != nil else { return nil }
        let cachedInput = TranscriptUsageReader.intValue(totals["cached_input_tokens"])
        let totalInput = TranscriptUsageReader.intValue(totals["input_tokens"])
        var raw = TranscriptUsageReader.RawModelUsage()
        raw.inputTokens = max(0, totalInput - cachedInput)
        raw.cacheReadTokens = cachedInput
        raw.cacheCreationTokens = TranscriptUsageReader.intValue(totals["cache_write_input_tokens"])
        raw.outputTokens = TranscriptUsageReader.intValue(totals["output_tokens"])
        raw.thinkingTokens = TranscriptUsageReader.intValue(totals["reasoning_output_tokens"])
        return raw
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
