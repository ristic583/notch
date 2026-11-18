import Observation
import SwiftUI

// A build from this repository runs unlocked. The official builds compile their
// license check from `Services/License/Private`, which is not part of this
// repository, in place of this file: `Package.swift` picks whichever is there.
// Everything below is the surface the rest of the app talks to.

enum LicenseRefusal: Error {
    case unlicensed
}

enum LicenseCheck {
    /// Always succeeds here.
    static func stored() -> Result<Void, LicenseRefusal> { .success(()) }
}

@MainActor
@Observable
final class LicenseService {
    let isValid = true
    /// Called when the app becomes licensed or stops being licensed; never, here.
    @ObservationIgnored var onChange: (() -> Void)?

    func refresh() {}
}

/// What the card shows until a license is in. Never on screen in this build.
struct ActivationPane: View {
    let license: LicenseService

    var body: some View { EmptyView() }
}

/// Settings › General › License. Nothing to show in this build.
struct LicenseSettingsSection: View {
    let license: LicenseService

    var body: some View { EmptyView() }
}
