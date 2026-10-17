import SwiftUI

/// Opens one window at launch, for the App Store screenshots (Debug builds
/// only, nil otherwise):
///
///     Dictate.app/Contents/MacOS/Dictate -ScreenshotWindow settings -ScreenshotTab review
///
/// Windows: setup, stats, settings. Settings tabs: general, dictation,
/// lexicon, review.
nonisolated enum ScreenshotMode {
    #if DEBUG
    static let window = UserDefaults.standard.string(forKey: "ScreenshotWindow")
    static let settingsTab = UserDefaults.standard.string(forKey: "ScreenshotTab")
    #else
    static let window: String? = nil
    static let settingsTab: String? = nil
    #endif
}

/// The Settings scene only opens from a view: the screenshot of the settings
/// goes through the statistics window, which steps aside once they are up.
struct ScreenshotSettingsOpener: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.task {
            guard ScreenshotMode.window == "settings" else { return }
            openSettings()
            dismissWindow(id: "stats")
        }
    }
}
