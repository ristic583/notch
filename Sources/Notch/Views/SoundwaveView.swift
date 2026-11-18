import AppKit
import SwiftUI

/// Bars driven by the live spectrum. Rendering bypasses SwiftUI: a display link
/// moves a few CALayers directly, and pauses itself when idle (0 CPU).
struct SoundwaveView: NSViewRepresentable {
    /// Band levels, 0...1: the live spectrum or the simulated one.
    let levels: () -> [Float]
    /// While false the bars fall to rest and the display link pauses.
    let isActive: Bool
    var color: Color = .white

    func makeNSView(context: Context) -> SoundwaveNSView {
        SoundwaveNSView()
    }

    func updateNSView(_ view: SoundwaveNSView, context: Context) {
        view.levelsProvider = levels
        view.barColor = NSColor(color)
        view.isActive = isActive
    }
}

final class SoundwaveNSView: NSView {
    var levelsProvider: (() -> [Float])?
    var barColor: NSColor = .white {
        didSet { bars.forEach { $0.backgroundColor = barColor.cgColor } }
    }
    var isActive = false {
        didSet { if isActive != oldValue { updateDisplayLink() } }
    }

    /// Resting height as a fraction of the view height.
    private let minimumFraction: CGFloat = 0.16
    /// Smoothing time constants: fast attack, slower decay.
    private let attack: Double = 0.045
    private let decay: Double = 0.17

    private let barCount = SpectrumAnalyzer.bandCount
    private var bars: [CALayer] = []
    private var displayed: [Double]
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var powerObserver: NSObjectProtocol?

    /// 60 fps is plenty for bars and halves the cost on ProMotion; Low Power Mode drops to 30.
    private static var frameRateRange: CAFrameRateRange {
        ProcessInfo.processInfo.isLowPowerModeEnabled
            ? CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    override init(frame: NSRect) {
        displayed = Array(repeating: 0, count: barCount)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = barColor.cgColor
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayLink?.preferredFrameRateRange = Self.frameRateRange
            }
        }
    }

    deinit {
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutBars()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayLink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        bars.forEach { $0.contentsScale = scale }
    }

    private func updateDisplayLink() {
        let needsLink = window != nil && (isActive || displayed.contains { $0 > 0.002 })
        if needsLink, displayLink == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = Self.frameRateRange
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTimestamp = 0
        } else if !needsLink, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(max(now - lastTimestamp, 0.001), 0.1)
        lastTimestamp = now

        let targets = isActive ? (levelsProvider?() ?? []) : []
        var settled = true
        for i in 0..<barCount {
            let target = i < targets.count ? Double(targets[i]) : 0
            let current = displayed[i]
            let tau = target > current ? attack : decay
            displayed[i] = current + (target - current) * (1 - exp(-dt / tau))
            if displayed[i] > 0.002 { settled = false }
        }
        layoutBars()
        if !isActive, settled { updateDisplayLink() }
    }

    private func layoutBars() {
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let slot = bounds.width / CGFloat(barCount)
        let width = max(1.5, slot * 0.58)
        let minimum = max(width, bounds.height * minimumFraction)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let height = minimum + (bounds.height - minimum) * CGFloat(min(max(displayed[i], 0), 1))
            bar.frame = CGRect(x: slot * CGFloat(i) + (slot - width) / 2,
                               y: (bounds.height - height) / 2,
                               width: width, height: height)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
    }
}
