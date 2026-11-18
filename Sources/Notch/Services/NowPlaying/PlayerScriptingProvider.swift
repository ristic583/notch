import AppKit
import os

/// Fallback for when MediaRemote is unavailable: Spotify and Apple Music post
/// distributed notifications on every change (no permission needed); AppleScript
/// fills in artwork / position and sends commands (Automation permission).
@MainActor
final class PlayerScriptingProvider {
    struct Player {
        let source: NowPlayingSource
        let bundleID: String
        let appName: String
        let notification: String
    }

    static let spotify = Player(source: .spotify, bundleID: "com.spotify.client", appName: "Spotify",
                                notification: "com.spotify.client.PlaybackStateChanged")
    static let music = Player(source: .music, bundleID: "com.apple.Music", appName: "Music",
                              notification: "com.apple.Music.playerInfo")
    static let players = [spotify, music]

    var onSnapshot: ((NowPlayingSnapshot?) -> Void)?

    /// When false (MediaRemote is delivering data), only notifications are tracked
    /// and no AppleScript runs, so no Automation prompt appears needlessly.
    var isActive = false {
        didSet {
            guard isActive, !oldValue else { return }
            refreshRunningPlayers()
            publish()
        }
    }

    private var snapshots: [NowPlayingSource: NowPlayingSnapshot] = [:]
    private var lastChange: [NowPlayingSource: Date] = [:]
    private var artworkCache: [String: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []
    private let scriptQueue = DispatchQueue(label: "notch.applescript", qos: .userInitiated)
    private let log = Logger(subsystem: "Notch", category: "Scripting")

    func start() {
        let center = DistributedNotificationCenter.default()
        for player in Self.players {
            observers.append(center.addObserver(forName: .init(player.notification), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.handle(info, from: player) }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let player = Self.players.first(where: { $0.bundleID == bundleID }) else { return }
                self.snapshots[player.source] = nil
                self.publish()
            }
        })
    }

    func stop() {
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
    }

    // MARK: - Commands

    func send(_ command: MediaRemoteBridge.Command, to source: NowPlayingSource) {
        guard let player = Self.players.first(where: { $0.source == source }) else { return }
        let verb: String
        switch command {
        case .toggle: verb = "playpause"
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .next: verb = "next track"
        case .prev: verb = "previous track"
        case .refresh: return
        }
        run("tell application \"\(player.appName)\" to \(verb)") { _ in }
    }

    func seek(to seconds: TimeInterval, in source: NowPlayingSource) {
        guard let player = Self.players.first(where: { $0.source == source }) else { return }
        run(String(format: "tell application \"%@\" to set player position to %.2f", player.appName, seconds)) { _ in }
        // Music doesn't post a notification for seeks; keep our clock in step.
        if var snapshot = snapshots[source] {
            snapshot.clock.elapsed = seconds
            snapshot.clock.timestamp = Date()
            snapshots[source] = snapshot
        }
    }

    // MARK: - Notifications

    private func handle(_ info: [AnyHashable: Any], from player: Player) {
        let state = (info["Player State"] as? String ?? "").lowercased()
        guard state != "stopped", let title = info["Name"] as? String, !title.isEmpty else {
            snapshots[player.source] = nil
            publish()
            return
        }
        let durationMS = (info["Duration"] as? Double) ?? (info["Total Time"] as? Double)
        var track = NowPlayingTrack(
            title: title,
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            duration: durationMS.map { $0 / 1000 },
            artwork: nil
        )
        track.artwork = artworkCache[track.id] ?? (snapshots[player.source]?.track?.id == track.id ? snapshots[player.source]?.track?.artwork : nil)

        let isPlaying = state == "playing"
        var clock = PlaybackClock(elapsed: 0, timestamp: Date(), rate: isPlaying ? 1 : 0)
        if let position = info["Playback Position"] as? Double {
            clock.elapsed = position
        } else if let previous = snapshots[player.source], previous.track?.id == track.id {
            clock.elapsed = previous.clock.position(at: Date(), duration: track.duration)
        }
        snapshots[player.source] = NowPlayingSnapshot(source: player.source, track: track, isPlaying: isPlaying, clock: clock)
        lastChange[player.source] = Date()
        publish()

        if isActive { fetchDetails(for: player, trackID: track.id) }
    }

