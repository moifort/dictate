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
        if !Permissions.allGranted || !model.hotkeyActive || !Permissions.fnKeyFree {
            Button("Terminer la configuration…") { open { openWindow(id: "setup") } }
        }
        Divider()
        Toggle("Amélioration par Claude", isOn: Bindable(model.settings).enhancementEnabled)
        Button("Réglages…") { open { openSettings() } }
            .keyboardShortcut(",")
        Divider()
        Button("Quitter Dictate") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch model.transcriber.state {
        case .notLoaded, .loading: "Chargement de Whisper…"
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
