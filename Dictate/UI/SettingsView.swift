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
                Text("Langue annoncée au moteur de transcription et à Claude. Les termes techniques anglais sont reconnus quelle que soit la langue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Moteur", selection: Bindable(model.settings).transcriptionEngine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.settings.transcriptionEngine) { model.transcriptionEngineChanged() }
                if !model.settings.transcriptionEngine.supports(language: model.settings.language) {
                    Text("Parakeet ne connaît pas le \(DictationLanguage.name(of: model.settings.language)) : choisissez Whisper pour cette langue.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Transcription")
            } footer: {
                Text(transcriptionFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Amélioration") {
                Toggle("Nettoyer le texte avec Claude (Haiku)", isOn: Bindable(model.settings).enhancementEnabled)
                    .onChange(of: model.settings.enhancementEnabled) { model.settingsChanged() }
                Toggle(isOn: Bindable(model.settings).shareFieldContext) {
                    Text("Envoyer à Claude le texte qui précède le curseur")
                    Text("Les 500 derniers caractères du champ, pour orthographier les noms comme vous et garder le ton. Jamais les mots de passe.")
                }
                .disabled(!model.settings.enhancementEnabled)
                claudeCLIRow
            }

            Section {
                TextEditor(text: Bindable(model.settings).vocabularyText)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .onChange(of: model.settings.vocabularyText) { model.settingsChanged() }
                // Shown as on when Claude is off: Whisper then always gets the vocabulary.
                // Parakeet has no prompt: shown as off.
                Toggle("Guider aussi Whisper avec ce vocabulaire", isOn: Binding(
                    get: {
                        model.settings.transcriptionEngine.acceptsVocabulary
                            && (model.settings.guideWhisperWithVocabulary || !model.settings.enhancementEnabled)
                    },
                    set: { model.settings.guideWhisperWithVocabulary = $0 }
                ))
                .disabled(!model.settings.enhancementEnabled || !model.settings.transcriptionEngine.acceptsVocabulary)
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

    private var transcriptionFooter: String {
        switch model.settings.transcriptionEngine {
        case .whisper:
            "Whisper large-v3 turbo : toutes les langues, guidé par votre vocabulaire. Environ 1,5 s par dictée sur un M1 Pro, 3,5 s avec le vocabulaire."
        case .parakeet:
            "Parakeet : plusieurs fois plus rapide, 25 langues européennes. Il ne lit pas le vocabulaire : Claude seul corrige votre jargon. Premier usage : téléchargement d'environ 610 Mo."
        }
    }

    /// Status, short path and actions of the `claude` CLI on a single row.
    private var claudeCLIRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                HStack {
                    Button("Tester") { Task { await model.testClaude() } }
                        .disabled(model.claudeCLIPath == nil)
                    Button("Choisir…", action: chooseClaudeCLI)
                }
            } label: {
                HStack(spacing: 8) {
                    claudeCLIStatusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(claudeCLITitle)
                        if let path = model.claudeCLIPath {
                            Text(model.claudeCLIDisplayPath(path))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path.path)
                        }
                    }
                }
            }
            if overrideIgnored {
                Text("Le fichier choisi n'est pas exécutable : détection automatique utilisée.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.settings.cliPathOverride.isEmpty {
                Button("Revenir à la détection automatique") {
                    model.settings.cliPathOverride = ""
                    model.settingsChanged()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if let result = model.claudeTestResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var claudeCLIStatusIcon: some View {
        if model.isProbingClaudeCLI {
            ProgressView().controlSize(.small)
        } else if model.claudeCLIVersion != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var claudeCLITitle: String {
        if model.claudeCLIPath == nil { return "CLI claude introuvable" }
        if let version = model.claudeCLIVersion { return "CLI claude \(version)" }
        return model.isProbingClaudeCLI ? "CLI claude" : "CLI claude : ne répond pas"
    }

    private var overrideIgnored: Bool {
        let override = model.settings.cliPathOverride
        return !override.isEmpty && model.claudeCLIPath?.path != override
    }

    private func chooseClaudeCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // The bundled CLI lives inside claude.app, and standalone installs in ~/.local.
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = model.claudeCLIPath?.deletingLastPathComponent()
        panel.message = "Choisissez l'exécutable claude"
        panel.prompt = "Choisir"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.cliPathOverride = url.path
        model.settingsChanged()
    }

    /// An accessory app must be activated for its windows to come forward.
    private func open(_ action: () -> Void) {
        NSApp.activate()
        action()
    }
}
