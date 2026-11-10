import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A spinner and a sentence: a model downloading or loading.
struct ProgressStatus: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What failed and a button to try again.
struct RetryRow: View {
    let message: LocalizedStringKey
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Réessayer", action: retry)
                .controlSize(.small)
        }
        .font(.callout)
    }
}

/// A reviewer's state on one line, with the button that tries it on a
/// sample dictation, and room for the reviewer's own buttons.
struct ReviewerStatusRow<Title: View, Extra: View>: View {
    let ready: Bool
    /// Still being checked: a spinner instead of the verdict.
    var checking = false
    let canTest: Bool
    let test: () -> Void
    @ViewBuilder let title: Title
    @ViewBuilder let extra: Extra

    init(
        ready: Bool, checking: Bool = false, canTest: Bool, test: @escaping () -> Void,
        @ViewBuilder title: () -> Title, @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) {
        self.ready = ready
        self.checking = checking
        self.canTest = canTest
        self.test = test
        self.title = title()
        self.extra = extra()
    }

    var body: some View {
        HStack(spacing: 8) {
            if checking {
                ProgressView().controlSize(.small)
            } else if ready {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            title
            Spacer()
            Button("Tester", action: test)
                .disabled(!canTest)
            extra
        }
    }
}

extension BinaryFloatingPoint {
    /// "42 %": every progress and share the app shows.
    var percentText: String {
        Double(self).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The open panel for picking one file, brought to the front.
enum FilePicker {
    static func chooseFile(
        types: [UTType] = [],
        in directory: URL? = nil,
        message: String,
        prompt: String,
        insidePackages: Bool = false
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.treatsFilePackagesAsDirectories = insidePackages
        panel.showsHiddenFiles = insidePackages
        panel.directoryURL = directory
        panel.message = message
        panel.prompt = prompt
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
