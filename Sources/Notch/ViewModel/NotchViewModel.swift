import AppKit
import Observation
import SwiftUI

enum NotchState: Equatable {
    case collapsed
    case hover
    case expanded
    /// Short peek at a new track: compact card that closes on its own.
    case preview
    /// Transient wide pill: charging, battery warnings, volume feedback (see `NotchAlert`).
    case alert
}

enum NotchAlert: Equatable {
    case charging
    case lowBattery
    case fullyCharged
    case volume
    case brightness
    case timerDone
    case accessory
    case agent
    case usageLimit

    /// Volume and brightness drop down into a slim card: a slider doesn't fit
    /// in the ~79 pt of pill left beside the camera housing.
    var isLevel: Bool { self == .volume || self == .brightness }
}

enum ExpandedTab: Equatable {
    case nowPlaying
    case shelf
    case clipboard
    case tools
    case claude
}

/// Size and corner radii of the black pill for one state.
struct NotchMetrics: Equatable {
    /// Body size, without the concave "ears" at the top corners.
    var size: CGSize
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    /// Full width including the ears.
    var outerWidth: CGFloat { size.width + topRadius * 2 }
}

@MainActor
@Observable
final class NotchViewModel {
    private(set) var state: NotchState = .collapsed
    private(set) var alert: NotchAlert = .charging
    private(set) var geometry: NotchGeometry
    /// The track shown in the UI. Lags `nowPlaying.track` by one run-loop turn so
    /// the slide direction is applied before the old content is removed.
    private(set) var track: NowPlayingTrack?
    private(set) var trackDirection: TrackDirection = .next
    private(set) var artworkColor: Color = .white
    var tab: ExpandedTab = .nowPlaying
    /// True while something inside the card is being used (scrubbing, a menu):
    /// the card must stay open even if the mouse leaves it.
    private(set) var isInteracting = false
    /// The session an agent alert is about.
    private(set) var agentAlert: AgentSession?
    /// A file drag from another app is in progress near the notch.
    private(set) var isFileDragging = false

    let settings: AppSettings
    let nowPlaying: NowPlayingService
    let spectrum: AudioSpectrumService
    let battery: BatteryService
    let audioOutput: AudioOutputService
    let brightness: BrightnessService
    let shelf: ShelfService
    let clipboard: ClipboardService
    let timer: TimerService
    let microphone: MicrophoneService
    let awake: AwakeService
    let bluetooth: BluetoothService
    let agents: AgentActivityService
    let usage: UsageService
    let license: LicenseService
    /// A second, independent answer for the card, so `license.isValid` alone unlocks nothing.
    private(set) var licenseConfirmed = false

    @ObservationIgnored private var collapseWork: DispatchWorkItem?
    /// Keeps the card open while something happens elsewhere, without taking the mouse.
    @ObservationIgnored private var isHeldOpen = false
    @ObservationIgnored private var alertWork: DispatchWorkItem?
    @ObservationIgnored private var previewWork: DispatchWorkItem?
    @ObservationIgnored private var clearTrackWork: DispatchWorkItem?
    @ObservationIgnored private var lastSkip: (direction: TrackDirection, date: Date)?

