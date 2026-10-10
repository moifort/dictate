import Testing
@testable import Dictate

struct AppCategoryTests {
    @Test(arguments: [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.jetbrains.intellij",
        "com.anthropic.claudefordesktop",
    ])
    func developerToolsAreCode(bundleID: String) {
        #expect(AppCategory(bundleID: bundleID) == .code)
    }

    @Test(arguments: ["com.apple.mail", "com.microsoft.Outlook"])
    func mailClientsAreMail(bundleID: String) {
        #expect(AppCategory(bundleID: bundleID) == .mail)
    }

    @Test(arguments: ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp"])
    func messagingAppsAreChat(bundleID: String) {
        #expect(AppCategory(bundleID: bundleID) == .chat)
    }

    @Test func unknownOrMissingBundleIsOther() {
        #expect(AppCategory(bundleID: "com.apple.Safari") == .other)
        #expect(AppCategory(bundleID: nil) == .other)
    }
}
