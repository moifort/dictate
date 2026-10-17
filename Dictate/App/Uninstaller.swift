import AppKit
import ServiceManagement

/// Removes Dictate and everything it left on this Mac. Files go to the Trash
/// rather than being deleted, so a mistaken click can still be undone.
struct Uninstaller {
    let bundle: URL
    let bundleIdentifier: String
    let home: URL

    init(bundle: Bundle = .main, home: URL = .homeDirectory) {
        self.bundle = bundle.bundleURL
        bundleIdentifier = bundle.bundleIdentifier ?? "com.thibautmottet.dictate"
        self.home = home
    }

    /// Models, statistics and caches. The models alone weigh a few gigabytes.
    var leftovers: [URL] {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        return [
            library.appending(path: "Application Support/Dictate", directoryHint: .isDirectory),
            library.appending(path: "Caches/\(bundleIdentifier)", directoryHint: .isDirectory),
            library.appending(path: "HTTPStorages/\(bundleIdentifier)", directoryHint: .isDirectory),
        ]
    }

    /// A Debug build runs from DerivedData: trashing it would only break the next build.
    var removesBundle: Bool {
        UpdateInstaller.isUpdatable(bundle)
    }

    /// Asks first, then cleans up and quits.
    func confirmAndRun() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Désinstaller Dictate ?")
        alert.informativeText = String(localized: """
            L'application, les modèles de transcription, les statistiques et les réglages \
            seront placés dans la Corbeille ou effacés, et Dictate quittera.
            """)
        alert.addButton(withTitle: String(localized: "Désinstaller")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Annuler"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run()
    }

    func run() {
        Log.app.info("uninstalling \(bundleIdentifier, privacy: .public)")
        try? SMAppService.mainApp.unregister()
        resetPrivacyGrants()
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)

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
    private func resetPrivacyGrants() {
        let tccutil = Process()
        tccutil.executableURL = URL(filePath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "All", bundleIdentifier]
        try? tccutil.run()
        tccutil.waitUntilExit()
    }
}
