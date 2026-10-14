import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Dictate \(model.updater.currentVersion)")
        if let statusLine {
            Text(statusLine)
        }
        if let error = model.lastError {
            Text(error)
        }
        if !model.setup.isComplete {
            Button("Terminer la configuration…") { open { openWindow(id: "setup") } }
        }
        if let release = model.updater.available {
            Button("Mettre à jour vers \(release.version)…") { open { openWindow(id: "update") } }
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

    /// Nothing to say while everything works: only problems and progress show.
    private var statusLine: String? {
        let engine = model.transcriber.engine.displayName
        return switch model.transcriber.state {
        case .notLoaded, .loading: "Chargement de \(engine)…"
        case .downloading(let fraction): "Téléchargement de \(engine)… \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .failed(let message): "\(engine) indisponible : \(message)"
        case .ready: model.hotkeyActive ? boosterStatusLine : "Touche \(model.settings.pushToTalkKey.displayName) inactive"
        }
    }

    /// Only its download: the rest is in the settings, and dictation never waits for it.
    private var boosterStatusLine: String? {
        guard case .downloading(let fraction) = model.booster.state else { return nil }
        return "Téléchargement du modèle de vocabulaire… \(fraction.formatted(.percent.precision(.fractionLength(0))))"
    }

    /// An accessory app must be activated for its windows to come forward.
    private func open(_ action: () -> Void) {
        NSApp.activate()
        action()
    }
}
