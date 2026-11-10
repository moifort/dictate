import AppKit
import Observation

/// One published version on GitHub.
nonisolated struct Release: Equatable, Sendable {
    var version: String
    var notes: String
    var downloadURL: URL
    /// The same zip through the GitHub API, tried when `downloadURL` fails: on
    /// 2026-11-08 github.com answered 504 to every release download for hours
    /// while the API served the assets fine.
    var fallbackURL: URL?

    /// The URLs to try for the zip, in order.
    var downloadURLs: [URL] { [downloadURL] + (fallbackURL.map { [$0] } ?? []) }

    /// Releases newer than `current`, oldest first, from GitHub's `/releases` JSON.
    static func newer(than current: String, in json: Data) throws -> [Release] {
        guard let entries = try JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        return entries.compactMap(Release.init(github:))
            .filter { Version(current) < Version($0.version) }
            .sorted { Version($0.version) < Version($1.version) }
    }

    private init?(github entry: [String: Any]) {
        guard entry["draft"] as? Bool != true, entry["prerelease"] as? Bool != true,
              let tag = entry["tag_name"] as? String,
              let assets = entry["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let download = (zip["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        notes = (entry["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        downloadURL = download
        fallbackURL = (zip["url"] as? String).flatMap(URL.init(string:))
    }
}

/// Dotted numeric version, compared component by component.
nonisolated struct Version: Comparable, Sendable {
    let components: [Int]

    init(_ string: String) {
        components = string.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        return false
    }
}

/// Checks GitHub for newer releases and installs them, like Stats does.
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        /// `releases` holds newer versions; the last one is installed.
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let repository = "moifort/dictate"
    static let checkInterval: Duration = .seconds(6 * 3600)

    private(set) var state: State = .idle
    /// Releases newer than the running one, oldest first. Survives downloading and failures so the
    /// window keeps showing what is being installed and lets the user retry.
    private(set) var releases: [Release] = []
    private(set) var lastCheck: Date?
    let currentVersion: String

    /// Whether this copy can replace itself: false for builds run from Xcode.
    let canInstall: Bool

    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let expectation: UpdateInstaller.Expectation
    @ObservationIgnored private let fetch: @Sendable (URL) async throws -> Data
    @ObservationIgnored private let download: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL
    @ObservationIgnored private let finish: @MainActor (URL) -> Void
    @ObservationIgnored private let installer = UpdateInstaller()
    @ObservationIgnored private var periodic: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    /// Whether the app may relaunch now: false while a dictation is being
    /// recorded or is on its way to the field. An update found mid-dictation
    /// waits for it rather than quitting under the user.
    @ObservationIgnored var isIdle: () -> Bool = { true }
    /// How often a verified update checks whether the dictation is over.
    @ObservationIgnored var idlePoll: Duration = .seconds(1)

    init(
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
        bundleURL: URL = Bundle.main.bundleURL,
        expectation: UpdateInstaller.Expectation = Updater.expectation(),
        fetch: @escaping @Sendable (URL) async throws -> Data = Updater.fetchFromGitHub,
        download: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL = Updater.downloadWithProgress,
        finish: @escaping @MainActor (URL) -> Void = Updater.relaunchAndQuit
    ) {
        self.currentVersion = currentVersion
        self.bundleURL = bundleURL
        self.expectation = expectation
        self.fetch = fetch
        self.download = download
        self.finish = finish
        canInstall = UpdateInstaller.isUpdatable(bundleURL)
    }

    static func relaunchAndQuit(_ bundle: URL) {
        do {
            try UpdateInstaller().relaunch(bundle)
        } catch {
            Log.app.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "updated app could not be relaunched", category: "updater")
        }
        NSApp.terminate(nil)
    }

    var available: Release? { releases.last }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    /// Checks shortly after launch, then every few hours. `autoInstall` installs without asking.
    func startPeriodicChecks(autoInstall: @escaping () -> Bool) {
        periodic?.cancel()
        periodic = Task {
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await check()
                if autoInstall(), available != nil { install() }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func check() async {
        guard !isBusy else { return }
        state = .checking
        defer { lastCheck = .now }
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases")!
            self.releases = try Release.newer(than: currentVersion, in: try await fetch(url))
            state = self.releases.isEmpty ? .idle : .available
            Log.app.info("update check: \(self.releases.count) newer release(s)")
        } catch {
            if Self.isTransient(error) {
                // No network, or GitHub down for a moment, is the ordinary way a
                // background check fails: the next one runs a few hours later,
                // nobody needs to hear about it.
                Log.app.info("update check skipped, GitHub unreachable: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.app.error("update check failed: \(error.localizedDescription, privacy: .public)")
                ErrorReporter.capture(error, "update check failed", category: "updater", level: .warning)
            }
            releases = []
            state = .idle
        }
    }

    /// GitHub answered outside 2xx. The status tells a failure on GitHub's side, which
    /// passes, from a request GitHub refuses, which does not.
    nonisolated struct ServerError: LocalizedError {
        let statusCode: Int
        /// GitHub's rate limit for anonymous requests is spent until it resets:
        /// 429, or 403 with no request left.
        var isRateLimited = false

        init(statusCode: Int, isRateLimited: Bool = false) {
            self.statusCode = statusCode
            self.isRateLimited = isRateLimited
        }

        /// Reads the status and, for a refusal, GitHub's rate limit headers.
        init(_ response: HTTPURLResponse) {
            let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining")
            self.init(
                statusCode: response.statusCode,
                isRateLimited: response.statusCode == 429 || (response.statusCode == 403 && remaining == "0")
            )
        }

        var errorDescription: String? {
            String(localized: "GitHub ne répond pas pour le moment (erreur \(statusCode)). Réessayez plus tard.")
        }
    }

    /// Whether `error` is a passing failure, on the way to GitHub or on its side: no
    /// network, a 5xx answer such as the 504 its releases API returns now and then,
    /// or its rate limit, shared by every app behind the same address. None is
    /// anything the app could fix, so none is reported to Sentry.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        if isOffline(error) { return true }
        guard let error = error as? ServerError else { return false }
        return error.isRateLimited || 500..<600 ~= error.statusCode
    }

    /// Whether `error` says the Mac cannot reach GitHub right now, as opposed to GitHub
    /// answering something unexpected. Matched on the `URLError` code, which Foundation
    /// also hands over bridged as an `NSError` in the `NSURLErrorDomain`.
    nonisolated static func isOffline(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Downloads, verifies, swaps the bundle and relaunches the app.
    func install() {
        guard let release = available, installTask == nil else { return }
        guard canInstall else {
            state = .failed(UpdateError.notInstalled.localizedDescription)
            return
        }
        installTask = Task {
            defer { installTask = nil }
            state = .downloading(0)
            let current = bundleURL
            let scratch = UpdateInstaller.scratchDirectory(nextTo: current)
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                let archive = try await downloadArchive(of: release)
                state = .installing
                let (installer, expectation) = (installer, expectation)
                let fresh = try await Task.detached {
                    // Not needed once extracted, whatever happens next.
                    defer { try? FileManager.default.removeItem(at: archive) }
                    let fresh = try installer.extract(archive, into: scratch)
                    try installer.verify(fresh, against: expectation)
                    return fresh
                }.value
                // Swapped and relaunched only between dictations: the relaunch
                // would cut one short, and the swap must not precede it by long.
                if !isIdle() {
                    Log.app.info("update to \(release.version, privacy: .public) ready, waiting for the dictation to end")
                    while !isIdle() { try? await Task.sleep(for: idlePoll) }
                }
                try await Task.detached { try installer.replace(current, with: fresh) }.value
                Log.app.info("updated to \(release.version, privacy: .public), relaunching")
                state = .idle
                finish(current)
            } catch {
                if Self.isTransient(error) {
                    // A download the network cut short is shown to the user, who
                    // can retry: like a skipped check, nothing Sentry could fix.
                    Log.app.notice("update to \(release.version, privacy: .public) interrupted, offline: \(error.localizedDescription, privacy: .public)")
                } else {
                    Log.app.error("update failed: \(error.localizedDescription, privacy: .public)")
                    ErrorReporter.capture(error, "update to \(release.version) failed", category: "updater")
                }
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Downloads the release's zip from the first of its URLs that answers. Only a
    /// passing failure moves on to the next URL: a bad archive would be as bad there.
    private func downloadArchive(of release: Release) async throws -> URL {
        let urls = release.downloadURLs
        for (index, url) in urls.enumerated() {
            state = .downloading(0)
            do {
                return try await download(url) { [weak self] fraction in
                    Task { @MainActor in
                        if case .downloading = self?.state { self?.state = .downloading(fraction) }
                    }
                }
            } catch where index < urls.count - 1 && Self.isTransient(error) {
                Log.app.notice("update download from \(url.host() ?? "?", privacy: .public) failed, trying the next URL: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw URLError(.badURL)
    }

    /// The identifiers Dictate ships under, old and new (Polyforms).
    static let releaseIdentifiers = ["com.thibautmottet.dictate", "com.polyforms.dictate"]

    /// Same app, and the same team when this build carries one.
    static func expectation(bundle: Bundle = .main) -> UpdateInstaller.Expectation {
        var code: SecCode?
        var info: CFDictionary?
        var team: String?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopySigningInformation(code as! SecStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let info = info as? [String: Any] {
            team = info[kSecCodeInfoTeamIdentifier as String] as? String
        }
        let identifier = bundle.bundleIdentifier ?? releaseIdentifiers[0]
        return .init(
            bundleIdentifier: identifier,
            teamIdentifier: team,
            alsoAccepted: releaseIdentifiers.contains(identifier) ? releaseIdentifiers : []
        )
    }

    @Sendable nonisolated static func fetchFromGitHub(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= http.statusCode else { throw ServerError(http) }
        return data
    }

    /// Downloads to a file of its own, reporting progress as it goes. The
    /// caller deletes the file once done; nothing is left behind on failure.
    @Sendable nonisolated static func downloadWithProgress(
        _ url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: url)
        // The API serves the asset itself, rather than its JSON, only when asked to.
        if url.host() == "api.github.com" {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        }
        let (downloaded, response) = try await URLSession.shared.download(for: request, delegate: DownloadProgress(progress))
        // URLSession leaves the file to the caller, whatever the answer.
        let destination = FileManager.default.temporaryDirectory.appending(path: "Dictate-\(UUID().uuidString).zip")
        do {
            // A 504 page saved as the zip used to fail later as "the archive could not be extracted".
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard 200..<300 ~= http.statusCode else { throw ServerError(http) }
            // A connection that ends early leaves a truncated zip: say so, rather than fail extracting it.
            let total = response.expectedContentLength
            let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard total <= 0 || Int64(size) == total else { throw URLError(.networkConnectionLost) }
            try FileManager.default.moveItem(at: downloaded, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
        progress(1)
        return destination
    }
}

/// Reports a download's progress from its task, as URLSession updates it.
private nonisolated final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            // Unknown sizes report 0 until the end: nothing worth showing.
            if progress.totalUnitCount > 0 { report(progress.fractionCompleted) }
        }
    }
}
