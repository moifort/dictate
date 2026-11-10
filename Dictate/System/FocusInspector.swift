#if !APP_STORE
import AppKit
import ApplicationServices

/// Uses the Accessibility API to find out whether a text field has focus.
///
/// Every read runs off the main actor under one overall deadline: an app
/// that is slow to answer (Electron, a busy browser) can hold each call for
/// the whole messaging timeout, and the reads sit right before the paste.
final class FocusInspector: FocusInspecting, FieldReading {
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

    func hasEditableFocus() async -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return await AXReader.read { $0.hasEditableFocus(pid: pid) }
    }

    func fieldContext(maxLength: Int) async -> FieldContext {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return FieldContext() }
        return await AXReader.read { $0.fieldContext(pid: pid, maxLength: maxLength) }
    }

    func focusedField() async -> (any ReadableField)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let focused = await AXReader.read({ ax in
                  ax.focusedElement(pid: pid).flatMap { ax.isSecure($0) ? nil : AXElement($0) }
              })
        else { return nil }
        return AccessibilityField(element: focused)
    }

    /// Off the main actor and not awaited: the app builds its tree in the background.
    private func enableManualAccessibility(for pid: pid_t) {
        guard !electronEnabledPIDs.contains(pid) else { return }
        electronEnabledPIDs.insert(pid)
        Task.detached(priority: .userInitiated) {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, AXReader.defaultMessagingTimeout)
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }
}

/// An accessibility element handed from one thread to another. Each read
/// uses it from one thread at a time, which the AX API allows.
nonisolated struct AXElement: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

/// Accessibility reads, optionally capped by a deadline. Not shared between
/// threads: each read builds its own.
nonisolated final class AXReader {
    /// How long one call may wait for an app, in seconds: the system's 6 s
    /// would hold a dictation for an app that is busy.
    static let defaultMessagingTimeout: Float = 0.5

    private let messagingTimeout: Float
    /// Web pages nest deeply; past this, the focused element is not in a page.
    private static let maxWebAreaDepth = 60

    /// The overall time one read may take, whatever the number of calls: a
    /// busy app would otherwise block for the default 6 s per call.
    static let readBudget = Duration.seconds(1)

    private var deadline: ContinuousClock.Instant?

    init(deadline: ContinuousClock.Instant? = nil, messagingTimeout: Float = AXReader.defaultMessagingTimeout) {
        self.deadline = deadline
        self.messagingTimeout = messagingTimeout
    }

    /// The app's focused window.
    func focusedWindow(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        return copyElement(appElement, kAXFocusedWindowAttribute)
    }

    func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Runs `body` off the main actor with a reader capped by `budget`.
    @concurrent
    static func read<T: Sendable>(budget: Duration = readBudget, _ body: @Sendable (AXReader) -> T) async -> T {
        body(AXReader(deadline: .now + budget))
    }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]
    private static let webAreaRole = "AXWebArea"
    private static let selectedTextMarkerRange = "AXSelectedTextMarkerRange"

    func hasEditableFocus(pid: pid_t) -> Bool {
        guard let focused = focusedElement(pid: pid) else { return false }
        let role = copyString(focused, kAXRoleAttribute)
        if let role, Self.textRoles.contains(role) {
            return true
        }
        // Rich editors and web `contenteditable` expose a selection and a settable value.
        let settable = isSettable(focused, kAXValueAttribute)
        let hasSelection = copyValue(focused, kAXSelectedTextRangeAttribute) != nil
            // A page edited as a whole (Mail's message body) is focused as its web
            // area, which only exposes text markers; its value is settable when editable.
            || (role == Self.webAreaRole && copyValue(focused, Self.selectedTextMarkerRange) != nil)
        let editable = hasSelection && settable
        if !editable {
            Log.dictation.notice("no editable focus: role \(role ?? "none", privacy: .public), selection \(hasSelection), settable \(settable), in time \(self.isWithinBudget())")
        }
        return editable
    }

    func fieldContext(pid: pid_t, maxLength: Int) -> FieldContext {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
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
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
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

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        guard isWithinBudget() else { return false }
        var settable: DarwinBoolean = false
        noteTimeout(AXUIElementIsAttributeSettable(element, attribute as CFString, &settable))
        return settable.boolValue
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
        AXUIElementSetMessagingTimeout(child, messagingTimeout)
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
    private nonisolated static let maxLength = 200_000

    private let element: AXElement

    init(element: AXElement) {
        self.element = element
    }

    func snapshot() async -> FieldSnapshot? {
        await AXReader.read { [element] ax in Self.snapshot(element.element, ax) }
    }

    private nonisolated static func snapshot(_ element: AXUIElement, _ ax: AXReader) -> FieldSnapshot? {
        guard !ax.isSecure(element) else { return nil }
        // The length first: a document's whole text (Xcode, Notes) is not
        // worth copying, and the field is read twice per dictation.
        let count = ax.copyValue(element, kAXNumberOfCharactersAttribute) as? Int
        guard count.map({ $0 <= maxLength }) ?? true,
              let text = ax.copyString(element, kAXValueAttribute) else { return nil }
        let length = (text as NSString).length
        // Not every app reports the length: the copy is checked too.
        guard length <= maxLength else { return nil }
        // Without a selection, assume the caret sits at the end, where a paste usually lands.
        var selection = CFRange(location: length, length: 0)
        if let value = ax.copyValue(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cfRange, &selection)
        }
        return FieldSnapshot(text: text, selection: NSRange(location: selection.location, length: selection.length))
    }
}
#endif
