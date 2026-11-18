import SwiftUI

/// Small cover on the left wing, live bars on the right wing; the middle stays
/// hidden behind the camera housing.
struct CollapsedView: View {
    let viewModel: NotchViewModel
    let namespace: Namespace.ID

    var body: some View {
        let height = viewModel.geometry.notchSize.height
        let isHover = viewModel.state == .hover
        let artworkSize = height - 10
        let wing = max(artworkSize, viewModel.wingWidth(for: viewModel.state) - (isHover ? 14 : 11))
        HStack(spacing: 0) {
            ArtworkView(track: viewModel.track, direction: viewModel.trackDirection, cornerRadius: 6)
                .matchedGeometryEffect(id: "artwork", in: namespace)
                .frame(width: artworkSize, height: artworkSize)
                .scaleEffect(isHover ? 1.14 : 1)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                if viewModel.settings.showMicIndicator, viewModel.microphone.isInUse, !viewModel.microphone.isMuted {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                        .help("Microphone in use")
                }
                WaveIndicator(viewModel: viewModel)
                    .matchedGeometryEffect(id: "wave", in: namespace)
                    .frame(width: artworkSize, height: artworkSize * 0.62)
                    .scaleEffect(isHover ? 1.14 : 1)
            }
            .frame(maxWidth: wing, alignment: .trailing)
            .animation(.snappy, value: viewModel.microphone.isInUse)
        }
        .padding(.horizontal, isHover ? 14 : 11)
        .frame(maxHeight: .infinity)
    }
}

/// Transient states: charging and battery warnings stay in the wings beside the
/// notch, volume and brightness drop down into a slim card with a full-width bar.
struct AlertView: View {
    let viewModel: NotchViewModel

    var body: some View {
        let battery = viewModel.battery
        let level = battery.hasBattery ? battery.level : 76
        Group {
            switch viewModel.alert {
            case .charging:
                wings {
                    label("bolt.fill", "Charging", color: .green, pulse: true)
                } trailing: {
                    batteryInfo(level: level, color: .green, animated: true)
                }
            case .fullyCharged:
                wings {
                    label("checkmark.circle.fill", "Charged", color: .green)
                } trailing: {
                    batteryInfo(level: 100, color: .green, animated: false)
                }
            case .lowBattery:
                wings {
                    label("exclamationmark.triangle.fill", "Low Battery",
                          color: level <= 10 ? .red : .orange, pulse: true)
                } trailing: {
                    batteryInfo(level: level, color: level <= 10 ? .red : .orange, animated: false)
                }
            case .timerDone:
                wings {
                    label("timer", "Time's up", color: .white, pulse: true)
                } trailing: {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(.white.opacity(0.85))
                        .symbolEffect(.pulse, options: .repeating)
                }
            case .agent:
                let session = viewModel.agentAlert
                wings {
                    label(session?.status.symbol ?? "sparkles",
                          session?.project ?? "Claude Code",
                          color: session?.status == .waiting ? .orange : .green,
                          pulse: session?.status == .waiting)
                } trailing: {
                    Text(session?.status.title ?? "")
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .usageLimit:
                let window = viewModel.usage.fiveHour
                let percent = Int((window?.usedPercent ?? 0).rounded())
                wings {
                    label("asterisk", "Claude", color: percent >= 90 ? .red : .claudeOrange, pulse: true)
                } trailing: {
                    HStack(spacing: 0) {
                        Text("\(percent)%")
                            .foregroundStyle(.white.opacity(0.85))
                        if let remaining = window?.remaining {
                            Text(" · \(remaining)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                }
            case .accessory:
                let accessory = viewModel.bluetooth.lastConnected
                wings {
                    label(accessory?.symbol ?? "wave.3.right", accessory?.name ?? "Connected", color: .white)
                } trailing: {
                    accessoryBattery(accessory)
                }
            case .volume:
                let output = viewModel.audioOutput
                let volume = output.isMuted ? 0 : output.volume
                LevelCard(notchHeight: viewModel.geometry.notchSize.height,
                          symbol: VolumeSymbol.name(volume: volume, muted: output.isMuted),
                          level: volume)
            case .brightness:
                LevelCard(notchHeight: viewModel.geometry.notchSize.height,
                          symbol: viewModel.brightness.brightness < 0.5 ? "sun.min.fill" : "sun.max.fill",
                          level: viewModel.brightness.brightness)
            }
        }
        .font(.system(size: 12.5, weight: .semibold))
    }

    private func wings<Leading: View, Trailing: View>(@ViewBuilder _ leading: () -> Leading,
                                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        // Each side is clamped to its wing, so the camera housing never cuts text.
        let wing = max(0, viewModel.wingWidth(for: .alert) - 16)
        return HStack(spacing: 0) {
            leading()
                .frame(maxWidth: wing, alignment: .leading)
            Spacer(minLength: 0)
            trailing()
                .frame(maxWidth: wing, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }

    private func label(_ symbol: String, _ text: String, color: Color, pulse: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: pulse)
            Text(text)
                .foregroundStyle(.white.opacity(0.85))
                .minimumScaleFactor(0.8)
        }
    }

    /// AirPods report each bud; other devices only one level.
    @ViewBuilder
    private func accessoryBattery(_ accessory: BluetoothAccessory?) -> some View {
        if let accessory, let lowest = accessory.lowestLevel {
            HStack(spacing: 6) {
                if accessory.left != nil || accessory.right != nil {
                    Image(systemName: "bolt.horizontal")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.system(size: 10))
                }
                Text("\(Int((lowest * 100).rounded()))%")
                    .foregroundStyle(.white)
                    .monospacedDigit()
                BatteryGlyph(level: Int((lowest * 100).rounded()),
                             color: lowest <= 0.2 ? .orange : .green,
                             animated: false)
            }
        } else {
            Text("Connected")
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func batteryInfo(level: Int, color: Color, animated: Bool) -> some View {
        HStack(spacing: 7) {
            Text("\(level)%")
                .foregroundStyle(.white)
                .monospacedDigit()
            BatteryGlyph(level: level, color: color, animated: animated)
        }
    }
}

/// Volume / brightness: icon, full-width bar and percentage, all below the notch.
private struct LevelCard: View {
    let notchHeight: CGFloat
    let symbol: String
    let level: Float

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.white)
                    .frame(width: 20)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white)
                            .frame(width: max(7, proxy.size.width * CGFloat(min(max(level, 0), 1))))
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 7)
                Text("\(Int((level * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, alignment: .trailing)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: level)
            .frame(height: 22)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }
}

enum VolumeSymbol {
    static func name(volume: Float, muted: Bool) -> String {
        if muted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Battery outline filled to the level; optionally grows in with a light sweep.
private struct BatteryGlyph: View {
    let level: Int
    let color: Color
    let animated: Bool
    @State private var filled = false

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1.2)
                GeometryReader { proxy in
                    let shown = animated ? (filled ? max(level, 8) : 0) : max(level, 8)
                    let width = proxy.size.width * CGFloat(shown) / 100
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(color)
                        .frame(width: width)
                        .overlay {
                            if animated {
                                PhaseAnimator([false, true]) { phase in
                                    LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                                   startPoint: .leading, endPoint: .trailing)
                                        .frame(width: 12)
                                        .offset(x: phase ? width : -12)
                                } animation: { phase in
                                    phase ? .easeInOut(duration: 0.9).delay(0.2) : .linear(duration: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                }
                .padding(2)
            }
            .frame(width: 26, height: 13)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.45))
                .frame(width: 2, height: 5)
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.9).delay(0.15)) { filled = true }
        }
    }
}
