import SwiftUI

/// What is new, and a button to install it.
struct UpdateView: View {
    let updater: Updater
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title.weight(.semibold))
                Text("Vous utilisez la version \(updater.currentVersion).")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            status

            HStack {
                Spacer()
                Button("Plus tard") { dismissWindow(id: "update") }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Installer et relancer") { updater.install() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.available == nil || updater.isBusy || !updater.canInstall)
            }
            .controlSize(.large)
        }
        .padding(36)
        .frame(width: 520)
        .animation(.snappy, value: updater.state)
    }

    private var title: String {
        if updater.state == .checking { return String(localized: "Recherche en cours") }
        return updater.available.map { "Dictate \($0.version)" } ?? String(localized: "Dictate est à jour")
    }

    private var notes: AttributedString {
        let markdown = updater.releases.reversed().map { "**\($0.version)**\n\n\($0.notes.isEmpty ? String(localized: "Pas de notes.") : $0.notes)" }
            .joined(separator: "\n\n")
        return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Recherche de mises à jour…").font(.caption).foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Téléchargement…").font(.caption).foregroundStyle(.secondary) }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installation…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        default:
            if !updater.canInstall {
                Text("Cette copie tourne depuis un dossier de build : installez-la dans Applications pour la mettre à jour.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
