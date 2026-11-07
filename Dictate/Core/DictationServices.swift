import Foundation
import DictateKit

/// Captures microphone audio as 16 kHz mono samples.
protocol AudioRecording: AnyObject {
    /// Returns once the microphone delivers sound, or gives up waiting for
    /// it. Cancelling the calling task cuts that wait short.
    func start() async throws
    /// Stops recording and returns everything captured since `start()`.
    func stop() -> [Float]
}

@MainActor protocol Transcriber: AnyObject, Sendable {
    /// `language` is the ISO 639-1 code of the dictated language.
    func transcribe(samples: [Float], language: String) async throws -> String
    /// The same text, with the confidence of each word when the engine reports it.
    func transcription(samples: [Float], language: String) async throws -> Transcription
}

extension Transcriber {
    /// For engines without per-word confidence.
    func transcription(samples: [Float], language: String) async throws -> Transcription {
        Transcription(text: try await transcribe(samples: samples, language: language))
    }
}

@MainActor protocol Enhancer: AnyObject, Sendable {
    /// Must honour task cancellation: the controller cancels on timeout.
    func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String
}

extension Enhancer {
    func enhance(transcript: String, context: DictationContext) async throws -> String {
        try await enhance(Transcription(text: transcript), context: context)
    }
}

protocol FocusInspecting: AnyObject {
    func frontmostBundleID() -> String?
    func frontmostAppName() -> String?
    /// The focused field's surroundings: up to `maxLength` characters on each
    /// side of the cursor, its label, the window title and the page host.
    /// Text is nil for password fields and when the app does not expose it.
    /// Async so the controller can run it alongside the transcription.
    func fieldContext(maxLength: Int) async -> FieldContext
    /// Whether the focused UI element accepts text input.
    func hasEditableFocus() -> Bool
}

protocol TextInserting: AnyObject {
    /// Pastes into the focused field, then restores the previous pasteboard.
    /// With `submit`, presses Return once the text is in, to send it.
    func paste(_ text: String, submit: Bool) async
    /// Leaves the text in the pasteboard for the user to paste.
    func copyToPasteboard(_ text: String)
}

extension AudioRecorder: AudioRecording {}
