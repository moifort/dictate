import AppKit
import Carbon.HIToolbox

/// Inserts text by pasting it, which works in every kind of app, then puts
/// the user's previous pasteboard content back.
final class TextInserter: TextInserting {
    /// Marks our temporary content so clipboard managers ignore it.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Between the paste and Return: Electron apps read the pasteboard on
    /// `Cmd+V`, and a Return handled first would send the field without it.
    private static let submitDelay: Duration = .milliseconds(150)

    /// Set on the `Cmd+V` and Return events we post, so the push-to-talk monitor ignores
    /// them: a paste landing early in the next dictation's press must not
    /// read as a shortcut and cancel it.
    nonisolated static let eventMarker: Int64 = 0x4449_4354

    /// How long the target app has to read the pasteboard after `Cmd+V`.
    /// A fixed delay: macOS tells no one when another app reads it, and a
    /// data promise would be read early by clipboard managers too.
    static let defaultRestoreDelay: Duration = .milliseconds(400)

    private let pasteboard: NSPasteboard
    private let restoreDelay: Duration
    /// Posts a key with its modifiers; injected so tests never type into the Mac.
    private let postKey: (Int, CGEventFlags) -> Void
    /// The user's content while one of our pastes waits to be undone.
    private var pendingRestore: (saved: [[NSPasteboard.PasteboardType: Data]], task: Task<Void, Never>)?

    init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: Duration = TextInserter.defaultRestoreDelay,
        postKey: ((Int, CGEventFlags) -> Void)? = nil
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.postKey = postKey ?? Self.postSystemKey
    }

    func paste(_ text: String, submit: Bool) async {
        // Back-to-back dictations: the pasteboard still holds the previous
        // text, so the user's content saved for it is the one to put back.
        let saved = pendingRestore?.saved ?? snapshot()
        pendingRestore?.task.cancel()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transientType)
        let ourChange = pasteboard.changeCount

        #if !APP_STORE
        postKey(kVK_ANSI_V, .maskCommand)
        if submit {
            try? await Task.sleep(for: Self.submitDelay)
            // No flags: Shift or Command held with Return mean a new line or
            // something else in most composers.
            postKey(kVK_Return, [])
        }
        #endif
        // The dictation is over for the user once Cmd+V is posted. The target
        // app needs a moment to read the pasteboard, so it is restored later,
        // off the critical path.
        let task = Task { [self, restoreDelay] in
            try? await Task.sleep(for: restoreDelay)
            guard !Task.isCancelled else { return }
            pendingRestore = nil
            guard pasteboard.changeCount == ourChange else { return }
            restore(saved)
        }
        pendingRestore = (saved, task)
    }

    func copyToPasteboard(_ text: String) {
        // The text is meant to stay: nothing is put back over it.
        pendingRestore?.task.cancel()
        pendingRestore = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func postSystemKey(_ key: Int, flags: CGEventFlags) {
        #if !APP_STORE
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(key)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event?.post(tap: .cghidEventTap)
        }
        #endif
    }

    private func snapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            // An app can declare a type twice: the first one is kept rather than trapping.
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }) { first, _ in first }
        }
    }

    private func restore(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        })
    }
}
