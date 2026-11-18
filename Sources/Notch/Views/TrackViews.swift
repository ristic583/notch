import SwiftUI

extension AnyTransition {
    /// Content slides in the direction of the skip: next → left, previous → right.
    static func trackSlide(_ direction: TrackDirection, distance: CGFloat) -> AnyTransition {
        let sign: CGFloat = direction == .next ? 1 : -1
        return .asymmetric(
            insertion: .offset(x: sign * distance).combined(with: .opacity),
            removal: .offset(x: -sign * distance).combined(with: .opacity)
        )
    }
}

/// Album cover with a stable frame; the image inside slides on track changes,
/// so the frame itself can take part in `matchedGeometryEffect`.
struct ArtworkView: View {
    let track: NowPlayingTrack?
    let direction: TrackDirection
    var cornerRadius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let track {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.1))
                        Image(systemName: "music.note")
                            .font(.system(size: proxy.size.width * 0.42, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        if let artwork = track.artwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                                .transition(.opacity)
                        }
                    }
                    .id(track.id)
                    .transition(.trackSlide(direction, distance: proxy.size.width * 0.7))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Title + artist that slide together with the artwork.
struct TrackTitleView: View {
    let track: NowPlayingTrack?
    let direction: TrackDirection

    var body: some View {
        ZStack(alignment: .leading) {
            if let track {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .id(track.id)
                .transition(.trackSlide(direction, distance: 40))
            } else {
                Text("Nothing playing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
