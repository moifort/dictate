import SwiftUI

/// Classic macOS preferences: icon tabs in the toolbar, labels in the left
/// column. The app itself, then the stages of a dictation: transcription,
/// the words it must get right, the review pass.
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
            Tab("Lexique", systemImage: "character.book.closed") {
                LexiconSettings(model: model)
            }
            Tab("Relecture", systemImage: "sparkles") {
                ReviewSettings(model: model)
            }
        }
        .frame(width: 560)
    }
}

/// Language and engine: what turns speech into raw text.
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
}

/// The terms every dictation must spell right.
private struct LexiconSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Termes :") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: Bindable(model.settings).vocabularyText)
                        .font(.body.monospaced())
                        .frame(height: 220)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        .onChange(of: model.settings.vocabularyText) { model.settingsChanged() }
                    Hint("Un par ligne : noms, outils, sigles. Claude les écrit exactement ainsi, quel que soit le moteur.")
                }
            }

            if model.settings.transcriptionEngine.acceptsVocabulary {
                LabeledContent("Whisper :") {
                    VStack(alignment: .leading, spacing: 6) {
                        // Shown as on when Claude is off: Whisper then always gets the lexicon.
                        Toggle("Guider aussi Whisper avec ces termes", isOn: Binding(
                            get: { model.settings.guideWhisperWithVocabulary || !model.settings.enhancementEnabled },
                            set: { model.settings.guideWhisperWithVocabulary = $0 }
                        ))
                        .disabled(!model.settings.enhancementEnabled)
                        Hint(whisperHint)
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    private var whisperHint: String {
        if !model.settings.enhancementEnabled {
            return "Toujours actif sans relecture : Whisper est alors seul à connaître votre jargon."
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

/// Who reviews a dictation. Only Claude is wired today; the others show
/// where this is going, and "Aucun" keeps the raw transcription.
private enum Reviewer: String, CaseIterable, Identifiable {
    case none, claude, chatGPT, gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Aucun"
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .gemini: "Gemini"
        }
    }

    /// Stand-ins until each service ships a logo we may embed.
    var symbol: String {
        switch self {
        case .none: "nosign"
        case .claude: "sparkles"
        case .chatGPT: "bubble.left.and.text.bubble.right"
        case .gemini: "star.circle"
        }
    }

    var isAvailable: Bool { self == .none || self == .claude }
}

/// The pass that turns the raw transcription into clean text.
private struct ReviewSettings: View {
    @Bindable var model: AppModel

    /// "Aucun" is the enhancement switch under another name.
    private var reviewer: Binding<Reviewer> {
        Binding(
            get: { model.settings.enhancementEnabled ? .claude : .none },
            set: {
                model.settings.enhancementEnabled = $0 == .claude
                model.settingsChanged()
            }
        )
    }

    var body: some View {
        Form {
            LabeledContent("Relecture par :") {
                ReviewerPicker(selection: reviewer)
            }

            if model.settings.enhancementEnabled {
                LabeledContent("Claude :") {
                    VStack(alignment: .leading, spacing: 6) {
                        Hint("Modèle Haiku, via votre compte Claude Code. Ponctuation, hésitations retirées, lexique appliqué.")
                        Toggle("Lire le texte avant le curseur", isOn: Bindable(model.settings).shareFieldContext)
                            .padding(.top, 4)
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

/// A row of icon tiles, like the appearance picker in System Settings.
private struct ReviewerPicker: View {
    @Binding var selection: Reviewer

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Reviewer.allCases) { reviewer in
                Button {
                    selection = reviewer
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: reviewer.symbol)
                            .font(.system(size: 22))
                            .frame(width: 56, height: 40)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selection == reviewer ? Color.accentColor : .clear, lineWidth: 2)
                            }
                        Text(reviewer.displayName)
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!reviewer.isAvailable)
                .help(reviewer.isAvailable ? "" : "Bientôt")
            }
        }
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
