import SwiftUI

/// First-launch checklist: permissions, fn key, Whisper model, Claude CLI.
struct SetupView: View {
    let model: AppModel
    @State private var refresh = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configuration de Dictate").font(.title2.bold())
            Text("Maintenez fn pour dicter, relâchez pour insérer le texte.")
                .foregroundStyle(.secondary)

            row("Micro", ok: Permissions.microphone, action: "Autoriser") {
                Task { _ = await Permissions.requestMicrophone() }
            }
            row("Surveillance de l'entrée (touche fn)", ok: Permissions.inputMonitoring, action: "Autoriser") {
                Permissions.requestInputMonitoring()
                Permissions.openPrivacySettings("Privacy_ListenEvent")
            }
            row("Accessibilité (insertion du texte)", ok: Permissions.accessibility, action: "Autoriser") {
                Permissions.requestAccessibility()
            }
            row("Touche 🌐 réglée sur « Ne rien faire »", ok: Permissions.fnKeyFree, action: "Réglages Clavier") {
                Permissions.openKeyboardSettings()
            }
            row("Modèle Whisper (~630 Mo au premier lancement)", ok: model.transcriber.state == .ready, action: nil) {}
            row("CLI claude", ok: model.claudeCLIPath != nil, action: "Revérifier") {
                model.refreshClaudeCLI()
            }
        }
        .padding(24)
        .frame(width: 520)
        .id(refresh)
        .onReceive(timer) { _ in refresh += 1 }
    }

    private func row(_ title: String, ok: Bool, action: String?, perform: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
            Text(title)
            Spacer()
            if !ok, let action {
                Button(action, action: perform)
            }
        }
    }
}
