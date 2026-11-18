import Foundation
import IOKit.ps
import Observation

/// Battery level and charger state via IOKit power source notifications (no polling).
@MainActor
@Observable
final class BatteryService {
    private(set) var level: Int = 100
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    private(set) var hasBattery = false

    /// Fired on the transition battery → AC power.
    @ObservationIgnored var onPowerConnected: (() -> Void)?
    /// Fired once when the level drops to one of `lowThresholds` while on battery.
    @ObservationIgnored var onLowBattery: ((Int) -> Void)?
    /// Fired once when charging reaches 100%.
    @ObservationIgnored var onFullyCharged: (() -> Void)?
    /// Fired whenever the charger is plugged in or unplugged.
    @ObservationIgnored var onPowerStateChanged: ((Bool) -> Void)?

    static let lowThresholds = [20, 10]

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.update(notify: true) }
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        update(notify: false)
    }

    private func update(notify: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let wasPluggedIn = isPluggedIn
            let previousLevel = level

            hasBattery = true
            level = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            isPluggedIn = pluggedIn

            guard notify else { return }
            if pluggedIn != wasPluggedIn { onPowerStateChanged?(pluggedIn) }
            if pluggedIn, !wasPluggedIn { onPowerConnected?() }
            if !pluggedIn, Self.lowThresholds.contains(where: { level <= $0 && previousLevel > $0 }) {
                onLowBattery?(level)
            }
            if pluggedIn, level >= 100, previousLevel < 100 { onFullyCharged?() }
            return
        }
        hasBattery = false
    }
}
