import Foundation
import IOKit.pwr_mgt
import Observation

/// What stays awake, mirroring `caffeinate -d` and `caffeinate -i`.
enum AwakeMode: String, CaseIterable, Identifiable {
    /// Display stays on too.
    case display
    /// Mac keeps working, display may sleep (downloads, renders).
    case system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .display: "Display and system"
        case .system: "System only (display may sleep)"
        }
    }

    var assertionType: String {
        switch self {
        case .display: kIOPMAssertionTypePreventUserIdleDisplaySleep
        case .system: kIOPMAssertionTypePreventUserIdleSystemSleep
        }
    }
}

/// Keeps the Mac (and optionally its display) awake through an IOKit power assertion.
@MainActor
@Observable
final class AwakeService {
    /// nil = until switched off.
    static let durations: [(title: String, seconds: TimeInterval?)] = [
        ("Until turned off", nil),
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60),
        ("2 hours", 2 * 60 * 60),
        ("4 hours", 4 * 60 * 60),
    ]

    private(set) var isActive = false
    private(set) var endDate: Date?
    private(set) var mode: AwakeMode = .display
    /// True when a rule switched it on (charger, timer), not the user.
    private(set) var isAutomatic = false

    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var expiry: Timer?

    var remainingText: String? {
        guard let endDate else { return nil }
        let seconds = Int(max(0, endDate.timeIntervalSinceNow).rounded(.up))
        return String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }

    func enable(for duration: TimeInterval?, mode: AwakeMode = .display, automatic: Bool = false) {
        disable()
        self.mode = mode
        isAutomatic = automatic
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(mode.assertionType as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Notch: keep awake" as CFString,
                                                 &id)
        guard result == kIOReturnSuccess else { return }
        assertionID = id
        isActive = true
        guard let duration else { return }
        endDate = Date().addingTimeInterval(duration)
        expiry = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.disable() }
        }
    }

    /// Switches on / off from a rule, leaving a session the user started alone.
    func setAutomatic(_ wanted: Bool, mode: AwakeMode) {
        if wanted {
            guard !isActive else { return }
            enable(for: nil, mode: mode, automatic: true)
        } else if isAutomatic {
            disable()
        }
    }

    func disable() {
        expiry?.invalidate()
        expiry = nil
        endDate = nil
        isAutomatic = false
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    func toggle(defaultDuration: TimeInterval?, mode: AwakeMode) {
        isActive ? disable() : enable(for: defaultDuration, mode: mode)
    }
}
