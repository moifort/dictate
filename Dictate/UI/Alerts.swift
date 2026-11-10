import AppKit

/// The modal questions and reports, kept with the interface rather than in
/// the model: the model does the work, these ask and show.
enum Alerts {
    /// Developer tool: word error rates over the corpus, logged and shown.
    static func showEvaluation(of corpus: EvaluationCorpus) {
        let evaluation = CorpusEvaluation(entries: corpus.entries)
        Log.app.info("corpus evaluation:\n\(evaluation.summary, privacy: .public)")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Taux d'erreur sur le corpus")
        let seconds = PostInsertionObserver.defaultDelay.components.seconds
        alert.informativeText = evaluation.summary + "\n\n" + String(localized: """
            Référence : le texte laissé dans le champ \(seconds) s \
            après l'insertion. Une erreur non corrigée compte comme juste : ces taux sont des minimums.
            """)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: String(localized: "Afficher dans le Finder"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([corpus.folder])
        }
    }

    /// Asks first: the recordings cannot be brought back.
    static func confirmDeletion(of corpus: EvaluationCorpus) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Supprimer le corpus d'évaluation ?")
        alert.informativeText = String(localized: "Les \(corpus.entries.count) enregistrements et leurs textes seront effacés de ce Mac.")
        alert.addButton(withTitle: String(localized: "Supprimer")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Annuler"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        corpus.deleteAll()
    }

    /// Asks first, then cleans up and quits.
    static func confirmUninstall(_ uninstaller: Uninstaller = Uninstaller()) {
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
        Task { await uninstaller.run() }
    }
}
