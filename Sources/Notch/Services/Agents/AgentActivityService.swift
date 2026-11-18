import AppKit
import Observation

struct AgentSession: Identifiable, Equatable {
    enum Status: Equatable {
        case working
        case waiting
        case done

        var symbol: String {
            switch self {
            case .working: "circle.dotted"
            case .waiting: "hand.raised.fill"
            case .done: "checkmark.circle.fill"
            }
        }

        var title: String {
            switch self {
            case .working: "Working"
            case .waiting: "Needs you"
            case .done: "Finished"
            }
        }
    }

    let id: String
    var project: String
    var directory: URL?
    var status: Status
    /// What a notification said, e.g. which permission Claude is waiting for.
    var message: String?
    var updated: Date
}

/// Claude Code sessions, fed by hooks that append to a log file we watch.
/// Nothing is polled and no private API is used: Claude Code calls the hook.
@MainActor
@Observable
final class AgentActivityService {
    private(set) var sessions: [AgentSession] = []

    /// Fired when a session starts waiting for the user, or finishes.
    @ObservationIgnored var onStatusChange: ((AgentSession) -> Void)?

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch", isDirectory: true)
    }

    static var eventsURL: URL { supportDirectory.appendingPathComponent("agent-events.jsonl") }

    /// The hook inside the app bundle (what we install into Claude Code).
    static var hookScriptURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("notch-agent-hook")
    }

    /// How long a "needs you" state is trusted without any further event.
    static let waitingTimeout: TimeInterval = 180

    var waitingSession: AgentSession? {
        sessions
            .filter { $0.status == .waiting && Date().timeIntervalSince($0.updated) < Self.waitingTimeout }
            .max { $0.updated < $1.updated }
    }

    var activeSessions: [AgentSession] {
        sessions
            .filter { Date().timeIntervalSince($0.updated) < 6 * 3600 }
            .sorted { $0.updated > $1.updated }
    }

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var descriptor: Int32 = -1
    @ObservationIgnored private var offset: UInt64 = 0
    @ObservationIgnored private var staleCheck: Timer?

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        let path = Self.eventsURL.path
        // Old events are history, not news: every start begins with an empty log,
        // readable by this user only. That also keeps it from growing forever.
        if FileManager.default.fileExists(atPath: path) {
            try? Data().write(to: Self.eventsURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } else {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        offset = 0

        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let fd = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readNewEvents() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source

        // A session can be answered in the terminal without another hook firing,
        // so a stale "needs you" falls back to "working" on its own.
        staleCheck = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireStaleWaiting() }
        }
    }

    private func expireStaleWaiting() {
        let now = Date()
        for index in sessions.indices where sessions[index].status == .waiting
            && now.timeIntervalSince(sessions[index].updated) >= Self.waitingTimeout {
            sessions[index].status = .working
        }
        prune()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        staleCheck?.invalidate()
        staleCheck = nil
    }

    func clearFinished() {
        sessions.removeAll { $0.status == .done }
    }

    // MARK: - Reading

    private func readNewEvents() {
        guard let handle = try? FileHandle(forReadingFrom: Self.eventsURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0 } // file was truncated or replaced
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset = size

        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            // The hook passes on a few fields of Claude Code's event, not the event itself.
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = json["session_id"] as? String,
                  let event = (json["hook_event_name"] as? String) ?? (json["event"] as? String) else { continue }
            apply(event: event, id: id, json: json)
        }
        prune()
    }

    private func apply(event: String, id: String, json: [String: Any]) {
        let directory = (json["cwd"] as? String).map { URL(fileURLWithPath: $0) }
        let project = directory?.lastPathComponent ?? "Claude Code"
        let status: AgentSession.Status?
        switch event {
        case "Notification": status = .waiting
        case "Stop", "SubagentStop": status = .done
        case "SessionEnd": status = nil
        default: status = .working // SessionStart, UserPromptSubmit, tool events
        }

        guard let status else {
            sessions.removeAll { $0.id == id }
            return
        }

        let message = json["message"] as? String
        let previous = sessions.first { $0.id == id }?.status
        let session = AgentSession(id: id, project: project, directory: directory,
                                   status: status, message: message, updated: Date())
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        // Only the states worth interrupting for.
        if status != previous, status == .waiting || status == .done {
            onStatusChange?(session)
        }
    }

    private func prune() {
        // Finished sessions stop being interesting quickly.
        sessions.removeAll { $0.status == .done && Date().timeIntervalSince($0.updated) > 900 }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        sessions.removeAll { $0.updated < cutoff }
    }
}
