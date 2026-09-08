import Foundation
import Testing

@testable import TkzApp

/// The matcher behind ⌘P / ⇧⌘P (TKZ-20, M2.4). Pure value tests — no AppKit, no window.
struct FuzzyMatchTests {

    static func score(_ query: String, _ text: String) -> Int? {
        FuzzyMatch.match(query, in: text)?.score
    }

    /// The matched substrings, as strings — this is what a highlight would draw.
    static func matched(_ query: String, _ text: String) -> [String]? {
        guard let match = FuzzyMatch.match(query, in: text) else { return nil }
        return match.ranges.map { String(text[$0]) }
    }

    @Test func matchesSubsequencesAndRejectsNonSubsequences() {
        #expect(FuzzyMatch.match("abc", in: "a-b-c") != nil)
        #expect(FuzzyMatch.match("abc", in: "acb") == nil)
        #expect(FuzzyMatch.match("abcd", in: "abc") == nil, "query longer than candidate cannot match")
        #expect(FuzzyMatch.match("", in: "anything")?.score == 0, "an empty query matches everything")
        #expect(FuzzyMatch.match("", in: "anything")?.ranges.isEmpty == true)
    }

    @Test func isCaseAndDiacriticInsensitive() {
        #expect(FuzzyMatch.match("PIPE", in: "deal pipeline") != nil)
        #expect(FuzzyMatch.match("resume", in: "Résumé builder") != nil)
        #expect(Self.matched("resume", "Résumé") == ["Résumé"])
    }

    @Test func prefixOutranksMidWord() {
        let prefix = Self.score("log", "logger")
        let midWord = Self.score("log", "catalogue")
        #expect(prefix != nil && midWord != nil)
        #expect(prefix! > midWord!, "prefix \(prefix!) should beat mid-word \(midWord!)")
    }

    @Test func wordBoundaryOutranksMidWord() {
        let boundary = Self.score("log", "my-logger")
        let midWord = Self.score("log", "catalogue")
        #expect(boundary != nil && midWord != nil)
        #expect(boundary! > midWord!, "boundary \(boundary!) should beat mid-word \(midWord!)")
        #expect(Self.score("log", "logger")! > boundary!, "prefix should still beat a boundary")
    }

    @Test func contiguousOutranksScattered() {
        let contiguous = Self.score("abc", "abcdef")
        let scattered = Self.score("abc", "a_b_c_def")
        #expect(contiguous != nil && scattered != nil)
        #expect(contiguous! > scattered!, "contiguous \(contiguous!) should beat scattered \(scattered!)")
    }

    @Test func camelCaseAndDigitBoundariesCount() {
        let camel = Self.score("fb", "fooBar")
        let plain = Self.score("fb", "foobar")
        #expect(camel != nil && plain != nil)
        #expect(camel! > plain!)
        #expect(Self.score("r42", "release4200") != nil)
    }

    @Test func rangesAreContiguousRunsAndUsableForHighlighting() {
        #expect(Self.matched("pipe", "deal pipeline") == ["pipe"])
        #expect(Self.matched("dp", "deal pipeline") == ["d", "p"])

        // The exact shape a palette row needs: NSRange conversion round-trips to the same text.
        let text = "feat/pricing-engine"
        let match = FuzzyMatch.match("pricing", in: text)
        #expect(match != nil)
        let nsRanges = match!.nsRanges(in: text)
        #expect(nsRanges.count == 1)
        let ns = text as NSString
        #expect(ns.substring(with: nsRanges[0]) == "pricing")
    }

    @Test func nonASCIITitlesDoNotMisIndex() {
        // Emoji (multi-scalar), a ZWJ family, and a combining-mark "e" — all one Character each.
        let text = "🚀 déploy the 👨‍👩‍👧 family étape"
        let match = FuzzyMatch.match("family", in: text)
        #expect(match != nil)
        #expect(match!.ranges.map { String(text[$0]) } == ["family"])

        // A match that starts *after* an emoji must still slice the right substring.
        let rocket = FuzzyMatch.match("deploy", in: text)
        #expect(rocket != nil)
        #expect(rocket!.ranges.map { String(text[$0]) } == ["déploy"])

        // Matching the emoji itself, and a candidate that is nothing but emoji, must not trap.
        #expect(FuzzyMatch.match("🚀", in: text) != nil)
        #expect(FuzzyMatch.match("👨‍👩‍👧", in: "👨‍👩‍👧") != nil)
        #expect(FuzzyMatch.match("x", in: "🚀🚀🚀") == nil)
    }

    @Test func exactMatchOutranksAPrefixOfALongerString() {
        let exact = Self.score("main", "main")
        let longer = Self.score("main", "maintenance")
        #expect(exact! > longer!)
    }

    @Test func bestMatchPicksTheHighestScoringTarget() {
        let targets = ["catalogue", "logger", "no match here"].map(FuzzyMatch.Target.init)
        let best = FuzzyMatch.bestMatch(FuzzyMatch.Pattern("log"), in: targets)
        #expect(best?.index == 1)
        #expect(FuzzyMatch.bestMatch(FuzzyMatch.Pattern("zzz"), in: targets) == nil)
    }
}
