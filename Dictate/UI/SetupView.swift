import SwiftUI

/// Onboarding in the manner of Apple's setup assistants: a welcome page, a
/// checklist of everything Dictate needs, ticked one line at a time as macOS
/// grants it, and a page to try a dictation. Shown at launch until
/// `SetupChecklist` is complete.
struct SetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    /// Decided once when the window opens; the permission poll never moves it.
    @State private var page: Page
    @State private var direction = SlideDirection()

    nonisolated enum Page: Hashable, Sendable, CaseIterable {
        case welcome
        case checklist
        case tryIt
    }

    private static let pages = Page.allCases
    private static let size = CGSize(width: 600, height: 680)

    init(model: AppModel) {
        self.model = model
        _page = State(initialValue: Self.firstPage(for: model.setup))
    }

    /// A fresh install opens on the welcome page, a resumed setup on the
    /// checklist, whatever macOS had already granted.
    nonisolated static func firstPage(for checklist: SetupChecklist) -> Page {
        guard checklist.hasStarted else { return .welcome }
        return checklist.isComplete ? .tryIt : .checklist
    }

    private var index: Int { Self.pages.firstIndex(of: page) ?? 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ZStack {
                    content
                        .id(page)
                        .transition(PageSlide(direction: direction, width: Self.size.width))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                bottomBar
                    .padding(.horizontal, 48)
                    .padding(.bottom, 32)
            }

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
        .frame(width: Self.size.width, height: Self.size.height)
        // One animation for the slide, the chevron and the bottom bar.
        .animation(.snappy(duration: 0.45), value: page)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome:
            WelcomePage()
        case .checklist:
            ChecklistPage(model: model)
        case .tryIt:
            TryItPage(model: model)
        }
    }

    // MARK: Bottom bar

    /// Stays in place while the pages slide, like the Continue button of a
    /// setup assistant; only its wording follows the page.
    private var bottomBar: some View {
        BottomBar(
            primary: primaryTitle,
            primaryEnabled: page != .checklist || model.setup.isComplete,
            prominent: page != .tryIt || model.setup.isComplete,
            onPrimary: primaryAction,
            pageIndex: index,
            pageCount: Self.pages.count
        )
    }

    private var primaryTitle: LocalizedStringKey {
        switch page {
        case .welcome, .checklist: "Continuer"
        case .tryIt: model.setup.isComplete ? "Commencer" : "Plus tard"
        }
    }

    private func primaryAction() {
        switch page {
        case .welcome, .checklist:
            go(to: index + 1)
        case .tryIt:
            dismissWindow(id: "setup")
        }
    }

    private func go(to target: Int) {
        guard Self.pages.indices.contains(target), target != index else { return }
        direction.forward = target > index
        page = Self.pages[target]
    }
}

// MARK: - Slide

/// Where the next page change goes. Shared by reference: SwiftUI evaluates
/// the outgoing page with the modifiers it had before the change, so a
/// direction captured as a value would be the one of the previous navigation
/// and both pages would head for the same edge.
private final class SlideDirection {
    var forward = true
}

/// Pages come in from the trailing edge and leave by the leading one when
/// going forward, the reverse when going back.
private struct PageSlide: Transition {
    let direction: SlideDirection
    let width: CGFloat

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(x: phase.value * (direction.forward ? -width : width))
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

// MARK: - Checklist

/// Every step on one page. The one being worked on is unfolded with its
/// explanation and buttons; a step ticks with a bounce when macOS grants it,
/// and the next missing one unfolds a beat later.
private struct ChecklistPage: View {
    let model: AppModel
    @State private var unfolded: SetupStep?

