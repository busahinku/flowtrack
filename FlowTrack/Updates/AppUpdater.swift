import Foundation
import Combine
import Sparkle

/// Manages Sparkle auto-updates. Singleton kept alive for the lifetime of the app.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController

    var updater: SPUUpdater { controller.updater }

    @Published var canCheckForUpdates = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Observe Sparkle's canCheckForUpdates KVO property
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
