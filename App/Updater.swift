import Sparkle
import SwiftUI

/// Sparkle updates from GitHub Releases (D129). Off in debug builds and until
/// the release key is set up, so a development build never replaces itself.
@MainActor
final class Updater {
    static let shared = Updater()

    let controller: SPUStandardUpdaterController

    static var isEnabled: Bool {
        #if DEBUG
        false
        #else
        (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
        #endif
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Sparkle's own preferences (D186), saved by Sparkle in Orbit's defaults.
    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var installsAutomatically: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
}
