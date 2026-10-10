import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusLine)
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
        Toggle("Amélioration par Claude", isOn: Bindable(model.settings).enhancementEnabled)
            .onChange(of: model.settings.enhancementEnabled) { model.settingsChanged() }
        Button("Réglages…") { open { openSettings() } }
            .keyboardShortcut(",")
        Divider()
        Button("Quitter Dictate") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch model.transcriber.state {
        case .notLoaded, .loading: "Chargement de Whisper…"
        case .downloading(let fraction): "Téléchargement de Whisper… \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .failed(let message): "Whisper indisponible : \(message)"
        case .ready: model.hotkeyActive ? "Prêt — maintenez fn pour dicter" : "Touche fn inactive"
        }
    }

    /// An accessory app must be activated for its windows to come forward.
    private func open(_ action: () -> Void) {
        NSApp.activate()
        action()
    }
}
