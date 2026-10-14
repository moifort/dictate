import Foundation
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

    @Test(arguments: [
        ("mail.google.com", AppCategory.mail), ("outlook.office.com", .mail), ("app.fastmail.com", .mail),
        ("app.slack.com", .chat), ("acme.slack.com", .chat), ("discord.com", .chat), ("web.whatsapp.com", .chat),
        ("github.com", .code), ("gist.github.com", .code), ("www.github.com", .code), ("GitLab.com", .code),
        ("github.com.", .code),
    ])
    func webAppsAreCategorizedByHost(host: String, category: AppCategory) {
        #expect(AppCategory(webHost: host) == category)
    }

    @Test(arguments: ["www.google.com", "google.com", "notgithub.com", "github.com.evil.example", "docs.google.com", ""])
    func unknownHostsHaveNoCategory(host: String) {
        #expect(AppCategory(webHost: host) == nil)
    }

    @Test func webHostKeepsTheHostOnly() throws {
        let url = try #require(URL(string: "https://Mail.Google.com/mail/u/0/?token=secret#inbox/123"))
        #expect(FieldContext.webHost(of: url) == "mail.google.com")
    }

    @Test(arguments: ["file:///Users/me/notes.txt", "about:blank", "chrome://settings", "vscode-file://vscode-app/index.html"])
    func nonWebURLsHaveNoHost(string: String) throws {
        let url = try #require(URL(string: string))
        #expect(FieldContext.webHost(of: url) == nil)
    }

    @Test func browserTabRefinesOnlyAnUncategorizedApp() {
        var browser = DictationContext(category: .other)
        browser.include(FieldContext(webHost: "github.com"))
        #expect(browser.category == .code)
        #expect(browser.webHost == "github.com")

        var slack = DictationContext(category: .chat)
        slack.include(FieldContext(webHost: "github.com"))
        #expect(slack.category == .chat)

        var unknownSite = DictationContext(category: .other)
        unknownSite.include(FieldContext(webHost: "example.com"))
        #expect(unknownSite.category == .other)
    }
}
