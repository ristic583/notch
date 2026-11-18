import SwiftUI

/// Open path tracing the sides and bottom of the camera housing, starting at
/// the top left. Trimmed, it reads as a progress line around the notch.
struct NotchOutlineShape: Shape {
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(bottomRadius, rect.height, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Song (or timer) progress drawn around the physical notch: a hairline with a
/// soft glow behind it.
struct NotchProgressLine: View {
    let viewModel: NotchViewModel
    /// How far outside the camera housing the line sits.
    private let gap: CGFloat = 3
    /// 0.5 pt is one physical pixel on a Retina display.
    private let lineWidth: CGFloat = 0.5

    var body: some View {
        let notch = viewModel.geometry.notchSize
        let shape = NotchOutlineShape(bottomRadius: notch.height * 0.32 + gap)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let progress = viewModel.notchProgress(at: context.date) ?? 0
            let color = viewModel.notchProgressColor
            ZStack {
                shape
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Glow: the same path, wider and blurred, under the hairline.
                shape
                    .trim(from: 0, to: max(0.0005, progress))
                    .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: lineWidth * 4, lineCap: .round))
                    .blur(radius: 2.5)
                shape
                    .trim(from: 0, to: max(0.0005, progress))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            .animation(.linear(duration: 0.5), value: progress)
            .frame(width: notch.width + gap * 2, height: notch.height + gap)
        }
        .frame(width: notch.width + gap * 2, height: notch.height + gap)
        .allowsHitTesting(false)
    }
}
