import SwiftUI

/// The app's windows, by the identifiers SwiftUI opens them with.
enum WindowID: String {
    case setup
    case stats
    case update
    /// Not a window of its own: the Settings scene, for the screenshots.
    case settings
}

/// The settings tabs, also picked by the screenshots (`-ScreenshotTab`).
enum SettingsTab: String, Hashable {
    case general, dictation, lexicon, review
}

extension OpenWindowAction {
    func callAsFunction(_ window: WindowID) { callAsFunction(id: window.rawValue) }
}

extension DismissWindowAction {
    func callAsFunction(_ window: WindowID) { callAsFunction(id: window.rawValue) }
}
