import SwiftUI

/// Classic macOS preferences: icon tabs in the toolbar, labels in the left
/// column. From what every user touches to what most never will: the
/// dictation itself, the Claude pass, then the app's housekeeping.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("Dictée", systemImage: "mic") {
                DictationSettings(model: model)
            }
            Tab("Claude", systemImage: "sparkles") {
                ClaudeSettings(model: model)
            }
            Tab("Général", systemImage: "gearshape") {
                GeneralSettings(model: model)
            }
        }
        .frame(width: 560)
    }
}

/// Language, engine and lexicon: everything that shapes the raw transcription.
private struct DictationSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            LanguagePicker(model: model, label: "Langue :")

            LabeledContent("Moteur :") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Moteur", selection: Bindable(model.settings).transcriptionEngine) {
                        ForEach(TranscriptionEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: model.settings.transcriptionEngine) { model.transcriptionEngineChanged() }
                    Hint(engineHint)
                    if !model.settings.transcriptionEngine.supports(language: model.settings.language) {
                        Label(
                            "Parakeet ne gère pas le \(DictationLanguage.name(of: model.settings.language)) : choisissez Whisper.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Divider()

            LabeledContent("Lexique :") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: Bindable(model.settings).vocabularyText)
                        .font(.body.monospaced())
                        .frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        .onChange(of: model.settings.vocabularyText) { model.settingsChanged() }
                    Hint("Un terme par ligne : noms, outils, sigles. Claude les écrit exactement ainsi, quel que soit le moteur.")
                    if model.settings.transcriptionEngine.acceptsVocabulary {
                        // Shown as on when Claude is off: Whisper then always gets the lexicon.
                        Toggle("Le donner aussi à Whisper", isOn: Binding(
                            get: { model.settings.guideWhisperWithVocabulary || !model.settings.enhancementEnabled },
                            set: { model.settings.guideWhisperWithVocabulary = $0 }
                        ))
                        .disabled(!model.settings.enhancementEnabled)
                        Hint(whisperLexiconHint)
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    private var engineHint: String {
        switch model.settings.transcriptionEngine {
        case .whisper:
            "Toutes les langues, environ 1,5 s par dictée."
        case .parakeet:
            "Plusieurs fois plus rapide, 25 langues européennes. Ignore le lexique : seul Claude l'applique. 610 Mo à télécharger au premier usage."
        }
    }

    private var whisperLexiconHint: String {
        if !model.settings.enhancementEnabled {
            return "Toujours actif tant que Claude est désactivé : Whisper est alors seul à connaître votre jargon."
        }
        return "Plus précis sur le jargon, mais environ 2 s de plus par dictée."
    }
}

/// The pass that turns the raw transcription into clean text.
private struct ClaudeSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Relecture :") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Relire le texte avec Claude", isOn: Bindable(model.settings).enhancementEnabled)
                        .onChange(of: model.settings.enhancementEnabled) { model.settingsChanged() }
                    Hint("Ponctuation, hésitations retirées, lexique appliqué. Passe par votre compte Claude Code, avec le modèle Haiku.")
                    Toggle("Lui montrer ce qui précède le curseur", isOn: Bindable(model.settings).shareFieldContext)
                        .disabled(!model.settings.enhancementEnabled)
                    Hint("Les 500 derniers caractères du champ, pour reprendre vos noms et votre ton. Jamais dans un champ de mot de passe.")
                }
            }

            Divider()

            LabeledContent("Programme claude :") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        claudeCLIStatusIcon
                        Text(claudeCLITitle)
                        Spacer()
                        Button("Tester") { Task { await model.testClaude() } }
                            .disabled(model.claudeCLIPath == nil)
                        Button("Choisir…", action: chooseClaudeCLI)
                    }
                    if let path = model.claudeCLIPath {
                        Text(model.claudeCLIDisplayPath(path))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path.path)
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
                    Hint("Détecté dans l'application Claude ou dans votre installation de Claude Code.")
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
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
        if model.claudeCLIPath == nil { return "Introuvable" }
        if let version = model.claudeCLIVersion { return "Version \(version)" }
        return model.isProbingClaudeCLI ? "Vérification…" : "Ne répond pas"
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
}

/// Launch at login, updates and the way out.
private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            LabeledContent("Démarrage :") {
                Toggle("Ouvrir Dictate à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        model.settings.launchAtLogin = launchAtLogin
                        // Registration can be refused: show what macOS actually did.
                        launchAtLogin = model.settings.launchAtLogin
                    }
            }

            Divider()

            LabeledContent("Mises à jour :") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Installer les nouvelles versions automatiquement", isOn: Bindable(model.settings).autoUpdate)
                    Hint("Vérifiées au lancement, puis toutes les six heures.")
                }
            }

            LabeledContent("Version \(model.updater.currentVersion) :") {
                HStack {
                    if let release = model.updater.available {
                        Button("Installer \(release.version)…") {
                            NSApp.activate()
                            openWindow(id: "update")
                        }
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

            Divider()

            LabeledContent("Désinstallation :") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Désinstaller Dictate…") { Uninstaller().confirmAndRun() }
                    Hint("Place l'application, les modèles et les statistiques dans la Corbeille, efface les réglages et quitte.")
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .onAppear { launchAtLogin = model.settings.launchAtLogin }
    }
}

/// The small grey explanation under a control.
private struct Hint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
