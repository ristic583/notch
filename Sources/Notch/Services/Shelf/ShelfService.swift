import AppKit
import Observation
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

/// Files parked on the notch. Only references are kept (nothing is copied);
/// entries whose file disappeared are dropped on load.
@MainActor
@Observable
final class ShelfService {
    private(set) var items: [ShelfItem] = []

    @ObservationIgnored private let key = "shelfItems"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { ShelfItem(url: URL(fileURLWithPath: $0)) }
    }

    func add(_ urls: [URL]) {
        let new = urls
            .filter { $0.isFileURL }
            .map(ShelfItem.init(url:))
            .filter { item in !items.contains(item) }
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        save()
    }

    /// Loads file URLs from a drop and adds them.
    func add(from providers: [NSItemProvider]) {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { [weak self] in self?.add([url]) }
            }
        }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0 == item }
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func airDrop(_ items: [ShelfItem]) {
        guard !items.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: items.map(\.url))
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: key)
    }
}
