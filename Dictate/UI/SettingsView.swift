import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Amélioration") {
                Toggle("Nettoyer le texte avec Claude (Haiku)", isOn: Bindable(model.settings).enhancementEnabled)
                LabeledContent("CLI claude") {
                    Text(model.claudeCLIPath?.path ?? "Introuvable")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                TextField("Chemin personnalisé (optionnel)", text: Bindable(model.settings).cliPathOverride)
                    .onSubmit { model.settingsChanged() }
                HStack {
                    Button("Tester") { Task { await model.testClaude() } }
                    if let result = model.claudeTestResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextEditor(text: Bindable(model.settings).vocabularyText)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .onChange(of: model.settings.vocabularyText) { model.settingsChanged() }
            } header: {
                Text("Vocabulaire")
            } footer: {
                Text("Un terme par ligne. Utilisé par Whisper et par Claude pour orthographier correctement votre jargon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Général") {
                Toggle("Lancer Dictate à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { model.settings.launchAtLogin = launchAtLogin }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { launchAtLogin = model.settings.launchAtLogin }
    }
}