    /// The most relevant player: a playing one, most recently changed.
    private func publish() {
        let best = snapshots.values
            .filter(\.hasContent)
            .sorted {
                if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
                return (lastChange[$0.source] ?? .distantPast) > (lastChange[$1.source] ?? .distantPast)
            }
            .first
        onSnapshot?(best)
    }

    // MARK: - AppleScript

    private func refreshRunningPlayers() {
        for player in Self.players where isRunning(player) {
            queryState(of: player)
        }
    }

    private func isRunning(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    /// Full state query, used when we start without having seen a notification.
    private func queryState(of player: Player) {
        let script: String
        switch player.source {
        case .spotify:
            script = """
            tell application "Spotify"
                set t to current track
                return {name of t, artist of t, album of t, (duration of t) / 1000, player position, player state as string}
            end tell
            """
        default:
            script = """
            tell application "Music"
                set t to current track
                return {name of t, artist of t, album of t, duration of t, player position, player state as string}
            end tell
            """
        }
        run(script) { [weak self] result in
            guard let self, let result, result.numberOfItems >= 6 else { return }
            let state = result.atIndex(6)?.stringValue ?? "stopped"
            var info: [AnyHashable: Any] = [
                "Name": result.atIndex(1)?.stringValue ?? "",
                "Artist": result.atIndex(2)?.stringValue ?? "",
                "Album": result.atIndex(3)?.stringValue ?? "",
                "Player State": state.prefix(1).uppercased() + state.dropFirst(),
            ]
            if let duration = result.atIndex(4)?.doubleValue { info["Duration"] = duration * 1000 }
            if let position = result.atIndex(5)?.doubleValue { info["Playback Position"] = position }
            self.handle(info, from: player)
        }
    }

    private func fetchDetails(for player: Player, trackID: String) {
        guard isRunning(player) else { return }

        // Music does not include the position in its notification.
        if player.source == .music {
            run("tell application \"Music\" to return player position") { [weak self] result in
                guard let self, let position = result?.doubleValue,
                      var snapshot = self.snapshots[.music], snapshot.track?.id == trackID else { return }
                snapshot.clock.elapsed = position
                snapshot.clock.timestamp = Date()
                self.snapshots[.music] = snapshot
                self.publish()
            }
        }

        guard artworkCache[trackID] == nil else { return }
        switch player.source {
        case .spotify:
            run("tell application \"Spotify\" to return artwork url of current track") { [weak self] result in
                guard let string = result?.stringValue, let url = URL(string: string) else { return }
                Task { [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = NSImage(data: data) else { return }
                    self?.setArtwork(image, for: trackID, source: .spotify)
                }
            }
        default:
            run("tell application \"Music\" to return data of artwork 1 of current track") { [weak self] result in
                guard let data = result?.data, let image = NSImage(data: data) else { return }
                self?.setArtwork(image, for: trackID, source: .music)
            }
        }
    }

    private func setArtwork(_ image: NSImage, for trackID: String, source: NowPlayingSource) {
        if artworkCache.count > 20 { artworkCache.removeAll() }
        artworkCache[trackID] = image
        guard var snapshot = snapshots[source], snapshot.track?.id == trackID else { return }
        snapshot.track?.artwork = image
        snapshots[source] = snapshot
        publish()
    }

    private func run(_ source: String, completion: @escaping @MainActor (NSAppleEventDescriptor?) -> Void) {
        let log = log
        scriptQueue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                log.debug("AppleScript failed: \(error, privacy: .public)")
            }
            nonisolated(unsafe) let output = error == nil ? result : nil
            DispatchQueue.main.async { completion(output) }
        }
    }
}
