import AppKit
import CoreGraphics

/// Reports whether the frontmost app shows a fullscreen window on a given screen.
/// Event based: re-checked when the active Space or the frontmost app changes
/// (entering fullscreen always switches Space).
@MainActor
final class FullscreenObserver {
    var onChange: ((Bool) -> Void)?
    private(set) var isFullscreen = false
    var screen: NSScreen? { didSet { scheduleCheck() } }

    private var observers: [NSObjectProtocol] = []
    private var pendingCheck: DispatchWorkItem?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            })
        }
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    /// Space transitions animate; check once they have settled.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func check() {
        let value = screen.map(Self.frontmostAppIsFullscreen(on:)) ?? false
        guard value != isFullscreen else { return }
        isFullscreen = value
        onChange?(value)
    }

    /// A fullscreen window covers the whole display (a zoomed window stops below the menu bar).
    /// Window bounds and owners are available without Screen Recording permission.
    static func frontmostAppIsFullscreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return false }
            return bounds == displayBounds
        }
    }
}
