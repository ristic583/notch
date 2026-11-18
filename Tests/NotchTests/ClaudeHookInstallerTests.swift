import Foundation
import Testing
@testable import Notch

/// The installer edits a file that belongs to Claude Code and to the user, so
/// what matters is what it leaves alone. Every test works on its own copy.
@Suite(.serialized)
final class ClaudeHookInstallerTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID().uuidString)")
    let original = ClaudeHookInstaller.settingsURL
    let script: String

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ClaudeHookInstaller.settingsURL = directory.appendingPathComponent("settings.json")
        script = try Self.executable(in: directory, named: "notch-agent-hook")
    }

    deinit {
        ClaudeHookInstaller.settingsURL = original
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func installsEveryEventIntoAMissingFile() throws {
        try ClaudeHookInstaller.install(scriptPath: script)
        let hooks = try #require(settings()["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(ClaudeHookInstaller.events))
        for event in ClaudeHookInstaller.events {
            #expect(commands(hooks[event]) == [script])
        }
        #expect(ClaudeHookInstaller.isInstalled)
    }

    @Test func installingTwiceAddsNothing() throws {
        try ClaudeHookInstaller.install(scriptPath: script)
        try ClaudeHookInstaller.install(scriptPath: script)
        let hooks = try #require(settings()["hooks"] as? [String: Any])
        #expect(commands(hooks["Stop"]) == [script])
    }

    @Test func keepsWhatWasAlreadyThere() throws {
        try write([
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ])
        try ClaudeHookInstaller.install(scriptPath: script)

        let installed = try settings()
        #expect(installed["model"] as? String == "opus")
        #expect(commands((installed["hooks"] as? [String: Any])?["Stop"]) == ["say done", script])
        // The file as it was is kept beside it.
        let backup = ClaudeHookInstaller.settingsURL.appendingPathExtension("notch-backup")
        #expect(try Self.json(at: backup)["hooks"] != nil)

        try ClaudeHookInstaller.remove()
        let removed = try settings()
        #expect(removed["model"] as? String == "opus")
        #expect((removed["hooks"] as? [String: Any])?.keys.sorted() == ["Stop"])
        #expect(commands((removed["hooks"] as? [String: Any])?["Stop"]) == ["say done"])
        #expect(!ClaudeHookInstaller.isInstalled)
    }

    @Test func removingLeavesNoEmptyHooks() throws {
        try ClaudeHookInstaller.install(scriptPath: script)
        try ClaudeHookInstaller.remove()
        #expect(try settings()["hooks"] == nil)
    }

    @Test(arguments: ["[1, 2]", "{ \"model\": \"op"])
    func leavesAFileItCannotReadAlone(contents: String) throws {
        try Data(contents.utf8).write(to: ClaudeHookInstaller.settingsURL)
        let line = try Self.executable(in: directory, named: "notch-statusline")
        #expect(throws: ClaudeHookInstaller.InstallError.self) { try ClaudeHookInstaller.install(scriptPath: script) }
        #expect(throws: ClaudeHookInstaller.InstallError.self) { try ClaudeHookInstaller.installStatusLine(scriptPath: line) }
        #expect(try String(contentsOf: ClaudeHookInstaller.settingsURL, encoding: .utf8) == contents)
    }

    @Test func refusesAMissingScript() {
        #expect(throws: ClaudeHookInstaller.InstallError.self) {
            try ClaudeHookInstaller.install(scriptPath: directory.appendingPathComponent("nothing-here").path)
        }
    }

    @Test func quotesAPathTheShellWouldSplit() throws {
        #expect(ClaudeHookInstaller.shellWord("/Applications/Notch.app/Contents/Resources/notch-agent-hook")
            == "/Applications/Notch.app/Contents/Resources/notch-agent-hook")
        #expect(ClaudeHookInstaller.shellWord("/Users/ana/My Apps/Notch.app/hook") == "'/Users/ana/My Apps/Notch.app/hook'")
        #expect(ClaudeHookInstaller.shellWord("/tmp/it's/hook") == #"'/tmp/it'\''s/hook'"#)

        let folder = directory.appendingPathComponent("My Apps")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let spaced = try Self.executable(in: folder, named: "notch-agent-hook")
        try ClaudeHookInstaller.install(scriptPath: spaced)
        #expect(commands((try settings()["hooks"] as? [String: Any])?["Stop"]) == ["'\(spaced)'"])
        #expect(ClaudeHookInstaller.isInstalled)
    }

    // MARK: - Status line

    @Test func leavesSomeoneElsesStatusLineAlone() throws {
        try write(["statusLine": ["type": "command", "command": "~/bin/my-line"]])
        #expect(ClaudeHookInstaller.statusLineState == .foreign("~/bin/my-line"))
        try ClaudeHookInstaller.removeStatusLine()
        #expect(ClaudeHookInstaller.statusLineState == .foreign("~/bin/my-line"))
    }

    @Test func installsAndRemovesItsOwnStatusLine() throws {
        let line = try Self.executable(in: directory, named: "notch-statusline")
        #expect(ClaudeHookInstaller.statusLineState == .absent)
        try ClaudeHookInstaller.installStatusLine(scriptPath: line)
        #expect(ClaudeHookInstaller.statusLineState == .ours)
        try ClaudeHookInstaller.removeStatusLine()
        #expect(ClaudeHookInstaller.statusLineState == .absent)
    }

    // MARK: - Helpers

    private func settings() throws -> [String: Any] {
        try Self.json(at: ClaudeHookInstaller.settingsURL)
    }

    private func write(_ settings: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: settings).write(to: ClaudeHookInstaller.settingsURL)
    }

    private func commands(_ groups: Any?) -> [String] {
        (groups as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    private static func json(at url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func executable(in directory: URL, named name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
