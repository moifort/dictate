import Foundation

nonisolated enum UpdateError: LocalizedError, Equatable {
    case extractionFailed
    case appBundleNotFound
    case signatureRejected(String)
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .extractionFailed: String(localized: "L'archive téléchargée n'a pas pu être extraite.")
        case .appBundleNotFound: String(localized: "L'archive ne contient pas d'application.")
        case .signatureRejected(let details): String(localized: "La signature de la mise à jour est invalide. \(details)")
        case .notInstalled: String(localized: "Dictate ne tourne pas depuis un emplacement où il peut se mettre à jour.")
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

        /// `codesign` requirement language.
        var requirement: String {
            var clauses = ["identifier \"\(bundleIdentifier)\""]
            if let teamIdentifier {
                clauses.append("anchor apple generic")
                clauses.append("certificate leaf[subject.OU] = \"\(teamIdentifier)\"")
            }
            return clauses.joined(separator: " and ")
        }
    }

    /// Unzips `archive` and returns the single `.app` it contains.
    func extract(_ archive: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", archive.path, directory.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.extractionFailed }

        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appBundleNotFound
        }
        return app
    }

    /// Rejects anything that is not a validly signed Dictate from the same team.
    func verify(_ bundle: URL, against expectation: Expectation) throws {
        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--strict", "-R=\(expectation.requirement)", bundle.path]
        let errors = Pipe()
        codesign.standardError = errors
        codesign.standardOutput = errors
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UpdateError.signatureRejected(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Puts `replacement` where `current` is. The old bundle is restored if the move fails.
    func replace(_ current: URL, with replacement: URL) throws {
        let fileManager = FileManager.default
        let backup = current.deletingLastPathComponent().appending(path: ".\(current.lastPathComponent).previous")
        try? fileManager.removeItem(at: backup)
        try fileManager.moveItem(at: current, to: backup)
        do {
            try fileManager.moveItem(at: replacement, to: current)
        } catch {
            do {
                try fileManager.moveItem(at: backup, to: current)
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
