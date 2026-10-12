import SwiftUI

/// Classic macOS preferences: icon tabs in the toolbar, labels in the left
/// column. The app itself, then the two halves of a dictation: the
/// transcription and the review pass.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("Général", systemImage: "gearshape") {
                GeneralSettings(model: model)
            }
            Tab("Dictée", systemImage: "mic") {
                DictationSettings(model: model)
            }
            Tab("Relecture", systemImage: "sparkles") {
                ReviewSettings(model: model)
            }
        }
        .frame(width: 560)
    }
}

/// Language, then engine and lexicon together: everything that shapes the raw transcription.
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

                    TextEditor(text: Bindable(model.settings).vocabularyText)
                        .font(.body.monospaced())
                        .frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        .padding(.top, 8)
                        .onChange(of: model.settings.vocabularyText) { model.settingsChanged() }
                    Hint("Lexique, un terme par ligne : noms, outils, sigles. Claude les écrit exactement ainsi, quel que soit le moteur.")
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

/// Launch at login, updates and the way out, on a single label.
private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            LabeledContent("Application :") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Ouvrir à l'ouverture de session", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) {
                            model.settings.launchAtLogin = launchAtLogin
                            // Registration can be refused: show what macOS actually did.
                            launchAtLogin = model.settings.launchAtLogin
                        }
                    Toggle("Installer les mises à jour automatiquement", isOn: Bindable(model.settings).autoUpdate)
                    HStack {
                        Text("Version \(model.updater.currentVersion)")
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
                            Hint("À jour, vérifié \(lastCheck.formatted(.relative(presentation: .named)))")
                        }
                    }
                    Button("Désinstaller Dictate…") { Uninstaller().confirmAndRun() }
                        .padding(.top, 8)
                    Hint("Met l'application, les modèles et les statistiques à la Corbeille, efface les réglages.")
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .onAppear { launchAtLogin = model.settings.launchAtLogin }
    }
}

/// The models that could review a dictation. Only Claude is wired today;
/// the others show where this is going.
private enum Reviewer: String, CaseIterable, Identifiable {
    case claude, chatGPT, gemini, local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude (Haiku)"
        case .chatGPT: "ChatGPT"
        case .gemini: "Gemini"
        case .local: "Modèle local"
        }
    }

    var isAvailable: Bool { self == .claude }
}

/// The pass that turns the raw transcription into clean text.
private struct ReviewSettings: View {
    @Bindable var model: AppModel
    @State private var reviewer = Reviewer.claude

    var body: some View {
        Form {
            LabeledContent("Modèle :") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Modèle", selection: $reviewer) {
                        ForEach(Reviewer.allCases) { reviewer in
                            Text(reviewer.displayName).tag(reviewer).disabled(!reviewer.isAvailable)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Hint("Via votre compte Claude Code.")
                }
            }

            LabeledContent("Relecture :") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Relire chaque dictée", isOn: Bindable(model.settings).enhancementEnabled)
                        .onChange(of: model.settings.enhancementEnabled) { model.settingsChanged() }
                    Hint("Ponctuation, hésitations retirées, lexique appliqué.")
                    Toggle("Lire le texte avant le curseur", isOn: Bindable(model.settings).shareFieldContext)
                        .disabled(!model.settings.enhancementEnabled)
                    Hint("500 caractères, pour reprendre vos noms et votre ton. Jamais un mot de passe.")
                }
            }

            Divider()

            LabeledContent("Binaire :") {
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
                        Text("Fichier non exécutable : détection automatique utilisée.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !model.settings.cliPathOverride.isEmpty {
                        Button("Détection automatique") {
                            model.settings.cliPathOverride = ""
                            model.settingsChanged()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    if let result = model.claudeTestResult {
                        Hint(result)
                    }
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
        if model.claudeCLIPath == nil { return "claude introuvable" }
        if let version = model.claudeCLIVersion { return "claude \(version)" }
        return model.isProbingClaudeCLI ? "claude" : "claude ne répond pas"
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
