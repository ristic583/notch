import Foundation
import Testing
@testable import Notch

/// Where the clipboard history rests between launches. The pasteboard itself
/// is never written here, so running the tests leaves your clipboard alone.
@Suite(.serialized)
@MainActor
final class ClipboardStorageTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID().uuidString)")
    let original = ClipboardService.storageURL
    let suite = "NotchTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ClipboardService.storageURL = directory.appendingPathComponent("clipboard.json")
        defaults = try #require(UserDefaults(suiteName: suite))
        ClipboardService.legacyDefaults = defaults
    }

    deinit {
        let original = original
        Task { @MainActor in
            ClipboardService.storageURL = original
            ClipboardService.legacyDefaults = .standard
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func readsBackWhatWasStored() throws {
        try store([
            ["type": "text", "value": "first", "date": 1_700_000_000.0, "pinned": false],
            ["type": "text", "value": "second", "date": 1_700_000_100.0, "pinned": true],
            ["type": "files", "value": ["/nowhere/gone.txt"], "date": 1_700_000_200.0, "pinned": false],
            ["type": "something-newer", "value": "?"],
        ])
        let service = ClipboardService()
        // A file that no longer exists and an entry of an unknown kind are dropped.
        #expect(service.items.map(\.preview) == ["first", "second"])
        #expect(service.items.map(\.isPinned) == [false, true])
    }

    @Test func savesChangesForThisUserOnly() throws {
        try store([["type": "text", "value": "a secret", "date": 1_700_000_000.0, "pinned": false]])
        let service = ClipboardService()
        service.togglePin(try #require(service.items.first))

        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: ClipboardService.storageURL)) as? [[String: Any]])
        #expect(stored.first?["pinned"] as? Bool == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: ClipboardService.storageURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try ClipboardService.storageURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // Nothing half-written is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["clipboard.json"])
    }

    @Test func removingTheLastEntryEmptiesTheFile() throws {
        try store([["type": "text", "value": "only", "date": 1_700_000_000.0, "pinned": false]])
        let service = ClipboardService()
        service.remove(try #require(service.items.first))
        #expect(ClipboardService().items.isEmpty)
    }

    // MARK: - Moving out of the preferences

    @Test func movesTheHistoryOutOfThePreferences() throws {
        defaults.set([["type": "text", "value": "from before", "date": 1_700_000_000.0, "pinned": true]],
                     forKey: ClipboardService.legacyDefaultsKey)
        #expect(ClipboardService().items.map(\.preview) == ["from before"])
        #expect(defaults.object(forKey: ClipboardService.legacyDefaultsKey) == nil)
        // It is in the file now, so the next launch finds it there.
        #expect(ClipboardService().items.map(\.isPinned) == [true])
    }

    @Test func keepsBothWhenAFileIsAlreadyThere() throws {
        let shared: [String: Any] = ["type": "text", "value": "in both", "date": 1_700_000_000.0, "pinned": false]
        try store([["type": "text", "value": "in the file", "date": 1_700_000_100.0, "pinned": false], shared])
        defaults.set([shared, ["type": "text", "value": "in the preferences", "date": 1_700_000_200.0, "pinned": false]],
                     forKey: ClipboardService.legacyDefaultsKey)
        #expect(ClipboardService().items.map(\.preview) == ["in the file", "in both", "in the preferences"])
        #expect(defaults.object(forKey: ClipboardService.legacyDefaultsKey) == nil)
    }

    @Test func keepsThePreferencesWhenTheFileCannotBeWritten() throws {
        defaults.set([["type": "text", "value": "from before", "date": 1_700_000_000.0, "pinned": false]],
                     forKey: ClipboardService.legacyDefaultsKey)
        ClipboardService.storageURL = URL(fileURLWithPath: "/dev/null/clipboard.json")
        #expect(ClipboardService().items.map(\.preview) == ["from before"])
        #expect(defaults.object(forKey: ClipboardService.legacyDefaultsKey) != nil)
    }

    private func store(_ entries: [[String: Any]]) throws {
        try JSONSerialization.data(withJSONObject: entries).write(to: ClipboardService.storageURL)
    }
}
