import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum SoundwaveMode: String, CaseIterable, Identifiable {
    /// Real spectrum of the system audio (needs the audio capture permission).
    case live
    /// Looks like music but listens to nothing.
    case simulated
    case off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live audio"
        case .simulated: "Simulated"
        case .off: "Off"
        }
    }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    /// Always on the built-in screen with the notch.
    case builtIn
    /// Follows whichever screen the pointer is on (a pill at the top on screens without a notch).
    case followPointer

    var id: String { rawValue }
    var title: String {
        switch self {
        case .builtIn: "Built-in display only"
        case .followPointer: "Follow the pointer"
        }
    }
}

enum WaveColorMode: String, CaseIterable, Identifiable {
    case artwork, white, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .artwork: "Match artwork"
        case .white: "White"
        case .custom: "Custom"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let didChange = Notification.Name("NotchSettingsDidChange")

    @ObservationIgnored private let defaults = UserDefaults.standard

    // General
    var displayMode: DisplayMode { didSet { save(displayMode.rawValue, "displayMode") } }
    var hideInFullscreen: Bool { didSet { save(hideInFullscreen, "hideInFullscreen") } }
    var hideFromScreenCapture: Bool { didSet { save(hideFromScreenCapture, "hideFromScreenCapture") } }

    // Music
    var soundwaveMode: SoundwaveMode { didSet { save(soundwaveMode.rawValue, "soundwaveMode") } }
    var showNotchProgress: Bool { didSet { save(showNotchProgress, "showNotchProgress") } }
    var showTrackPreview: Bool { didSet { save(showTrackPreview, "showTrackPreview") } }
    var previewDuration: Double { didSet { save(previewDuration, "previewDuration") } }
    var waveColorMode: WaveColorMode { didSet { save(waveColorMode.rawValue, "waveColorMode") } }
    var customWaveColor: Color { didSet { save(Self.components(of: customWaveColor), "customWaveColor") } }
    var swipeToSkip: Bool { didSet { save(swipeToSkip, "swipeToSkip") } }
    var scrollForVolume: Bool { didSet { save(scrollForVolume, "scrollForVolume") } }

    // System HUD
    var overrideSystemHUD: Bool { didSet { save(overrideSystemHUD, "overrideSystemHUD") } }

    // Battery
    var showChargingAlert: Bool { didSet { save(showChargingAlert, "showChargingAlert") } }
    var lowBatteryAlerts: Bool { didSet { save(lowBatteryAlerts, "lowBatteryAlerts") } }
    var fullyChargedAlert: Bool { didSet { save(fullyChargedAlert, "fullyChargedAlert") } }
    var accessoryAlerts: Bool { didSet { save(accessoryAlerts, "accessoryAlerts") } }

    // Shelf
    var shelfEnabled: Bool { didSet { save(shelfEnabled, "shelfEnabled") } }
    var catchScreenshots: Bool { didSet { save(catchScreenshots, "catchScreenshots") } }
    var catchDownloads: Bool { didSet { save(catchDownloads, "catchDownloads") } }

    // Clipboard
    var clipboardEnabled: Bool { didSet { save(clipboardEnabled, "clipboardEnabled") } }
    var clipboardLimit: Double { didSet { save(clipboardLimit, "clipboardLimit") } }

    // Tools
    var showToolsTab: Bool { didSet { save(showToolsTab, "showToolsTab") } }
    var showClaudeTab: Bool { didSet { save(showClaudeTab, "showClaudeTab") } }
    var showMicIndicator: Bool { didSet { save(showMicIndicator, "showMicIndicator") } }
    var agentActivity: Bool { didSet { save(agentActivity, "agentActivity") } }
    var usageAlerts: Bool { didSet { save(usageAlerts, "usageAlerts") } }
    var awakeMode: AwakeMode { didSet { save(awakeMode.rawValue, "awakeMode") } }
    /// Minutes used when the tile is clicked; 0 = until turned off.
    var awakeDefaultMinutes: Double { didSet { save(awakeDefaultMinutes, "awakeDefaultMinutes") } }
    var awakeWhileCharging: Bool { didSet { save(awakeWhileCharging, "awakeWhileCharging") } }
    var awakeWhileTimerRuns: Bool { didSet { save(awakeWhileTimerRuns, "awakeWhileTimerRuns") } }

    /// `nil` means "until turned off".
    var awakeDefaultDuration: TimeInterval? {
        awakeDefaultMinutes > 0 ? awakeDefaultMinutes * 60 : nil
    }

    /// Mirrors `SMAppService.mainApp.status`; refreshed on demand.
    private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status

    init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .builtIn
        hideInFullscreen = bool("hideInFullscreen", true)
        hideFromScreenCapture = bool("hideFromScreenCapture", false)
        // Migrates the earlier on/off switch.
        soundwaveMode = SoundwaveMode(rawValue: d.string(forKey: "soundwaveMode") ?? "")
            ?? (bool("showSoundwave", true) ? .live : .off)
        showNotchProgress = bool("showNotchProgress", false)
        showTrackPreview = bool("showTrackPreview", true)
        previewDuration = min(max(d.object(forKey: "previewDuration") as? Double ?? 3.2, 1), 6)
        waveColorMode = WaveColorMode(rawValue: d.string(forKey: "waveColorMode") ?? "") ?? .artwork
        customWaveColor = Self.color(from: d.array(forKey: "customWaveColor") as? [Double]) ?? Color(red: 0.45, green: 0.85, blue: 1)
        swipeToSkip = bool("swipeToSkip", true)
        scrollForVolume = bool("scrollForVolume", true)
        overrideSystemHUD = bool("overrideSystemHUD", false)
        showChargingAlert = bool("showChargingAlert", true)
        lowBatteryAlerts = bool("lowBatteryAlerts", true)
        fullyChargedAlert = bool("fullyChargedAlert", true)
        accessoryAlerts = bool("accessoryAlerts", true)
        shelfEnabled = bool("shelfEnabled", true)
        catchScreenshots = bool("catchScreenshots", true)
        catchDownloads = bool("catchDownloads", false)
        clipboardEnabled = bool("clipboardEnabled", true)
        clipboardLimit = min(max(d.object(forKey: "clipboardLimit") as? Double ?? 50, 10), 200)
        showToolsTab = bool("showToolsTab", true)
        showClaudeTab = bool("showClaudeTab", true)
        showMicIndicator = bool("showMicIndicator", true)
        agentActivity = bool("agentActivity", true)
        usageAlerts = bool("usageAlerts", true)
        awakeMode = AwakeMode(rawValue: d.string(forKey: "awakeMode") ?? "") ?? .display
        awakeDefaultMinutes = d.object(forKey: "awakeDefaultMinutes") as? Double ?? 0
        awakeWhileCharging = bool("awakeWhileCharging", false)
        awakeWhileTimerRuns = bool("awakeWhileTimerRuns", false)
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        defer { refreshLaunchAtLogin() }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    // MARK: - Persistence

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func components(of color: Color) -> [Double] {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return [ns.redComponent, ns.greenComponent, ns.blueComponent].map(Double.init)
    }

    private static func color(from components: [Double]?) -> Color? {
        guard let c = components, c.count == 3 else { return nil }
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2])
    }
}
