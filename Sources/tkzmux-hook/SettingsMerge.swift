// `tkzmux-hook settings-merge` — the only subcommand allowed to write to stdout. `Darwin` only.
import Darwin

private let injectedEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification"]
private let notificationMatcher =
    "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|elicitation_complete|elicitation_response|agent_needs_input"

/// Reads a small file via raw `open`/`read` (no `FileManager`, no Foundation).
func readFile(_ path: String) -> [UInt8]? {
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

// MARK: - statusline-settings

/// `tkzmux-hook statusline-settings <settings.json> install|uninstall|value <previous.json>`
///
/// Prints the rewritten `settings.json` on stdout; the app writes it atomically. This lives in the
/// hook binary rather than in `ClaudeBridge` for one reason: `JSONParser`/`jsonSerializePretty`
/// preserve key order and number source text, so every key the user has that tkzmux knows nothing
/// about survives the round trip byte for byte. `Persistence.JSONValue` would reorder and reformat.
///
/// `install` replaces `statusLine.command` with ours, keeping `type`, `refreshInterval`, `padding`
/// and anything else in that object. `uninstall` restores what `previous.json` recorded, or removes
/// the key when it recorded `{"statusLine": null}`. Both print nothing and exit 1 on any problem, so
/// a caller that sees no output never writes a truncated settings file.
func runStatuslineSettings(_ args: [String]) -> Int32 {
    guard args.count >= 3 else {
        debugLog("statusline-settings: usage <settings.json> install|uninstall <previous.json>")
        return 1
    }
    let settingsPath = args[0]
    let mode = args[1]
    let previousPath = args[2]

    // A settings.json that does not exist yet is an empty document, not an error.
    var base: JSONValue = .object([])
    if let bytes = readFile(settingsPath) {
        var parser = JSONParser(bytes: bytes)
        guard let parsed = parser.parse() else {
            debugLog("statusline-settings: invalid JSON in \(settingsPath)")
            return 1
        }
        base = parsed
    }
    guard var pairs = base.asObject else {
        debugLog("statusline-settings: top-level document is not an object")
        return 1
    }

    switch mode {
    case "install":
        guard let binRaw = envString("TKZMUX_BIN"), !binRaw.isEmpty else {
            debugLog("statusline-settings: TKZMUX_BIN unset")
            return 1
        }
        let command = "\"\(binRaw)/tkzmux-hook\" statusline"
        var statusLine: [JSONPair] = pairs.first(where: { $0.key == "statusLine" })?.value.asObject ?? []
        if !statusLine.contains(where: { $0.key == "type" }) {
            statusLine.insert(JSONPair(key: "type", value: .string("command")), at: 0)
        }
        if let index = statusLine.firstIndex(where: { $0.key == "command" }) {
            statusLine[index] = JSONPair(key: "command", value: .string(command))
        } else {
            statusLine.append(JSONPair(key: "command", value: .string(command)))
        }
        setPair(&pairs, key: "statusLine", value: .object(statusLine))

    case "uninstall":
        guard let bytes = readFile(previousPath) else {
            debugLog("statusline-settings: no saved statusline at \(previousPath)")
            return 1
        }
        var parser = JSONParser(bytes: bytes)
        guard let saved = parser.parse(), let restored = saved.get("statusLine") else {
            debugLog("statusline-settings: \(previousPath) has no 'statusLine'")
            return 1
        }
        if case .null = restored {
            pairs.removeAll { $0.key == "statusLine" }
        } else {
            setPair(&pairs, key: "statusLine", value: restored)
        }

    case "value":
        // Prints just `{"statusLine": <value>}` — what the installer saves as the companion file so
        // the user's original command can be restored byte for byte. `null` records "there was
        // none", which is what lets `uninstall` tell that apart from a companion file that is simply
        // missing (lost state, which must refuse rather than delete the key).
        let current = pairs.first(where: { $0.key == "statusLine" })?.value ?? .null
        print(jsonSerializePretty(.object([JSONPair(key: "statusLine", value: current)])))
        return 0

    default:
        debugLog("statusline-settings: unknown mode \(mode)")
        return 1
    }

    print(jsonSerializePretty(.object(pairs)))
    return 0
}

/// Replaces a top-level key in place (keeping its position) or appends it.
private func setPair(_ pairs: inout [JSONPair], key: String, value: JSONValue) {
    if let index = pairs.firstIndex(where: { $0.key == key }) {
        pairs[index] = JSONPair(key: key, value: value)
    } else {
        pairs.append(JSONPair(key: key, value: value))
    }
}
