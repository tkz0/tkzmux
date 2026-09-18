// PwdDecoder — the three OSC sequences that report a working directory do not agree on a format,
// and one of them can name a machine that is not this one.
//
// These were the surviving tests of `SessionEventHandlerTests` when that type was deleted as dead
// code; the decoder is the only part of it the app ever called.

import Foundation
import Testing

@testable import TkzApp

@Test func pwdDecodingHandlesBothProtocols() {
    // OSC 7 sends a file:// URI; OSC 9 / OSC 1337 send a bare path.
    #expect(PwdDecoder.decode("/Users/x/dev/tkzmux") == "/Users/x/dev/tkzmux")
    #expect(PwdDecoder.decode("file:///Users/x/dev/tkzmux") == "/Users/x/dev/tkzmux")
    #expect(PwdDecoder.decode("file://localhost/Users/x/a%20b") == "/Users/x/a b")
    // The shell clearing its pwd, which is not the same as a pwd of "".
    #expect(PwdDecoder.decode("") == nil)
    // A URI naming another machine is not a path here.
    #expect(PwdDecoder.decode("file://elsewhere.local/Users/x") == nil)
}

/// This machine's own name has to decode, or every `cd` in a shell whose `$HOST` is the real
/// hostname rather than `localhost` would report no directory at all.
@Test func pwdDecodingAcceptsThisMachinesOwnHostname() {
    let host = ProcessInfo.processInfo.hostName
    #expect(PwdDecoder.decode("file://\(host)/tmp/here") == "/tmp/here")
}