    init(settings: AppSettings, nowPlaying: NowPlayingService, spectrum: AudioSpectrumService,
         battery: BatteryService, audioOutput: AudioOutputService, brightness: BrightnessService,
         shelf: ShelfService, clipboard: ClipboardService, timer: TimerService,
         microphone: MicrophoneService, awake: AwakeService, bluetooth: BluetoothService,
         agents: AgentActivityService, usage: UsageService, license: LicenseService) {
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.spectrum = spectrum
        self.battery = battery
        self.audioOutput = audioOutput
        self.brightness = brightness
        self.shelf = shelf
        self.clipboard = clipboard
        self.timer = timer
        self.microphone = microphone
        self.awake = awake
        self.bluetooth = bluetooth
        self.agents = agents
        self.usage = usage
        self.license = license
        licenseConfirmed = { if case .success = LicenseCheck.stored() { true } else { false } }()
        geometry = NotchGeometry.preferredScreen().map(NotchGeometry.init(screen:))
            ?? NotchGeometry(screen: NSScreen.main!)
        brightness.use(screen: NotchGeometry.preferredScreen())

        nowPlaying.onTrackChange = { [weak self] old, new in self?.trackChanged(from: old, to: new) }
        nowPlaying.onPlayingChange = { [weak self] playing in self?.syncSpectrum(isPlaying: playing) }
        battery.onPowerConnected = { [weak self] in
            guard let self, self.settings.showChargingAlert else { return }
            self.showAlert(.charging)
        }
        battery.onLowBattery = { [weak self] _ in
            guard let self, self.settings.lowBatteryAlerts else { return }
            self.showAlert(.lowBattery, duration: 4)
        }
        timer.onFinished = { [weak self] in self?.showAlert(.timerDone, duration: 5) }
        agents.onStatusChange = { [weak self] session in
            guard let self else { return }
            self.usage.refreshNow() // a reply just finished, so the usage moved
            guard self.settings.agentActivity else { return }
            self.agentAlert = session
            self.showAlert(.agent, duration: session.status == .waiting ? 4 : 2.5)
        }
        usage.onLimitWarning = { [weak self] _ in
            guard let self, self.settings.usageAlerts else { return }
            self.showAlert(.usageLimit, duration: 4)
        }
        bluetooth.onConnected = { [weak self] _ in
            guard let self, self.settings.accessoryAlerts else { return }
            self.showAlert(.accessory, duration: 3.5)
        }
        battery.onFullyCharged = { [weak self] in
            guard let self, self.settings.fullyChargedAlert else { return }
            self.showAlert(.fullyCharged)
        }
    }

    /// Unlicensed, the pill stays a plain notch: no media, bubbles, progress or alerts.
    var hasMedia: Bool { track != nil && license.isValid }

    // MARK: - Detached activity bubble (Dynamic Island style)

    /// What the detached capsule shows, if anything.
    enum Activity: Equatable {
        case timer
        case agent(AgentSession)
    }

    /// An agent waiting for you matters more than the countdown.
    var activity: Activity? {
        guard license.isValid else { return nil }
        if settings.agentActivity, let session = agents.waitingSession { return .agent(session) }
        if timer.isRunning { return .timer }
        return nil
    }

    /// Separate capsule to the right of the notch, like the second island on iPhone.
    var showsActivityBubble: Bool { activity != nil && (state == .collapsed || state == .hover) }
    var activityBubbleSize: CGSize {
        let width: CGFloat
        switch activity {
        case .agent: width = 124 // icon + project name
        case .timer: width = timer.phase == nil ? 76 : 92 // a pomodoro run shows its phase
        case nil: width = 76
        }
        return CGSize(width: width, height: max(20, geometry.notchSize.height - 9))
    }
    /// Gap between the pill and the bubble.
    static let activityBubbleGap: CGFloat = 8

    func activityRect() -> CGRect {
        let pill = pillRect(for: state)
        let size = activityBubbleSize
        return CGRect(x: pill.maxX + Self.activityBubbleGap,
                      y: geometry.screenFrame.maxY - 4 - size.height,
                      width: size.width,
                      height: size.height)
    }

    /// Capture only runs while the soundwave is on and something is playing,
    /// so the system recording indicator isn't up for nothing.
    func syncSpectrum(isPlaying: Bool? = nil) {
        let playing = isPlaying ?? nowPlaying.isPlaying
        spectrum.setPlaying(playing && settings.soundwaveMode == .live)
    }

    var waveColor: Color {
        switch settings.waveColorMode {
        case .artwork: artworkColor
        case .white: .white
        case .custom: settings.customWaveColor
        }
    }

    // MARK: - Progress around the notch

    /// Song progress, or the timer when nothing is playing. nil = nothing to show.
    func notchProgress(at date: Date) -> Double? {
        guard settings.showNotchProgress else { return nil }
        if let duration = track?.duration, duration > 0 {
            return min(max(nowPlaying.position(at: date) / duration, 0), 1)
        }
        if timer.isRunning, timer.total > 0 {
            return min(max(1 - timer.remaining / timer.total, 0), 1)
        }
        return nil
    }

    var notchProgressColor: Color {
        (track?.duration ?? 0) > 0 ? waveColor : .orange
    }

    /// Shown in the states where the pill covers the area around the housing.
    var showsNotchProgress: Bool {
        guard license.isValid, notchProgress(at: Date()) != nil else { return false }
        return state == .collapsed || state == .hover || state == .preview || state == .expanded
    }

    // MARK: - Layout

    var metrics: NotchMetrics { metrics(for: state) }

