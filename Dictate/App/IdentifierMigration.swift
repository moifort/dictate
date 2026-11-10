import Foundation

/// Brings over what Dictate left under its other release identifier: the
/// settings, the API keys, the statistics, the evaluation corpus and the
/// vocabulary suggestions. Dictate ships as `com.thibautmottet.dictate` and
/// `com.polyforms.dictate`; when a copy runs under one and finds nothing of
/// its own but data under the other, the user's history follows it.
///
/// Copies, never moves: the other copy may still be installed. Runs before
/// the settings are read, and only for a release identifier: a Debug build
/// keeps its data apart on purpose. The App Store build's sandbox hides the
/// other copy's files, so there it finds nothing and does nothing.
nonisolated struct IdentifierMigration {
    let current: String
    /// The identifiers that migrate: the releases, never a Debug build's.
    let releases: [String]
    let others: [String]
    let library: URL
    /// Gives access to every app's defaults domain.
    let defaults: UserDefaults
    /// The keychain item holding `provider`'s key for `identifier`.
    let secret: (_ identifier: String, _ provider: APIProvider) -> SecretStore

    init(
        current: String = AppIdentity.current,
        releases: [String] = AppIdentity.releases,
        others: [String]? = nil,
        library: URL = .libraryDirectory,
        defaults: UserDefaults = .standard,
        secret: @escaping (_ identifier: String, _ provider: APIProvider) -> SecretStore = { identifier, provider in
            MovingSecret(
                to: KeychainSecret(service: KeychainSecret.service(for: identifier), account: provider.keychainAccount),
                from: KeychainSecret(service: KeychainSecret.legacyService(for: identifier), account: provider.keychainAccount)
            )
        }
    ) {
        self.current = current
        self.releases = releases
        self.others = others ?? releases.filter { $0 != current }
        self.library = library
        self.defaults = defaults
        self.secret = secret
    }

    /// What was brought over, for the log.
    @discardableResult
    func run() -> [String] {
        guard releases.contains(current) else { return [] }
        var migrated: [String] = []
        for other in others {
            if migrateDefaults(from: other) { migrated.append("settings from \(other)") }
            migrated += migrateKeys(from: other).map { "\($0.rawValue) key from \(other)" }
            migrated += migrateFiles(from: other).map { "\($0) from \(other)" }
        }
        return migrated
    }

    /// The whole defaults domain, when this copy has none yet.
    private func migrateDefaults(from other: String) -> Bool {
        guard defaults.persistentDomain(forName: current)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: other), !old.isEmpty else { return false }
        defaults.setPersistentDomain(old, forName: current)
        return true
    }

    /// Each key this copy lacks.
    private func migrateKeys(from other: String) -> [APIProvider] {
        APIProvider.allCases.filter { provider in
            let mine = secret(current, provider), theirs = secret(other, provider)
            guard (try? mine.read()) == .some(nil),
                  let key = try? theirs.read(), !key.isEmpty,
                  (try? mine.write(key)) != nil else { return false }
            return true
        }
    }

    /// The statistics, the corpus and the suggestions, each when this copy has none.
    private func migrateFiles(from other: String) -> [String] {
        let mine = AppPaths(identifier: current, library: library)
        let theirs = AppPaths(identifier: other, library: library)
        let items: [(String, URL, URL)] = [
            ("statistics", theirs.statistics, mine.statistics),
            ("corpus", theirs.corpus, mine.corpus),
            ("vocabulary suggestions", theirs.vocabularySuggestions, mine.vocabularySuggestions),
        ]
        let fileManager = FileManager.default
        return items.compactMap { name, source, destination in
            guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else { return nil }
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                return name
            } catch {
                ErrorReporter.capture(error, "\(name) could not be brought over from \(other)", category: "migration", level: .warning)
                return nil
            }
        }
    }
}
