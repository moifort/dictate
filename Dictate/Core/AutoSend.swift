import Foundation

/// Apps where a dictation is a message to send: once the text is pasted,
/// Return is pressed for the user. Claude's composer sends on Return and
/// keeps Shift+Return for a new line, so a dictation never needs a lone
/// Return there.
nonisolated enum AutoSend {
    static let bundleIDs: Set<String> = [
        "com.anthropic.claudefordesktop",
    ]

    static func applies(to bundleID: String?) -> Bool {
        bundleID.map(bundleIDs.contains) ?? false
    }
}
