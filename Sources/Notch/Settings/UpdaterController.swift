import Foundation
import Observation
#if canImport(Sparkle)
import Sparkle
#endif

/// Thin wrapper so the rest of the app doesn't depend on Sparkle directly.
/// `make()` returns nil when Sparkle isn't linked or no feed URL is configured.
@MainActor
@Observable
final class UpdaterController {
    #if canImport(Sparkle)
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            DispatchQueue.main.async { self?.canCheckForUpdates = value }
        }
    }

    static func make() -> UpdaterController? {
        // Both the feed and the public key must be baked in, otherwise Sparkle can't verify anything.
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !feed.isEmpty, !key.isEmpty, !feed.contains("$("), !key.contains("$(") else { return nil }
        return UpdaterController()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
    #else
    let canCheckForUpdates = false
    var automaticallyChecks = false
    static func make() -> UpdaterController? { nil }
    func checkForUpdates() {}
    #endif
}
