import Foundation
import Testing
@testable import Dictate

struct ClaudeCLILocatorTests {
    private let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private func makeExecutable(_ relativePath: String) throws -> URL {
        let url = home.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func bundled(_ version: String) -> String {
        "Library/Application Support/Claude/claude-code/\(version)/abc123/claude.app/Contents/MacOS/claude"
    }

    @Test func returnsNilWhenNothingInstalled() {
        let locator = ClaudeCLILocator(home: home, systemDirectories: [])
        #expect(locator.locate(override: nil) == nil)
    }

    @Test func picksNewestBundledVersion() throws {
        _ = try makeExecutable(bundled("2.1.289"))
        let newest = try makeExecutable(bundled("2.1.293"))
        _ = try makeExecutable(bundled("2.1.30"))
        let locator = ClaudeCLILocator(home: home, systemDirectories: [])
        #expect(locator.locate(override: nil) == newest)
    }

    @Test func prefersStandaloneInstallOverBundled() throws {
        _ = try makeExecutable(bundled("2.1.293"))
        let standalone = try makeExecutable(".local/bin/claude")
        let locator = ClaudeCLILocator(home: home, systemDirectories: [])
        #expect(locator.locate(override: nil) == standalone)
    }

    @Test func executableOverrideWins() throws {
        _ = try makeExecutable(".local/bin/claude")
        let custom = try makeExecutable("custom/claude")
        let locator = ClaudeCLILocator(home: home, systemDirectories: [])
        #expect(locator.locate(override: custom.path) == custom)
    }

    @Test func invalidOverrideFallsBackToSearch() throws {
        let standalone = try makeExecutable(".local/bin/claude")
        let locator = ClaudeCLILocator(home: home, systemDirectories: [])
        #expect(locator.locate(override: "/nope/claude") == standalone)
    }

    @Test func parsesTheVersionLine() {
        #expect(ClaudeCLILocator.parseVersion("2.1.293 (Claude Code)\n") == "2.1.293")
        #expect(ClaudeCLILocator.parseVersion("command not found") == nil)
        #expect(ClaudeCLILocator.parseVersion("") == nil)
    }

    @Test func readsTheVersionFromTheBinary() async throws {
        let script = home.appending(path: "claude")
        try Data("#!/bin/sh\necho '2.1.293 (Claude Code)'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        #expect(await ClaudeCLILocator.version(of: script) == "2.1.293")
    }

    @Test func shortensDisplayedPaths() {
        let locator = ClaudeCLILocator(home: home, systemDirectories: [])
        #expect(locator.displayPath(of: home.appending(path: ".local/bin/claude")) == "~/.local/bin/claude")
        #expect(locator.displayPath(of: home.appending(path: bundled("2.1.293"))) == "App Claude")
        #expect(locator.displayPath(of: URL(filePath: "/opt/homebrew/bin/claude")) == "/opt/homebrew/bin/claude")
    }
}
