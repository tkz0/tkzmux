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

// MARK: - The contiguous matcher (GUI pass 2026-09-11)

@Suite("Substring matching")
struct SubstringMatchTests {

    @Test func aRunOfCharactersMatchesAndIsRangedOverTheOriginal() throws {
        let match = try #require(FuzzyMatch.substring("almi", in: "CoreInvest.Almi.Api"))
        #expect(match.ranges.count == 1, "a substring hit is one contiguous range")
        let range = try #require(match.ranges.first)
        #expect("CoreInvest.Almi.Api"[range] == "Almi")
    }

    @Test func scatteredLettersAreNotAMatch() {
        // The whole point: `almi` must not match `M<a>inToo<l>bar<M>anager.sw<i>ft`.
        #expect(FuzzyMatch.substring("almi", in: "MainToolbarManager.swift") == nil)
        #expect(FuzzyMatch.substring("almi", in: "worktree-lively-roaming-hinton") == nil)
        // ...which is exactly what the fuzzy matcher *does* find, and still should for ⇧⌘P.
        #expect(FuzzyMatch.match("almi", in: "MainToolbarManager.swift") != nil)
    }

    @Test func matchingIgnoresCaseAndDiacritics() throws {
        let match = try #require(FuzzyMatch.substring("almi", in: "ÁLMI regions"))
        let range = try #require(match.ranges.first)
        #expect("ÁLMI regions"[range] == "ÁLMI")
    }

    @Test func aHitAtAWordBoundaryOutranksOneBuriedMidWord() throws {
        let boundary = try #require(FuzzyMatch.substring("api", in: "src/api/client.swift"))
        let buried = try #require(FuzzyMatch.substring("api", in: "src/therapist.swift"))
        #expect(boundary.score > buried.score)
    }

    @Test func aPrefixOutranksAnythingLaterAndAnExactMatchWinsOutright() throws {
        let exact = try #require(FuzzyMatch.substring("almi", in: "almi"))
        let prefix = try #require(FuzzyMatch.substring("almi", in: "almi-regions"))
        let later = try #require(FuzzyMatch.substring("almi", in: "regions-almi"))
        #expect(exact.score > prefix.score)
        #expect(prefix.score > later.score)
    }

    @Test func theBestOccurrenceWinsWhenThereAreSeveral() throws {
        // Mid-word first, then at a separator: the second one is the one to highlight.
        let match = try #require(FuzzyMatch.substring("api", in: "therapist/api/x.swift"))
        let range = try #require(match.ranges.first)
        let text = "therapist/api/x.swift"
        #expect(text.distance(from: text.startIndex, to: range.lowerBound) == 10)
    }

    @Test func aQueryLongerThanTheCandidateCannotMatch() {
        #expect(FuzzyMatch.substring("almi-regions", in: "almi") == nil)
    }

    @Test func anEmptyQueryMatchesEverythingWithNoRanges() throws {
        let match = try #require(FuzzyMatch.substring("", in: "anything"))
        #expect(match.score == 0)
        #expect(match.ranges.isEmpty)
    }

    @Test func aMatchThatRunsToTheEndIsRangedCorrectly() throws {
        let match = try #require(FuzzyMatch.substring("swift", in: "client.swift"))
        let range = try #require(match.ranges.first)
        #expect("client.swift"[range] == "swift")
        #expect(range.upperBound == "client.swift".endIndex)
    }
}
