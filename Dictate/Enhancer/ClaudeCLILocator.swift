import Foundation

/// Finds the `claude` CLI: explicit override, then standalone installs, then
/// the newest copy bundled with the Claude desktop app.
nonisolated struct ClaudeCLILocator: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var systemDirectories: [URL] = [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin")]

    func locate(override: String?) -> URL? {
        if let override, !override.isEmpty, isExecutable(URL(filePath: override)) {
            return URL(filePath: override)
        }
        let standalone = [home.appending(path: ".local/bin/claude"), home.appending(path: ".claude/local/claude")]
            + systemDirectories.map { $0.appending(path: "claude") }
        if let found = standalone.first(where: isExecutable) {
            return found
        }
        return newestBundledCLI()
    }

    /// `~/Library/Application Support/Claude/claude-code/<version>/<build>/claude.app/Contents/MacOS/claude`
    private func newestBundledCLI() -> URL? {
        let root = home.appending(path: "Library/Application Support/Claude/claude-code")
        let fileManager = FileManager.default
        let versions = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for version in versions.sorted(by: { Self.isNewer($0, than: $1) }) {
            let versionURL = root.appending(path: version)
            let builds = (try? fileManager.contentsOfDirectory(atPath: versionURL.path)) ?? []
            for build in builds {
                let candidate = versionURL.appending(path: "\(build)/claude.app/Contents/MacOS/claude")
                if isExecutable(candidate) { return candidate }
            }
        }
        return nil
    }

    private func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
