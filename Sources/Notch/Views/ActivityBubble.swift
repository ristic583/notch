import SwiftUI

/// Separate capsule beside the notch, the way iPhone splits off a second
/// activity: an agent waiting for you, otherwise the running timer.
struct ActivityBubble: View {
    let viewModel: NotchViewModel
    @State private var isHovering = false

    var body: some View {
        let size = viewModel.activityBubbleSize
        Group {
            switch viewModel.activity {
            case let .agent(session):
                agent(session)
            case .timer:
                timer
            case nil:
                EmptyView()
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Capsule().fill(Color.black))
        .scaleEffect(isHovering ? 1.07 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture { tapped() }
    }

    private var timer: some View {
        let timer = viewModel.timer
        let progress = timer.total > 0 ? 1 - timer.remaining / timer.total : 0
        return HStack(spacing: 6) {
            if let phase = timer.phase {
                Image(systemName: phase.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(phase == .work ? .white.opacity(0.85) : .green)
            }
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.001, progress))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            }
            .frame(width: 13, height: 13)
            Text(timer.formattedRemaining)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .help("Timer — click to open")
    }

    private func agent(_ session: AgentSession) -> some View {
        HStack(spacing: 6) {
            Image(systemName: session.status.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(session.status == .waiting ? .orange : .white)
                .symbolEffect(.pulse, options: .repeating, isActive: session.status == .waiting)
            Text(session.project)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .help(session.message ?? "Claude Code — \(session.status.title)")
    }

    private func tapped() {
        switch viewModel.activity {
        case let .agent(session):
            if let directory = session.directory {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        default:
            viewModel.open(tab: .tools)
        }
    }
}
