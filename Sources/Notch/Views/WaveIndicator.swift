import SwiftUI

/// The bars, fed either by real system audio or by the simulator, or a quiet
/// glyph when the soundwave is off. Only the live mode captures any audio.
struct WaveIndicator: View {
    let viewModel: NotchViewModel
    var symbolSize: CGFloat = 13

    private static let simulated = SimulatedSpectrum()

    var body: some View {
        switch viewModel.settings.soundwaveMode {
        case .live:
            SoundwaveView(levels: { [weak spectrum = viewModel.spectrum] in spectrum?.levels() ?? [] },
                          isActive: viewModel.spectrum.isActive,
                          color: viewModel.waveColor)
        case .simulated:
            // Driven by the playback position, so the imaginary beat follows the
            // song: it holds on pause and restarts with a new track.
            SoundwaveView(levels: { [nowPlaying = viewModel.nowPlaying] in
                              Self.simulated.levels(at: nowPlaying.position(at: Date()))
                          },
                          isActive: viewModel.nowPlaying.isPlaying,
                          color: viewModel.waveColor)
        case .off:
            Image(systemName: "waveform")
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(viewModel.waveColor.opacity(viewModel.nowPlaying.isPlaying ? 0.85 : 0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
