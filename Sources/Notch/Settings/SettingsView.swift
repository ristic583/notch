import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(settings: AppSettings, updater: UpdaterController?, account: ClaudeAccount, license: LicenseService) {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, updater: updater,
                                                                 account: account, license: license))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Notch Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func show() {
        (window?.contentViewController as? NSHostingController<SettingsView>)?.rootView.settings.refreshLaunchAtLogin()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center() // after SwiftUI has laid out, otherwise it centers the wrong size
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case music
    case levels
    case battery
    case shelf
    case clipboard
    case tools
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .music: "Music"
        case .levels: "Volume & Brightness"
        case .battery: "Battery"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .tools: "Tools"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .music: "music.note"
        case .levels: "speaker.wave.2"
        case .battery: "battery.75percent"
        case .shelf: "tray.full"
        case .clipboard: "doc.on.clipboard"
        case .tools: "switch.2"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// Sidebar with one section open at a time.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let updater: UpdaterController?
    let account: ClaudeAccount
    let license: LicenseService
    @State private var selection: SettingsSection? = .general
    @State private var loginError: String?
    @State private var hookError: String?
    @State private var hookToggle = false

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Form {
                switch selection ?? .general {
                case .general: general
                case .music: music
                case .levels: levels
                case .battery: battery
                case .shelf: shelf
                case .clipboard: clipboard
                case .tools: tools
                case .updates: updates
                }
            }
            .formStyle(.grouped)
            .navigationTitle((selection ?? .general).title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 700, height: 440)
    }

    // MARK: - Sections

    @ViewBuilder
    private var general: some View {
        LicenseSettingsSection(license: license)
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { enabled in
                    do {
                        try settings.setLaunchAtLogin(enabled)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                }
            ))
            if settings.launchAtLoginStatus == .requiresApproval {
                HStack {
                    Text("Allow Notch in System Settings › General › Login Items.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                }
                .font(.callout)
            }
            if let loginError {
                Text(loginError).font(.callout).foregroundStyle(.red)
            }
        }
        Section {
            Picker("Show the pill on", selection: $settings.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
            }
            Text("On a display without a notch the pill sits centred at the top of the screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Hide when an app is in fullscreen", isOn: $settings.hideInFullscreen)
            Toggle("Hide from screenshots and screen sharing", isOn: $settings.hideFromScreenCapture)
        }
    }

    @ViewBuilder
    private var music: some View {
        Section {
            Picker("Soundwave", selection: $settings.soundwaveMode) {
                ForEach(SoundwaveMode.allCases) { Text($0.title).tag($0) }
            }
            Text(soundwaveHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Soundwave color", selection: $settings.waveColorMode) {
                ForEach(WaveColorMode.allCases) { Text($0.title).tag($0) }
            }
            if settings.waveColorMode == .custom {
                ColorPicker("Custom color", selection: $settings.customWaveColor, supportsOpacity: false)
            }
        }
        Section {
            Toggle("Draw progress around the notch", isOn: $settings.showNotchProgress)
            Text("A thin line along the camera housing follows the song, or the timer when nothing plays.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Show preview when the track changes", isOn: $settings.showTrackPreview)
            LabeledContent("Preview duration") {
                HStack {
                    Slider(value: $settings.previewDuration, in: 1...6, step: 0.5)
                        .frame(width: 160)
                    Text(String(format: "%.1f s", settings.previewDuration))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!settings.showTrackPreview)
        }
        Section {
            Toggle("Swipe on the notch to skip tracks", isOn: $settings.swipeToSkip)
            Toggle("Scroll on the notch to change volume", isOn: $settings.scrollForVolume)
        }
    }

    @ViewBuilder
    private var levels: some View {
        Section {
            Toggle("Replace the system volume and brightness HUD", isOn: Binding(
                get: { settings.overrideSystemHUD },
                set: { enabled in
                    settings.overrideSystemHUD = enabled
                    if enabled, !MediaKeyMonitor.isTrusted { MediaKeyMonitor.requestTrust() }
                }
            ))
            if settings.overrideSystemHUD, !MediaKeyMonitor.isTrusted {
                HStack {
                    Text("Needs Accessibility permission to read the keys.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") { MediaKeyMonitor.openAccessibilitySettings() }
                }
                .font(.callout)
            }
            Text("The keyboard backlight keys keep using the system HUD.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var battery: some View {
        Section {
            Toggle("Show when the charger is connected", isOn: $settings.showChargingAlert)
            Toggle("Warn at 20% and 10%", isOn: $settings.lowBatteryAlerts)
            Toggle("Show when fully charged", isOn: $settings.fullyChargedAlert)
            Toggle("Show when a Bluetooth accessory connects", isOn: $settings.accessoryAlerts)
            Text("AirPods and similar also show their battery, read from the system a couple of seconds after connecting.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var shelf: some View {
        Section {
            Toggle("Drop files on the notch", isOn: $settings.shelfEnabled)
            Text("Files stay on the notch until you drag them out. Only paths are kept, nothing is copied.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section("Catch automatically") {
            Toggle("New screenshots", isOn: $settings.catchScreenshots)
            Toggle("Finished downloads", isOn: $settings.catchDownloads)
            Text("New files land on the shelf so you can drag them straight into a message, and your Desktop stays clean.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .disabled(!settings.shelfEnabled)
    }

    @ViewBuilder
    private var clipboard: some View {
        Section {
            Toggle("Keep clipboard history", isOn: $settings.clipboardEnabled)
            LabeledContent("Entries kept") {
                HStack {
                    Slider(value: $settings.clipboardLimit, in: 10...200, step: 10)
                        .frame(width: 160)
                    Text("\(Int(settings.clipboardLimit))")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!settings.clipboardEnabled)
            Text("Entries password managers mark as private are skipped. Text and files survive a restart; images are kept only while the app runs.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tools: some View {
        Section("Tabs in the notch") {
            Toggle("Show the Tools tab", isOn: $settings.showToolsTab)
            Toggle("Show the Claude tab", isOn: $settings.showClaudeTab)
        }
        Section("Microphone") {
            Toggle("Show a red dot while the microphone is in use", isOn: $settings.showMicIndicator)
        }
        Section("Claude Code") {
            Toggle("Show agent sessions in the notch", isOn: $settings.agentActivity)
            Toggle("Warn at 80% and 90% of the 5-hour limit", isOn: $settings.usageAlerts)
            HStack {
                Text(hookStatus)
                    .foregroundStyle(.secondary)
                Spacer()
                if ClaudeHookInstaller.isInstalled {
                    Button("Remove hooks") { runHookChange { try ClaudeHookInstaller.remove() } }
                } else {
                    Button("Install hooks") {
                        runHookChange {
                            guard let script = AgentActivityService.hookScriptURL?.path else {
                                throw ClaudeHookInstaller.InstallError.missingScript
                            }
                            try ClaudeHookInstaller.install(scriptPath: script)
                        }
                    }
                }
            }
            .font(.callout)
            if let hookError {
                Text(hookError).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Text(accountStatus)
                    .foregroundStyle(.secondary)
                Spacer()
                if account.isSignedIn {
                    Button("Disconnect") { account.signOut() }
                } else if account.isSigningIn {
                    Button("Cancel") { account.cancelSignIn() }
                } else {
                    Button("Connect Claude account") { account.signIn() }
                }
            }
            .font(.callout)
            if let problem = account.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            Text("Signs Notch in to your Claude account with access to your profile and usage only; it can't run Claude. The numbers then update on every click and after every reply. It uses Claude Code's sign-in, which isn't public API, so it can stop working if Anthropic changes it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text(statusLineStatus)
                    .foregroundStyle(.secondary)
                Spacer()
                switch ClaudeHookInstaller.statusLineState {
                case .ours:
                    Button("Remove status line") { runHookChange { try ClaudeHookInstaller.removeStatusLine() } }
                case .absent:
                    Button("Show usage") {
                        runHookChange {
                            guard let script = UsageService.statusLineScriptURL?.path else {
                                throw ClaudeHookInstaller.InstallError.missingScript
                            }
                            try ClaudeHookInstaller.installStatusLine(scriptPath: script)
                        }
                    }
                case .foreign:
                    EmptyView()
                }
            }
            .font(.callout)
            Text("Without the account, usage comes from the Claude Code status line, which only terminal sessions update. Your own status line, if you have one, is left alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("The hooks let Claude Code tell Notch when a session needs you or finishes. ~/.claude/settings.json is backed up first, and only Notch's own entries are touched. Open sessions pick it up after a restart.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        Section("Keep awake") {
            Picker("Keeps awake", selection: $settings.awakeMode) {
                ForEach(AwakeMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("When clicked, stay awake", selection: $settings.awakeDefaultMinutes) {
                Text("Until turned off").tag(0.0)
                Text("15 minutes").tag(15.0)
                Text("30 minutes").tag(30.0)
                Text("1 hour").tag(60.0)
                Text("2 hours").tag(120.0)
                Text("4 hours").tag(240.0)
            }
            Toggle("Turn on automatically while charging", isOn: $settings.awakeWhileCharging)
            Toggle("Turn on automatically while a timer runs", isOn: $settings.awakeWhileTimerRuns)
            Text("Automatic sessions switch off on their own and never cancel one you started yourself. Right-click the tile in Tools for a one-off duration.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var updates: some View {
        Section {
            if let updater {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }
                ))
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } else {
                Text("Updates are not configured in this build.")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
        }
    }

    private var accountStatus: String {
        if account.isSignedIn { return "Usage comes straight from your Claude account" }
        if account.isSigningIn { return "Finish signing in in your browser…" }
        return "Claude account not connected"
    }

    private var statusLineStatus: String {
        _ = hookToggle
        switch ClaudeHookInstaller.statusLineState {
        case .ours: return "Usage shown in Tools, via the Claude Code status line"
        case .absent: return "Subscription usage (5h / weekly) not connected"
        case let .foreign(command): return "You already use a status line: \(command.prefix(40))"
        }
    }

    private var hookStatus: String {
        _ = hookToggle // re-read after installing / removing
        return ClaudeHookInstaller.isInstalled ? "Hooks installed in ~/.claude/settings.json" : "Hooks not installed yet"
    }

    private func runHookChange(_ change: () throws -> Void) {
        do {
            try change()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        hookToggle.toggle()
    }

    private var soundwaveHint: String {
        switch settings.soundwaveMode {
        case .live: "Follows system audio, so macOS shows its recording indicator while something plays."
        case .simulated: "Bars move on their own while music plays. Nothing is captured, so no recording indicator."
        case .off: "A static glyph instead of the bars. Nothing is captured."
        }
    }
}
