import Foundation

/// The identifiers Dictate ships under, and the one this copy runs as. The
/// one place they are written: everything else derives from here.
nonisolated enum AppIdentity {
    /// The Developer ID build's, from GitHub and Homebrew.
    static let developerID = "com.thibautmottet.dictate"
    /// The Mac App Store build's, under the Polyforms name from the start.
    static let appStore = "com.polyforms.dictate"
    /// Both release identifiers: an update or an older copy's data may come from either.
    static let releases = [developerID, appStore]

    /// The running copy's: Debug builds carry `.dev`, so their settings,
    /// statistics and keys stay apart from the installed release's.
    static var current: String { Bundle.main.bundleIdentifier ?? developerID }
}

/// Where Dictate keeps its files. The models are shared by every copy; the
/// rest is kept per bundle identifier, so a Debug build never mixes its test
/// dictations into the release's.
nonisolated struct AppPaths: Equatable, Sendable {
    let identifier: String
    /// `~/Library`, the sandbox container's in the App Store build.
    let library: URL

    init(identifier: String = AppIdentity.current, library: URL = .libraryDirectory) {
        self.identifier = identifier
        self.library = library
    }

    /// `~/Library/Application Support/Dictate`.
    var root: URL { library.appending(path: "Application Support/Dictate", directoryHint: .isDirectory) }
    var models: URL { root.appending(path: "Models", directoryHint: .isDirectory) }
    var statistics: URL { root.appending(path: "Statistics/\(identifier).jsonl") }
    var corpus: URL { root.appending(path: "Corpus/\(identifier)", directoryHint: .isDirectory) }
    var vocabularySuggestions: URL { root.appending(path: "Vocabulary/\(identifier)/suggestions.json") }
    var caches: URL { library.appending(path: "Caches/\(identifier)", directoryHint: .isDirectory) }
    var httpStorage: URL { library.appending(path: "HTTPStorages/\(identifier)", directoryHint: .isDirectory) }

    /// What uninstalling removes: models, statistics and caches. The models
    /// alone weigh a few gigabytes.
    var leftovers: [URL] { [root, caches, httpStorage] }
}
