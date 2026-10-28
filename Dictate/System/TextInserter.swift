import AppKit
import Carbon.HIToolbox

/// Inserts text by pasting it, which works in every kind of app, then puts
/// the user's previous pasteboard content back.
final class TextInserter: TextInserting {
    /// Marks our temporary content so clipboard managers ignore it.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Set on the `Cmd+V` events we post, so the push-to-talk monitor ignores
    /// them: a paste landing early in the next dictation's press must not
    /// read as a shortcut and cancel it.
    nonisolated static let eventMarker: Int64 = 0x4449_4354

    private let pasteboard = NSPasteboard.general
    /// The user's content while one of our pastes waits to be undone.
    private var pendingRestore: (saved: [[NSPasteboard.PasteboardType: Data]], task: Task<Void, Never>)?

    func paste(_ text: String) async {
        // Back-to-back dictations: the pasteboard still holds the previous
        // text, so the user's content saved for it is the one to put back.
        let saved = pendingRestore?.saved ?? snapshot()
        pendingRestore?.task.cancel()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transientType)
        let ourChange = pasteboard.changeCount

        postCommandV()
        // The dictation is over for the user once Cmd+V is posted. The target
        // app needs a moment to read the pasteboard, so it is restored later,
        // off the critical path.
        let task = Task { [self] in
            try? await Task.sleep(for: .milliseconds(400))
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

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func snapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
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
