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
                    Hint("25 langues européennes, sur cette machine. Le lexique est appliqué par la relecture, et par Parakeet si vous renforcez le vocabulaire (onglet Lexique). 610 Mo à télécharger au premier usage.")
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
            String(localized: "Maintenez 🌐 fn pour dicter. macOS doit la laisser libre : Clavier → « Appuyer sur la touche 🌐 pour » → « Ne rien faire ».")
        case .control:
            String(localized: "Maintenez l'une des touches control pour dicter. Un raccourci comme control-C n'enregistre rien.")
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

    private func status(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The boosting model downloads like the engine's, but dictation never waits
/// for it: until it is ready, transcripts go through as Parakeet heard them.
private struct BoosterStatus: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.booster.state {
            case .loading:
                status("Chargement du modèle de vocabulaire…")
            case .downloading(let fraction):
                status("Téléchargement du modèle de vocabulaire… \(fraction.formatted(.percent.precision(.fractionLength(0)))).")
            case .failed(let message):
                HStack(spacing: 8) {
                    Label("Modèle de vocabulaire indisponible : \(message)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Réessayer") { model.retryBooster() }
                        .controlSize(.small)
                }
                .font(.callout)
            case .notLoaded:
                if model.settings.vocabulary.isEmpty {
                    Hint("Sans effet tant que le lexique est vide.")
                }
            case .ready:
                EmptyView()
            }
        }
        .animation(.snappy, value: model.booster.state)
    }

    private func status(_ text: LocalizedStringKey) -> some View {
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
        guard let diskUsage else {
            return String(localized: "Poids : \(engine.weightsName), \(engine.parameterCount) M de paramètres.")
        }
        let size = diskUsage.formatted(.byteCount(style: .file))
        return String(localized: "Poids : \(engine.weightsName), \(engine.parameterCount) M de paramètres, \(size) sur le disque.")
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
                        .onChange(of: model.settings.vocabularyText) {
                            model.settingsChanged()
                            model.vocabularyBoostingChanged()
                        }
                    Hint("Un par ligne : noms, outils, sigles. La relecture les écrit exactement ainsi.")
                }
            }

            LabeledContent("Transcription :") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Renforcer le vocabulaire dans la transcription (expérimental)",
                        isOn: Bindable(model.settings).boostVocabulary
                    )
                    .onChange(of: model.settings.boostVocabulary) { model.vocabularyBoostingChanged() }
                    Hint("""
                        Un second modèle cherche ces termes dans l'audio et corrige la transcription avant Claude. \
                        Entraîné surtout sur l'anglais : son effet en français reste à mesurer. \
                        Environ 100 Mo à télécharger.
                        """)
                    if model.settings.boostVocabulary {
                        BoosterStatus(model: model)
                    }
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
                    if Distribution.isAppStore {
                        // The App Store installs the updates, and deleting the app removes its container.
                        Text("Version \(model.updater.currentVersion)")
                    } else {
                        selfDistributedControls
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    /// Updates and uninstall, for the copies downloaded from the website.
    @ViewBuilder private var selfDistributedControls: some View {
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

/// Who reviews a dictation. Only Claude is wired today; the others show
/// where this is going, and "Aucun" keeps the raw transcription.
/// The tiles of the reviewer picker: the reviewers Dictate has, and the
/// services it may get one day.
private enum ReviewerTile: String, CaseIterable, Identifiable {
    case none, apple, claude, chatGPT, gemini

    var id: String { rawValue }

    init(_ reviewer: Reviewer) {
        switch reviewer {
        case .none: self = .none
        case .apple: self = .apple
        case .claude: self = .claude
        }
    }

    /// Nil for the services that are not available yet.
    var reviewer: Reviewer? {
        switch self {
        case .none: Reviewer.none
        case .apple: .apple
        case .claude: .claude
        case .chatGPT, .gemini: nil
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .none: "Aucun"
        case .apple: "Apple"
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .gemini: "Gemini"
        }
    }

    /// Stand-ins until each service ships a logo we may embed.
    var symbol: String {
        switch self {
        case .none: "nosign"
        case .apple: "apple.intelligence"
        case .claude: "sparkles"
        case .chatGPT: "bubble.left.and.text.bubble.right"
        case .gemini: "star.circle"
        }
    }

    var isAvailable: Bool { reviewer != nil }
}

/// The pass that turns the raw transcription into clean text.
private struct ReviewSettings: View {
    @Bindable var model: AppModel

    private var reviewer: Binding<ReviewerTile> {
        Binding(
            get: { ReviewerTile(model.settings.reviewer) },
            set: { if let reviewer = $0.reviewer { model.selectReviewer(reviewer) } }
        )
    }

    var body: some View {
        Form {
            LabeledContent("Relecture par :") {
                VStack(alignment: .leading, spacing: 6) {
                    ReviewerPicker(selection: reviewer)
                    Hint(reviewerHint)
                }
            }

            // Greyed out rather than removed under "Aucun", so that the window
            // keeps its height: it is sized to its content.
            Group {
                LabeledContent("Contexte :") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Lire le texte autour du curseur", isOn: Bindable(model.settings).shareFieldContext)
                        Hint("Texte du champ, titre de la fenêtre et domaine du site, pour reprendre vos noms et votre ton. Jamais un mot de passe.")
                    }
                }

                Divider()

                if model.settings.reviewer == .apple || Distribution.isAppStore {
                    appleStatus
                } else {
                    claudeBinary
                }
            }
            .disabled(!model.settings.enhancementEnabled)
        }
        .formStyle(.columns)
        .padding(20)
    }

    private var reviewerHint: String {
        let hint = switch model.settings.reviewer {
        case .none:
            String(localized: "Le texte transcrit est inséré tel quel, hésitations comprises.")
        case .apple:
            String(localized: "Le modèle d'Apple Intelligence, sur ce Mac. Rien ne sort de l'ordinateur, aucun compte nécessaire.")
        case .claude:
            String(localized: "Modèle Haiku, via votre compte Claude Code. Un peu plus rapide et plus sûr sur le jargon.")
        }
        guard !model.settings.reviewerIsChosen, !Distribution.isAppStore else { return hint }
        return String(localized: "Choix automatique : Claude si sa commande est installée, sinon Apple Intelligence, sinon aucun.") + " " + hint
    }

    private var appleStatus: some View {
        LabeledContent("Modèle :") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if model.appleIntelligence.isAvailable {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Apple Intelligence prêt")
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Apple Intelligence indisponible")
                    }
                    Spacer()
                    Button("Tester") { Task { await model.testReviewer() } }
                        .disabled(!model.appleIntelligence.isAvailable)
                }
                if let explanation = model.appleIntelligence.explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Ouvrir les Réglages") { Permissions.openAppleIntelligenceSettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if let result = model.reviewTestResult {
                    Hint(result)
                }
            }
        }
    }

    private var claudeBinary: some View {
        LabeledContent("Binaire :") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    claudeCLIStatusIcon
                    Text(claudeCLITitle)
                    Spacer()
                    Button("Tester") { Task { await model.testReviewer() } }
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
                if let result = model.reviewTestResult {
                    Hint(result)
                }
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
        if model.claudeCLIPath == nil { return String(localized: "claude introuvable") }
        if let version = model.claudeCLIVersion { return "claude \(version)" }
        return model.isProbingClaudeCLI ? "claude" : String(localized: "claude ne répond pas")
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
        panel.message = String(localized: "Choisissez l'exécutable claude")
        panel.prompt = String(localized: "Choisir")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.cliPathOverride = url.path
        model.settingsChanged()
    }
}

/// A row of icon tiles, like the appearance picker in System Settings.
private struct ReviewerPicker: View {
    @Binding var selection: ReviewerTile

    var body: some View {
        HStack(spacing: 12) {
            ForEach(ReviewerTile.allCases.filter { $0 != .claude || !Distribution.isAppStore }) { reviewer in
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
                .help(reviewer.isAvailable ? Text(verbatim: "") : Text("Bientôt"))
            }
        }
    }
}

/// The small grey explanation under a control.
private struct Hint: View {
    let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }

    /// Already localized, or not meant to be: a path, a test result.
    @_disfavoredOverload
    init(_ string: String) { text = Text(verbatim: string) }

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
