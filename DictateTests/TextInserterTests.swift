import AppKit
import Testing
@testable import Dictate

/// On a pasteboard of its own, with the keys recorded rather than posted.
@MainActor
struct TextInserterTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("TextInserterTests-\(UUID().uuidString)"))
    private let keys = KeyLog()

    private func makeInserter() -> TextInserter {
        TextInserter(pasteboard: pasteboard, restoreDelay: .milliseconds(50)) { [keys] key, flags in keys.append(key, flags) }
    }

    private func waitForRestore() async throws { try await Task.sleep(for: .milliseconds(200)) }

    @Test func theUsersContentComesBackAfterThePaste() async throws {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("le texte de l'utilisateur", forType: .string)
        item.setData(Data("<b>riche</b>".utf8), forType: .html)
        pasteboard.writeObjects([item])

        let inserter = makeInserter()
        await inserter.paste("Dictée.", submit: false)
        #expect(pasteboard.string(forType: .string) == "Dictée.")
        #expect(keys.entries.count == 1)

        try await waitForRestore()
        #expect(pasteboard.string(forType: .string) == "le texte de l'utilisateur")
        #expect(pasteboard.data(forType: .html) == Data("<b>riche</b>".utf8))
    }

    /// Back-to-back dictations restore what the user had, not the first dictation.
    @Test func backToBackPastesRestoreTheUsersContent() async throws {
        pasteboard.clearContents()
        pasteboard.setString("à garder", forType: .string)
        let inserter = makeInserter()
        await inserter.paste("Un.", submit: false)
        await inserter.paste("Deux.", submit: false)
        try await waitForRestore()
        #expect(pasteboard.string(forType: .string) == "à garder")
    }

    /// The user copied something meanwhile: that wins.
    @Test func aNewCopyIsNotOverwritten() async throws {
        pasteboard.clearContents()
        pasteboard.setString("ancien", forType: .string)
        let inserter = makeInserter()
        await inserter.paste("Dictée.", submit: false)
        pasteboard.clearContents()
        pasteboard.setString("nouveau", forType: .string)
        try await waitForRestore()
        #expect(pasteboard.string(forType: .string) == "nouveau")
    }

    @Test func copyingLeavesTheTextInPlace() async throws {
        pasteboard.clearContents()
        pasteboard.setString("ancien", forType: .string)
        let inserter = makeInserter()
        inserter.copyToPasteboard("Dictée.")
        try await waitForRestore()
        #expect(pasteboard.string(forType: .string) == "Dictée.")
        #expect(keys.entries.isEmpty)
    }

    @Test func submitPressesReturnAfterThePaste() async {
        pasteboard.clearContents()
        let inserter = makeInserter()
        await inserter.paste("Envoyé.", submit: true)
        #expect(keys.entries.map(\.key) == [9, 36])
    }
}

@MainActor
private final class KeyLog {
    private(set) var entries: [(key: Int, flags: CGEventFlags)] = []
    func append(_ key: Int, _ flags: CGEventFlags) { entries.append((key, flags)) }
}
