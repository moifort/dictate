import Foundation

/// What the enhancer knows about where the dictation will be inserted.
nonisolated struct DictationContext: Equatable, Sendable {
    var category: AppCategory = .other
    /// Name of the frontmost app, e.g. "Slack".
    var appName: String?
    /// End of the text already in the focused field, up to the cursor.
    var precedingText: String?
    /// Start of the text after the cursor (or after the selection).
    var followingText: String?
    /// What the focused field is for, e.g. "Subject" or "Message #general".
    var fieldLabel: String?
    /// Title of the focused window: an email subject, a channel, a PR title.
    var windowTitle: String?
    /// Host of the browser tab, e.g. "mail.google.com". See `FieldContext.webHost`.
    var webHost: String?

    /// Adds what was read from the focused field. A known web app refines the
    /// category of a browser, which is `other` from its bundle ID alone.
    mutating func include(_ field: FieldContext) {
        precedingText = field.precedingText
        followingText = field.followingText
        fieldLabel = field.fieldLabel
        windowTitle = field.windowTitle
        webHost = field.webHost
        if category == .other, let host = field.webHost, let webCategory = AppCategory(webHost: host) {
            category = webCategory
        }
    }
}

/// What the Accessibility API exposes around the cursor, read when `fn` is released.
nonisolated struct FieldContext: Equatable, Sendable {
    var precedingText: String?
    var followingText: String?
    var fieldLabel: String?
    var windowTitle: String?
    /// The host only: paths and query strings can carry tokens, search terms or
    /// document names, and the host is enough to tell Gmail from GitHub.
    var webHost: String?

    /// The host of a web page, lowercased, or nil for anything but http(s)
    /// (`file:`, `about:`, `chrome:`…).
    static func webHost(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        return host
    }
}
