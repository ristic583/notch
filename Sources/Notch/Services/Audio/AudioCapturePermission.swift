import AppKit

/// "Screen & System Audio Recording → System Audio Recording Only" permission
/// used by Core Audio process taps. There is no public API to query it, so this
/// uses the TCC SPI (the same approach as Apple's AudioCap sample community code).
enum AudioCapturePermission {
    enum Status {
        case unknown
        case denied
        case authorized
    }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFn.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if needed. Without the SPI the tap itself triggers the prompt.
    static func request(completion: @escaping @MainActor (Bool) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        unsafeBitCast(symbol, to: RequestFn.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
