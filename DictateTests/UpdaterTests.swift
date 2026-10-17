import Foundation
import Testing
@testable import Dictate

struct ReleaseTests {
    private let feed = """
    [
      {"tag_name": "v0.4.0", "draft": true, "prerelease": false, "body": "wip",
       "assets": [{"name": "Dictate-0.4.0.zip", "browser_download_url": "https://x/0.4.0.zip"}]},
      {"tag_name": "v0.3.0", "draft": false, "prerelease": false, "body": "Third",
       "assets": [{"name": "Dictate-0.3.0.zip", "browser_download_url": "https://x/0.3.0.zip"}]},
      {"tag_name": "v0.2.1", "draft": false, "prerelease": true, "body": "beta",
       "assets": [{"name": "Dictate-0.2.1.zip", "browser_download_url": "https://x/0.2.1.zip"}]},
      {"tag_name": "v0.2.0", "draft": false, "prerelease": false, "body": "Second",
       "assets": [{"name": "Dictate-0.2.0.zip", "browser_download_url": "https://x/0.2.0.zip"}]},
      {"tag_name": "v0.1.5", "draft": false, "prerelease": false, "body": "No asset", "assets": []},
      {"tag_name": "v0.1.0", "draft": false, "prerelease": false, "body": "First",
       "assets": [{"name": "Dictate-0.1.0.zip", "browser_download_url": "https://x/0.1.0.zip"}]}
    ]
    """

    @Test func keepsOnlyPublishedNewerReleasesWithAZip() throws {
        let newer = try Release.newer(than: "0.1.0", in: Data(feed.utf8))
        #expect(newer.map(\.version) == ["0.2.0", "0.3.0"])
        #expect(newer.last?.downloadURL == URL(string: "https://x/0.3.0.zip"))
        #expect(newer.last?.notes == "Third")
    }

    @Test func nothingWhenUpToDate() throws {
        #expect(try Release.newer(than: "0.3.0", in: Data(feed.utf8)).isEmpty)
        #expect(try Release.newer(than: "1.0", in: Data(feed.utf8)).isEmpty)
    }

    @Test func versionsCompareNumerically() {
        #expect(Version("0.9.0") < Version("0.10.0"))
        #expect(Version("1.0") < Version("1.0.1"))
        #expect(!(Version("1.0.0") < Version("1.0")))
        #expect(Version("0.0.0-abc1234") < Version("0.1.0"))
    }
}

/// Builds tiny ad-hoc signed bundles to exercise extraction, verification and swap.
struct UpdateInstallerTests {
    private let root: URL
    private let installer = UpdateInstaller()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A minimal signed app: an executable copied from the system and an Info.plist.
    private func makeApp(named name: String, identifier: String, version: String, at directory: URL) throws -> URL {
        let app = directory.appending(path: "\(name).app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: macOS.appending(path: name))
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": name,
            "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    private func zip(_ app: URL) throws -> URL {
        let archive = app.deletingLastPathComponent().appending(path: "\(app.lastPathComponent).zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        return archive
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
    }

    private func version(of app: URL) -> String? {
        Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    @Test func extractsVerifiesAndSwapsTheBundle() throws {
        let installed = try makeApp(named: "Fake", identifier: "test.fake", version: "1.0", at: root.appending(path: "Applications"))
        let archive = try zip(try makeApp(named: "Fake", identifier: "test.fake", version: "2.0", at: root.appending(path: "release")))

        let fresh = try installer.extract(archive, into: root.appending(path: "scratch"))
        try installer.verify(fresh, against: .init(bundleIdentifier: "test.fake", teamIdentifier: nil))
        try installer.replace(installed, with: fresh)

        #expect(version(of: installed) == "2.0")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Applications/.Fake.app.previous").path))
    }

    @Test func rejectsABundleWithAnotherIdentifier() throws {
        let other = try makeApp(named: "Fake", identifier: "test.other", version: "2.0", at: root)
        #expect(throws: UpdateError.self) {
            try installer.verify(other, against: .init(bundleIdentifier: "test.fake", teamIdentifier: nil))
        }
    }

    @Test func rejectsAnAdHocBundleWhenATeamIsRequired() throws {
        let adHoc = try makeApp(named: "Fake", identifier: "test.fake", version: "2.0", at: root)
        #expect(throws: UpdateError.self) {
            try installer.verify(adHoc, against: .init(bundleIdentifier: "test.fake", teamIdentifier: "46C337T7YN"))
        }
    }

    @Test func rejectsATamperedBundle() throws {
        let app = try makeApp(named: "Fake", identifier: "test.fake", version: "2.0", at: root)
        // Swap the executable after signing: the seal no longer matches.
        let executable = app.appending(path: "Contents/MacOS/Fake")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/false"), to: executable)
        #expect(throws: UpdateError.self) {
            try installer.verify(app, against: .init(bundleIdentifier: "test.fake", teamIdentifier: nil))
        }
    }

