import Foundation

/// Finds the `claude` CLI: explicit override, then standalone installs, then
/// the newest copy bundled with the Claude desktop app.
nonisolated struct ClaudeCLILocator: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var systemDirectories: [URL] = [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin")]

    func locate(override: String?) -> URL? {
        guard !Distribution.isAppStore else { return nil }
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

    /// Short form for the settings: the bundled copy hides deep inside the desktop app.
    func displayPath(of url: URL) -> String {
        if url.path.contains("/Claude/claude-code/") { return "App Claude" }
        let homePath = home.path
        return url.path.hasPrefix(homePath + "/") ? "~" + url.path.dropFirst(homePath.count) : url.path
    }

    /// Runs `claude --version`; nil when the binary does not answer like Claude Code.
    static func version(of executable: URL) async -> String? {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["--version"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                ErrorReporter.capture(error, "claude --version could not be run", category: "enhancer", level: .warning)
                return nil
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return parseVersion(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// `2.1.3 (Claude Code)` → `2.1.3`.
    static func parseVersion(_ output: String) -> String? {
        guard let first = output.split(whereSeparator: \.isWhitespace).first, first.first?.isNumber == true else {
            return nil
        }
        return String(first)
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
