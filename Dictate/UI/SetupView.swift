import SwiftUI

/// Onboarding in the manner of Apple's setup assistants: one centred column
/// per page, a large symbol, a title, a short explanation, the one action
/// that matters, and "Continuer" at the bottom. Shown at launch until
/// `SetupChecklist` is complete.
struct SetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    /// nil until the user navigates: a fresh install opens on the welcome
    /// page, a resumed setup on the first missing step.
    @State private var visited: Page?
    @State private var movingForward = true

    enum Page: Hashable {
        case welcome
        case step(SetupStep)
        case tryIt
    }

    private static let pages: [Page] = [.welcome] + SetupStep.allCases.map(Page.step) + [.tryIt]

    private var page: Page {
        if let visited { return visited }
        if model.setup.completedCount == 0 { return .welcome }
        return model.setup.current.map(Page.step) ?? .tryIt
    }

    private var index: Int { Self.pages.firstIndex(of: page) ?? 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                content
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .animation(.snappy(duration: 0.45), value: page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if index > 0 {
                Button { go(to: index - 1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.callout.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .padding(.leading, 14)
                .padding(.top, 44)
                .transition(.opacity)
            }
        }
        .frame(width: 600, height: 640)
        .animation(.snappy, value: index)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome:
            WelcomePage(onContinue: { go(to: 1) })
        case .step(let step):
            StepPage(model: model, step: step, onContinue: { advance(after: step) }) {
                actions(for: step)
            }
        case .tryIt:
            TryItPage(model: model) { dismissWindow(id: "setup") }
        }
    }

    private func go(to target: Int) {
        guard Self.pages.indices.contains(target) else { return }
        movingForward = target > index
        visited = Self.pages[target]
    }

    /// Continue on the language page is the confirmation itself.
    private func advance(after step: SetupStep) {
        if step == .language { model.confirmLanguage() }
        go(to: index + 1)
    }

    // MARK: Step actions

    @ViewBuilder
    private func actions(for step: SetupStep) -> some View {
        switch step {
        case .language:
            LanguagePicker(model: model)
                .labelsHidden()
                .frame(width: 280)

        case .microphone:
            Actions {
                Button("Autoriser le micro") { Task { await Permissions.requestMicrophone() } }
                    .buttonStyle(.glassProminent)
            }

        case .inputMonitoring:
            Instructions([
                "Ouvrez les Réglages et activez Dictate dans la liste.",
                "S'il n'y figure pas, glissez l'app depuis le Finder dans la liste.",
            ])
            Actions {
                Button("Ouvrir les Réglages") {
                    Permissions.requestInputMonitoring()
                    Permissions.openPrivacySettings("Privacy_ListenEvent")
                }
                .buttonStyle(.glassProminent)
                Button("Montrer dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .buttonStyle(.glass)
            }

        case .accessibility:
            Actions {
                Button("Autoriser") { Permissions.requestAccessibility() }
                    .buttonStyle(.glassProminent)
                Button("Ouvrir les Réglages") { Permissions.openPrivacySettings("Privacy_Accessibility") }
                    .buttonStyle(.glass)
            }

        case .fnKey:
            Instructions([
                "Réglages Système → Clavier.",
                "« Appuyer sur la touche 🌐 pour » → « Ne rien faire ».",
            ])
            Actions {
                Button("Ouvrir les réglages Clavier") { Permissions.openKeyboardSettings() }
                    .buttonStyle(.glassProminent)
            }

        case .transcriptionModel:
            TranscriptionModelProgress(model: model)

        case .claude:
            if !model.settings.enhancementEnabled {
                Text("Dictate insère le texte brut transcrit. Claude s'active dans les Réglages.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let path = model.claudeCLIPath {
                Text(path.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Actions {
                    Link("Télécharger Claude", destination: URL(string: "https://claude.ai/download")!)
                        .buttonStyle(.glassProminent)
                    Button("Revérifier") {
                        model.refreshClaudeCLI()
                        model.refreshSetup()
                    }
                    .buttonStyle(.glass)
                }
                Text("Connectez-vous une fois dans Claude Code ou l'app Claude, puis revérifiez.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Step copy

private extension SetupStep {
    var heading: String {
        switch self {
        case .language: "Langue de dictée"
        case .microphone: "Micro"
        case .inputMonitoring: "Surveillance de la touche fn"
        case .accessibility: "Insertion du texte"
        case .fnKey: "Libérer la touche 🌐"
        case .transcriptionModel: "Modèle de transcription"
        case .claude: "Correction par Claude"
        }
    }

    var explanation: String {
        switch self {
        case .language:
            "La transcription est plus fiable quand elle sait à l'avance dans quelle langue vous parlez. Dictate a repris celle de macOS ; changez-la si vous dictez dans une autre. Les termes techniques anglais restent reconnus."
        case .microphone:
            "Dictate n'écoute que pendant que vous maintenez fn. L'audio est transcrit sur ce Mac et n'en sort jamais."
        case .inputMonitoring:
            "macOS appelle cette autorisation « Surveillance de l'entrée ». Elle sert à savoir quand fn est enfoncée ; aucune frappe n'est enregistrée."
        case .accessibility:
            "Pour repérer le champ de texte actif et y coller votre dictée. Sans champ actif, le texte reste dans le presse-papiers."
        case .fnKey:
            "Par défaut, macOS ouvre les emoji ou sa propre dictée quand on appuie sur 🌐 fn."
        case .transcriptionModel:
            "Un modèle de transcription tourne sur ce Mac, sans réseau. Il se télécharge une seule fois, environ 630 Mo."
        case .claude:
            "Claude Haiku retire les hésitations et corrige la ponctuation et votre jargon, avec votre abonnement Claude, via la commande claude de Claude Code ou de l'app Claude."
        }
    }

    var symbol: String {
        switch self {
        case .language: "character.bubble"
        case .microphone: "mic"
        case .inputMonitoring: "keyboard"
        case .accessibility: "accessibility"
        case .fnKey: "globe"
        case .transcriptionModel: "waveform"
        case .claude: "sparkles"
        }
    }

    /// What the secondary link under "Continuer" does on an unfinished page.
    var skipTitle: String? {
        switch self {
        case .claude: "Continuer sans Claude"
        default: nil
        }
    }
}

// MARK: - Shared layout

/// The column every page uses: symbol, title, explanation, content, then the
/// bottom bar with the primary button, an optional secondary link and the
/// page dots.
private struct PageLayout<Hero: View, Content: View, Footer: View>: View {
    let title: String
    let explanation: String
    @ViewBuilder let hero: Hero
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 44)
            hero
                .frame(height: 88)

            Text(title)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 22)

            Text(explanation)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 18) {
                content
            }
            .padding(.top, 32)

            Spacer(minLength: 24)

            footer
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 32)
    }
}

/// Primary button, optional secondary link, page dots.
private struct BottomBar: View {
    let primary: String
    var primaryEnabled = true
    var prominent = true
    let onPrimary: () -> Void
    var secondary: String? = nil
    var onSecondary: () -> Void = {}
    let pageIndex: Int
    let pageCount: Int

    var body: some View {
        VStack(spacing: 18) {
            Button(action: onPrimary) {
                Text(primary)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
            .controlSize(.extraLarge)
            .frame(width: 260)
            .disabled(!primaryEnabled)
            .keyboardShortcut(.defaultAction)

            ZStack {
                // Reserves the line so the dots do not jump between pages.
                Text(" ").font(.callout)
                if let secondary {
                    Button(secondary, action: onSecondary)
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .transition(.opacity)
                }
            }

            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
            .animation(.snappy, value: pageIndex)
        }
        .animation(.snappy, value: secondary)
    }
}

/// Lets one button switch between glass styles without duplicating the view.
private struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

private let pageCount = SetupStep.allCases.count + 2

// MARK: - Pages

private struct WelcomePage: View {
    let onContinue: () -> Void

    var body: some View {
        PageLayout(
            title: "Bienvenue dans Dictate",
            explanation: "Maintenez fn, parlez, relâchez : le texte apparaît dans le champ actif, dans n'importe quelle app."
        ) {
            AppTile()
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                FeatureRow(symbol: "lock.shield", title: "Transcription sur ce Mac",
                           detail: "Le modèle tourne en local. Votre voix ne quitte pas l'ordinateur.")
                FeatureRow(symbol: "sparkles", title: "Nettoyage par Claude",
                           detail: "Hésitations, ponctuation et jargon corrigés avec votre abonnement Claude.")
                FeatureRow(symbol: "keyboard", title: "Une seule touche",
                           detail: "fn suffit, même par-dessus une app en plein écran.")
            }
            .frame(maxWidth: 400)
        } footer: {
            BottomBar(primary: "Continuer", onPrimary: onContinue, pageIndex: 0, pageCount: pageCount)
        }
    }
}

/// Stands in for the app icon on the welcome page.
private struct AppTile: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [.accentColor.opacity(0.95), .accentColor.opacity(0.65)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .accentColor.opacity(0.35), radius: 18, y: 8)
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 84, height: 84)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 40, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StepPage<Content: View>: View {
    let model: AppModel
    let step: SetupStep
    let onContinue: () -> Void
    @ViewBuilder let content: Content

    private var done: Bool { model.setup.isDone(step) }

    var body: some View {
        PageLayout(title: step.heading, explanation: done ? "C'est fait." : step.explanation) {
            Image(systemName: done ? "checkmark.circle.fill" : step.symbol)
                .font(.system(size: 60, weight: .medium))
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, options: .nonRepeating, value: done)
        } content: {
            if !done {
                content
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        } footer: {
            BottomBar(
                primary: "Continuer",
                primaryEnabled: done || step == .language,
                onPrimary: onContinue,
                secondary: done ? nil : step.skipTitle,
                onSecondary: { if step == .claude { model.continueWithoutClaude() } },
                pageIndex: step.rawValue + 1,
                pageCount: pageCount
            )
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: done)
    }
}

/// Last page: a scratch field to check the whole chain end to end.
private struct TryItPage: View {
    let model: AppModel
    let onFinish: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        PageLayout(
            title: model.setup.isComplete ? "Tout est prêt" : "Essayer",
            explanation: "Cliquez dans le champ, maintenez fn, parlez, relâchez."
        ) {
            Image(systemName: model.setup.isComplete ? "checkmark.seal.fill" : "waveform")
                .font(.system(size: 60, weight: .medium))
                .foregroundStyle(model.setup.isComplete ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace))
        } content: {
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(width: 420, height: 110)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))

            status
                .font(.callout)
                .id(statusKey)
                .transition(.blurReplace)
        } footer: {
            BottomBar(
                primary: model.setup.isComplete ? "Commencer" : "Plus tard",
                prominent: model.setup.isComplete,
                onPrimary: onFinish,
                pageIndex: pageCount - 1,
                pageCount: pageCount
            )
        }
        .animation(.snappy, value: statusKey)
        .animation(.snappy, value: model.setup.isComplete)
        .onAppear { focused = true }
    }

    private var statusKey: String {
        switch model.controller.phase {
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .enhancing: "enhancing"
        case .idle:
            if case .failed = model.transcriber.state { "failed" }
            else if model.transcriber.state != .ready { "preparing" }
            else if !text.isEmpty, case .pasted = model.controller.lastOutcome { "success" }
            else { "ready" }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch statusKey {
        case "recording":
            Label("Je vous écoute…", systemImage: "mic.fill").foregroundStyle(.red)
        case "transcribing":
            Label("Transcription…", systemImage: "waveform").foregroundStyle(.secondary)
        case "enhancing":
            Label("Correction par Claude…", systemImage: "sparkles").foregroundStyle(.secondary)
        case "failed":
            if case .failed(let message) = model.transcriber.state {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        case "preparing":
            Label("\(model.transcriber.engine.displayName) se prépare, encore un instant…", systemImage: "hourglass").foregroundStyle(.secondary)
        case "success":
            Label("Ça marche.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            Label("Maintenez fn pour dicter", systemImage: "globe").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pieces

/// One glass container per group of buttons, so neighbouring glass can merge.
private struct Actions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) { content }
        }
        .controlSize(.large)
    }
}

private struct Instructions: View {
    let lines: [String]

    init(_ lines: [String]) { self.lines = lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.tint, in: .circle)
                    Text(line)
                }
            }
        }
    }
}

private struct TranscriptionModelProgress: View {
    let model: AppModel

    private var size: Int { model.transcriber.engine.downloadSize }

    var body: some View {
        ZStack {
            switch model.transcriber.state {
            case .downloading(let fraction):
                VStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .animation(.smooth, value: fraction)
                    Text("\(Int(fraction * Double(size))) Mo sur \(size)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: Int(fraction * Double(size)))
                }
                .frame(width: 320)
                .id("downloading")
            case .loading, .notLoaded:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.setup.transcriptionModel ? "Préparation du modèle pour ce Mac…" : "Connexion…")
                        .foregroundStyle(.secondary)
                }
                .id("loading")
            case .failed(let message):
                VStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Réessayer") { model.retryTranscriber() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
                .id("failed")
            case .ready:
                EmptyView()
            }
        }
        .transition(.blurReplace)
        .animation(.snappy, value: model.transcriber.state)
    }
}
