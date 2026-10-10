import AppKit
import ApplicationServices

/// Uses the Accessibility API to find out whether a text field has focus.
final class FocusInspector: FocusInspecting {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    private var electronEnabledPIDs: Set<pid_t> = []

    /// Also turns on the accessibility tree of Electron apps (VS Code, Slack…),
    /// which they only build on request; it is ready by the time `fn` is released.
    func frontmostBundleID() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        enableManualAccessibility(for: app.processIdentifier)
        return app.bundleIdentifier
    }

    func hasEditableFocus() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = copyElement(appElement, kAXFocusedUIElementAttribute) else { return false }

        if let role = copyString(focused, kAXRoleAttribute), Self.textRoles.contains(role) {
            return true
        }
        // Rich editors and web `contenteditable` expose a selection and a settable value.
        var settable: DarwinBoolean = false
        let hasSelection = copyValue(focused, kAXSelectedTextRangeAttribute) != nil
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        return hasSelection && settable.boolValue
    }

    private func enableManualAccessibility(for pid: pid_t) {
        guard !electronEnabledPIDs.contains(pid) else { return }
        electronEnabledPIDs.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }
}
