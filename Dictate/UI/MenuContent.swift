import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        updateItem
        if let statusLine {
            Text(statusLine)
        }
        if let error = model.lastError {
            Text(error)
        }
        if !model.setup.isComplete {
            Button("Terminer la configuration…") { open { openWindow(id: "setup") } }
        }
        Divider()
        Button("Statistiques…") { open { openWindow(id: "stats") } }
        if model.settings.suggestVocabulary {
            let suggestions = model.pendingVocabularySuggestions
            if !suggestions.isEmpty {
                Menu("Suggestions de vocabulaire (\(suggestions.count))") {
                    ForEach(suggestions) { suggestion in
                        Menu(suggestion.term) {
                            Text(suggestion.reasonDescription)
                            Button("Ajouter au lexique") { model.acceptVocabularySuggestion(suggestion) }
                            Button("Ignorer") { model.ignoreVocabularySuggestion(suggestion) }
                        }
                    }
                }
            }
        }
        if model.settings.keepEvaluationCorpus {
            Button("Évaluer le corpus (\(model.corpus.entries.count) dictées)…") { model.evaluateCorpus() }
                .disabled(model.corpus.entries.isEmpty)
        }
        Button("Réglages…") { open { openSettings() } }
            .keyboardShortcut(",")
        Divider()
        Button("Quitter Dictate") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The version, then the update to install or a way to look for one. The App Store
    /// installs its own updates, so there it only names the version.
    @ViewBuilder private var updateItem: some View {
        let updater = model.updater
        Text("Dictate \(updater.currentVersion)")
        if !Distribution.isAppStore {
            switch updater.state {
            case .checking:
                Text("Recherche d'une mise à jour…")
            case .downloading(let fraction):
                Text("Téléchargement de la mise à jour… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
            case .installing:
                Text("Installation de la mise à jour…")
            case .idle, .available, .failed:
                if let release = updater.available {
                    Button("Redémarrer pour installer la mise à jour \(release.version)") {
                        // A failure, or a copy that cannot replace itself, is explained in the window.
                        if updater.canInstall, !isFailed(updater.state) {
                            updater.install()
                        } else {
                            open { openWindow(id: "update") }
                        }
                    }
                } else {
                    // The update window shows the search, then the result: up to date or what is new.
                    Button("Rechercher une mise à jour…") {
                        open { openWindow(id: "update") }
                        Task { await updater.check() }
                    }
                }
            }
        }
    }

    private func isFailed(_ state: Updater.State) -> Bool {
        if case .failed = state { true } else { false }
    }

    /// Nothing to say while everything works: only problems and progress show.
    private var statusLine: String? {
        let engine = model.transcriber.engine.displayName
        return switch model.transcriber.state {
        case .notLoaded, .loading: String(localized: "Chargement de \(engine)…")
        case .downloading(let fraction): String(localized: "Téléchargement de \(engine)… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        case .failed(let message): String(localized: "\(engine) indisponible : \(message)")
        case .ready: model.hotkeyActive ? boosterStatusLine : String(localized: "Touche \(model.settings.pushToTalkKey.displayName) inactive")
        }
    }

    /// Only its download: the rest is in the settings, and dictation never waits for it.
    private var boosterStatusLine: String? {
        guard case .downloading(let fraction) = model.booster.state else { return nil }
        return String(localized: "Téléchargement du modèle de vocabulaire… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
    }

    /// An accessory app must be activated for its windows to come forward.
    private func open(_ action: () -> Void) {
        NSApp.activate()
        action()
    }
}
