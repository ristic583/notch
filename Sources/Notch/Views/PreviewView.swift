import SwiftUI

/// Compact card shown for a few seconds when the track changes.
struct PreviewView: View {
    let viewModel: NotchViewModel
    let namespace: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            // As high as possible: the text (centered in the 40 pt row, ~3 pt inset) sits
            // just below the camera housing; artwork and bars are in the wings beside it.
            Color.clear.frame(height: max(0, viewModel.geometry.notchSize.height - 1))
            HStack(spacing: 11) {
                ArtworkView(track: viewModel.track, direction: viewModel.trackDirection, cornerRadius: 8)
                    .matchedGeometryEffect(id: "artwork", in: namespace)
                    .frame(width: 40, height: 40)
                TrackTitleView(track: viewModel.track, direction: viewModel.trackDirection)
                WaveIndicator(viewModel: viewModel, symbolSize: 14)
                    .matchedGeometryEffect(id: "wave", in: namespace)
                    .frame(width: 26, height: 18)
            }
        }
        .padding(.horizontal, 18)
    }
}
