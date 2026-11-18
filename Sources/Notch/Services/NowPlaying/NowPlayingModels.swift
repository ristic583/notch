import AppKit

enum NowPlayingSource: Equatable {
    case mediaRemote
    case spotify
    case music
}

/// Identity + metadata of the current track. Playback position lives in `PlaybackClock`.
struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    var artwork: NSImage?

    var id: String { "\(title)\u{1F}\(artist)\u{1F}\(album)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.duration == rhs.duration && lhs.artwork === rhs.artwork
    }
}

/// Position that can be extrapolated at any moment without polling.
struct PlaybackClock: Equatable {
    var elapsed: TimeInterval = 0
    var timestamp: Date = .distantPast
    var rate: Double = 0

    func position(at date: Date, duration: TimeInterval?) -> TimeInterval {
        let value = elapsed + max(0, date.timeIntervalSince(timestamp)) * rate
        if let duration, duration > 0 { return min(max(0, value), duration) }
        return max(0, value)
    }
}

/// What one provider currently knows.
struct NowPlayingSnapshot {
    var source: NowPlayingSource
    var track: NowPlayingTrack?
    var isPlaying: Bool
    var clock: PlaybackClock

    var hasContent: Bool { track.map { !$0.title.isEmpty } ?? false }
}

enum TrackDirection {
    case next
    case previous
}