    @Test func requirementLanguage() {
        #expect(UpdateInstaller.Expectation(bundleIdentifier: "a.b", teamIdentifier: nil).requirement == "identifier \"a.b\"")
        #expect(UpdateInstaller.Expectation(bundleIdentifier: "a.b", teamIdentifier: "T").requirement
            == "identifier \"a.b\" and anchor apple generic and certificate leaf[subject.OU] = \"T\"")
    }

    @Test func buildProductsAreNotUpdatable() {
        #expect(!UpdateInstaller.isUpdatable(URL(filePath: "/Users/x/Code/speech/build/Build/Products/Debug/Dictate.app")))
        #expect(!UpdateInstaller.isUpdatable(URL(filePath: "/System/Applications/Mail.app")))
        #expect(UpdateInstaller.isUpdatable(root.appending(path: "Any.app")))
    }
}

/// The whole flow against a local "GitHub": feed, archive, swap, relaunch hook.
@MainActor
struct UpdaterFlowTests {
    @Test func checksDownloadsVerifiesAndSwaps() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flow-\(UUID().uuidString)")
        let applications = root.appending(path: "Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        // The installed copy is this very test host; the "release" is the same app with a bumped version.
        let installed = applications.appending(path: "Dictate.app")
        try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: installed)
        let staged = root.appending(path: "release/Dictate.app")
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: staged)
        try shell("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleShortVersionString 9.9.9", staged.appending(path: "Contents/Info.plist").path])
        try shell("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", staged.path])
        let archive = root.appending(path: "Dictate-9.9.9.zip")
        try shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", staged.path, archive.path])

        let feed = """
        [{"tag_name": "v9.9.9", "draft": false, "prerelease": false, "body": "Big one",
          "assets": [{"name": "Dictate-9.9.9.zip", "browser_download_url": "\(archive.absoluteString)"}]}]
        """
        var relaunched: URL?
        let updater = Updater(
            currentVersion: "0.1.0",
            bundleURL: installed,
            expectation: .init(bundleIdentifier: try #require(Bundle.main.bundleIdentifier), teamIdentifier: nil),
            fetch: { _ in Data(feed.utf8) },
            download: { url, progress in progress(1); return url },
            finish: { relaunched = $0 }
        )
        #expect(updater.canInstall)

        await updater.check()
        #expect(updater.available?.version == "9.9.9")

        updater.install()
        for _ in 0..<100 where relaunched == nil && updater.state != .idle {
            if case .failed = updater.state { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(updater.state == .idle, "\(updater.state)")
        #expect(relaunched == installed)
        #expect(Bundle(url: installed)?.infoDictionary?["CFBundleShortVersionString"] as? String == "9.9.9")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func keepsTheReleaseWhileDownloadingAndAfterAFailure() async throws {
        let feed = """
        [{"tag_name": "v9.9.9", "draft": false, "prerelease": false, "body": "Big one",
          "assets": [{"name": "Dictate-9.9.9.zip", "browser_download_url": "https://x/9.9.9.zip"}]}]
        """
        let updater = Updater(
            currentVersion: "0.1.0",
            bundleURL: FileManager.default.temporaryDirectory.appending(path: "Dictate.app"),
            expectation: .init(bundleIdentifier: "test.fake", teamIdentifier: nil),
            fetch: { _ in Data(feed.utf8) },
            download: { _, progress in
                progress(0.5)
                try await Task.sleep(for: .milliseconds(300))
                throw URLError(.networkConnectionLost)
            },
            finish: { _ in }
        )
        await updater.check()
        #expect(updater.available?.version == "9.9.9")

        updater.install()
        try await Task.sleep(for: .milliseconds(100))
        #expect(updater.state == .downloading(0.5), "\(updater.state)")
        #expect(updater.available?.version == "9.9.9")
        #expect(updater.releases.map(\.notes) == ["Big one"])

        for _ in 0..<50 {
            if case .failed = updater.state { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .failed = updater.state else { Issue.record("\(updater.state)"); return }
        #expect(updater.available?.version == "9.9.9")
    }

    @Test func thisBuildExpectsItsOwnIdentifierAndTeam() {
        let expectation = Updater.expectation()
        // Debug builds carry a `.dev` suffix, so compare with the running bundle.
        #expect(expectation.bundleIdentifier == Bundle.main.bundleIdentifier)
        #expect(expectation.bundleIdentifier.hasPrefix("com.thibautmottet.dictate"))
        // Signed with an Apple certificate locally, ad hoc on CI.
        if let team = expectation.teamIdentifier { #expect(team == "46C337T7YN") }
    }

    /// Installed copies must accept a release under the Polyforms identifier.
    @Test func releasesUnderEitherIdentifierAreAccepted() {
        let expectation = UpdateInstaller.Expectation(
            bundleIdentifier: "com.thibautmottet.dictate",
            teamIdentifier: "46C337T7YN",
            alsoAccepted: Updater.releaseIdentifiers
        )
        #expect(expectation.requirement == """
            (identifier "com.thibautmottet.dictate" or identifier "com.polyforms.dictate") \
            and anchor apple generic and certificate leaf[subject.OU] = "46C337T7YN"
            """)
    }

    @Test func anOtherAppOnlyAcceptsItsOwnIdentifier() {
        let expectation = UpdateInstaller.Expectation(bundleIdentifier: "test.fake", teamIdentifier: nil)
        #expect(expectation.requirement == #"identifier "test.fake""#)
    }

    private func shell(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
    }
}

/// A Mac with no network is the usual way a background check fails: that is
/// not an error worth a Sentry event, only a check to run again later.
struct UpdaterOfflineTests {
    @Test func noNetworkIsOffline() {
        #expect(Updater.isOffline(URLError(.notConnectedToInternet)))
        #expect(Updater.isOffline(URLError(.networkConnectionLost)))
        #expect(Updater.isOffline(URLError(.cannotFindHost)))
        #expect(Updater.isOffline(URLError(.dnsLookupFailed)))
        #expect(Updater.isOffline(URLError(.timedOut)))
    }

    /// Foundation hands URLSession failures over as `NSError`, the form Sentry saw.
    @Test func bridgedNSErrorIsOffline() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(Updater.isOffline(error))
    }

    @Test func otherFailuresAreNotOffline() {
        #expect(!Updater.isOffline(URLError(.badServerResponse)))
        #expect(!Updater.isOffline(NSError(domain: "test", code: 1)))
    }

    @Test func offlineCheckEndsIdleWithNothingToInstall() async {
        let updater = Updater(
            currentVersion: "0.1.0",
            bundleURL: FileManager.default.temporaryDirectory.appending(path: "Dictate.app"),
            expectation: .init(bundleIdentifier: "test.fake", teamIdentifier: nil),
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            download: { url, _ in url },
            finish: { _ in }
        )
        await updater.check()
        #expect(updater.state == .idle)
        #expect(updater.releases.isEmpty)
        #expect(updater.lastCheck != nil)
    }
}
