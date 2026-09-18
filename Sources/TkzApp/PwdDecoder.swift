// PwdDecoder — what a shell's "here is my working directory" report actually means.
//
// Three OSC sequences say it and they do not agree on the format, so the window decodes once, here,
// rather than at each call site. Lifted out of `SessionEventHandler` when that type was deleted; it
// is the one piece of it the app ever used.

import Foundation

public enum PwdDecoder {
    /// Names that mean "this machine" in an OSC 7 URI. Resolved once: `hostName` can block on
    /// reverse DNS, and OSC 7 fires on every `cd` once shell integration is in place.
    ///
    /// Deliberately strict — a host this set does not know decodes to `nil`, and only the raw
    /// payload survives. `$HOST` drifting from `ProcessInfo.hostName` (a network rename) is the way
    /// that happens in practice.
    private static let localHostNames: Set<String> = {
        var names: Set<String> = ["localhost", "127.0.0.1", "::1"]
        names.insert(ProcessInfo.processInfo.hostName.lowercased())
        if let local = Host.current().localizedName { names.insert(local.lowercased()) }
        for name in Host.current().names { names.insert(name.lowercased()) }
        return names
    }()

    /// Decodes what `TerminalEvent.pwd` carries into a plain path.
    ///
    /// OSC 7 sends `file://<host>/<percent-encoded path>`; OSC 9 and OSC 1337 CurrentDir send a
    /// bare path. Returns `nil` for an empty payload (the shell clearing the pwd) and for a
    /// `file://` URI naming some *other* host, which is not a path on this machine.
    public static func decode(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        guard raw.hasPrefix("file://") else { return raw }
        guard let components = URLComponents(string: raw) else { return nil }
        let host = components.host ?? ""
        if !host.isEmpty, !localHostNames.contains(host.lowercased()) { return nil }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return path.isEmpty ? nil : path
    }
}
