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

    /// The category of a web app from its host, e.g. "mail.google.com" → mail;
    /// nil for sites with no clear tone. "www." and subdomains of a listed
    /// domain match it ("acme.slack.com" → chat).
    init?(webHost: String) {
        var host = webHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        for (domain, category) in Self.webDomains where host == domain || host.hasSuffix("." + domain) {
            self = category
            return
        }
        return nil
    }

    private static let webDomains: [(String, AppCategory)] = [
        ("mail.google.com", .mail),
        ("outlook.live.com", .mail),
        ("outlook.office.com", .mail),
        ("outlook.office365.com", .mail),
        ("mail.proton.me", .mail),
        ("app.fastmail.com", .mail),
        ("mail.yahoo.com", .mail),
        ("app.hey.com", .mail),
        ("mail.superhuman.com", .mail),

        ("slack.com", .chat),
        ("discord.com", .chat),
        ("web.whatsapp.com", .chat),
        ("web.telegram.org", .chat),
        ("teams.microsoft.com", .chat),
        ("teams.live.com", .chat),
        ("chat.google.com", .chat),
        ("messenger.com", .chat),

        ("github.com", .code),
        ("github.dev", .code),
        ("gitlab.com", .code),
        ("bitbucket.org", .code),
        ("codeberg.org", .code),
        ("vscode.dev", .code),
        ("stackoverflow.com", .code),
        ("claude.ai", .code),
    ]

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
