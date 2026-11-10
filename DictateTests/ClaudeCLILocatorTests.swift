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

    @Test func parsesTheAuthStatus() {
        #expect(ClaudeCLILocator.parseSignedIn(Data(#"{"loggedIn": true, "subscriptionType": "max"}"#.utf8)) == true)
        #expect(ClaudeCLILocator.parseSignedIn(Data(#"{"loggedIn": false, "authMethod": "none"}"#.utf8)) == false)
        #expect(ClaudeCLILocator.parseSignedIn(Data("Unknown command: auth".utf8)) == nil)
    }

    @Test func readsTheSignedOutStatusDespiteTheExitCode() async throws {
        let script = try executable("#!/bin/sh\necho '{\"loggedIn\": false}'\nexit 1\n")
        #expect(await ClaudeCLILocator.isSignedIn(script) == false)
    }

    @Test func givesUpOnACLIThatHangs() async throws {
        let script = try executable("#!/bin/sh\nexec sleep 30\n")
        #expect(await ClaudeCLILocator.isSignedIn(script, timeout: .milliseconds(500)) == nil)
    }

    private func executable(_ contents: String) throws -> URL {
        let script = home.appending(path: "claude")
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test func shortensDisplayedPaths() {
        let locator = ClaudeCLILocator(home: home, systemDirectories: [])
        #expect(locator.displayPath(of: home.appending(path: ".local/bin/claude")) == "~/.local/bin/claude")
        #expect(locator.displayPath(of: home.appending(path: bundled("2.1.293"))) == "App Claude")
        #expect(locator.displayPath(of: URL(filePath: "/opt/homebrew/bin/claude")) == "/opt/homebrew/bin/claude")
    }
}

struct SubprocessTests {
    @Test func returnsTheOutputAndStatus() async throws {
        let output = try await Subprocess.run(URL(filePath: "/bin/sh"), ["-c", "echo hello; exit 3"])
        #expect(output.text == "hello\n")
        #expect(output.status == 3)
        #expect(!output.succeeded)
    }

    /// A tool reading its input gets an empty one rather than waiting for the app's.
    @Test func standardInputIsEmpty() async throws {
        let output = try await Subprocess.run(URL(filePath: "/bin/cat"), [], timeout: .seconds(5))
        #expect(output.succeeded)
        #expect(output.data.isEmpty)
    }

    @Test func aHangingToolIsTerminated() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await Subprocess.run(URL(filePath: "/bin/sleep"), ["30"], timeout: .milliseconds(200))
        #expect(output.timedOut)
        #expect(clock.now - start < .seconds(5))
    }

    /// More than a pipe holds: read as it comes, or the tool would never exit.
    @Test func aLargeOutputIsReadWhole() async throws {
        let output = try await Subprocess.run(URL(filePath: "/bin/sh"), ["-c", "head -c 300000 /dev/zero"])
        #expect(output.data.count == 300_000)
    }

    @Test func aMissingToolThrows() async {
        await #expect(throws: (any Error).self) {
            try await Subprocess.run(URL(filePath: "/nonexistent/tool"), [])
        }
    }
}
