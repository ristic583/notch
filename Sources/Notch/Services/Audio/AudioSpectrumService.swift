import CoreAudio
import Observation
import os

/// Owns system-audio capture and exposes band levels for the soundwave.
/// Capture only runs while something is playing, to save CPU and to keep the
/// system "recording" indicator off when idle.
@MainActor
@Observable
final class AudioSpectrumService {
    enum Status: Equatable {
        case idle
        case running
        case permissionDenied
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// True while the bars need to animate (capturing, or still falling after a stop).
    private(set) var isActive = false

    @ObservationIgnored private let analyzer = SpectrumAnalyzer()
    @ObservationIgnored private lazy var tapCapture = ProcessTapCapture(analyzer: analyzer)
    @ObservationIgnored private lazy var screenCapture = ScreenCaptureAudioCapture(analyzer: analyzer)
    @ObservationIgnored private var wantsCapture = false
    @ObservationIgnored private var pendingStop: DispatchWorkItem?
    @ObservationIgnored private var pendingIdle: DispatchWorkItem?
    @ObservationIgnored private var deviceListenerInstalled = false
    @ObservationIgnored private let log = Logger(subsystem: "Notch", category: "Audio")

    private var isCapturing: Bool { tapCapture.isRunning || screenCapture.isRunning }

    /// Latest band levels, 0...1. Cheap; called once per display frame.
    func levels() -> [Float] {
        analyzer.currentLevels()
    }

    /// Follows playback: starts right away, stops a little after pausing.
    func setPlaying(_ playing: Bool) {
        pendingStop?.cancel()
        if playing {
            start()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            pendingStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    func start() {
        wantsCapture = true
        guard !isCapturing else { return }
        switch AudioCapturePermission.status {
        case .authorized:
            startCapture()
        case .denied:
            status = .permissionDenied
        case .unknown:
            AudioCapturePermission.request { [weak self] granted in
                guard let self, self.wantsCapture else { return }
                if granted { self.startCapture() } else { self.status = .permissionDenied }
            }
        }
    }

    func stop() {
        wantsCapture = false
        tapCapture.stop()
        screenCapture.stop()
        if status == .running { status = .idle }
        // Let the bars fall down before the display link is paused.
        pendingIdle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCapturing else { return }
            self.isActive = false
        }
        pendingIdle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func startCapture() {
        installDeviceListener()
        do {
            try tapCapture.start()
            didStart()
        } catch {
            log.error("Process tap failed (\(String(describing: error))), falling back to ScreenCaptureKit")
            Task {
                do {
                    try await screenCapture.start()
                    if wantsCapture { didStart() } else { screenCapture.stop() }
                } catch {
                    log.error("ScreenCaptureKit audio failed: \(error.localizedDescription)")
                    status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func didStart() {
        pendingIdle?.cancel()
        status = .running
        isActive = true
    }

    /// Rebuild the tap when the output device changes (e.g. AirPods connect).
    private func installDeviceListener() {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.tapCapture.isRunning else { return }
                self.tapCapture.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.wantsCapture else { return }
                    self.startCapture()
                }
            }
        }
    }
}
