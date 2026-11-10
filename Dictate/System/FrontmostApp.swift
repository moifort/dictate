import AppKit

/// The App Store build's `FocusInspector`: it knows which app is in front,
/// never what its fields contain. Without Accessibility (guideline 2.4.5) no
/// field can be read, so every dictation stays in the pasteboard.
final class FrontmostApp: FocusInspecting, FieldReading {
    func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    func fieldContext(maxLength: Int) async -> FieldContext { FieldContext() }

    func hasEditableFocus() async -> Bool { false }

    func focusedField() async -> (any ReadableField)? { nil }
}
