import AppKit
import ApplicationServices
import IOKit.hidsystem

/// Intercepts the volume / brightness keys with a CGEvent tap so the app can
/// show its own HUD in the notch. Handled keys are swallowed, which is what
/// keeps the system HUD from appearing; everything else passes through.
/// Needs Accessibility permission.
@MainActor
final class MediaKeyMonitor {
    enum Key {
        case volumeUp
        case volumeDown
        case mute
        case brightnessUp
        case brightnessDown
    }

    /// `fine` is true with Shift+Option held (quarter steps, like macOS).
    var onKey: ((Key, _ fine: Bool) -> Void)?

    private(set) var isRunning = false
    /// Read from the tap thread: don't swallow brightness keys we can't act on.
    private let flags = Flags()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var handlesBrightness: Bool {
        get { flags.handlesBrightness }
        set { flags.handlesBrightness = newValue }
    }

    // MARK: - Permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard Self.isTrusted else { return false }

        let mask = CGEventMask(1 << NX_SYSDEFINED)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // must be able to swallow events
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning, let tap, let source else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        isRunning = false
    }

    // MARK: - Tap callback (not on the main actor)

    private final class Flags: @unchecked Sendable {
        var handlesBrightness = true
    }

    nonisolated private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The tap is disabled if it ever takes too long; just switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = MainActor.assumeIsolated({ self.tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let passThrough = Unmanaged.passUnretained(event)
        guard type.rawValue == UInt32(NX_SYSDEFINED),
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else { return passThrough }

        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyIsDown = ((data & 0xFF00) >> 8) == 0x0A
        let key: Key
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP: key = .volumeUp
        case NX_KEYTYPE_SOUND_DOWN: key = .volumeDown
        case NX_KEYTYPE_MUTE: key = .mute
        case NX_KEYTYPE_BRIGHTNESS_UP where flags.handlesBrightness: key = .brightnessUp
        case NX_KEYTYPE_BRIGHTNESS_DOWN where flags.handlesBrightness: key = .brightnessDown
        default: return passThrough
        }

        if keyIsDown {
            let modifiers = nsEvent.modifierFlags
            let fine = modifiers.contains(.shift) && modifiers.contains(.option)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onKey?(key, fine) }
            }
        }
        return nil // swallowed: no system HUD
    }
}
