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

}
