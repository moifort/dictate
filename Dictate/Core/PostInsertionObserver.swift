import Foundation

/// What a text field contained at one moment, as accessibility reports it.
nonisolated struct FieldSnapshot: Equatable, Sendable {
    var text: String
    /// Selection, or the caret when empty. UTF-16 units, like every AX range.
    var selection: NSRange
}

/// A text field that can be read again later, even once the focus moved on.
protocol ReadableField: AnyObject {
    /// Nil when the field is gone, became secure or no longer exposes its text.
    func snapshot() -> FieldSnapshot?
}

protocol FieldReading: AnyObject {
    /// The focused text field; nil for password fields and when nothing readable has focus.
    func focusedField() -> (any ReadableField)?
}

/// A field caught right before a paste, to be compared with what it becomes.
struct InsertionWatch {
    let field: any ReadableField
    let before: FieldSnapshot
}

/// The field before the paste and a few seconds after, once the user had
/// time to fix what was dictated.
nonisolated struct InsertionFollowUp: Equatable, Sendable {
    let before: FieldSnapshot
    let after: FieldSnapshot
    /// The text that was pasted.
    let inserted: String

    /// The pasted text as the user left it; see `InsertedSegment.locate`.
    var corrected: String? {
        InsertedSegment.locate(inserted: inserted, before: before, after: after.text)
    }
}

/// Re-reads the field a dictation was pasted into, `delay` later, to see what
/// the user made of it. Call `watchFocusedField()` right before pasting, then
/// `followUp(_:inserted:)` once the paste is posted.
///
/// A second dictation into the same field would blur the comparison: `settle()`
/// reads every waiting field at once, and should be called when one starts.
final class PostInsertionObserver {
    /// Long enough to fix a word or two, short enough to precede most sends.
    static let defaultDelay: Duration = .seconds(5)

    private let reader: any FieldReading
    private let delay: Duration
    private var waiting: [UUID: Waiter] = [:]

    private struct Waiter {
        let watch: InsertionWatch
        let inserted: String
        let continuation: CheckedContinuation<InsertionFollowUp?, Never>
    }

    init(reader: any FieldReading, delay: Duration = PostInsertionObserver.defaultDelay) {
        self.reader = reader
        self.delay = delay
    }

    /// The focused field and its content. Nil when it cannot be read.
    func watchFocusedField() -> InsertionWatch? {
        guard let field = reader.focusedField(), let before = field.snapshot() else { return nil }
        return InsertionWatch(field: field, before: before)
    }

    /// Waits for `delay`, or for `settle()`, then reads the field again.
    /// Nil when the field could not be read by then.
    func followUp(_ watch: InsertionWatch, inserted: String) async -> InsertionFollowUp? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiting[id] = Waiter(watch: watch, inserted: inserted, continuation: continuation)
            Task { [delay] in
                try? await Task.sleep(for: delay)
                self.complete(id)
            }
        }
    }

    /// Reads every waiting field now.
    func settle() {
        for id in Array(waiting.keys) { complete(id) }
    }

    var hasPendingFollowUps: Bool { !waiting.isEmpty }

    private func complete(_ id: UUID) {
        guard let waiter = waiting.removeValue(forKey: id) else { return }
        let followUp = waiter.watch.field.snapshot().map {
            InsertionFollowUp(before: waiter.watch.before, after: $0, inserted: waiter.inserted)
        }
        waiter.continuation.resume(returning: followUp)
    }
}

/// Finds what became of a pasted text in the field it was pasted into.
///
/// The paste replaced the selection of `before`, so the field then read
/// `prefix + inserted + suffix`. Whatever lies between the prefix and the
/// suffix in `after` is the inserted text with the user's fixes:
///
/// 1. When `after` still starts with the whole prefix and ends with the whole
///    suffix, the segment is what lies between them: edits stayed inside it.
/// 2. Otherwise the user also edited around it. The segment starts after the
///    last `anchorLength` characters of the prefix, at their occurrence nearest
///    to where the prefix used to end, and ends before the first characters of
///    the suffix, searched after that start. A missing anchor falls back to
///    the part of the prefix (or suffix) left unchanged, which can include
///    edits next to the segment.
/// 3. An empty field (a chat message sent) or a segment far longer than the
///    pasted text (the field now holds something else) yields nil: no
///    reference beats a wrong one.
nonisolated enum InsertedSegment {
    static let anchorLength = 32

    static func locate(inserted: String, before: FieldSnapshot, after: String) -> String? {
        let text = before.text as NSString
        guard before.selection.location != NSNotFound, NSMaxRange(before.selection) <= text.length else { return nil }
        let prefix = text.substring(to: before.selection.location)
        let suffix = text.substring(from: NSMaxRange(before.selection))
        guard !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let segment: Substring
        if after.count >= prefix.count + suffix.count, after.hasPrefix(prefix), after.hasSuffix(suffix) {
            segment = after.dropFirst(prefix.count).dropLast(suffix.count)
        } else {
            let start = segmentStart(prefix: prefix, after: after)
            guard let end = segmentEnd(suffix: suffix, after: after, from: start), start <= end else { return nil }
            segment = after[start..<end]
        }

        let corrected = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected.count <= inserted.count * 3 + 40 else { return nil }
        return corrected
    }

    private static func segmentStart(prefix: String, after: String) -> String.Index {
        guard !prefix.isEmpty else { return after.startIndex }
        let anchor = String(prefix.suffix(anchorLength))
        let expected = after.index(after.startIndex, offsetBy: min(prefix.count, after.count))
        let matches = after.ranges(of: anchor)
        if let nearest = matches.min(by: { distance(after, $0.upperBound, expected) < distance(after, $1.upperBound, expected) }) {
            return nearest.upperBound
        }
        return after.index(after.startIndex, offsetBy: commonPrefixLength(prefix, after))
    }

    private static func segmentEnd(suffix: String, after: String, from start: String.Index) -> String.Index? {
        guard !suffix.isEmpty else { return after.endIndex }
        let anchor = String(suffix.prefix(anchorLength))
        if let match = after[start...].firstRange(of: anchor) {
            return match.lowerBound
        }
        let kept = commonPrefixLength(String(suffix.reversed()), String(after.reversed()))
        return after.index(after.endIndex, offsetBy: -kept)
    }

    private static func distance(_ text: String, _ a: String.Index, _ b: String.Index) -> Int {
        abs(text.distance(from: a, to: b))
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}
