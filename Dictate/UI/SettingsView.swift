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
            LabeledContent("Touche :") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Touche", selection: Bindable(model.settings).pushToTalkKey) {
                        ForEach(PushToTalkKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: model.settings.pushToTalkKey) { model.pushToTalkKeyChanged() }
                    Hint(keyHint)
                }
            }

            LanguagePicker(model: model, label: "Langue :")

            LabeledContent("Moteur :") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.transcriber.engine.displayName)
                    Hint("25 langues européennes, sur cette machine. Ignore le lexique : seul Claude l'applique. 610 Mo à télécharger au premier usage.")
                    ModelWeights(model: model)
                    EngineStatus(model: model)
                }
            }

            LabeledContent("Évaluation :") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Garder les dictées pour mesurer la précision", isOn: Bindable(model.settings).keepEvaluationCorpus)
                    Hint("""
                        Conserve sur ce Mac l'audio, la transcription, le texte inséré et le contenu du champ \
                        \(PostInsertionObserver.defaultDelay.components.seconds) s plus tard, vos corrections comprises. \
                        Rien n'est envoyé.
                        """)
                    if !model.corpus.entries.isEmpty {
                        HStack {
                            Text("\(model.corpus.entries.count) dictées gardées")
                            Button("Supprimer…") { model.confirmAndDeleteCorpus() }
                        }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    private var keyHint: String {
        switch model.settings.pushToTalkKey {
        case .fn:
            "Maintenez 🌐 fn pour dicter. macOS doit la laisser libre : Clavier → « Appuyer sur la touche 🌐 pour » → « Ne rien faire »."
        case .control:
            "Maintenez l'une des touches control pour dicter. Un raccourci comme control-C n'enregistre rien."
        }
    }
}

/// Switching engines loads a model of several hundred MB: until it is in
/// memory, dictation is unavailable, and the user must know why.
private struct EngineStatus: View {
    let model: AppModel

    private var engine: String { model.transcriber.engine.displayName }

    var body: some View {
        Group {
            switch model.transcriber.state {
            case .notLoaded, .loading:
                status("Chargement de \(engine)… Dictate est indisponible en attendant.")
            case .downloading(let fraction):
                status("Téléchargement de \(engine)… \(fraction.formatted(.percent.precision(.fractionLength(0)))). Dictate est indisponible en attendant.")
            case .failed(let message):
                HStack(spacing: 8) {
                    Label("\(engine) indisponible : \(message)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Réessayer") { model.retryTranscriber() }
                        .controlSize(.small)
                }
                .font(.callout)
            case .ready:
                EmptyView()
            }
        }
        .animation(.snappy, value: model.transcriber.state)
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Which checkpoint the engine runs and, once downloaded, what it takes on disk.
private struct ModelWeights: View {
    let model: AppModel
    @State private var diskUsage: Int64?

    private var engine: TranscriptionEngine { model.transcriber.engine }

    var body: some View {
        Hint(description)
            // Measured again when the engine changes or its download completes.
            .task(id: "\(engine.rawValue)-\(model.transcriber.state == .ready)") {
                let folder = model.transcriber.modelFolder
                diskUsage = model.transcriber.isModelDownloaded
                    ? await Task.detached { ModelStorage.diskUsage(of: folder) }.value
                    : nil
            }
    }

    private var description: String {
        let weights = "Poids : \(engine.weightsName), \(engine.parameterCount) M de paramètres"
        guard let diskUsage else { return weights + "." }
        return weights + ", \(diskUsage.formatted(.byteCount(style: .file))) sur le disque."
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
                    Hint("Un par ligne : noms, outils, sigles. Claude les écrit exactement ainsi.")
                }
            }

            LabeledContent("Suggestions :") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Suggérer des mots pour le vocabulaire", isOn: Bindable(model.settings).suggestVocabulary)
                    Hint("""
                        Relit le champ \(PostInsertionObserver.defaultDelay.components.seconds) s après chaque dictée \
                        pour repérer les noms que vous corrigez, et compte ceux qui reviennent dans le texte déjà écrit \
                        (avec « Lire le texte autour du curseur »). Tout reste sur ce Mac.
                        """)
                    VocabularySuggestionList(model: model)
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }
}

/// The terms waiting for an answer, each with what brought it up.
private struct VocabularySuggestionList: View {
    let model: AppModel

    var body: some View {
        let suggestions = model.pendingVocabularySuggestions
        if !suggestions.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(suggestions) { suggestion in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.term)
                                Text(suggestion.reasonDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Ajouter") { model.acceptVocabularySuggestion(suggestion) }
                            Button("Ignorer") { model.ignoreVocabularySuggestion(suggestion) }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(height: min(CGFloat(suggestions.count) * 40, 160))
            .padding(.top, 4)
        }
    }
}

/// Launch at login, updates and the way out, on a single label.
private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            LabeledContent("Application :") {
                VStack(alignment: .leading, spacing: 8) {
                    LaunchAtLoginToggle(settings: model.settings)
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

            // Greyed out rather than removed under "Aucun", so that the window
            // keeps its height: it is sized to its content.
            Group {
                LabeledContent("Claude :") {
                    VStack(alignment: .leading, spacing: 6) {
                        Hint("Modèle Haiku, via votre compte Claude Code. Ponctuation, hésitations retirées, lexique appliqué.")
                        Toggle("Lire le texte autour du curseur", isOn: Bindable(model.settings).shareFieldContext)
                            .padding(.top, 4)
                        Hint("Texte du champ, titre de la fenêtre et domaine du site, pour reprendre vos noms et votre ton. Jamais un mot de passe.")
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
            .disabled(!model.settings.enhancementEnabled)
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
