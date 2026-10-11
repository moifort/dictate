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

    func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    func hasEditableFocus() -> Bool {
        guard let focused = focusedElement() else { return false }

        if let role = copyString(focused, kAXRoleAttribute), Self.textRoles.contains(role) {
            return true
        }
        // Rich editors and web `contenteditable` expose a selection and a settable value.
        var settable: DarwinBoolean = false
        let hasSelection = copyValue(focused, kAXSelectedTextRangeAttribute) != nil
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        return hasSelection && settable.boolValue
    }

    func precedingText(maxLength: Int) -> String? {
        guard let focused = focusedElement(), !isSecure(focused) else { return nil }
        guard let rangeValue = copyValue(focused, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location > 0 else { return nil }

        let start = max(0, selection.location - maxLength)
        var range = CFRange(location: start, length: selection.location - start)
        // Asking for the range only avoids copying a whole document (Xcode, Notes).
        if let rangeArgument = AXValueCreate(.cfRange, &range) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                focused, kAXStringForRangeParameterizedAttribute as CFString, rangeArgument, &value
            ) == .success, let text = value as? String {
                return text
            }
        }
        // AX ranges count UTF-16 units, like NSString.
        guard let value = copyString(focused, kAXValueAttribute) as NSString?,
              range.location + range.length <= value.length else { return nil }
        return value.substring(with: NSRange(location: range.location, length: range.length))
    }

    private func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // A busy app would otherwise block the dictation for the default 6 s.
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        return copyElement(appElement, kAXFocusedUIElementAttribute)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        return copyString(element, kAXSubroleAttribute) == secure || copyString(element, kAXRoleAttribute) == secure
    }

    private func enableManualAccessibility(for pid: pid_t) {
        guard !electronEnabledPIDs.contains(pid) else { return }
        electronEnabledPIDs.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
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
