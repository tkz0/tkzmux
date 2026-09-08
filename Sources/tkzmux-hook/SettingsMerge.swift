// `tkzmux-hook settings-merge` — the only subcommand allowed to write to stdout. `Darwin` only.
import Darwin

private let injectedEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification"]
private let notificationMatcher =
    "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|elicitation_complete|elicitation_response|agent_needs_input"

/// Reads a small file via raw `open`/`read` (no `FileManager`, no Foundation).
private func readFile(_ path: String) -> [UInt8]? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var data = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = buf.withUnsafeMutableBytes { ptr -> Int in
            read(fd, ptr.baseAddress, ptr.count)
        }
        if n < 0 { return nil }
        if n == 0 { break }
        data.append(contentsOf: buf[0..<n])
    }
    return data
}

private func injectedHookGroup(event: String, bin: String) -> JSONValue {
    let command = "\"\(bin)/tkzmux-hook\" \(event)"
    var hookObject: [JSONPair] = [
        JSONPair(key: "type", value: .string("command")),
        JSONPair(key: "command", value: .string(command)),
    ]
    if event == "SessionEnd" {
        hookObject.append(JSONPair(key: "timeout", value: .number("1")))
    }
    var group: [JSONPair] = []
    if event == "Notification" {
        group.append(JSONPair(key: "matcher", value: .string(notificationMatcher)))
    }
    group.append(JSONPair(key: "hooks", value: .array([.object(hookObject)])))
    return .object(group)
}

/// Returns the process exit code. On every failure path this prints nothing (the caller must not
/// have already written partial output), matching "exit 1, print nothing".
func runSettingsMerge(arg: String?) -> Int32 {
    guard let binRaw = envString("TKZMUX_BIN"), !binRaw.isEmpty else {
        debugLog("settings-merge: TKZMUX_BIN unset")
        return 1
    }

    let base: JSONValue
    if let arg, !arg.isEmpty {
        if arg.hasPrefix("{") {
            var parser = JSONParser(arg)
            guard let v = parser.parse() else {
                debugLog("settings-merge: invalid JSON argument")
                return 1
            }
            base = v
        } else {
            guard let contents = readFile(arg) else {
                debugLog("settings-merge: cannot read \(arg)")
                return 1
            }
            var parser = JSONParser(bytes: contents)
            guard let v = parser.parse() else {
                debugLog("settings-merge: invalid JSON in \(arg)")
                return 1
            }
            base = v
        }
    } else {
        base = .object([])
    }

    guard var pairs = base.asObject else {
        debugLog("settings-merge: top-level document is not an object")
        return 1
    }

    var hooksPairs: [JSONPair] = []
    if let existingHooksIndex = pairs.firstIndex(where: { $0.key == "hooks" }) {
        guard let existingHooks = pairs[existingHooksIndex].value.asObject else {
            debugLog("settings-merge: hooks is present but not an object")
            return 1
        }
        hooksPairs = existingHooks
    }

    for event in injectedEvents {
        let injected = injectedHookGroup(event: event, bin: binRaw)
        var group: [JSONValue] = []
        if let existingIndex = hooksPairs.firstIndex(where: { $0.key == event }) {
            guard let existingGroup = hooksPairs[existingIndex].value.asArray else {
                debugLog("settings-merge: hooks.\(event) is present but not an array")
                return 1
            }
            group = existingGroup
        }
        group.append(injected)
        if let existingIndex = hooksPairs.firstIndex(where: { $0.key == event }) {
            hooksPairs[existingIndex] = JSONPair(key: event, value: .array(group))
        } else {
            hooksPairs.append(JSONPair(key: event, value: .array(group)))
        }
    }

    if let hooksIndex = pairs.firstIndex(where: { $0.key == "hooks" }) {
        pairs[hooksIndex] = JSONPair(key: "hooks", value: .object(hooksPairs))
    } else {
        pairs.append(JSONPair(key: "hooks", value: .object(hooksPairs)))
    }

    print(jsonSerialize(.object(pairs)))
    return 0
}
