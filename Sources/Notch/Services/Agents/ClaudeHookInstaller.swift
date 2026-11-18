import Foundation

/// Adds (or removes) the Notch hook in ~/.claude/settings.json. Only our own
/// entries are touched and the file is backed up before it is rewritten.
enum ClaudeHookInstaller {
    /// Events we care about: start / prompt mean "working", Notification means
    /// "needs you", Stop means "finished".
    static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    /// Claude Code's user settings. Tests point this at a file of their own.
    static var settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    enum InstallError: LocalizedError {
        case missingScript
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .missingScript: "The hook script is missing from the app bundle."
            case let .unreadable(detail): "Could not update ~/.claude/settings.json: \(detail)"
            }
        }
    }

    static var isInstalled: Bool {
        guard let settings = try? read(), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.contains { event in
            containsOurHook(hooks[event])
        }
    }

    static func install(scriptPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else { throw InstallError.missingScript }
        var settings = try read() // a file we can't read is left as it is
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard !containsOurHook(groups) else { continue }
            groups.append(["hooks": [["type": "command", "command": shellWord(scriptPath)]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try write(settings)
    }

    static func remove() throws {
        guard var settings = try? read(), var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll { group in
                commands(in: group).contains { $0.contains("notch-agent-hook") }
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try write(settings)
    }

    // MARK: - Status line (the only local source of subscription usage)

    static var statusLineState: StatusLineState {
        guard let settings = try? read(), let line = settings["statusLine"] as? [String: Any] else { return .absent }
        let command = line["command"] as? String ?? ""
        return command.contains("notch-statusline") ? .ours : .foreign(command)
    }

    enum StatusLineState: Equatable {
        case absent
        case ours
        /// Someone else's status line: we leave it alone.
        case foreign(String)
    }

    static func installStatusLine(scriptPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else { throw InstallError.missingScript }
        var settings = try read()
        settings["statusLine"] = ["type": "command", "command": shellWord(scriptPath), "padding": 0]
        try write(settings)
    }

    static func removeStatusLine() throws {
        guard var settings = try? read(), case .ours = statusLineState else { return }
        settings.removeValue(forKey: "statusLine")
        try write(settings)
    }

    // MARK: - Helpers

    /// The path as one word for the shell Claude Code runs the command in, so
    /// an app kept in a folder with a space in its name still works.
    static func shellWord(_ path: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%")
        if !path.isEmpty, path.unicodeScalars.allSatisfy(plain.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func containsOurHook(_ value: Any?) -> Bool {
        guard let groups = value as? [[String: Any]] else { return false }
        return groups.contains { group in
            commands(in: group).contains { $0.contains("notch-agent-hook") }
        }
    }

    private static func commands(in group: [String: Any]) -> [String] {
        (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }

    private static func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw InstallError.unreadable("the file isn't valid JSON. Fix it, then try again.")
        }
        guard let json = parsed as? [String: Any] else {
            throw InstallError.unreadable("the file isn't a JSON object")
        }
        return json
    }

    private static func write(_ settings: [String: Any]) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("notch-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