    init(model: AppModel) {
        self.model = model
        _unfolded = State(initialValue: model.setup.current)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            Text("Configuration")
                .font(.system(size: 30, weight: .bold))

            (model.setup.isComplete ? Text("Tout est prêt.") : Text("Chaque ligne se coche dès que c'est accordé."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .padding(.top, 8)

            VStack(spacing: 2) {
                ForEach(SetupStep.allCases) { step in
                    ChecklistRow(step: step, done: model.setup.isDone(step), unfolded: unfolded == step) {
                        unfolded = unfolded == step ? nil : step
                    } content: {
                        StepActions(model: model, step: step)
                    }
                }
            }
            .frame(maxWidth: 480)
            .padding(.top, 24)
            .animation(.spring(duration: 0.4, bounce: 0.2), value: unfolded)
            .animation(.spring(duration: 0.45, bounce: 0.3), value: model.setup)

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 48)
        .onChange(of: model.setup) { old, new in
            // The unfolded step was just granted: let the tick land, then
            // move on to the next missing one.
            guard let step = unfolded, new.isDone(step), !old.isDone(step) else { return }
            Task {
                try? await Task.sleep(for: .seconds(0.6))
                if unfolded == step { unfolded = model.setup.current }
            }
        }
    }
}

private struct ChecklistRow<Content: View>: View {
    let step: SetupStep
    let done: Bool
    let unfolded: Bool
    let onTap: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    Image(systemName: done ? "checkmark.circle.fill" : step.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(statusStyle)
                        .frame(width: 28)
                        .contentTransition(.symbolEffect(.replace.downUp))
                        .symbolEffect(.bounce, options: .nonRepeating, value: done)
                    Text(step.heading)
                        .font(.headline)
                        .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Spacer(minLength: 0)
                    if !done && !unfolded {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if unfolded {
                content
                    .padding(.leading, 56)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .background(unfolded ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
    }

    private var statusStyle: AnyShapeStyle {
        if done { AnyShapeStyle(.green) }
        else if unfolded { AnyShapeStyle(.tint) }
        else { AnyShapeStyle(.secondary) }
    }
}

/// What the unfolded row shows: the explanation, then the one action that
/// matters, or the progress while the step completes by itself.
private struct StepActions: View {
    let model: AppModel
    let step: SetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(step.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch step {
        case .language:
            Actions {
                LanguagePicker(model: model)
                    .labelsHidden()
                    .frame(width: 200)
                Button("Confirmer") { model.confirmLanguage() }
                    .buttonStyle(.glassProminent)
            }

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
                Button("Dicter avec control") {
                    model.settings.pushToTalkKey = .control
                    model.pushToTalkKeyChanged()
                }
                .buttonStyle(.glass)
            }

        case .transcriptionModel:
            TranscriptionModelProgress(model: model)

        case .review:
            ReviewStep(model: model)
        }
    }
}

/// The reviewer's own line of the checklist: which one is chosen, whether it
/// is ready, and how to switch when it is not.
private struct ReviewStep: View {
    let model: AppModel

    var body: some View {
        switch model.settings.reviewer {
        case .none:
            Text("Dictate insère le texte brut transcrit. La relecture s'active dans les Réglages.")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .apple:
            if model.appleIntelligence.isAvailable {
                appleReadyText
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !model.settings.reviewerIsChosen && !Distribution.isAppStore {
                    Actions {
                        if model.claudeCLIPath == nil {
                            Link("Télécharger Claude", destination: URL(string: "https://claude.ai/download")!)
                                .buttonStyle(.glass)
                        } else {
                            Button("Revérifier") { model.recheckClaude() }
                                .buttonStyle(.glass)
                        }
                    }
                }
            } else {
                Actions {
                    Button("Ouvrir les Réglages") { Permissions.openAppleIntelligenceSettings() }
                        .buttonStyle(.glassProminent)
                    if !Distribution.isAppStore {
                        Button("Utiliser Claude") { model.selectReviewer(.claude) }
                            .buttonStyle(.glass)
                    }
                    Button("Continuer sans relecture") { model.selectReviewer(.none) }
                        .buttonStyle(.glass)
                }
                Text(model.appleIntelligence.explanation ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .claude:
            if let path = model.claudeCLIPath, model.claudeSignedIn {
                Text(path.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Actions {
                    if model.claudeCLIPath == nil {
                        Link("Télécharger Claude", destination: URL(string: "https://claude.ai/download")!)
                            .buttonStyle(.glassProminent)
                        Button("Revérifier") { model.recheckClaude() }
                            .buttonStyle(.glass)
                    } else {
                        Button("Revérifier") { model.recheckClaude() }
                            .buttonStyle(.glassProminent)
                    }
                    if model.appleIntelligence.isAvailable {
                        Button("Utiliser Apple Intelligence") { model.selectReviewer(.apple) }
                            .buttonStyle(.glass)
                    }
                    Button("Continuer sans relecture") { model.selectReviewer(.none) }
                        .buttonStyle(.glass)
                }
                Text("Connectez-vous une fois dans Claude Code ou l'app Claude, puis revérifiez.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Why the on-device model reviews: picked, or the automatic choice
    /// because Claude is missing or signed out.
    private var appleReadyText: Text {
        if model.settings.reviewerIsChosen || Distribution.isAppStore {
            return Text("Apple Intelligence est prêt : la relecture se fait sur ce Mac.")
        }
        if model.claudeCLIPath == nil {
            return Text("Claude est introuvable : Apple Intelligence relit sur ce Mac. Installez Claude pour qu'il prenne le relais.")
        }
        return Text("Claude n'est connecté à aucun compte : Apple Intelligence relit sur ce Mac. Connectez-vous à Claude pour qu'il prenne le relais.")
    }
}

// MARK: - Step copy

private extension SetupStep {
    var heading: LocalizedStringKey {
        switch self {
        case .language: "Langue de dictée"
        case .microphone: "Micro"
        case .inputMonitoring: "Surveillance de la touche de dictée"
        case .accessibility: "Insertion du texte"
        case .fnKey: "Libérer la touche 🌐"
        case .transcriptionModel: "Modèle de transcription"
        case .review: "Relecture du texte"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .language:
            "La transcription est plus fiable quand elle sait à l'avance dans quelle langue vous parlez. Dictate a repris celle de macOS ; changez-la si vous dictez dans une autre. Les termes techniques anglais restent reconnus."
        case .microphone:
            "Dictate n'écoute que pendant que vous maintenez la touche de dictée. L'audio est transcrit sur ce Mac et n'en sort jamais."
        case .inputMonitoring:
            "macOS appelle cette autorisation « Surveillance de l'entrée ». Elle sert à savoir quand la touche de dictée est enfoncée ; aucune frappe n'est enregistrée."
        case .accessibility:
            "Pour repérer le champ de texte actif et y coller votre dictée. Sans champ actif, le texte reste dans le presse-papiers."
        case .fnKey:
            "Par défaut, macOS ouvre les emoji ou sa propre dictée quand on appuie sur 🌐 fn. Vous pouvez aussi dicter avec control, qui n'a rien à régler."
        case .transcriptionModel:
            "Un modèle de transcription tourne sur ce Mac, sans réseau. Il se télécharge une seule fois, environ 630 Mo."
        case .review:
            "Un modèle de langage retire les hésitations et corrige la ponctuation et votre jargon : Claude Haiku avec votre abonnement Claude, via la commande claude, ou à défaut Apple Intelligence sur ce Mac. Au choix dans les Réglages."
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
        case .review: "sparkles"
        }
    }
}

// MARK: - Shared layout

/// The column the welcome and try-it pages use: symbol, title, explanation,
/// content. The bottom bar is not part of it, so that it stays put while
/// pages slide.
private struct PageLayout<Hero: View, Content: View>: View {
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey
    @ViewBuilder let hero: Hero
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 44)
            hero
                .frame(height: 88)

            Text(title)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .padding(.top, 22)

            Text(explanation)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .frame(maxWidth: 430)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 18) {
                content
            }
            .padding(.top, 32)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 48)
    }
}

/// Primary button and page dots.
private struct BottomBar: View {
    let primary: LocalizedStringKey
    var primaryEnabled = true
    var prominent = true
    let onPrimary: () -> Void
    let pageIndex: Int
    let pageCount: Int

    var body: some View {
        VStack(spacing: 18) {
            Button(action: onPrimary) {
                Text(primary)
                    .font(.body.weight(.semibold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
            .controlSize(.extraLarge)
            .frame(width: 260)
            .disabled(!primaryEnabled)
            .keyboardShortcut(.defaultAction)

            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .animation(.snappy, value: primaryEnabled)
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

// MARK: - Pages

private struct WelcomePage: View {
    var body: some View {
        PageLayout(
            title: "Bienvenue dans Dictate",
            explanation: "Maintenez control, parlez, relâchez : le texte apparaît dans le champ actif, dans n'importe quelle app."
        ) {
            AppTile()
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                FeatureRow(symbol: "lock.shield", title: "Transcription sur ce Mac",
                           detail: "Le modèle tourne en local. Votre voix ne quitte pas l'ordinateur.")
                FeatureRow(symbol: "sparkles", title: "Texte relu par l'IA",
                           detail: "Hésitations, ponctuation et jargon corrigés, par Apple Intelligence sur ce Mac ou par Claude.")
                FeatureRow(symbol: "keyboard", title: "Une seule touche",
                           detail: "control suffit, même par-dessus une app en plein écran. fn au choix dans les Réglages.")
            }
            .frame(maxWidth: 400)
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
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

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

/// Last page: a scratch field to check the whole chain end to end.
private struct TryItPage: View {
    let model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        PageLayout(
            title: model.setup.isComplete ? "Tout est prêt" : "Essayer",
            explanation: "Cliquez dans le champ, maintenez \(model.settings.pushToTalkKey.displayName), parlez, relâchez."
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

            VStack(spacing: 4) {
                LaunchAtLoginToggle("Ouvrir Dictate à l'ouverture de session", settings: model.settings)
                Text("La touche de dictée répond dès que le Mac démarre.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
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
            Label("Relecture…", systemImage: "sparkles").foregroundStyle(.secondary)
        case "failed":
            if case .failed(let message) = model.transcriber.state {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        case "preparing":
            Label("\(model.transcriber.engine.displayName) se prépare, encore un instant…", systemImage: "hourglass").foregroundStyle(.secondary)
        case "success":
            Label("Ça marche.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            let key = model.settings.pushToTalkKey
            Label("Maintenez \(key.displayName) pour dicter", systemImage: key.symbol).foregroundStyle(.secondary)
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
    }
}

private struct Instructions: View {
    let lines: [LocalizedStringKey]

    init(_ lines: [LocalizedStringKey]) { self.lines = lines }

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
                        .font(.callout)
                }
            }
        }
    }
}

private struct TranscriptionModelProgress: View {
    let model: AppModel

    private var size: Int { model.transcriber.engine.downloadSize }

    var body: some View {
        ZStack(alignment: .leading) {
            switch model.transcriber.state {
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 8) {
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
                .transition(.blurReplace)
            case .loading, .notLoaded:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    (model.setup.transcriptionModel ? Text("Préparation du modèle pour ce Mac…") : Text("Connexion…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .id("loading")
                .transition(.blurReplace)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Réessayer") { model.retryTranscriber() }
                        .buttonStyle(.glassProminent)
                }
                .id("failed")
                .transition(.blurReplace)
            case .ready:
                EmptyView()
            }
        }
        .animation(.snappy, value: model.transcriber.state)
    }
}
