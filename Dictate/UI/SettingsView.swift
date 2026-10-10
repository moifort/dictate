import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                LanguagePicker(model: model)
            } header: {
                Text("Langue")
            } footer: {
                Text("Langue annoncée à Whisper et à Claude. Les termes techniques anglais sont reconnus quelle que soit la langue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Amélioration") {
                Toggle("Nettoyer le texte avec Claude (Haiku)", isOn: Bindable(model.settings).enhancementEnabled)
                    .onChange(of: model.settings.enhancementEnabled) { model.settingsChanged() }
                LabeledContent("CLI claude") {
                    Text(model.claudeCLIPath?.path ?? "Introuvable")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                TextField("Chemin personnalisé (optionnel)", text: Bindable(model.settings).cliPathOverride)
                    .onChange(of: model.settings.cliPathOverride) { model.settingsChanged() }
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
                // Shown as on when Claude is off: Whisper then always gets the vocabulary.
                Toggle("Guider aussi Whisper avec ce vocabulaire", isOn: Binding(
                    get: { model.settings.guideWhisperWithVocabulary || !model.settings.enhancementEnabled },
                    set: { model.settings.guideWhisperWithVocabulary = $0 }
                ))
                .disabled(!model.settings.enhancementEnabled)
            } header: {
                Text("Vocabulaire")
            } footer: {
                Text("""
                    Un terme par ligne, utilisé par Claude pour orthographier correctement votre jargon. \
                    Le donner aussi à Whisper le rend plus précis mais ajoute environ 2 s par dictée ; \
                    c'est toujours le cas quand Claude est désactivé.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mises à jour") {
                Toggle("Installer les mises à jour automatiquement", isOn: Bindable(model.settings).autoUpdate)
                LabeledContent("Version \(model.updater.currentVersion)") {
                    HStack {
                        if let release = model.updater.available {
                            Button("Installer \(release.version)") { open { openWindow(id: "update") } }
                        } else {
                            Button("Rechercher") { Task { await model.updater.check() } }
                                .disabled(model.updater.isBusy)
                        }
                        if model.updater.state == .checking {
                            ProgressView().controlSize(.small)
                        } else if let lastCheck = model.updater.lastCheck, model.updater.available == nil {
                            Text("À jour, vérifié \(lastCheck.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Général") {
                Toggle("Lancer Dictate à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        model.settings.launchAtLogin = launchAtLogin
                        // Registration can be refused: show what macOS actually did.
                        launchAtLogin = model.settings.launchAtLogin
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { launchAtLogin = model.settings.launchAtLogin }
    }

    /// An accessory app must be activated for its windows to come forward.
    private func open(_ action: () -> Void) {
        NSApp.activate()
        action()
    }
}