    func metrics(for state: NotchState) -> NotchMetrics {
        let notch = geometry.notchSize
        let wing = notch.height + 12 // room for artwork / bars beside the notch
        switch state {
        case .collapsed where hasMedia:
            // A few points taller when the progress line runs below the housing.
            let height = notch.height + (showsNotchProgress ? 3 : 0)
            return NotchMetrics(size: CGSize(width: notch.width + wing * 2, height: height),
                                topRadius: 6, bottomRadius: height * 0.36)
        case .collapsed:
            let height = notch.height + (showsNotchProgress ? 3 : 0)
            return NotchMetrics(size: CGSize(width: notch.width, height: height),
                                topRadius: 6, bottomRadius: height * 0.3)
        case .hover where hasMedia:
            return NotchMetrics(size: CGSize(width: notch.width + wing * 2 + 20, height: notch.height + 6),
                                topRadius: 7, bottomRadius: (notch.height + 6) * 0.4)
        case .hover:
            let height = notch.height + (showsNotchProgress ? 6 : 5)
            return NotchMetrics(size: CGSize(width: notch.width + 24, height: height),
                                topRadius: 7, bottomRadius: height * 0.36)
        case .expanded:
            return NotchMetrics(size: CGSize(width: max(notch.width + 230, 430), height: notch.height + 162),
                                topRadius: 12, bottomRadius: 30)
        case .preview:
            return NotchMetrics(size: CGSize(width: max(notch.width + 170, 370), height: notch.height + 56),
                                topRadius: 10, bottomRadius: 22)
        case .alert where alert.isLevel:
            return NotchMetrics(size: CGSize(width: max(notch.width + 150, 340), height: notch.height + 44),
                                topRadius: 9, bottomRadius: 20)
        case .alert:
            return NotchMetrics(size: CGSize(width: notch.width + 190, height: notch.height),
                                topRadius: 6, bottomRadius: notch.height * 0.36)
        }
    }

    /// Space beside the camera housing in a given state. Content in the wings
    /// must stay inside this, otherwise the physical notch covers it.
    func wingWidth(for state: NotchState) -> CGFloat {
        max(0, (metrics(for: state).outerWidth - geometry.notchSize.width) / 2)
    }

    /// Fixed window size: large enough for every state plus the shadow,
    /// so animations never resize the window (no layout jumps).
    var windowSize: CGSize {
        let expanded = metrics(for: .expanded)
        return CGSize(width: expanded.outerWidth + 120, height: expanded.size.height + 50)
    }

    /// Pill rectangle in screen coordinates.
    func pillRect(for state: NotchState) -> CGRect {
        let m = metrics(for: state)
        return CGRect(x: geometry.centerX - m.outerWidth / 2,
                      y: geometry.screenFrame.maxY - m.size.height,
                      width: m.outerWidth,
                      height: m.size.height)
    }

    /// Pill rectangle for mouse hit tests. With the cursor pushed against the top of the
    /// screen, `NSEvent.mouseLocation.y` equals `maxY`, which `CGRect.contains` excludes,
    /// so the rect extends a little above the screen edge.
    func hitRect(for state: NotchState) -> CGRect {
        var rect = pillRect(for: state)
        rect.size.height += 2
        return rect
    }

    func updateGeometry(_ geometry: NotchGeometry) {
        brightness.use(screen: NotchGeometry.preferredScreen())
        guard geometry != self.geometry else { return }
        self.geometry = geometry
    }

    // MARK: - Mouse

    /// Returns whether the window should receive mouse events at this location.
    @discardableResult
    func mouseMoved(to point: CGPoint) -> Bool {
        if isFileDragging, NSEvent.pressedMouseButtons == 0 { fileDragEnded() }
        // While interacting the pointer may leave the card; keep it open and receiving events.
        if isInteracting { return true }
        switch state {
        case .collapsed:
            if pillRect(for: .collapsed).insetBy(dx: -4, dy: -4).contains(point) {
                setState(.hover)
            }
        case .hover:
            if !pillRect(for: .hover).insetBy(dx: -6, dy: -6).contains(point) {
                setState(.collapsed)
            }
        case .expanded:
            if hitRect(for: .expanded).contains(point) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil {
                scheduleCollapse(after: 1)
            }
        case .preview:
            if hitRect(for: .preview).contains(point) {
                previewWork?.cancel() // stays while the mouse is on it
                previewWork = nil
            } else if previewWork == nil {
                schedulePreviewEnd(after: 1)
            }
        case .alert:
            break
        }
        return hitRect(for: state).contains(point)
            || (showsActivityBubble && activityRect().insetBy(dx: -3, dy: -3).contains(point))
    }

