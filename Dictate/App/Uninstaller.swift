import AppKit
import ServiceManagement

/// Removes Dictate and everything it left on this Mac. Files go to the Trash
/// rather than being deleted, so a mistaken click can still be undone.
struct Uninstaller {
    let bundle: URL
    let paths: AppPaths

    var bundleIdentifier: String { paths.identifier }

    init(bundle: Bundle = .main, home: URL = .homeDirectory) {
        self.bundle = bundle.bundleURL
        paths = AppPaths(
            identifier: bundle.bundleIdentifier ?? AppIdentity.developerID,
            library: home.appending(path: "Library", directoryHint: .isDirectory)
        )
    }

    var leftovers: [URL] { paths.leftovers }

    /// A Debug build runs from DerivedData: trashing it would only break the next build.
    var removesBundle: Bool {
        UpdateInstaller.isUpdatable(bundle)
    }

    func run() async {
        Log.app.info("uninstalling \(bundleIdentifier, privacy: .public)")
        try? await SMAppService.mainApp.unregister()
        await resetPrivacyGrants()
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        Self.removeAPIKeys()

        let existing = (leftovers + (removesBundle ? [bundle] : []))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.recycle(existing) { _, error in
            if let error {
                Log.app.error("uninstall left files behind: \(error.localizedDescription, privacy: .public)")
                ErrorReporter.capture(error, "uninstall left files behind", category: "uninstaller")
            }
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// Best effort: grants stored in the system database need an admin, and
    /// macOS drops them anyway once the app is gone from the disk.
    private func resetPrivacyGrants() async {
        do {
            _ = try await Subprocess.run(URL(filePath: "/usr/bin/tccutil"), ["reset", "All", bundleIdentifier], timeout: .seconds(10))
        } catch {
            Log.app.error("tccutil could not run: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The keys live in the keychain, which the Trash does not reach.
    static func removeAPIKeys(_ store: (APIProvider) -> SecretStore = { KeychainSecret(account: $0.keychainAccount) }) {
        for provider in APIProvider.allCases { try? store(provider).write("") }
    }
}
