import SwiftUI

/// Fills the whole (fixed-size, transparent) panel; the pill is pinned to the
/// top center and only its size / shape animate.
struct NotchRootView: View {
    let viewModel: NotchViewModel
    @Namespace private var namespace

    var body: some View {
        let metrics = viewModel.metrics
        let shape = NotchShape(topRadius: metrics.topRadius, bottomRadius: metrics.bottomRadius)
        let isExpanded = viewModel.state == .expanded || viewModel.state == .preview

        ZStack(alignment: .top) {
            if viewModel.showsActivityBubble {
                // Sits to the right of the pill, detached, like the second island on iPhone.
                ActivityBubble(viewModel: viewModel)
                    .offset(x: metrics.outerWidth / 2 + NotchViewModel.activityBubbleGap + viewModel.activityBubbleSize.width / 2,
                            y: 4)
                    .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
            }
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(isExpanded ? 0.45 : 0), radius: 14, y: 6)

            if viewModel.showsNotchProgress {
                NotchProgressLine(viewModel: viewModel)
                    .transition(.opacity)
            }

            content
                .padding(.horizontal, metrics.topRadius)
                .frame(width: metrics.outerWidth, height: metrics.size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: metrics.outerWidth, height: metrics.size.height)
        .contentShape(Rectangle()) // a notch-shaped hit area can miss clicks on the very top edge
        .onTapGesture { viewModel.pillTapped() }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: viewModel.hasMedia)
        .animation(.spring(response: 0.42, dampingFraction: 0.7), value: viewModel.showsActivityBubble)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showsNotchProgress)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .expanded:
            ExpandedView(viewModel: viewModel, namespace: namespace)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(.easeOut(duration: 0.25).delay(0.06)),
                    removal: .opacity.animation(.easeIn(duration: 0.12))
                ))
        case .preview:
            PreviewView(viewModel: viewModel, namespace: namespace)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(.easeOut(duration: 0.25).delay(0.06)),
                    removal: .opacity.animation(.easeIn(duration: 0.12))
                ))
        case .alert:
            AlertView(viewModel: viewModel)
                .transition(.blurReplace)
        case .collapsed, .hover:
            if viewModel.hasMedia {
                CollapsedView(viewModel: viewModel, namespace: namespace)
                    .frame(maxHeight: viewModel.metrics.size.height)
                    .transition(.blurReplace)
            }
        }
    }
}
