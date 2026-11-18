import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let nowPlaying = NowPlayingService()
    private let spectrum = AudioSpectrumService()
    private let battery = BatteryService()
    private let audioOutput = AudioOutputService()
    private let brightness = BrightnessService()
    private let shelf = ShelfService()
    private let clipboard = ClipboardService()
    private let timer = TimerService()
    private let microphone = MicrophoneService()
    private let awake = AwakeService()
    private let bluetooth = BluetoothService()
    private let agents = AgentActivityService()
    private let usage = UsageService()
    private let license = LicenseService()
    private let mediaKeys = MediaKeyMonitor()
    private let folderWatcher = FolderWatcher()
    private lazy var viewModel = NotchViewModel(settings: settings, nowPlaying: nowPlaying, spectrum: spectrum,
                                                battery: battery, audioOutput: audioOutput, brightness: brightness,
                                                shelf: shelf, clipboard: clipboard, timer: timer,
                                                microphone: microphone, awake: awake, bluetooth: bluetooth,
                                                agents: agents, usage: usage, license: license)
    private let updater = UpdaterController.make()
    private var windowController: NotchWindowController?
    private lazy var settingsWindow = SettingsWindowController(settings: settings, updater: updater,
                                                                         account: usage.account, license: license)
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = NotchWindowController(viewModel: viewModel) { [weak self] in self?.buildMenu() }
        windowController?.showWindow(nil)
        setUpStatusItem()
        battery.onPowerStateChanged = { [weak self] _ in self?.updateAutoAwake() }
        timer.onRunningChanged = { [weak self] _ in self?.updateAutoAwake() }
        folderWatcher.onNewFile = { [weak self] url in self?.shelf.add([url]) }
        mediaKeys.onKey = { [weak self] key, fine in self?.viewModel.handleMediaKey(key, fine: fine) }
        license.onChange = { [weak self] in self?.applyLicense() }
        applyLicense()

        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.license.isValid else { return }
                self.updateMediaKeys()
                self.viewModel.syncSpectrum()
                self.applyToolSettings()
                self.updateAutoAwake()
            }
        }
        // Accessibility may be granted while we run; re-check when the app is used.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.license.isValid else { return }
                self.updateMediaKeys()
            }
        }
    }

    /// Without a license only the activation card works; activating starts
    /// everything without a relaunch.
    private func applyLicense() {
        viewModel.recheckLicense()
        if license.isValid { startFeatures() } else { stopFeatures() }
    }

    private var featuresRunning = false

    private func startFeatures() {
        // Asks the check itself rather than trusting `license.isValid`.
        guard !featuresRunning, case .success = LicenseCheck.stored() else { return }
        featuresRunning = true
        nowPlaying.start()
        battery.start()
        audioOutput.start()
        microphone.start()
        bluetooth.start()
        usage.start()
        applyToolSettings()
        updateMediaKeys()
        updateAutoAwake()

        // Once more, a while later and from its own copy of the check.
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 600...1800)) { [weak self] in
            guard let self, case .failure = LicenseCheck.stored() else { return }
            self.stopFeatures()
            self.viewModel.recheckLicense()
        }
    }

    /// Battery, audio output and microphone have no stop; the view model keeps
    /// their alerts and indicators away while unlicensed.
    private func stopFeatures() {
        guard featuresRunning else { return }
        featuresRunning = false
        spectrum.stop()
        nowPlaying.stop()
        mediaKeys.stop()
        clipboard.stop()
        bluetooth.stop()
        agents.stop()
        usage.stop()
        folderWatcher.stop()
        awake.disable()
    }

    /// Clipboard history and the folders we watch follow the settings.
    private func applyToolSettings() {
        if settings.agentActivity { agents.start() } else { agents.stop() }
        if settings.clipboardEnabled {
            clipboard.start(limit: Int(settings.clipboardLimit))
            clipboard.setLimit(Int(settings.clipboardLimit))
        } else {
            clipboard.stop()
        }

        var directories: [URL] = []
        if settings.shelfEnabled {
            if settings.catchScreenshots { directories.append(FolderWatcher.screenshotDirectory) }
            if settings.catchDownloads { directories.append(FolderWatcher.downloadsDirectory) }
        }
        if directories.isEmpty {
            folderWatcher.stop()
        } else {
            folderWatcher.onNewFile = { [weak self] url in
                guard let self else { return }
                let isScreenshot = FolderWatcher.isScreenshot(url)
                let fromScreenshotDir = url.deletingLastPathComponent().standardizedFileURL
                    == FolderWatcher.screenshotDirectory.standardizedFileURL
                if fromScreenshotDir {
                    guard self.settings.catchScreenshots, isScreenshot else { return }
                } else {
                    guard self.settings.catchDownloads, FolderWatcher.isFinishedDownload(url) else { return }
                }
                self.shelf.add([url])
            }
            folderWatcher.watch(directories)
        }
    }

    /// Keep-awake rules: charging and running timers.
    private func updateAutoAwake() {
        guard license.isValid else { return }
        let wanted = (settings.awakeWhileCharging && battery.isPluggedIn)
            || (settings.awakeWhileTimerRuns && timer.isRunning)
        awake.setAutomatic(wanted, mode: settings.awakeMode)
    }

    /// Starts / stops the key tap to match the setting and the permission.
    private func updateMediaKeys() {
        mediaKeys.handlesBrightness = brightness.isAvailable
        if settings.overrideSystemHUD {
            if !mediaKeys.isRunning { mediaKeys.start() }
        } else if mediaKeys.isRunning {
            mediaKeys.stop()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        spectrum.stop()
        nowPlaying.stop()
        mediaKeys.stop()
        clipboard.stop()
        bluetooth.stop()
        agents.stop()
        usage.stop()
        folderWatcher.stop()
        awake.disable()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch")
        item.button?.image?.size = NSSize(width: 16, height: 16)
        item.menu = buildMenu()
        statusItem = item
    }

    /// Used by the menu bar icon and by right-clicking the pill.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let audioStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        audioStatus.isEnabled = false
        menu.addItem(audioStatus)
        let audioSettings = NSMenuItem(title: "Open Privacy Settings…", action: #selector(openAudioSettings), keyEquivalent: "")
        audioSettings.target = self
        menu.addItem(audioSettings)
        menu.addItem(.separator())
        let launchAtLogin = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        if updater != nil {
            let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            updates.target = self
            menu.addItem(updates)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    /// Titles that depend on current state are filled in just before the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let status = AudioCapturePermission.status
        switch status {
        case .authorized: menu.items.first?.title = "System audio: allowed"
        case .denied: menu.items.first?.title = "System audio: denied"
        case .unknown: menu.items.first?.title = "System audio: not requested yet"
        }
        menu.item(withTitle: "Open Privacy Settings…")?.isHidden = status != .denied
        settings.refreshLaunchAtLogin()
        menu.item(withTitle: "Launch at Login")?.state = settings.launchAtLogin ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try settings.setLaunchAtLogin(!settings.launchAtLogin)
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
    }

    @objc private func openAudioSettings() {
        AudioCapturePermission.openSystemSettings()
    }
}
