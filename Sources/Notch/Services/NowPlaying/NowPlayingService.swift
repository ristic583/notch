import AppKit
import Observation

/// Merges the MediaRemote bridge (any app, incl. browsers) with the
/// Spotify / Apple Music AppleScript fallback.
@MainActor
@Observable
final class NowPlayingService {
    private(set) var track: NowPlayingTrack?
    private(set) var isPlaying = false
    private(set) var clock = PlaybackClock()
    private(set) var source: NowPlayingSource?

    /// Called whenever `track` changes (new track, or new artwork for the same one).
    @ObservationIgnored var onTrackChange: ((_ old: NowPlayingTrack?, _ new: NowPlayingTrack?) -> Void)?
    @ObservationIgnored var onPlayingChange: ((Bool) -> Void)?

    @ObservationIgnored private let bridge = MediaRemoteBridge()
    @ObservationIgnored private let scripting = PlayerScriptingProvider()
    @ObservationIgnored private var bridgeSnapshot: NowPlayingSnapshot?
    @ObservationIgnored private var scriptingSnapshot: NowPlayingSnapshot?
    @ObservationIgnored private var startupGraceOver = false
    /// After a seek, players may still report the old position for a moment.
    @ObservationIgnored private var pendingSeek: (target: TimeInterval, date: Date)?

    func start() {
        bridge.onSnapshot = { [weak self] in self?.bridgeSnapshot = $0; self?.recompute() }
        bridge.onUnavailable = { [weak self] in
            self?.bridgeSnapshot = nil
            self?.recompute()
        }
        scripting.onSnapshot = { [weak self] in self?.scriptingSnapshot = $0; self?.recompute() }
        scripting.start()
        bridge.start()
        // Give the bridge a moment before deciding the fallback is needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.startupGraceOver = true
            self?.recompute()
        }
    }

    func stop() {
        bridge.stop()
        scripting.stop()
    }

    func position(at date: Date) -> TimeInterval {
        clock.position(at: date, duration: track?.duration)
    }

    // MARK: - Controls

    func togglePlayPause() { send(.toggle) }
    func next() { send(.next) }
    func previous() { send(.prev) }

    func seek(to seconds: TimeInterval) {
        guard track != nil else { return }
        let target = max(0, min(seconds, track?.duration ?? seconds))
        switch source {
        case .mediaRemote?, nil: bridge.seek(to: target)
        case let player?: scripting.seek(to: target, in: player)
        }
        pendingSeek = (target, Date())
        var newClock = clock
        newClock.elapsed = target
        newClock.timestamp = Date()
        apply(isPlaying: isPlaying, clock: newClock)
    }

    private func send(_ command: MediaRemoteBridge.Command) {
        switch source {
        case .mediaRemote?: bridge.send(command)
        case let player?: scripting.send(command, to: player)
        case nil: bridge.send(command) // MediaRemote can resume the last player
        }
        // Optimistic UI for play/pause; the real state follows within ~100 ms.
        if command == .toggle, track != nil {
            apply(isPlaying: !isPlaying, clock: {
                var c = clock
                c.elapsed = position(at: Date())
                c.timestamp = Date()
                c.rate = isPlaying ? 0 : 1
                return c
            }())
        }
    }

    // MARK: - Merging

    private func recompute() {
        let bridgeHasContent = bridgeSnapshot?.hasContent ?? false
        let bridgeGaveData = bridge.isRunning && bridgeHasContent
        // Once the startup grace period passed, use AppleScript whenever the bridge has nothing.
        scripting.isActive = startupGraceOver && !bridgeGaveData

        let chosen: NowPlayingSnapshot?
        if bridgeHasContent {
            chosen = bridgeSnapshot
        } else if scriptingSnapshot?.hasContent == true {
            chosen = scriptingSnapshot
        } else {
            chosen = nil
        }

        let newTrack = chosen?.track
        if newTrack != track {
            let old = track
            track = newTrack
            onTrackChange?(old, newTrack)
        }
        source = chosen?.source
        var newClock = chosen?.clock ?? PlaybackClock()
        if let seek = pendingSeek {
            let age = Date().timeIntervalSince(seek.date)
            let expected = seek.target + (isPlaying ? age : 0)
            if age > 2 || abs(newClock.position(at: Date(), duration: nil) - expected) < 1.5 {
                pendingSeek = nil // player caught up (or gave up waiting)
            } else {
                newClock = clock // stale pre-seek report; keep the optimistic position
            }
        }
        apply(isPlaying: chosen?.isPlaying ?? false, clock: newClock)
    }

    private func apply(isPlaying playing: Bool, clock newClock: PlaybackClock) {
        if clock != newClock { clock = newClock }
        if playing != isPlaying {
            isPlaying = playing
            onPlayingChange?(playing)
        }
    }
}
