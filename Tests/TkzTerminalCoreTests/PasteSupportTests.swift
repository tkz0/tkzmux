import Testing
@testable import TkzTerminalCore

@Suite struct PasteSupportTests {
    // MARK: - Safety

    @Test func plainSingleLineTextIsSafe() {
        #expect(PasteSupport.isSafe("hello world") == true)
        #expect(PasteSupport.isSafe("") == true)
        #expect(PasteSupport.isSafe("git commit -m \"wip\"") == true)
    }

    @Test func newlinesAndTheBracketedTerminatorAreUnsafe() {
        #expect(PasteSupport.isSafe("rm -rf /\n") == false)
        #expect(PasteSupport.isSafe("line one\nline two") == false)
        #expect(PasteSupport.isSafe("evil\u{1b}[201~rm -rf /") == false)
    }

    // MARK: - Pasting

    /// Without bracketed paste, safe text goes to the pty verbatim.
    @Test func plainPasteWritesTheText() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        let capture = PtyOutputCapture()
        capture.install(on: terminal)

        #expect(try PasteSupport.paste(text: "hello", into: terminal) == .written)
        #expect(capture.text == "hello")
    }

    /// Unsafe text is refused with nothing written until the caller confirms.
    @Test func unsafePasteIsRejectedThenAllowed() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        let capture = PtyOutputCapture()
        capture.install(on: terminal)

        #expect(try PasteSupport.paste(text: "echo hi\n", into: terminal) == .rejectedUnsafe)
        #expect(capture.bytes.isEmpty)

        // Confirmed retry. Outside a bracketed paste the newline becomes a carriage return.
        #expect(try PasteSupport.paste(text: "echo hi\n", into: terminal, allowUnsafe: true) == .written)
        #expect(capture.text == "echo hi\r")
    }

    /// With mode 2004 the library frames the paste itself; newlines are then safe and preserved.
    @Test func bracketedPasteProducesTheBracketedForm() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        let capture = PtyOutputCapture()
        capture.install(on: terminal)
        terminal.write("\u{1b}[?2004h")
        capture.clear()

        #expect(try PasteSupport.paste(text: "line one\nline two", into: terminal) == .written)
        #expect(capture.text == "\u{1b}[200~line one\nline two\u{1b}[201~")
    }

    /// The reader may be asked for the data in one piece or several; either way the bytes arrive
    /// in order and complete, including multi-byte UTF-8.
    @Test func pasteRoundTripsUnicode() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        let capture = PtyOutputCapture()
        capture.install(on: terminal)
        terminal.write("\u{1b}[?2004h")
        capture.clear()

        let text = "räksmörgås 🍤 done"
        #expect(try PasteSupport.paste(text: text, into: terminal) == .written)
        #expect(capture.text == "\u{1b}[200~\(text)\u{1b}[201~")
    }

    /// A long paste exercises the library's chunking: write_pty is called repeatedly and the
    /// concatenation must still be the whole text.
    @Test func longPasteStreamsInChunks() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        let capture = PtyOutputCapture()
        capture.install(on: terminal)
        terminal.write("\u{1b}[?2004h")
        capture.clear()

        let text = String(repeating: "abcdefghij", count: 5_000)  // 50 KB
        #expect(try PasteSupport.paste(text: text, into: terminal) == .written)
        #expect(capture.text == "\u{1b}[200~\(text)\u{1b}[201~")
    }

    /// `source: .text` is the emoji-picker / dictation / IME-commit path.
    @Test func textSourceWritesTheSameBytes() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        let capture = PtyOutputCapture()
        capture.install(on: terminal)

        #expect(try PasteSupport.paste(text: "🙂", into: terminal, source: .text) == .written)
        #expect(capture.text == "🙂")
    }

    @Test func emptyPasteWritesNothing() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        let capture = PtyOutputCapture()
        capture.install(on: terminal)

        #expect(try PasteSupport.paste(text: "", into: terminal) == .nothingToPaste)
        #expect(capture.bytes.isEmpty)
    }

    /// Without a write_pty callback libghostty has nowhere to put the bytes and says so.
    @Test func pasteWithoutAWritePtyCallbackFails() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        #expect(throws: GhosttyError.self) {
            try PasteSupport.paste(text: "hello", into: terminal)
        }
    }
}
