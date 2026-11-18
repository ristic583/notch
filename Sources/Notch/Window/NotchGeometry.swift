import AppKit

/// Physical notch (or a notch-like pill for screens without one) in screen coordinates.
struct NotchGeometry: Equatable {
    /// Frame of the screen the pill lives on.
    var screenFrame: CGRect
    /// Size of the physical notch, or of the fallback pill.
    var notchSize: CGSize
    /// Horizontal center of the notch in screen coordinates.
    var centerX: CGFloat
    var hasNotch: Bool

    static let fallbackWidth: CGFloat = 190

    init(screen: NSScreen) {
        let frame = screen.frame
        screenFrame = frame
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            notchSize = CGSize(width: width, height: topInset)
            centerX = frame.minX + left.width + width / 2
            hasNotch = true
        } else {
            let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
            let height = menuBarHeight > 0 ? menuBarHeight : NSStatusBar.system.thickness
            notchSize = CGSize(width: Self.fallbackWidth, height: max(height, 24))
            centerX = frame.midX
            hasNotch = false
        }
    }

    /// Prefer the built-in screen with a notch; otherwise the primary (menu bar) screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    /// The screen the pointer is on, falling back to the preferred one.
    static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? preferredScreen()
    }
}
