import Foundation

nonisolated enum UpdateError: LocalizedError, Equatable {
    case extractionFailed
    case appBundleNotFound
    case signatureRejected(String)
    /// The archive holds another version than the release announced.
    case versionMismatch(expected: String, found: String)
    case notInstalled
    /// This copy has no Team ID to require of the update: anyone's ad-hoc
    /// signed bundle with the same identifier would pass.
    case unsignedCopy

    var errorDescription: String? {
        switch self {
        case .extractionFailed: String(localized: "L'archive téléchargée n'a pas pu être extraite.")
        case .appBundleNotFound: String(localized: "L'archive ne contient pas d'application.")
        case .signatureRejected(let details): String(localized: "La signature de la mise à jour est invalide. \(details)")
        case .versionMismatch(let expected, let found):
            String(localized: "La mise à jour contient la version \(found) au lieu de \(expected).")
        case .notInstalled: String(localized: "Dictate ne tourne pas depuis un emplacement où il peut se mettre à jour.")
        case .unsignedCopy: String(localized: "Cette copie de Dictate n'est pas signée : elle ne peut pas vérifier ses mises à jour. Téléchargez la dernière version sur le site.")
        }
    }
}

/// The file-system half of an update: extract, verify, swap, relaunch.
/// Pure functions on paths, so tests can run them on fake bundles.
nonisolated struct UpdateInstaller: Sendable {
    /// What a replacement bundle must satisfy before it is trusted.
    struct Expectation: Sendable, Equatable {
        var bundleIdentifier: String
        /// Required when the running app is signed with a real certificate.
        var teamIdentifier: String?
        /// Other identifiers the same app may ship under: Dictate moves from
        /// `com.thibautmottet.dictate` to `com.polyforms.dictate`.
        var alsoAccepted: [String] = []

        /// `codesign` requirement language.
        var requirement: String {
            let identifiers = ([bundleIdentifier] + alsoAccepted.filter { $0 != bundleIdentifier })
                .map { "identifier \"\($0)\"" }
            var clauses = [identifiers.count == 1 ? identifiers[0] : "(" + identifiers.joined(separator: " or ") + ")"]
            if let teamIdentifier {
                clauses.append("anchor apple generic")
                clauses.append("certificate leaf[subject.OU] = \"\(teamIdentifier)\"")
            }
            return clauses.joined(separator: " and ")
        }
    }

    /// Unzips `archive` and returns the single `.app` it contains.
    func extract(_ archive: URL, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ditto = try await Subprocess.run(URL(filePath: "/usr/bin/ditto"), ["-xk", archive.path, directory.path], timeout: .seconds(120))
        guard ditto.succeeded else { throw UpdateError.extractionFailed }

        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appBundleNotFound
        }
        return app
    }

    /// Rejects anything that is not a validly signed Dictate from the same
    /// team, nested code included, or not the announced `version`.
    func verify(_ bundle: URL, against expectation: Expectation, version: String? = nil) async throws {
        if let version {
            let found = Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            guard found == version else { throw UpdateError.versionMismatch(expected: version, found: found) }
        }
        let codesign = try await Subprocess.run(
            URL(filePath: "/usr/bin/codesign"),
            ["--verify", "--deep", "--strict", "-R=\(expectation.requirement)", bundle.path],
            timeout: .seconds(120),
            includingStandardError: true
        )
        guard codesign.succeeded else {
            throw UpdateError.signatureRejected(codesign.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Where to extract an update so that it sits on the same volume as `bundle`:
    /// moving it into place is then a rename, never a copy that can stop halfway.
    /// The temporary folder when the volume offers no such directory.
    /// A new, unique directory each time: remove it once done.
    static func scratchDirectory(nextTo bundle: URL) -> URL {
        (try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true
        )) ?? FileManager.default.temporaryDirectory.appending(
            path: "Dictate-update-\(UUID().uuidString)", directoryHint: .isDirectory
        )
    }

    /// Puts `replacement` where `current` is. The old bundle is restored if the
    /// move fails, after removing whatever part of the new one reached `current`.
    /// `move` is FileManager's, injected so tests can make it fail.
    func replace(
        _ current: URL,
        with replacement: URL,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        let fileManager = FileManager.default
        let backup = current.deletingLastPathComponent().appending(path: ".\(current.lastPathComponent).previous")
        try? fileManager.removeItem(at: backup)
        try move(current, backup)
        do {
            try move(replacement, current)
        } catch {
            // A move across volumes copies: a partial bundle would block the restore.
            if fileManager.fileExists(atPath: current.path) { try? fileManager.removeItem(at: current) }
            do {
                try move(backup, current)
            } catch let restore {
                ErrorReporter.capture(restore, "previous bundle could not be restored after a failed update", category: "updater", level: .fatal)
            }
            throw error
        }
        try? fileManager.removeItem(at: backup)
    }

    /// True when the bundle sits somewhere the user can overwrite, outside a build folder.
    static func isUpdatable(_ bundle: URL) -> Bool {
        let parent = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else { return false }
        return !bundle.path.contains("/Build/Products/") && !bundle.path.contains("/DerivedData/")
    }

    /// Launches the bundle again once this process has exited.
    func relaunch(_ bundle: URL) throws {
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", bundle.path]
        try shell.run()
    }
}
