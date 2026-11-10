import SwiftUI
import UniformTypeIdentifiers
import DictateKit

/// Classic macOS preferences: icon tabs in the toolbar, labels in the left
/// column. The app itself, then the stages of a dictation: transcription,
/// the words it must get right, the review pass.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var tab = ScreenshotMode.settingsTab ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Général", systemImage: "gearshape", value: "general") {
                GeneralSettings(model: model)
            }
            Tab("Dictée", systemImage: "mic", value: "dictation") {
                DictationSettings(model: model)
            }
            Tab("Lexique", systemImage: "character.book.closed", value: "lexicon") {
                LexiconSettings(model: model)
            }
            Tab("Relecture", systemImage: "sparkles", value: "review") {
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
                    if PushToTalkKey.available.count > 1 {
                        Picker("Touche", selection: Bindable(model.settings).pushToTalkKey) {
                            ForEach(PushToTalkKey.available) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .onChange(of: model.settings.pushToTalkKey) { model.pushToTalkKeyChanged() }
                    } else {
                        Text(model.settings.pushToTalkKey.displayName)
                    }
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

            // The App Store build never pastes, so it has nothing to send.
            if !Distribution.isAppStore {
                LabeledContent("Envoi :") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Appuyer sur Entrée après la dictée", isOn: Bindable(model.settings).autoSendEnabled)
                        Hint("Envoie le message une fois le texte collé, seulement dans ces apps :")
                        AutoSendAppList(settings: model.settings)
                            .disabled(!model.settings.autoSendEnabled)
                    }
                }
            }

            // The corpus reads the field back, which the App Store build cannot do.
            if !Distribution.isAppStore {
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
        case .optionSpace:
            String(localized: "Maintenez option + espace pour dicter, puis collez le texte avec ⌘V. Sur un clavier français, option + espace tape aussi l'espace insécable : préférez alors control + option + espace.")
        case .controlOptionSpace:
            String(localized: "Maintenez control + option + espace pour dicter, puis collez le texte avec ⌘V.")
        }
    }
}

/// The apps where Return follows the paste: each with its icon and a way
/// out, then a menu of the apps open right now, or any app on disk.
private struct AutoSendAppList: View {
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.autoSendBundleIDs.isEmpty {
                Hint("Aucune app : Entrée n'est jamais pressée.")
            }
            ForEach(settings.autoSendBundleIDs, id: \.self) { bundleID in
                let app = AppInfo(bundleID: bundleID)
                HStack(spacing: 6) {
                    AppIcon(image: app.icon)
                    Text(verbatim: app.name)
                    Spacer()
                    Button {
                        settings.removeAutoSendApp(bundleID)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Retirer \(app.name)")
                }
                .frame(maxWidth: 260)
            }
            Menu("Ajouter une app") {
                ForEach(runningApps, id: \.bundleID) { app in
                    Button {
                        settings.addAutoSendApp(app.bundleID)
                    } label: {
                        Label { Text(verbatim: app.name) } icon: { Image(nsImage: app.icon ?? NSImage()) }
                    }
                }
                if !runningApps.isEmpty { Divider() }
                Button("Autre…") { chooseApp() }
            }
            .fixedSize()
        }
    }

    /// The apps with a window open, minus Dictate and those already listed.
    private var runningApps: [AppInfo] {
        let listed = Set(settings.autoSendBundleIDs)
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != Bundle.main.bundleIdentifier && !listed.contains($0) }
        return Set(ids).map(AppInfo.init(bundleID:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.message = String(localized: "Choisissez une app où appuyer sur Entrée après la dictée")
        panel.prompt = String(localized: "Ajouter")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        settings.addAutoSendApp(bundleID)
    }
}

/// An app's name and icon from its bundle ID, or the ID alone once uninstalled.
private struct AppInfo {
    let bundleID: String
    let name: String
    let icon: NSImage?

    init(bundleID: String) {
        self.bundleID = bundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            name = bundleID
            icon = nil
            return
        }
        let displayName = FileManager.default.displayName(atPath: url.path)
        name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        icon = image
    }
}