    func mouseDownOutside() {
        if state == .expanded, !isInteracting, !isHeldOpen { setState(.collapsed) }
    }

    func pillTapped() {
        guard state == .collapsed || state == .hover || state == .preview else { return }
        license.refresh() // an expiry shows up at the latest here
        recheckLicense()
        if tab == .shelf || tab == .clipboard || tab == .tools || !isVisible(tab) { tab = .nowPlaying }
        usage.refreshNow() // opening the card shows the freshest numbers we have
        setState(.expanded)
    }

    /// Opens the card straight on a tab (menu bar item, keyboard, drops).
    func open(tab newTab: ExpandedTab) {
        tab = isVisible(newTab) ? newTab : .nowPlaying
        usage.refreshNow()
        setState(.expanded)
    }

    func recheckLicense() {
        if case .success = LicenseCheck.stored() { licenseConfirmed = true } else { licenseConfirmed = false }
    }

    /// Tabs can be switched off in Settings; the card never opens on a hidden one.
    func isVisible(_ tab: ExpandedTab) -> Bool {
        switch tab {
        case .nowPlaying: true
        case .shelf: settings.shelfEnabled
        case .clipboard: settings.clipboardEnabled
        case .tools: settings.showToolsTab
        case .claude: settings.showClaudeTab
        }
    }

    /// Runs `body` (e.g. a synchronous menu) with the card pinned open.
    func withInteraction(_ body: () -> Void) {
        setInteracting(true)
        body()
        setInteracting(false)
    }

    func setInteracting(_ interacting: Bool) {
        isInteracting = interacting
        if interacting {
            collapseWork?.cancel()
            collapseWork = nil
        } else if state == .expanded, !hitRect(for: .expanded).contains(NSEvent.mouseLocation) {
            scheduleCollapse(after: 1) // ended outside the card
        }
    }

    /// Keeps the card open while the user is in another app on its behalf (the
    /// Claude sign-in in the browser). Unlike `setInteracting`, clicks elsewhere
    /// still go where they are aimed.
    func holdOpen(_ hold: Bool) {
        isHeldOpen = hold
        if hold {
            collapseWork?.cancel()
            collapseWork = nil
        } else if state == .expanded, !hitRect(for: .expanded).contains(NSEvent.mouseLocation) {
            scheduleCollapse(after: 2)
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .expanded, !self.isInteracting, !self.isHeldOpen else { return }
            self.collapseWork = nil
            self.setState(.collapsed)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setState(_ newState: NotchState) {
        guard newState != state else { return }
        if newState != .expanded {
            collapseWork?.cancel()
            collapseWork = nil
        }
        if newState != .preview {
            previewWork?.cancel()
            previewWork = nil
        }
        let animation: Animation
        switch (state, newState) {
        case (_, .expanded), (_, .preview): animation = .spring(response: 0.42, dampingFraction: 0.76)
        case (.expanded, _), (.preview, _): animation = .spring(response: 0.4, dampingFraction: 0.86)
        case (_, .alert), (.alert, _): animation = .spring(response: 0.45, dampingFraction: 0.72)
        default: animation = .spring(response: 0.35, dampingFraction: 0.64) // hover: light overshoot
        }
        withAnimation(animation) { state = newState }
    }

    /// State to return to after a transient state, based on where the mouse is.
    private func restingState() -> NotchState {
        hitRect(for: .hover).contains(NSEvent.mouseLocation) ? .hover : .collapsed
    }

    // MARK: - Playback

    func togglePlayPause() { nowPlaying.togglePlayPause() }

    func seek(to seconds: TimeInterval) { nowPlaying.seek(to: seconds) }

    func skip(_ direction: TrackDirection) {
        guard hasMedia else { return }
        lastSkip = (direction, Date())
        switch direction {
        case .next: nowPlaying.next()
        case .previous: nowPlaying.previous()
        }
    }

    private func trackChanged(from old: NowPlayingTrack?, to new: NowPlayingTrack?) {
        clearTrackWork?.cancel()
        guard let new else {
            // Players briefly report "nothing" between tracks; don't flicker.
            let work = DispatchWorkItem { [weak self] in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self?.track = nil }
            }
            clearTrackWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            return
        }

        guard new.id != track?.id else {
            // Same track, e.g. artwork arrived: crossfade only.
            if new.artwork !== track?.artwork { updateArtworkColor(from: new.artwork) }
            withAnimation(.easeInOut(duration: 0.3)) { track = new }
            return
        }

        let userSkip = lastSkip.flatMap { Date().timeIntervalSince($0.date) < 4 ? $0.direction : nil }
        lastSkip = nil
        trackDirection = userSkip ?? .next
        updateArtworkColor(from: new.artwork)

        // Next run-loop turn: the old content re-renders with the new direction first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let appearing = self.track == nil
            withAnimation(appearing ? .spring(response: 0.45, dampingFraction: 0.75)
                                    : .spring(response: 0.42, dampingFraction: 0.85)) {
                self.track = new
            }
            self.showPreview()
        }
    }

