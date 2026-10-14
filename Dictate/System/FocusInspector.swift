import AppKit
import ApplicationServices

/// Uses the Accessibility API to find out whether a text field has focus.
final class FocusInspector: FocusInspecting, FieldReading {
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
        let ax = AXReader()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let focused = ax.focusedElement(pid: pid) else { return false }

        if let role = ax.copyString(focused, kAXRoleAttribute), Self.textRoles.contains(role) {
            return true
        }
        // Rich editors and web `contenteditable` expose a selection and a settable value.
        var settable: DarwinBoolean = false
        let hasSelection = ax.copyValue(focused, kAXSelectedTextRangeAttribute) != nil
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        return hasSelection && settable.boolValue
    }

    func fieldContext(maxLength: Int) async -> FieldContext {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return FieldContext() }
        return await Self.fieldContext(pid: pid, maxLength: maxLength)
    }

    private nonisolated static let readBudget = Duration.seconds(1)

    /// Off the main actor: an Electron app can hold each call for the whole
    /// messaging timeout, and the transcription runs meanwhile.
    @concurrent
    private nonisolated static func fieldContext(pid: pid_t, maxLength: Int) async -> FieldContext {
        // A busy app would otherwise block the dictation for the default 6 s per
        // call; the budget caps the whole read, whatever the number of calls.
        AXReader(deadline: .now + readBudget).fieldContext(pid: pid, maxLength: maxLength)
    }

    func focusedField() -> (any ReadableField)? {
        let ax = AXReader()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let focused = ax.focusedElement(pid: pid), !ax.isSecure(focused) else { return nil }
        return AccessibilityField(element: focused)
    }

    private func enableManualAccessibility(for pid: pid_t) {
        guard !electronEnabledPIDs.contains(pid) else { return }
        electronEnabledPIDs.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

/// Accessibility reads, optionally capped by a deadline. Not shared between
/// threads: each read builds its own.
private nonisolated final class AXReader {
    static let messagingTimeout: Float = 0.5
    /// Web pages nest deeply; past this, the focused element is not in a page.
    private static let maxWebAreaDepth = 60

    private var deadline: ContinuousClock.Instant?

    init(deadline: ContinuousClock.Instant? = nil) {
        self.deadline = deadline
    }

    func fieldContext(pid: pid_t, maxLength: Int) -> FieldContext {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        let window = copyElement(appElement, kAXFocusedWindowAttribute)
        let focused = copyElement(appElement, kAXFocusedUIElementAttribute)

        var field = FieldContext()
        field.windowTitle = window.flatMap { nonEmpty(copyString($0, kAXTitleAttribute)) }
        if let focused, !isSecure(focused) {
            if let selection = selectedRange(focused) {
                field.precedingText = precedingText(focused, selection: selection, maxLength: maxLength)
                field.followingText = followingText(focused, selection: selection, maxLength: maxLength)
            }
            field.fieldLabel = label(of: focused)
        }
        field.webHost = webHost(focused: focused, window: window)
        return field
    }

    func focusedElement(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        return copyElement(appElement, kAXFocusedUIElementAttribute)
    }


    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = copyValue(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private func precedingText(_ element: AXUIElement, selection: CFRange, maxLength: Int) -> String? {
        guard selection.location > 0 else { return nil }
        let start = max(0, selection.location - maxLength)
        return string(element, in: CFRange(location: start, length: selection.location - start))
    }

    /// The text after the selection, which the dictation will replace.
    private func followingText(_ element: AXUIElement, selection: CFRange, maxLength: Int) -> String? {
        let start = selection.location + max(0, selection.length)
        if let total = copyValue(element, kAXNumberOfCharactersAttribute) as? Int {
            guard start < total else { return nil }
            return string(element, in: CFRange(location: start, length: min(maxLength, total - start)))
        }
        // Without a length, only the whole value tells where the text ends.
        guard let value = copyString(element, kAXValueAttribute) as NSString?, start < value.length else { return nil }
        return value.substring(with: NSRange(location: start, length: min(maxLength, value.length - start)))
    }

    private func string(_ element: AXUIElement, in range: CFRange) -> String? {
        var range = range
        // Asking for the range only avoids copying a whole document (Xcode, Notes).
        if let rangeArgument = AXValueCreate(.cfRange, &range), isWithinBudget() {
            var value: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, rangeArgument, &value
            )
            noteTimeout(result)
            if result == .success, let text = value as? String {
                return text
            }
        }
        // AX ranges count UTF-16 units, like NSString.
        guard let value = copyString(element, kAXValueAttribute) as NSString?,
              range.location + range.length <= value.length else { return nil }
        return value.substring(with: NSRange(location: range.location, length: range.length))
    }

    /// What the field is for: its placeholder, its accessibility label, or the label next to it.
    private func label(of element: AXUIElement) -> String? {
        for attribute in [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute] {
            if let label = nonEmpty(copyString(element, attribute)) { return label }
        }
        guard let titleElement = copyElement(element, kAXTitleUIElementAttribute) else { return nil }
        return nonEmpty(copyString(titleElement, kAXValueAttribute)) ?? nonEmpty(copyString(titleElement, kAXTitleAttribute))
    }

    /// The host of the page in a browser (or an Electron app). Safari exposes the
    /// page as the window's document; Chromium and Firefox only on the web area
    /// holding the focus, whose outermost one is the tab (inner ones are iframes).
    private func webHost(focused: AXUIElement?, window: AXUIElement?) -> String? {
        if let window, let url = url(copyValue(window, kAXDocumentAttribute)), let host = FieldContext.webHost(of: url) {
            return host
        }
        var pageURL: URL?
        var element = focused
        for _ in 0..<Self.maxWebAreaDepth {
            guard let current = element else { break }
            let role = copyString(current, kAXRoleAttribute)
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            if role == "AXWebArea", let url = url(copyValue(current, kAXURLAttribute)) {
                pageURL = url
            }
            element = copyElement(current, kAXParentAttribute)
        }
        return pageURL.flatMap(FieldContext.webHost(of:))
    }

    private func url(_ value: CFTypeRef?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func isSecure(_ element: AXUIElement) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        return copyString(element, kAXSubroleAttribute) == secure || copyString(element, kAXRoleAttribute) == secure
    }

    private func isWithinBudget() -> Bool {
        deadline.map { ContinuousClock.now < $0 } ?? true
    }

    /// An app that let one call time out is busy: skip the remaining reads.
    private func noteTimeout(_ result: AXError) {
        if result == .cannotComplete, deadline != nil { deadline = .now }
    }

    func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard isWithinBudget() else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        noteTimeout(result)
        return result == .success ? value : nil
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let child = value as! AXUIElement
        // The timeout is per element, not inherited from the app element.
        AXUIElementSetMessagingTimeout(child, Self.messagingTimeout)
        return child
    }

    func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }
}

/// A text field held by its accessibility element, so that it can be read
/// again after the user moved to another field or app.
private final class AccessibilityField: ReadableField {
    /// Beyond this, the field is a document rather than a message: not worth copying.
    private static let maxLength = 200_000

    private let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    func snapshot() -> FieldSnapshot? {
        let ax = AXReader()
        guard !ax.isSecure(element),
              let text = ax.copyString(element, kAXValueAttribute) else { return nil }
        let length = (text as NSString).length
        guard length <= Self.maxLength else { return nil }
        // Without a selection, assume the caret sits at the end, where a paste usually lands.
        var selection = CFRange(location: length, length: 0)
        if let value = ax.copyValue(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cfRange, &selection)
        }
        return FieldSnapshot(text: text, selection: NSRange(location: selection.location, length: selection.length))
    }
}
