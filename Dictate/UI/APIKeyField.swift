import SwiftUI

/// Types and saves a provider's API key. Saved on submit only: the keychain
/// is not written on every keystroke.
struct APIKeyField: View {
    let model: AppModel
    let provider: APIProvider
    @State private var draft = ""

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 8) {
            // A form in columns would show the title as a label: the placeholder goes in the prompt.
            SecureField("Clé API \(provider.displayName)", text: $draft, prompt: Text(verbatim: provider.keyPlaceholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit(save)
            Button("Enregistrer", action: save)
                .disabled(trimmed.isEmpty)
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        model.saveAPIKey(trimmed, for: provider)
        draft = ""
    }

    /// `sk-ant-api…wxyz`: enough to recognise the key, not to use it.
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return "••••" }
        return "\(key.prefix(10))…\(key.suffix(4))"
    }
}
