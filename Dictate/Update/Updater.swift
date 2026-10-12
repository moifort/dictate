import AppKit
import Observation

/// One published version on GitHub.
nonisolated struct Release: Equatable, Sendable {
    var version: String
    var notes: String
    var downloadURL: URL

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
        try? UpdateInstaller().relaunch(bundle)
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
            Log.app.error("update check failed: \(error.localizedDescription, privacy: .public)")
            releases = []
            state = .idle
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
            let scratch = FileManager.default.temporaryDirectory.appending(path: "Dictate-update-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                let archive = try await download(release.downloadURL) { [weak self] fraction in
                    Task { @MainActor in
                        if case .downloading = self?.state { self?.state = .downloading(fraction) }
                    }
                }
                state = .installing
                let (installer, expectation, current) = (installer, expectation, bundleURL)
                try await Task.detached {
                    let fresh = try installer.extract(archive, into: scratch)
                    try installer.verify(fresh, against: expectation)
                    try installer.replace(current, with: fresh)
                }.value
                Log.app.info("updated to \(release.version, privacy: .public), relaunching")
                state = .idle
                finish(current)
            } catch {
                Log.app.error("update failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Same identifier, and the same team when this build carries one.
    static func expectation(bundle: Bundle = .main) -> UpdateInstaller.Expectation {
        var code: SecCode?
        var info: CFDictionary?
        var team: String?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopySigningInformation(code as! SecStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let info = info as? [String: Any] {
            team = info[kSecCodeInfoTeamIdentifier as String] as? String
        }
        return .init(bundleIdentifier: bundle.bundleIdentifier ?? "com.thibautmottet.dictate", teamIdentifier: team)
    }

    @Sendable nonisolated static func fetchFromGitHub(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? false else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    @Sendable nonisolated static func downloadWithProgress(
        _ url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(received) / Double(total)) }
            }
        }
        try handle.write(contentsOf: buffer)
        progress(1)
        return destination
    }
}
