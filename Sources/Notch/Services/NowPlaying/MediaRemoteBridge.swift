import AppKit
import os

/// Talks to `MediaRemoteBridge.dylib` running inside `/usr/bin/perl`.
/// MediaRemote is blocked for third-party processes on macOS 15.4+, but still
/// answers Apple platform binaries, so the bridge process relays the data.
@MainActor
final class MediaRemoteBridge {
    enum Command: String {
        case toggle, play, pause, next, prev, refresh
    }

    var onSnapshot: ((NowPlayingSnapshot) -> Void)?
    /// Called once the bridge gave up (missing resources or crashing repeatedly).
    var onUnavailable: (() -> Void)?

    private(set) var isRunning = false
    private var process: Process?
    private var stdinPipe: Pipe?
    private var artwork: NSImage?
    private var restartDates: [Date] = []
    private var stopping = false
    private let log = Logger(subsystem: "Notch", category: "MediaRemoteBridge")

    private static var resources: (script: URL, dylib: URL)? {
        let bundle = Bundle.main
        var candidates: [URL] = []
        if let dir = bundle.resourceURL { candidates.append(dir) }
        if let dev = ProcessInfo.processInfo.environment["NOTCH_BRIDGE_DIR"] {
            candidates.append(URL(fileURLWithPath: dev))
        }
        for dir in candidates {
            let script = dir.appendingPathComponent("notch-mediaremote.pl")
            let dylib = dir.appendingPathComponent("MediaRemoteBridge.dylib")
            if FileManager.default.fileExists(atPath: script.path),
               FileManager.default.fileExists(atPath: dylib.path) {
                return (script, dylib)
            }
        }
        return nil
    }

    func start() {
        stopping = false
        guard let resources = Self.resources else {
            log.info("Bridge resources not found; using AppleScript fallback only")
            onUnavailable?()
            return
        }
        launch(resources)
    }

    func stop() {
        stopping = true
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        isRunning = false
    }

    func send(_ command: Command) {
        write(command.rawValue)
    }

    func seek(to seconds: TimeInterval) {
        write(String(format: "seek %.3f", seconds))
    }

    private func write(_ line: String) {
        guard isRunning, let handle = stdinPipe?.fileHandleForWriting else { return }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func launch(_ resources: (script: URL, dylib: URL)) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.script.path, resources.dylib.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let reader = LineReader()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // Parse off the main thread (artwork decoding can be heavy), deliver on main.
            let messages = reader.feed(data).compactMap(Message.init(line:))
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async { self?.handle(messages) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.processDidExit() }
        }

        do {
            try process.run()
            self.process = process
            self.stdinPipe = input
            isRunning = true
        } catch {
            log.error("Failed to launch bridge: \(error.localizedDescription)")
            onUnavailable?()
        }
    }

    private func processDidExit() {
        isRunning = false
        process = nil
        guard !stopping else { return }
        let now = Date()
        restartDates = restartDates.filter { now.timeIntervalSince($0) < 60 } + [now]
        if restartDates.count > 4 {
            log.error("Bridge keeps exiting; giving up")
            onUnavailable?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.stopping, let resources = Self.resources else { return }
            self.launch(resources)
        }
    }

    // MARK: - Parsing

    /// Accumulates stdout bytes and hands back complete lines. Used from one reader queue only.
    private final class LineReader: @unchecked Sendable {
        private var buffer = Data()

        func feed(_ data: Data) -> [Data] {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }

    private struct Message: @unchecked Sendable {
        var json: [String: Any]
        var artwork: NSImage?
        var artworkChanged: Bool

        init?(line: Data) {
            guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
            self.json = json
            artworkChanged = json["artworkChanged"] as? Bool ?? false
            if artworkChanged, let base64 = json["artwork"] as? String, let data = Data(base64Encoded: base64) {
                artwork = NSImage(data: data)
            }
        }
    }

    private func handle(_ messages: [Message]) {
        for message in messages where message.json["type"] as? String == "now" {
            let json = message.json
            if message.artworkChanged { artwork = message.artwork }

            let title = json["title"] as? String ?? ""
            let track: NowPlayingTrack? = title.isEmpty ? nil : NowPlayingTrack(
                title: title,
                artist: json["artist"] as? String ?? "",
                album: json["album"] as? String ?? "",
                duration: json["duration"] as? Double,
                artwork: artwork
            )
            let isPlaying = json["playing"] as? Bool ?? false
            var clock = PlaybackClock()
            clock.elapsed = json["elapsed"] as? Double ?? 0
            if let ts = json["timestamp"] as? Double {
                clock.timestamp = Date(timeIntervalSince1970: ts)
            } else {
                clock.timestamp = Date()
            }
            let rate = json["rate"] as? Double
            clock.rate = isPlaying ? (rate.flatMap { $0 > 0 ? $0 : nil } ?? 1) : 0
            onSnapshot?(NowPlayingSnapshot(source: .mediaRemote, track: track, isPlaying: isPlaying, clock: clock))
        }
    }
}
