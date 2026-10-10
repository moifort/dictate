import SwiftUI

/// Step-by-step onboarding, shown at launch until `SetupChecklist` is complete.
/// Follows the first missing step and moves on by itself as each one is granted.
struct SetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    /// Picked in the sidebar; nil follows the first missing step.
    @State private var picked: Page?

    enum Page: Hashable {
        case step(SetupStep)
        case tryIt
    }

    private var page: Page {
        picked ?? model.setup.current.map(Page.step) ?? .tryIt
    }

    /// Selecting the step that is already current means "follow the checklist again".
    private var selection: Binding<Page?> {
        Binding(
            get: { page },
            set: { selected in
                guard let selected else { return }
                picked = selected == model.setup.current.map(Page.step) ? nil : selected
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack(alignment: .topLeading) {
                detail
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            .animation(.snappy(duration: 0.4), value: page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(width: 720, height: 460)
        .onChange(of: model.setup) { old, new in
            // A step was just granted: follow the next missing one.
            if case .step(let step) = picked, new.isDone(step), !old.isDone(step) {
                picked = nil
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: selection) {
            Section {
                ForEach(SetupStep.allCases) { step in
                    Label {
                        Text(step.title)
                    } icon: {
                        StatusIcon(done: model.setup.isDone(step), current: step == model.setup.current)
                    }
                    .tag(Page.step(step))
                }
            }
            Section {
                Label("Essayer", systemImage: "waveform")
                    .tag(Page.tryIt)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(200)
        .toolbar(removing: .sidebarToggle)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(model.setup.completedCount), total: Double(SetupStep.allCases.count))
                    .animation(.smooth(duration: 0.5), value: model.setup.completedCount)
                Text("\(model.setup.completedCount) sur \(SetupStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.setup.completedCount)
            }
            .padding(16)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .step(let step):
            StepPage(step: step, done: model.setup.isDone(step), onContinue: { picked = nil }) {
                content(for: step)
            }
        case .tryIt:
            TryItPage(model: model) { dismissWindow(id: "setup") }
        }
    }

    @ViewBuilder
    private func content(for step: SetupStep) -> some View {
        switch step {
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

        case .whisperModel:
            WhisperProgress(model: model)

        case .claude:
            if !model.settings.enhancementEnabled {
                Text("Dictate insère le texte brut de Whisper. Claude s'active dans les Réglages.")
                    .foregroundStyle(.secondary)
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
                    Button("Continuer sans Claude") { model.continueWithoutClaude() }
                        .buttonStyle(.glass)
                }
                Text("Connectez-vous une fois dans Claude Code ou l'app Claude, puis revérifiez.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Pages

private extension SetupStep {
    var title: String {
        switch self {
        case .microphone: "Micro"
        case .inputMonitoring: "Touche fn"
        case .accessibility: "Accessibilité"
        case .fnKey: "Touche 🌐"
        case .whisperModel: "Whisper"
        case .claude: "Claude"
        }
    }

    var heading: String {
        switch self {
        case .microphone: "Micro"
        case .inputMonitoring: "Surveillance de la touche fn"
        case .accessibility: "Insertion du texte"
        case .fnKey: "Libérer la touche 🌐"
        case .whisperModel: "Modèle de transcription"
        case .claude: "Correction par Claude"
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            "Dictate n'écoute que pendant que vous maintenez fn. L'audio est transcrit sur ce Mac et n'en sort jamais."
        case .inputMonitoring:
            "macOS appelle cette autorisation « Surveillance de l'entrée ». Elle sert à savoir quand fn est enfoncée ; aucune frappe n'est enregistrée."
        case .accessibility:
            "Pour repérer le champ de texte actif et y coller votre dictée. Sans champ actif, le texte reste dans le presse-papiers."
        case .fnKey:
            "Par défaut, macOS ouvre les emoji ou sa propre dictée quand on appuie sur 🌐 fn."
        case .whisperModel:
            "Whisper large-v3 turbo transcrit votre voix sur ce Mac, sans réseau. Le modèle se télécharge une seule fois, environ 630 Mo."
        case .claude:
            "Claude Haiku retire les hésitations et corrige la ponctuation et votre jargon, avec votre abonnement Claude, via la commande claude de Claude Code ou de l'app Claude."
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .inputMonitoring: "keyboard"
        case .accessibility: "accessibility"
        case .fnKey: "globe"
        case .whisperModel: "waveform"
        case .claude: "sparkles"
        }
    }
}

/// Sidebar bullet: empty, current or done, morphing between the three.
private struct StatusIcon: View {
    let done: Bool
    let current: Bool

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : current ? "circle.circle" : "circle")
            .foregroundStyle(done ? AnyShapeStyle(.green) : current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, options: .nonRepeating, value: done)
            .animation(.snappy, value: done)
            .animation(.snappy, value: current)
    }
}

private struct StepPage<Content: View>: View {
    let step: SetupStep
    let done: Bool
    let onContinue: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: done ? "checkmark.circle.fill" : step.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, options: .nonRepeating, value: done)
                .frame(height: 48)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(step.heading).font(.title.weight(.semibold))
                    if step.isOptional {
                        Text("facultatif")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                ZStack(alignment: .topLeading) {
                    if done {
                        Text("C'est fait.")
                            .foregroundStyle(.green)
                            .transition(.blurReplace)
                    } else {
                        Text(step.explanation)
                            .foregroundStyle(.secondary)
                            .transition(.blurReplace)
                    }
                }
            }

            if !done {
                content
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }

            Spacer()

            HStack {
                Text("\(step.rawValue + 1) / \(SetupStep.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                if done {
                    Button("Continuer", action: onContinue)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .transition(.scale(0.9).combined(with: .opacity))
                }
            }
        }
        .padding(36)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: done)
    }
}

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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(line)
                }
            }
        }
    }
}

private struct WhisperProgress: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .leading) {
            switch model.transcriber.state {
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: fraction)
                        .animation(.smooth, value: fraction)
                    Text("\(Int(fraction * 630)) Mo sur 630")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: Int(fraction * 630))
                }
                .frame(maxWidth: 320)
                .id("downloading")
            case .loading, .notLoaded:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.setup.whisperModel ? "Préparation du modèle pour ce Mac…" : "Connexion…")
                        .foregroundStyle(.secondary)
                }
                .id("loading")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Réessayer") { model.retryWhisper() }
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

/// Last page: a scratch field to check the whole chain end to end.
private struct TryItPage: View {
    let model: AppModel
    let onFinish: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: model.setup.isComplete ? "checkmark.seal.fill" : "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(model.setup.isComplete ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 48)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.setup.isComplete ? "Tout est prêt" : "Essayer").font(.title.weight(.semibold))
                Text("Cliquez dans le champ, maintenez fn, parlez, relâchez.")
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 110)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))

            status
                .font(.callout)
                .id(statusKey)
                .transition(.blurReplace)

            Spacer()

            HStack {
                Spacer()
                Button(model.setup.isComplete ? "Commencer" : "Plus tard", action: onFinish)
                    .buttonStyle(model.setup.isComplete ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
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
            Label("Whisper se prépare, encore un instant…", systemImage: "hourglass").foregroundStyle(.secondary)
        case "success":
            Label("Ça marche.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            Label("Maintenez fn pour dicter", systemImage: "globe").foregroundStyle(.secondary)
        }
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
