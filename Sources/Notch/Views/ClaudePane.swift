import AppKit
import SwiftUI

extension Color {
    /// Claude's orange, so the tab is recognisable at a glance.
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// Subscription usage and the live Claude Code sessions.
struct ClaudePane: View {
    let viewModel: NotchViewModel
    /// From pressing Connect until the check has had its moment.
    @State private var connecting = false

    var body: some View {
        let account = viewModel.usage.account
        VStack(spacing: 8) {
            if needsAccount {
                ConnectCard(account: account) {
                    connecting = true
                    viewModel.holdOpen(true) // the browser takes focus; the card waits for it
                    account.signIn()
                }
                .transition(.opacity)
            } else {
                UsageCard(fiveHour: viewModel.usage.fiveHour, sevenDay: viewModel.usage.sevenDay)
                    .transition(.opacity)
            }

            if viewModel.settings.agentActivity {
                // Sessions wait for the account, like the usage above them.
                if needsAccount || viewModel.agents.activeSessions.isEmpty {
                    HintCard(text: "Your Claude Code sessions will show up here.")
                } else {
                    SessionList(agents: viewModel.agents)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: account.isSigningIn) { _, signingIn in
            guard connecting, !signingIn else { return }
            // Signed in: the check shows, then the real numbers and sessions fade in.
            let delay = account.isSignedIn ? 1.6 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.snappy(duration: 0.35)) { connecting = false }
                viewModel.holdOpen(false)
            }
        }
    }

    /// Not signed in and no live status-line reading to show instead.
    private var needsAccount: Bool {
        let usage = viewModel.usage
        return connecting || (!usage.account.isSignedIn && !(usage.fiveHour.map { !$0.isExpired } ?? false))
    }
}

private struct UsageCard: View {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    var blurred = false

    var body: some View {
        VStack(spacing: 10) {
            window("5 hours", fiveHour)
            window("This week", sevenDay)
        }
        .blur(radius: blurred ? 4 : 0)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    @ViewBuilder
    private func window(_ title: String, _ value: UsageWindow?) -> some View {
        let shown = value.map { $0.isExpired ? 0 : $0.usedPercent } ?? 0
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                if let value, !value.isExpired {
                    Text("\(Int(shown.rounded()))%")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    if let remaining = value.remaining {
                        Text("· \(remaining)")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                } else {
                    Text(value == nil ? "—" : "reset")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Capsule()
                .fill(Color.white.opacity(0.16))
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(color(for: shown))
                            .frame(width: proxy.size.width * min(max(shown / 100, 0), 1), height: 5)
                            .animation(.snappy, value: shown)
                    }
                }
        }
    }

    private func color(for percent: Double) -> Color {
        switch percent {
        case ..<70: .claudeOrange
        case ..<90: .orange
        default: .red
        }
    }
}

/// The usage bars, blurred, with the way to connect on top.
private struct ConnectCard: View {
    let account: ClaudeAccount
    let connect: () -> Void

    var body: some View {
        UsageCard(fiveHour: UsageWindow(usedPercent: 42, resetsAt: Date().addingTimeInterval(8_220)),
                  sevenDay: UsageWindow(usedPercent: 18, resetsAt: Date().addingTimeInterval(345_600)),
                  blurred: true)
            .allowsHitTesting(false)
            .overlay { prompt }
    }

    @ViewBuilder
    private var prompt: some View {
        VStack(spacing: 5) {
            if account.isSignedIn { // only while the check has its moment
                ConnectedCheck()
                Text("Connected")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
            } else if account.isSigningIn {
                Text("Finish in your browser…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Button("Cancel") { account.cancelSignIn() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Button(action: connect) {
                    HStack(spacing: 5) {
                        Image(systemName: "asterisk")
                            .font(.system(size: 10, weight: .bold))
                        Text("Connect Claude")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 27)
                    .background(Capsule().fill(Color.claudeOrange))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                if let problem = account.problem {
                    Text(problem)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                }
            }
        }
    }
}

/// A circle that pops in and draws its check, for the moment the sign-in lands.
private struct ConnectedCheck: View {
    @State private var popped = false
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.claudeOrange)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .padding(8.5)
        }
        .frame(width: 30, height: 30)
        .scaleEffect(popped ? 1 : 0.3)
        .opacity(popped ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { popped = true }
            withAnimation(.easeOut(duration: 0.3).delay(0.15)) { drawn = true }
        }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return path
    }
}

private struct SessionList: View {
    let agents: AgentActivityService

    var body: some View {
        VStack(spacing: 4) {
            ForEach(agents.activeSessions.prefix(3)) { session in
                Button {
                    if let directory = session.directory {
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: session.status.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(color(for: session.status))
                            .frame(width: 16)
                        Text(session.project)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(session.status.title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.directory?.path ?? session.project)
            }
        }
    }

    private func color(for status: AgentSession.Status) -> Color {
        switch status {
        case .waiting: .claudeOrange
        case .working: .white.opacity(0.7)
        case .done: .green
        }
    }
}

private struct HintCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}
