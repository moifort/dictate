import SwiftUI

/// Types and saves an Anthropic API key, for Claude without a subscription.
/// Saved on submit only: the keychain is not written on every keystroke.
struct APIKeyField: View {
    let model: AppModel
    @State private var draft = ""

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 8) {
            SecureField("sk-ant-…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit(save)
            Button("Enregistrer", action: save)
                .disabled(trimmed.isEmpty)
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        model.saveAPIKey(trimmed)
        draft = ""
    }

    /// `sk-ant-api03-…wxyz`: enough to recognise the key, not to use it.
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return "••••" }
        return "\(key.prefix(10))…\(key.suffix(4))"
    }
}
