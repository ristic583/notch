import Foundation
import Observation

struct UsageWindow: Equatable {
    var usedPercent: Double
    /// Nil while the window hasn't started yet (nothing used).
    var resetsAt: Date?

    /// The window rolled over since the last reading, so the old percentage is void.
    var isExpired: Bool { resetsAt.map { $0 < Date() } ?? false }

    var remaining: String? {
        guard let resetsAt else { return nil }
        let seconds = Int(max(0, resetsAt.timeIntervalSinceNow))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 60)m"
    }
}

/// Official Claude subscription usage.
///
/// Two sources, and the newer reading wins: Notch's own Claude sign-in
/// (`ClaudeAccount`), fetched on every open, after every Claude reply and once
/// a minute; and the JSON Claude Code hands its status line, which only
/// terminal sessions produce (the desktop app never runs the status line).
@MainActor
@Observable
final class UsageService {
    private(set) var fiveHour: UsageWindow?
    private(set) var sevenDay: UsageWindow?
    private(set) var contextPercent: Double?
    /// When the numbers shown were measured.
    private(set) var updated: Date?

    let account = ClaudeAccount()

    /// Fired once when the 5-hour usage climbs past one of `warningThresholds`.
    @ObservationIgnored var onLimitWarning: ((Int) -> Void)?
    static let warningThresholds = [90, 80]

    static var fileURL: URL {
        AgentActivityService.supportDirectory.appendingPathComponent("usage.json")
    }

    static var statusLineScriptURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("notch-statusline")
    }

    var hasData: Bool { fiveHour != nil || sevenDay != nil }

    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var descriptor: Int32 = -1
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var lastFetch = Date.distantPast

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: AgentActivityService.supportDirectory,
                                                 withIntermediateDirectories: true)
        let path = Self.fileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        read()

        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let fd = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .extend, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reopenIfNeeded() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source

        account.onSignIn = { [weak self] in self?.fetch() }
        account.onSignOut = { [weak self] in self?.forgetAccountReading() }
        poll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetch() }
        }
        fetch()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        poll?.invalidate()
        poll = nil
    }

    /// Fresh numbers now: on opening the card or the Claude tab, and when a reply finishes.
    func refreshNow() {
        read()
        fetch()
    }

    /// Asks Claude directly. Clicks in quick succession share one request.
    private func fetch() {
        guard account.isSignedIn, !fetching, Date().timeIntervalSince(lastFetch) > 3 else { return }
        fetching = true
        lastFetch = Date()
        Task {
            defer { fetching = false }
            guard let usage = try? await account.fetchUsage(), account.isSignedIn else { return }
            apply(fiveHour: usage.fiveHour, sevenDay: usage.sevenDay, measured: Date())
        }
    }

    /// Only the status line is left to go by.
    private func forgetAccountReading() {
        fiveHour = nil
        sevenDay = nil
        updated = nil
        read()
    }

    /// The script replaces the file, so the watch has to follow the new inode.
    private func reopenIfNeeded() {
        read()
        stop()
        start()
    }

    private func read() {
        guard let data = try? Data(contentsOf: Self.fileURL), !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        contextPercent = (json["context_window"] as? [String: Any])?["used_percentage"] as? Double
        let limits = json["rate_limits"] as? [String: Any]
        let written = (try? Self.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        apply(fiveHour: Self.window(limits?["five_hour"]), sevenDay: Self.window(limits?["seven_day"]),
              measured: written ?? Date())
    }

    private func apply(fiveHour: UsageWindow?, sevenDay: UsageWindow?, measured: Date) {
        if let updated, measured < updated { return } // an older reading than the one shown
        // Only a crossing inside a window counts: no warning for where the first reading already is.
        let before = self.fiveHour.flatMap { $0.isExpired ? nil : $0.usedPercent }
        if let before, let after = fiveHour?.usedPercent,
           let crossed = Self.warningThresholds.first(where: { after >= Double($0) && before < Double($0) }) {
            onLimitWarning?(crossed)
        }
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        updated = measured
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let percent = dict["used_percentage"] as? Double,
              let resets = dict["resets_at"] as? Double else { return nil }
        return UsageWindow(usedPercent: percent, resetsAt: Date(timeIntervalSince1970: resets))
    }
}
