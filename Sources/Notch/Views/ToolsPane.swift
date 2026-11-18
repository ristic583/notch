import SwiftUI

/// Timer, microphone and keep-awake. Deliberately sparse: one timer line and
/// one row of toggles, with the details in tooltips instead of subtitles.
struct ToolsPane: View {
    let viewModel: NotchViewModel

    var body: some View {
        VStack(spacing: 10) {
            TimerCard(timer: viewModel.timer)
            HStack(spacing: 8) {
                MicrophoneChip(microphone: viewModel.microphone)
                AwakeChip(viewModel: viewModel)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct TimerCard: View {
    let timer: TimerService

    var body: some View {
        HStack(spacing: 10) {
            if timer.isRunning {
                if let phase = timer.phase {
                    Image(systemName: phase.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(phase == .work ? .white : .green)
                        .help("\(phase.title) — round \(timer.completedRounds + 1)")
                }
                Text(timer.formattedRemaining)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.white)
                                .frame(width: proxy.size.width * progress, height: 4)
                                .animation(.linear(duration: 0.5), value: progress)
                        }
                    }
                PillButton(title: "+1m") { timer.add(60) }
                PillButton(title: "Stop", prominent: true) { timer.cancel() }
            } else {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Timer")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                ForEach(TimerService.presets, id: \.self) { preset in
                    PillButton(title: Self.label(for: preset)) { timer.start(preset) }
                }
                PillButton(title: "Pomodoro") { timer.startPomodoro() }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var progress: Double {
        timer.total > 0 ? min(max(1 - timer.remaining / timer.total, 0), 1) : 0
    }

    private static func label(for seconds: TimeInterval) -> String {
        seconds < 3600 ? "\(Int(seconds / 60))m" : "\(Int(seconds / 3600))h"
    }
}

private struct MicrophoneChip: View {
    let microphone: MicrophoneService

    var body: some View {
        ToolChip(symbol: microphone.isMuted ? "mic.slash.fill" : "mic.fill",
                 label: microphone.isMuted ? "Muted" : (microphone.isInUse ? "Mic in use" : "Mic"),
                 tint: microphone.isMuted ? .orange : (microphone.isInUse ? .red : .white),
                 isOn: microphone.isMuted,
                 isEnabled: microphone.canMute,
                 help: microphone.deviceName.isEmpty
                     ? "No input device"
                     : "\(microphone.deviceName) — click to \(microphone.isMuted ? "unmute" : "mute")",
                 action: microphone.toggleMute)
    }
}

private struct AwakeChip: View {
    let viewModel: NotchViewModel

    var body: some View {
        let awake = viewModel.awake
        let settings = viewModel.settings
        ToolChip(symbol: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                 label: awake.isActive ? (awake.remainingText ?? "Awake") : "Keep awake",
                 tint: awake.isActive ? .yellow : .white,
                 isOn: awake.isActive,
                 isEnabled: true,
                 help: help,
                 action: { awake.toggle(defaultDuration: settings.awakeDefaultDuration, mode: settings.awakeMode) })
            .contextMenu {
                ForEach(AwakeService.durations, id: \.title) { duration in
                    Button(duration.title) { awake.enable(for: duration.seconds, mode: settings.awakeMode) }
                }
                Divider()
                Picker("Keeps awake", selection: Binding(get: { settings.awakeMode },
                                                         set: { mode in
                                                             settings.awakeMode = mode
                                                             if awake.isActive { awake.enable(for: nil, mode: mode) }
                                                         })) {
                    ForEach(AwakeMode.allCases) { Text($0.title).tag($0) }
                }
                if awake.isActive {
                    Divider()
                    Button("Turn off") { awake.disable() }
                }
            }
    }

    private var help: String {
        let awake = viewModel.awake
        let mode = viewModel.settings.awakeMode == .system ? "system only, display may sleep" : "display stays on"
        if awake.isActive {
            return (awake.isAutomatic ? "On automatically — " : "") + mode + ". Right-click for a duration."
        }
        return "Keep the Mac awake (\(mode)). Right-click for a duration."
    }
}

private struct ToolChip: View {
    let symbol: String
    let label: String
    let tint: Color
    let isOn: Bool
    let isEnabled: Bool
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isOn ? 0.18 : (isHovering ? 0.12 : 0.07))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(help)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
    }
}

private struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(prominent
                    ? Color.white.opacity(isHovering ? 1 : 0.9)
                    : Color.white.opacity(isHovering ? 0.22 : 0.13)))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
    }
}