    private func updateArtworkColor(from image: NSImage?) {
        let color = image.flatMap(ArtworkColor.accent(of:)).map(Color.init(nsColor:)) ?? .white
        withAnimation(.easeInOut(duration: 0.4)) { artworkColor = color }
    }

    // MARK: - Track preview

    /// Peek at the new track unless the full card or an alert is showing.
    private func showPreview() {
        guard license.isValid, settings.showTrackPreview,
              state == .collapsed || state == .hover || state == .preview else { return }
        setState(.preview)
        if !hitRect(for: .preview).contains(NSEvent.mouseLocation) {
            schedulePreviewEnd(after: settings.previewDuration)
        }
    }

    private func schedulePreviewEnd(after delay: TimeInterval) {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .preview else { return }
            self.previewWork = nil
            self.setState(self.restingState())
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Alerts (charging, battery, volume)

    func showAlert(_ kind: NotchAlert, duration: TimeInterval = 3) {
        guard license.isValid, state != .expanded else { return }
        alertWork?.cancel()
        if state == .alert, alert != kind {
            withAnimation(.easeInOut(duration: 0.2)) { alert = kind }
        } else {
            alert = kind
        }
        setState(.alert)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .alert else { return }
            self.setState(self.restingState())
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Gestures

    /// Positive = louder.
    func adjustVolume(by delta: Float) {
        guard settings.scrollForVolume else { return }
        changeVolume(by: delta)
    }

    func changeVolume(by delta: Float) {
        guard audioOutput.canSetVolume else { return }
        audioOutput.setVolume(audioOutput.volume + delta)
        showAlert(.volume, duration: 1.4)
    }

    func toggleMute() {
        audioOutput.setMuted(!audioOutput.isMuted)
        showAlert(.volume, duration: 1.4)
    }

    func changeBrightness(by delta: Float) {
        guard brightness.isAvailable else { return }
        brightness.adjust(by: delta)
        showAlert(.brightness, duration: 1.4)
    }

    /// Volume / brightness keys, when Notch replaces the system HUD.
    func handleMediaKey(_ key: MediaKeyMonitor.Key, fine: Bool) {
        let step: Float = fine ? 1 / 64 : 1 / 16
        switch key {
        case .volumeUp: changeVolume(by: step)
        case .volumeDown: changeVolume(by: -step)
        case .mute: toggleMute()
        case .brightnessUp: changeBrightness(by: step)
        case .brightnessDown: changeBrightness(by: -step)
        }
    }

    func swipe(_ direction: TrackDirection) {
        guard settings.swipeToSkip else { return }
        skip(direction)
    }

    // MARK: - Shelf (file drag & drop)

    /// A file drag from another app moved. Opens the shelf when it comes near the notch.
    /// Returns whether the panel should accept mouse (drop) events.
    func fileDragMoved(to point: CGPoint) -> Bool {
        guard settings.shelfEnabled, license.isValid else { return false }
        let attractZone = pillRect(for: .collapsed).insetBy(dx: -90, dy: -70)
        if !isFileDragging, attractZone.contains(point), state != .alert {
            isFileDragging = true
            tab = .shelf
            setState(.expanded)
        }
        guard isFileDragging else { return false }
        if hitRect(for: .expanded).contains(point) {
            collapseWork?.cancel()
            collapseWork = nil
            return true
        }
        if collapseWork == nil, state == .expanded { scheduleCollapse(after: 1) }
        return false
    }

    func fileDragEnded() {
        guard isFileDragging else { return }
        isFileDragging = false
        if state == .expanded, !hitRect(for: .expanded).contains(NSEvent.mouseLocation) {
            scheduleCollapse(after: 1)
        }
    }

    func dropFiles(_ providers: [NSItemProvider]) {
        shelf.add(from: providers)
        isFileDragging = false
        tab = .shelf
    }
}
