import AppKit
import SwiftUI

/// Card shown after a click. Tabs (Now Playing / Shelf) live in the left wing beside
/// the camera housing, the battery level in the right wing.
struct ExpandedView: View {
    let viewModel: NotchViewModel
    let namespace: Namespace.ID
    @State private var isDropTargeted = false

    var body: some View {
        let notchHeight = viewModel.geometry.notchSize.height
        let licensed = viewModel.license.isValid && viewModel.licenseConfirmed
        VStack(spacing: 0) {
            TopBar(viewModel: viewModel)
                .opacity(licensed ? 1 : 0)
                .allowsHitTesting(licensed)
                .frame(height: notchHeight)
                .padding(.bottom, 16)

            Group {
                if !licensed {
                    ActivationPane(license: viewModel.license)
                        .transition(.opacity)
                } else {
                switch viewModel.tab {
                case .nowPlaying:
                    NowPlayingPane(viewModel: viewModel, namespace: namespace)
                        .transition(.opacity.combined(with: .offset(x: -16)))
                case .shelf:
                    ShelfPane(viewModel: viewModel, isDropTargeted: isDropTargeted)
                        .transition(.opacity.combined(with: .offset(x: 16)))
                case .clipboard:
                    ClipboardPane(viewModel: viewModel)
                        .transition(.opacity.combined(with: .offset(x: 16)))
                case .tools:
                    ToolsPane(viewModel: viewModel)
                        .transition(.opacity.combined(with: .offset(x: 16)))
                case .claude:
                    ClaudePane(viewModel: viewModel)
                        .transition(.opacity.combined(with: .offset(x: 16)))
                }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 14)
        .animation(.snappy, value: licensed)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard licensed, viewModel.settings.shelfEnabled else { return false }
            withAnimation(.snappy) { viewModel.dropFiles(providers) }
            return true
        }
        .onChange(of: viewModel.tab) { _, tab in
            if tab == .claude { viewModel.usage.refreshNow() }
        }
        .onChange(of: viewModel.isVisible(viewModel.tab)) { _, visible in
            if !visible { withAnimation(.snappy) { viewModel.tab = .nowPlaying } } // switched off in Settings
        }
        .onChange(of: isDropTargeted) { _, targeted in
            if targeted, licensed, viewModel.settings.shelfEnabled {
                withAnimation(.snappy) { viewModel.tab = .shelf }
            }
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    let viewModel: NotchViewModel
    /// Matches the card's horizontal padding.
    static let sidePadding: CGFloat = 26

    var body: some View {
        // Tabs live in the two wings beside the camera housing, never under it.
        let wing = max(0, viewModel.wingWidth(for: .expanded) - Self.sidePadding)
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                tab(.nowPlaying, symbol: "music.note")
                if viewModel.isVisible(.shelf) {
                    tab(.shelf, symbol: "tray.full.fill", badge: viewModel.shelf.items.count)
                }
            }
            // Both groups hug the camera housing instead of the card edges.
            .padding(.trailing, 18)
            .frame(width: wing, alignment: .trailing)

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                if viewModel.isVisible(.clipboard) {
                    tab(.clipboard, symbol: "doc.on.clipboard")
                }
                if viewModel.isVisible(.tools) {
                    tab(.tools, symbol: "switch.2")
                }
                if viewModel.isVisible(.claude) {
                    ClaudeTabButton(viewModel: viewModel)
                }
            }
            .padding(.leading, 18)
            .frame(width: wing, alignment: .leading)
        }
    }

    private func tab(_ target: ExpandedTab, symbol: String, badge: Int = 0, tint: Color = .white) -> some View {
        TabButton(symbol: symbol, isSelected: viewModel.tab == target, badge: badge, tint: tint) {
            withAnimation(.snappy) { viewModel.tab = target }
        }
    }
}

/// Claude tab with a ring showing the 5-hour usage, readable without opening it.
private struct ClaudeTabButton: View {
    let viewModel: NotchViewModel

    var body: some View {
        let isSelected = viewModel.tab == .claude
        let usage = viewModel.usage
        let window = usage.fiveHour
        let percent = window.map { $0.isExpired ? 0 : $0.usedPercent } ?? 0
        let progress = percent / 100
        Button {
            withAnimation(.snappy) { viewModel.tab = .claude }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.claudeOrange.opacity(isSelected ? 0.22 : 0))
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1.8)
                Circle()
                    .trim(from: 0, to: max(0.001, min(progress, 1)))
                    .stroke(ringColor(progress), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: progress)
                Image(systemName: "asterisk")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? Color.claudeOrange : Color.claudeOrange.opacity(0.75))
            }
            .frame(width: 21, height: 21)
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(helpText)
    }

    private func ringColor(_ progress: Double) -> Color {
        switch progress {
        case ..<0.7: .claudeOrange
        case ..<0.9: .orange
        default: .red
        }
    }

    private var helpText: String {
        let usage = viewModel.usage
        guard let window = usage.fiveHour, !window.isExpired else {
            return "Claude — usage not connected yet"
        }
        let text = "Claude — \(Int(window.usedPercent.rounded()))% of the 5-hour limit"
        return window.remaining.map { "\(text), resets in \($0)" } ?? text
    }
}

