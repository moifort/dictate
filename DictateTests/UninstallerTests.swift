import Foundation
import Testing
@testable import Dictate

struct UninstallerTests {
    @Test func leftoversCoverModelsStatisticsAndCaches() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let uninstaller = Uninstaller(bundle: .main, home: home)
        let paths = uninstaller.leftovers.map(\.path)
        #expect(paths.contains("/Users/someone/Library/Application Support/Dictate"))
        #expect(paths.contains("/Users/someone/Library/Caches/\(uninstaller.bundleIdentifier)"))
        #expect(paths.allSatisfy { $0.hasPrefix("/Users/someone/Library/") })
    }

    @Test func theAPIKeysLeaveWithTheApp() {
        let stores = Dictionary(uniqueKeysWithValues: APIProvider.allCases.map { ($0, InMemorySecret("key-\($0.rawValue)")) })
        Uninstaller.removeAPIKeys { stores[$0]! }
        #expect(stores.values.allSatisfy { (try? $0.read()) == .some(nil) })
    }
}

struct AppPathsTests {
    /// Every per-copy file sits under its identifier; the models are shared.
    @Test func everyPathFollowsTheIdentifier() {
        let library = URL(filePath: "/Users/someone/Library", directoryHint: .isDirectory)
        let paths = AppPaths(identifier: "com.example.app", library: library)
        #expect(paths.models.path == "/Users/someone/Library/Application Support/Dictate/Models")
        #expect(paths.statistics.path == "/Users/someone/Library/Application Support/Dictate/Statistics/com.example.app.jsonl")
        #expect(paths.corpus.path == "/Users/someone/Library/Application Support/Dictate/Corpus/com.example.app")
        #expect(paths.vocabularySuggestions.path.hasSuffix("Dictate/Vocabulary/com.example.app/suggestions.json"))
        #expect(paths.leftovers.map(\.lastPathComponent) == ["Dictate", "com.example.app", "com.example.app"])
    }

    /// The defaults the app uses are this copy's.
    @Test func theAppUsesItsOwnIdentifier() {
        #expect(DictationHistory.defaultFile == AppPaths().statistics)
        #expect(AppPaths().identifier == Bundle.main.bundleIdentifier)
    }
}
