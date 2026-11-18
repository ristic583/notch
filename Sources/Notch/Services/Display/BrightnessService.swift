import AppKit
import Observation

/// Display brightness through the private DisplayServices framework. IOKit's
/// public brightness API doesn't work for built-in displays on Apple Silicon.
@MainActor
@Observable
final class BrightnessService {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private(set) var brightness: Float = 0
    /// False when the framework or the display doesn't support it (then the
    /// system keeps handling the brightness keys).
    private(set) var isAvailable = false

    @ObservationIgnored private let getBrightness: GetFn?
    @ObservationIgnored private let setBrightness: SetFn?
    @ObservationIgnored private var displayID = CGMainDisplayID()

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        getBrightness = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setBrightness = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        refresh()
    }

    /// Follow the screen the pill lives on (falls back to the main display).
    func use(screen: NSScreen?) {
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        displayID = number.map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        refresh()
    }

    func refresh() {
        guard let getBrightness else {
            isAvailable = false
            return
        }
        var value: Float = 0
        isAvailable = getBrightness(displayID, &value) == 0
        if isAvailable { brightness = min(max(value, 0), 1) }
    }

    func adjust(by delta: Float) {
        set(brightness + delta)
    }

    func set(_ value: Float) {
        guard isAvailable, let setBrightness else { return }
        let clamped = min(max(value, 0), 1)
        guard setBrightness(displayID, clamped) == 0 else {
            isAvailable = false
            return
        }
        brightness = clamped
    }
}
