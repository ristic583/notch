import AppKit
import SwiftUI

/// Borderless, transparent panel above the menu bar that never steals focus.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks work on the first click even though the panel is never key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchWindowController: NSWindowController {
    private let viewModel: NotchViewModel
    /// Menu shown on right-click anywhere on the pill (same as the menu bar icon).
    private let menuProvider: () -> NSMenu?
    private var settings: AppSettings { viewModel.settings }
    private let fullscreen = FullscreenObserver()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var isHidden = false
    private var currentScreen: NSScreen?

    // File drag detection (drag pasteboard changes when a drag session starts).
    private var dragPasteboardCount = NSPasteboard(name: .drag).changeCount
    private var isFileDragSession = false

    // Scroll gesture state (one gesture = began ... ended).
    private enum ScrollAxis { case horizontal, vertical }
    private var scrollAxis: ScrollAxis?
    private var scrollAccumulated = CGPoint.zero
    private var swipeHandled = false

    init(viewModel: NotchViewModel, menuProvider: @escaping () -> NSMenu?) {
        self.viewModel = viewModel
        self.menuProvider = menuProvider
        let panel = NotchPanel()
        super.init(window: panel)

        let hosting = FirstMouseHostingView(rootView: NotchRootView(viewModel: viewModel))
        hosting.sizingOptions = []
        panel.contentView = hosting

        reposition()
        applySettings()
        installMouseMonitors()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        observers.append(center.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        fullscreen.onChange = { [weak self] _ in self?.updateVisibility() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func showWindow(_ sender: Any?) {
        window?.orderFrontRegardless()
    }

    /// Pins the panel to the top center of the notch screen (also on resolution
    /// or display changes). The panel never resizes during animations.
    /// Which screen the pill belongs on right now.
    private func targetScreen() -> NSScreen? {
        switch settings.displayMode {
        case .builtIn: NotchGeometry.preferredScreen()
        case .followPointer: NotchGeometry.screenUnderPointer()
        }
    }

    private func reposition() {
        guard let panel = window, let screen = targetScreen() else { return }
        currentScreen = screen
        viewModel.updateGeometry(NotchGeometry(screen: screen))
        fullscreen.screen = screen
        let size = viewModel.windowSize
        let geometry = viewModel.geometry
        let frame = CGRect(x: (geometry.centerX - size.width / 2).rounded(),
                           y: geometry.screenFrame.maxY - size.height,
                           width: size.width,
                           height: size.height)
        panel.setFrame(frame, display: true)
    }

    /// With "follow the pointer", move the panel when the mouse changes screen.
    private func followPointerIfNeeded() {
        guard settings.displayMode == .followPointer,
              viewModel.state == .collapsed, // never mid-interaction
              let screen = NotchGeometry.screenUnderPointer(),
              screen !== currentScreen else { return }
        reposition()
    }

    private func applySettings() {
        // Excluded from screenshots / screen sharing that respect window sharing types.
        window?.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
        updateVisibility()
    }

    /// Fades the panel out while a fullscreen app is frontmost on the notch screen.
    private func updateVisibility() {
        guard let panel = window else { return }
        let hide = settings.hideInFullscreen && fullscreen.isFullscreen
        guard hide != isHidden else { return }
        isHidden = hide
        if hide { panel.ignoresMouseEvents = true }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = hide ? 0 : 1
        }
    }

    // MARK: - Mouse

    private func installMouseMonitors() {
        let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: moveEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(event) }
        }) { monitors.append(global) }

        if let local = NSEvent.addLocalMonitorForEvents(matching: moveEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(event) }
            return event
        }) { monitors.append(local) }

        // Clicks outside our panel arrive only through the global monitor.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dragPasteboardCount = NSPasteboard(name: .drag).changeCount
                self.viewModel.mouseDownOutside()
            }
        }) { monitors.append(global) }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.endFileDrag() }
        }) { monitors.append(global) }

        // Right-click anywhere on the pill opens the menu.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown], handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.showMenu(for: event) ?? false }
            return handled ? nil : event
        }) { monitors.append(local) }

        // Scroll gestures reach the panel only while the pointer is over the pill.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
            return event
        }) { monitors.append(local) }
    }

    /// Returns true when the event was consumed. Other windows (Settings) and the
    /// shelf, where files have their own menu, keep their right-click behaviour.
    private func showMenu(for event: NSEvent) -> Bool {
        guard event.window === window, !isHidden,
              !(viewModel.state == .expanded && viewModel.tab == .shelf),
              let menu = menuProvider() else { return false }
        // Popped synchronously, so the card can't close while the menu is up.
        viewModel.withInteraction {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        return true
    }

    private func pointerMoved(_ event: NSEvent) {
        guard !isHidden else { return }
        followPointerIfNeeded()
        let location = NSEvent.mouseLocation
        let inside: Bool
        if event.type == .leftMouseDragged, event.window == nil, isFileDrag() {
            inside = viewModel.fileDragMoved(to: location)
        } else {
            inside = viewModel.mouseMoved(to: location)
        }
        // Transparent parts of the panel must not block the menu bar / apps below.
        if window?.ignoresMouseEvents == inside {
            window?.ignoresMouseEvents = !inside
        }
    }

    /// True while another app drags files (the drag pasteboard changed since mouse down).
    private func isFileDrag() -> Bool {
        if isFileDragSession { return true }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragPasteboardCount,
              pasteboard.types?.contains(.fileURL) == true else { return false }
        isFileDragSession = true
        return true
    }

    private func endFileDrag() {
        guard isFileDragSession else { return }
        isFileDragSession = false
        dragPasteboardCount = NSPasteboard(name: .drag).changeCount
        viewModel.fileDragEnded()
    }

    // MARK: - Gestures

    /// Two-finger swipe left / right → next / previous; vertical scroll → volume.
    private func scrolled(_ event: NSEvent) {
        guard event.window === window, !isHidden else { return }
        // Gestures work on the pill and on the Now Playing tab. The other tabs
        // scroll their own content (clipboard list, shelf row).
        guard viewModel.state != .expanded || viewModel.tab == .nowPlaying else { return }
        guard event.momentumPhase.isEmpty else { return } // ignore inertia

        if event.phase == .began || event.phase == .mayBegin {
            scrollAxis = nil
            scrollAccumulated = .zero
            swipeHandled = false
        }

        let inverted = event.isDirectionInvertedFromDevice
        // Finger movement: +x = right, +y = up, independent of "natural scrolling".
        let fingerX = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let fingerY = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY

        if !event.hasPreciseScrollingDeltas {
            // Mouse wheel: one notch = one volume step.
            if fingerY != 0 { viewModel.adjustVolume(by: fingerY > 0 ? 1 / 16 : -1 / 16) }
            return
        }

        scrollAccumulated.x += fingerX
        scrollAccumulated.y += fingerY
        if scrollAxis == nil, max(abs(scrollAccumulated.x), abs(scrollAccumulated.y)) > 6 {
            scrollAxis = abs(scrollAccumulated.x) > abs(scrollAccumulated.y) ? .horizontal : .vertical
        }

        switch scrollAxis {
        case .horizontal?:
            if !swipeHandled, abs(scrollAccumulated.x) > 45 {
                swipeHandled = true
                // Fingers to the left push the content left, like the "next" slide.
                viewModel.swipe(scrollAccumulated.x < 0 ? .next : .previous)
            }
        case .vertical?:
            viewModel.adjustVolume(by: Float(fingerY) * 0.004)
        case nil:
            break
        }

        if event.phase == .ended || event.phase == .cancelled {
            scrollAxis = nil
            scrollAccumulated = .zero
        }
    }
}