private struct AppIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
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
                        Un second modèle cherche ces termes dans l'audio et corrige la transcription avant la relecture. \
                        Entraîné surtout sur l'anglais : son effet en français reste à mesurer. \
                        Environ 100 Mo à télécharger.
                        """)
                    if model.settings.boostVocabulary {
                        BoosterStatus(model: model)
                    }
                }
            }

            // Suggestions come from reading the field back, as for the corpus.
            if !Distribution.isAppStore {
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

/// Who reviews a dictation: one tile per reviewer, "Aucun" keeps the raw transcription.
private enum ReviewerTile: String, CaseIterable, Identifiable {
    case none, apple, claude, openAI, gemini

    var id: String { rawValue }

    init(_ reviewer: Reviewer) {
        switch reviewer {
        case .none: self = .none
        case .apple: self = .apple
        case .claude: self = .claude
        case .openAI: self = .openAI
        case .gemini: self = .gemini
        }
    }

    var reviewer: Reviewer {
        switch self {
        case .none: Reviewer.none
        case .apple: .apple
        case .claude: .claude
        case .openAI: .openAI
        case .gemini: .gemini
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .none: "Aucun"
        case .apple: "Apple"
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        }
    }

    var isAvailable: Bool { reviewer.isAvailable }
}

/// A reviewer's logo, or its SF Symbol, at the size of the picker's icons.
private struct ReviewerIcon: View {
    let reviewer: Reviewer

    var body: some View {
        if let logo = reviewer.logo {
            Image(logo)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: reviewer.symbol)
                .font(.system(size: 22))
        }
    }
}

/// The pass that turns the raw transcription into clean text.
private struct ReviewSettings: View {
    @Bindable var model: AppModel
    /// The key field under a greyed Claude tile, opened on demand.
    @State private var enteringAPIKey = false

    private var reviewer: Binding<ReviewerTile> {
        Binding(
            get: { ReviewerTile(model.settings.reviewer) },
            set: { model.selectReviewer($0.reviewer) }
        )
    }

    var body: some View {
        Form {
            LabeledContent("Relecture par :") {
                VStack(alignment: .leading, spacing: 6) {
                    ReviewerPicker(selection: reviewer, claudeReady: model.claudeReady)
                    Hint(reviewerHint)
                    // The binary section only shows under Claude: a greyed tile
                    // still needs a way to point at a CLI the search missed.
                    if !model.claudeReady && model.settings.reviewer != .claude && !Distribution.isAppStore {
                        claudeUnavailable
                    }
                }
            }
            // Signing in to Claude happens elsewhere: ask again each time the tab shows.
            .onAppear { model.recheckClaude() }

            // Greyed out rather than removed under "Aucun", so that the window
            // keeps its height: it is sized to its content.
            Group {
                if !Distribution.isAppStore {
                    LabeledContent("Contexte :") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Lire le texte autour du curseur", isOn: Bindable(model.settings).shareFieldContext)
                            Hint("Texte du champ, titre de la fenêtre et domaine du site, pour reprendre vos noms et votre ton. Jamais un mot de passe.")
                        }
                    }
                }

                LabeledContent("Émojis :") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Insérer les émojis dictés", isOn: Bindable(model.settings).dictatedEmojis)
                            .onChange(of: model.settings.dictatedEmojis) { model.settingsChanged() }
                        Hint("Dites « émoji fusée » ou « smiley qui pleure de rire » : 🚀, 😂.")
                    }
                }

                Divider()

                switch model.settings.reviewer {
                case _ where Distribution.isAppStore, .apple:
                    appleStatus
                case .openAI:
                    apiKeyStatus(.openAI)
                case .gemini:
                    apiKeyStatus(.gemini)
                case .claude, .none:
                    claudeAccess
                    if model.settings.claudeAccess == .apiKey {
                        apiKeyStatus(.anthropic)
                    } else {
                        claudeBinary
                    }
                }
            }
            .disabled(!model.settings.enhancementEnabled)
        }
        .formStyle(.columns)
        .padding(20)
    }

    private var claudeUnavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    if model.claudeCLIPath == nil {
                        Text("Claude introuvable.")
                    } else {
                        Text("Claude n'est connecté à aucun compte.")
                    }
                }
                .foregroundStyle(.secondary)
                Button("Choisir…", action: chooseClaudeCLI)
                Button("Revérifier") { model.recheckClaude() }
                Button("Clé API…") { enteringAPIKey.toggle() }
            }
            .buttonStyle(.link)
            if overrideIgnored {
                Text("Fichier non exécutable : détection automatique utilisée.")
                    .foregroundStyle(.orange)
            }
            if enteringAPIKey {
                APIKeyField(model: model, provider: .anthropic)
                Text("Sans abonnement : Claude via votre clé API Anthropic, facturée à l'usage.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    /// The subscription by default; the API key for those without one.
    private var claudeAccess: some View {
        LabeledContent("Accès :") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Accès", selection: Binding(
                    get: { model.settings.claudeAccess },
                    set: { model.selectClaudeAccess($0) }
                )) {
                    ForEach(ClaudeAccess.allCases) { access in
                        Text(access.displayName).tag(access)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                switch model.settings.claudeAccess {
                case .subscription:
                    Hint("Par défaut : votre abonnement Claude, via la commande claude. Rien à payer en plus.")
                case .apiKey:
                    Hint("Votre clé API Anthropic, facturée à l'usage. Pour qui n'a pas d'abonnement Claude.")
                }
            }
        }
    }

    private func apiKeyStatus(_ provider: APIProvider) -> some View {
        let saved = model.settings.hasAPIKey(provider)
        return LabeledContent("Clé :") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if saved {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(verbatim: APIKeyField.masked(model.settings.apiKey(provider)))
                            .font(.callout.monospaced())
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Aucune clé \(provider.displayName) enregistrée")
                    }
                    Spacer()
                    Button("Tester") { Task { await model.testReviewer() } }
                        .disabled(!saved)
                }
                APIKeyField(model: model, provider: provider)
                HStack(spacing: 12) {
                    Link("Créer une clé", destination: provider.keysPage)
                    if saved {
                        Button("Supprimer la clé") { model.saveAPIKey("", for: provider) }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                if let result = model.reviewTestResult {
                    Hint(result)
                }
            }
        }
    }

    private var reviewerHint: String {
        let hint = switch model.settings.reviewer {
        case .none:
            String(localized: "Le texte transcrit est inséré tel quel, hésitations comprises.")
        case .apple:
            String(localized: "Le modèle d'Apple Intelligence, sur ce Mac. Rien ne sort de l'ordinateur, aucun compte nécessaire.")
        case .claude where model.settings.claudeAccess == .apiKey:
            String(localized: "Modèle Haiku, via votre clé API Anthropic. Un peu plus rapide et plus sûr sur le jargon.")
        case .claude:
            String(localized: "Modèle Haiku, via votre abonnement Claude. Un peu plus rapide et plus sûr sur le jargon.")
        case .openAI:
            String(localized: "Modèle GPT-5.4 nano sans raisonnement, le plus rapide d'OpenAI, via votre clé API.")
        case .gemini:
            String(localized: "Modèle Gemini 3.5 Flash-Lite, le plus rapide de Google, via votre clé API.")
        }
        guard !model.settings.reviewerIsChosen, !Distribution.isAppStore else { return hint }
        return String(localized: "Choix automatique : Claude, sinon OpenAI, sinon Gemini, sinon Apple Intelligence, selon ce qui est détecté.") + " " + hint
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
        } else if model.claudeCLIVersion != nil, model.claudeSignedIn {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var claudeCLITitle: String {
        if model.claudeCLIPath == nil { return String(localized: "claude introuvable") }
        if let version = model.claudeCLIVersion {
            return model.claudeSignedIn ? "claude \(version)" : String(localized: "claude \(version), non connecté")
        }
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
    /// Claude's tile is greyed out until its CLI is here and signed in.
    let claudeReady: Bool

    var body: some View {
        HStack(spacing: 12) {
            // The App Store build shows only the reviewers it has: no cloud service.
            ForEach(ReviewerTile.allCases.filter(\.isAvailable)) { reviewer in
                Button {
                    selection = reviewer
                } label: {
                    VStack(spacing: 6) {
                        ReviewerIcon(reviewer: reviewer.reviewer)
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
                .disabled(reviewer == .claude && !claudeReady)
                .help(help(for: reviewer))
            }
        }
    }

    private func help(for reviewer: ReviewerTile) -> Text {
        switch reviewer {
        case .claude where !claudeReady:
            Text("Nécessite Claude Code ou l'app Claude connecté à votre abonnement, ou une clé API.")
        case .openAI, .gemini:
            Text("Avec votre clé API, facturée à l'usage.")
        default:
            Text(verbatim: "")
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
