import Foundation

/// Coarse category of the frontmost app, used to adapt the tone of the cleanup.
nonisolated enum AppCategory: String, CaseIterable, Sendable {
    case code
    case mail
    case chat
    case other

    init(bundleID: String?) {
        guard let bundleID else {
            self = .other
            return
        }
        if Self.codeBundleIDs.contains(bundleID) || Self.codeBundlePrefixes.contains(where: bundleID.hasPrefix) {
            self = .code
        } else if Self.mailBundleIDs.contains(bundleID) {
            self = .mail
        } else if Self.chatBundleIDs.contains(bundleID) {
            self = .chat
        } else {
            self = .other
        }
    }

    private static let codeBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "io.alacritty",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.anthropic.claudefordesktop",
    ]

    private static let codeBundlePrefixes = ["com.jetbrains.", "com.google.android.studio"]

    private static let mailBundleIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",
        "com.superhuman.electron",
    ]

    private static let chatBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
        "com.apple.MobileSMS",
        "com.microsoft.teams2",
        "org.whispersystems.signal-desktop",
    ]
}
