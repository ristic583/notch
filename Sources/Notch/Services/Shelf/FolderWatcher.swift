import AppKit

/// Watches folders and reports files that appear in them. Used to drop fresh
/// screenshots and downloads straight onto the shelf.
@MainActor
final class FolderWatcher {
    var onNewFile: ((URL) -> Void)?

    private var sources: [DispatchSourceFileSystemObject] = []
    private var seen: Set<String> = []
    private var pending: [URL: DispatchWorkItem] = [:]
    /// Ignore whatever was already in the folder when we started.
    private var startDate = Date()

    /// Where macOS puts screenshots (Desktop unless changed).
    static var screenshotDirectory: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let custom, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// A file macOS marked as a screen capture (falls back to the usual names).
    static func isScreenshot(_ url: URL) -> Bool {
        guard ["png", "jpg", "jpeg", "heic", "tiff", "pdf"].contains(url.pathExtension.lowercased()) else { return false }
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.hasPrefix("screenshot") || name.hasPrefix("screen shot") || name.hasPrefix("cleanshot")
    }

    /// Partial downloads and hidden files are skipped.
    static func isFinishedDownload(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        return !["download", "crdownload", "part", "partial", "tmp"].contains(url.pathExtension.lowercased())
    }

    func watch(_ directories: [URL]) {
        stop()
        startDate = Date()
        seen = Set(directories.flatMap { contents(of: $0).map(\.path) })
        for directory in directories {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .extend],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scan(directory) }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.creationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    private func scan(_ directory: URL) {
        for url in contents(of: directory) where !seen.contains(url.path) {
            seen.insert(url.path)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            guard created > startDate.addingTimeInterval(-2) else { continue } // pre-existing file
            // Give the writer a moment to finish (downloads, screenshot encoding).
            pending[url]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending[url] = nil
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                self.onNewFile?(url)
            }
            pending[url] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
    }
}