private struct TabButton: View {
    let symbol: String
    let isSelected: Bool
    var badge: Int = 0
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isSelected ? tint : tint.opacity(0.45))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(Color.white.opacity(isSelected ? 0.16 : 0)))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(Color.white))
                            .offset(x: 3, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Now Playing

private struct NowPlayingPane: View {
    let viewModel: NotchViewModel
    let namespace: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ArtworkView(track: viewModel.track, direction: viewModel.trackDirection, cornerRadius: 12)
                    .matchedGeometryEffect(id: "artwork", in: namespace)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

                TrackTitleView(track: viewModel.track, direction: viewModel.trackDirection)

                WaveIndicator(viewModel: viewModel, symbolSize: 16)
                    .matchedGeometryEffect(id: "wave", in: namespace)
                    .frame(width: 30, height: 22)
            }

            Group {
                if viewModel.settings.soundwaveMode == .live, viewModel.spectrum.status == .permissionDenied {
                    PermissionBanner()
                } else {
                    ProgressRow(viewModel: viewModel)
                }
            }
            .padding(.top, 12)

            ControlsRow(viewModel: viewModel)
                .padding(.top, 8)
        }
    }
}

/// Progress bar that doubles as a scrubber: thickens on hover, follows the drag
/// (time labels included) and seeks when released.
private struct ProgressRow: View {
    let viewModel: NotchViewModel
    /// Drag position as a fraction of the track while scrubbing.
    @State private var dragFraction: Double?
    @State private var isHovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = viewModel.track?.duration ?? 0
            let canSeek = duration > 0
            let live = viewModel.nowPlaying.position(at: context.date)
            let position = dragFraction.map { $0 * duration } ?? live
            let fraction = canSeek ? min(max(position / duration, 0), 1) : 0
            let isActive = canSeek && (isHovering || dragFraction != nil)
            HStack(spacing: 10) {
                Text(Self.format(position))
                    .frame(width: 38, alignment: .leading)
                GeometryReader { proxy in
                    let barHeight: CGFloat = isActive ? 8 : 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(isActive ? 0.24 : 0.18))
                        // No animation on purpose: a 1 px step every 0.5 s looks smooth, while a
                        // re-triggered linear animation keeps SwiftUI rendering at 120 Hz (~10% CPU).
                        Capsule().fill(Color.white.opacity(dragFraction != nil ? 1 : 0.9))
                            .frame(width: max(barHeight, proxy.size.width * fraction))
                    }
                    .frame(height: barHeight)
                    .frame(maxHeight: .infinity) // centered in a taller hit area
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard canSeek else { return }
                            if dragFraction == nil { viewModel.setInteracting(true) }
                            dragFraction = Self.fraction(of: value.location.x, in: proxy.size.width)
                        }
                        .onEnded { value in
                            guard canSeek else { return }
                            viewModel.seek(to: Self.fraction(of: value.location.x, in: proxy.size.width) * duration)
                            dragFraction = nil
                            viewModel.setInteracting(false)
                        })
                    .onHover { isHovering = $0 }
                    .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isActive)
                }
                .frame(height: 16)
                Text(canSeek ? "-" + Self.format(max(0, duration - position)) : "--:--")
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(dragFraction != nil ? 0.9 : 0.55))
        }
        .frame(height: 16)
    }

    private static func fraction(of x: CGFloat, in width: CGFloat) -> Double {
        width > 0 ? Double(min(max(x / width, 0), 1)) : 0
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ControlsRow: View {
    let viewModel: NotchViewModel

    var body: some View {
        HStack(spacing: 34) {
            ControlButton(symbol: "backward.fill", size: 17) { viewModel.skip(.previous) }
            ControlButton(symbol: viewModel.nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 23) {
                viewModel.togglePlayPause()
            }
            ControlButton(symbol: "forward.fill", size: 17) { viewModel.skip(.next) }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shelf

private struct ShelfPane: View {
    let viewModel: NotchViewModel
    let isDropTargeted: Bool

    var body: some View {
        let shelf = viewModel.shelf
        Group {
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 22, weight: .medium))
                        .symbolEffect(.bounce, value: isDropTargeted)
                    Text("Drop files here")
                        .font(.system(size: 13, weight: .semibold))
                    Text("They stay on the notch until you drag them out.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .foregroundStyle(.white.opacity(isDropTargeted ? 1 : 0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(shelf.items) { item in
                                ShelfTile(item: item, shelf: shelf)
                                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        .animation(.snappy, value: shelf.items)
                    }
                    VStack(spacing: 6) {
                        ShelfActionButton(symbol: "dot.radiowaves.left.and.right", help: "AirDrop all") {
                            shelf.airDrop(shelf.items)
                        }
                        ShelfActionButton(symbol: "trash", help: "Clear shelf") {
                            withAnimation(.snappy) { shelf.removeAll() }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.white.opacity(isDropTargeted ? 0.7 : (shelf.items.isEmpty ? 0.22 : 0)))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(isDropTargeted ? 0.08 : 0)))
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let shelf: ShelfService
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 66, height: 26, alignment: .top)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(isHovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    withAnimation(.snappy) { shelf.remove(item) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .onTapGesture(count: 2) { shelf.open(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Button("AirDrop") { shelf.airDrop([item]) }
            Divider()
            Button("Remove from Shelf") { withAnimation(.snappy) { shelf.remove(item) } }
        }
        .help(item.url.path)
    }
}

private struct ShelfActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.16 : 0.08)))
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
    }
}


private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: 40, height: 34)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.12 : 0)).frame(width: 36, height: 36))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.slash")
                .foregroundStyle(.orange)
            Text("System audio access is off, so the soundwave can't react.")
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Settings") { AudioCapturePermission.openSystemSettings() }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .font(.system(size: 11, weight: .medium))
        .frame(height: 16)
    }
}
