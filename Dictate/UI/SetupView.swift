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

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
                .background(.fill.quinary)
            Divider()
            detail
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 740, height: 480)
        .onChange(of: model.setup) { old, new in
            // A step was just granted: follow the next missing one.
            if case .step(let step) = picked, new.isDone(step), !old.isDone(step) {
                picked = nil
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text("Bienvenue dans Dictate").font(.headline)
                ProgressView(value: Double(model.setup.completedCount), total: Double(SetupStep.allCases.count))
                Text("\(model.setup.completedCount) sur \(SetupStep.allCases.count) prêts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            ForEach(SetupStep.allCases) { step in
                sidebarRow(.step(step), title: step.title, icon: statusIcon(for: step))
            }
            Divider().padding(.vertical, 6)
            sidebarRow(.tryIt, title: "Essayer", icon: Image(systemName: "sparkles"))

            Spacer()
        }
        .padding(16)
    }

    private func sidebarRow(_ target: Page, title: String, icon: some View) -> some View {
        Button {
            picked = target == model.setup.current.map(Page.step) ? nil : target
        } label: {
            HStack(spacing: 8) {
                icon.frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background(page == target ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func statusIcon(for step: SetupStep) -> some View {
        Group {
            if model.setup.isDone(step) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if step == model.setup.current {
                Image(systemName: "circle.circle.fill").foregroundStyle(.tint)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
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
            Text("Dictate n'écoute que pendant que vous maintenez fn. L'audio est transcrit sur ce Mac et n'en sort jamais.")
            Button("Autoriser le micro") { Task { await Permissions.requestMicrophone() } }
                .buttonStyle(.borderedProminent)

        case .inputMonitoring:
            Text("macOS appelle cette autorisation « Surveillance de l'entrée ». Dictate s'en sert pour savoir quand fn est enfoncée ; aucune frappe n'est enregistrée.")
            Instructions([
                "Ouvrez les Réglages avec le bouton ci-dessous.",
                "Activez Dictate dans la liste.",
                "S'il n'y figure pas, glissez l'app depuis le Finder dans la liste, ou ajoutez-la avec +.",
            ])
            HStack {
                Button("Ouvrir les Réglages") {
                    Permissions.requestInputMonitoring()
                    Permissions.openPrivacySettings("Privacy_ListenEvent")
                }
                .buttonStyle(.borderedProminent)
                Button("Montrer Dictate dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }

        case .accessibility:
            Text("Pour repérer le champ de texte actif et y coller votre dictée. Sans champ actif, le texte est laissé dans le presse-papiers.")
            HStack {
                Button("Autoriser") { Permissions.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                Button("Ouvrir les Réglages") { Permissions.openPrivacySettings("Privacy_Accessibility") }
            }

        case .fnKey:
            Text("Par défaut, macOS ouvre les emoji ou sa propre dictée quand on appuie sur 🌐 fn, ce qui gênerait Dictate.")
            Instructions([
                "Ouvrez Réglages Système → Clavier.",
                "Réglez « Appuyer sur la touche 🌐 pour » sur « Ne rien faire ».",
            ])
            Button("Ouvrir les réglages Clavier") { Permissions.openKeyboardSettings() }
                .buttonStyle(.borderedProminent)

        case .whisperModel:
            Text("Whisper large-v3 turbo transcrit votre voix sur ce Mac, sans réseau. Le modèle se télécharge une seule fois (environ 630 Mo).")
            WhisperProgress(model: model)

        case .claude:
            Text("Claude Haiku retire les hésitations, corrige la ponctuation et l'orthographe de votre jargon, avec votre abonnement Claude. Dictate utilise la commande claude installée avec Claude Code ou l'app Claude.")
            if !model.settings.enhancementEnabled {
                Text("Dictate insère le texte brut de Whisper. Vous pourrez activer Claude dans les Réglages.")
                    .foregroundStyle(.secondary)
            } else if let path = model.claudeCLIPath {
                Text(path.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                HStack {
                    Link("Télécharger l'app Claude", destination: URL(string: "https://claude.ai/download")!)
                        .buttonStyle(.borderedProminent)
                    Button("Revérifier") {
                        model.refreshClaudeCLI()
                        model.refreshSetup()
                    }
                    Button("Continuer sans Claude") { model.continueWithoutClaude() }
                }
                Text("Connectez-vous une fois dans Claude Code ou l'app Claude, puis revérifiez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        case .whisperModel: "Modèle Whisper"
        case .claude: "Claude"
        }
    }

    var heading: String {
        switch self {
        case .microphone: "Accès au micro"
        case .inputMonitoring: "Surveillance de la touche fn"
        case .accessibility: "Insertion du texte"
        case .fnKey: "Libérer la touche 🌐"
        case .whisperModel: "Modèle de transcription"
        case .claude: "Correction par Claude"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .inputMonitoring: "keyboard"
        case .accessibility: "accessibility"
        case .fnKey: "globe"
        case .whisperModel: "waveform"
        case .claude: "sparkles"
        }
    }
}

private struct StepPage<Content: View>: View {
    let step: SetupStep
    let done: Bool
    let onContinue: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: step.symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.tint, in: .rect(cornerRadius: 14))

            HStack(alignment: .firstTextBaseline) {
                Text(step.heading).font(.title2.bold())
                if step.isOptional {
                    Text("Facultatif")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.secondary, in: .capsule)
                }
            }

            if done {
                Label("C'est fait", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            }

            content
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Text("Étape \(step.rawValue + 1) sur \(SetupStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if done {
                    Button("Continuer", action: onContinue)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

private struct Instructions: View {
    let lines: [String]

    init(_ lines: [String]) { self.lines = lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.bold().monospacedDigit())
                        .frame(width: 18, height: 18)
                        .background(.fill.secondary, in: .circle)
                    Text(line)
                }
            }
        }
    }
}

private struct WhisperProgress: View {
    let model: AppModel

    var body: some View {
        switch model.transcriber.state {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text("\(fraction.formatted(.percent.precision(.fractionLength(0)))) — environ \(Int(fraction * 630)) Mo sur 630")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .loading, .notLoaded:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.setup.whisperModel ? "Préparation du modèle pour ce Mac…" : "Connexion…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Réessayer") { model.retryWhisper() }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            EmptyView()
        }
    }
}

/// Last page: a scratch field to check the whole chain end to end.
private struct TryItPage: View {
    let model: AppModel
    let onFinish: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: model.setup.isComplete ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(model.setup.isComplete ? AnyShapeStyle(.green) : AnyShapeStyle(.tint), in: .rect(cornerRadius: 14))

            Text(model.setup.isComplete ? "Tout est prêt" : "Essayer").font(.title2.bold())
            Text("Cliquez dans le champ, maintenez fn, parlez, puis relâchez. Le texte apparaît là où se trouve le curseur, dans n'importe quelle app.")
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 110)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            status
                .font(.callout)

            Spacer()

            HStack {
                if !model.setup.isComplete {
                    Text("\(model.setup.pending.count) étape(s) restante(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.setup.isComplete ? "Commencer" : "Plus tard", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var status: some View {
        switch model.controller.phase {
        case .recording:
            Label("Je vous écoute…", systemImage: "mic.fill").foregroundStyle(.red)
        case .transcribing:
            Label("Transcription…", systemImage: "waveform").foregroundStyle(.secondary)
        case .enhancing:
            Label("Correction par Claude…", systemImage: "sparkles").foregroundStyle(.secondary)
        case .idle:
            if case .failed(let message) = model.transcriber.state {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if model.transcriber.state != .ready {
                Label("Whisper se prépare, encore un instant…", systemImage: "hourglass").foregroundStyle(.secondary)
            } else if !text.isEmpty, case .pasted = model.controller.lastOutcome {
                Label("Ça marche !", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Maintenez fn pour dicter", systemImage: "globe").foregroundStyle(.secondary)
            }
        }
    }
}
