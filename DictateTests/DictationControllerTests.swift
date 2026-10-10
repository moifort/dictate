import Foundation
import Testing
@testable import Dictate

@MainActor
struct DictationControllerTests {
    private let speech = [Float](repeating: 0.2, count: 16_000)

    private func makeController(
        samples: [Float]? = nil,
        transcript: Result<String, Error> = .success("euh fais un pouche"),
        enhanced: Result<String, Error> = .success("Fais un push."),
        enhancerDelay: Duration = .zero,
        editableFocus: Bool = true,
        enhancementEnabled: Bool = true
    ) -> (DictationController, Fakes) {
        let fakes = Fakes(
            recorder: FakeRecorder(samples: samples ?? speech),
            transcriber: FakeTranscriber(result: transcript),
            enhancer: FakeEnhancer(result: enhanced, delay: enhancerDelay),
            focus: FakeFocus(editable: editableFocus, bundleID: "com.apple.Terminal"),
            inserter: FakeInserter()
        )
        let controller = DictationController(
            recorder: fakes.recorder,
            transcriber: fakes.transcriber,
            enhancer: fakes.enhancer,
            focus: fakes.focus,
            inserter: fakes.inserter,
            whisperVocabulary: { ["push"] },
            enhancementEnabled: { enhancementEnabled },
            enhancementTimeout: .milliseconds(200)
        )
        return (controller, fakes)
    }

    private func dictate(_ controller: DictationController) async {
        controller.handle(.pressed)
        controller.handle(.released)
        await controller.waitUntilIdle()
    }

    @Test func pressStartsRecording() {
        let (controller, fakes) = makeController()
        controller.handle(.pressed)
        #expect(controller.phase == .recording)
        #expect(fakes.recorder.isRecording)
    }

    @Test func fullDictationPastesEnhancedTextWithCategory() async {
        let (controller, fakes) = makeController()
        await dictate(controller)
        #expect(fakes.inserter.pasted == ["Fais un push."])
        #expect(fakes.enhancer.received.first?.category == .code)
        #expect(fakes.transcriber.receivedVocabulary == ["push"])
        #expect(fakes.transcriber.live?.appended == speech)
        #expect(fakes.transcriber.live?.finished == true)
        #expect(controller.lastOutcome == .pasted(raw: false))
        #expect(controller.phase == .idle)
    }

    @Test func noEditableFieldCopiesToPasteboard() async {
        let (controller, fakes) = makeController(editableFocus: false)
        await dictate(controller)
        #expect(fakes.inserter.pasted.isEmpty)
        #expect(fakes.inserter.copied == ["Fais un push."])
        #expect(controller.lastOutcome == .copied(raw: false))
    }

    @Test func enhancerErrorFallsBackToRawTranscript() async {
        let (controller, fakes) = makeController(enhanced: .failure(FakeError()))
        await dictate(controller)
        #expect(fakes.inserter.pasted == ["euh fais un pouche"])
        #expect(controller.lastOutcome == .pasted(raw: true))
    }

    @Test func enhancerTimeoutFallsBackToRawTranscript() async {
        let (controller, fakes) = makeController(enhancerDelay: .seconds(5))
        await dictate(controller)
        #expect(fakes.inserter.pasted == ["euh fais un pouche"])
        #expect(controller.lastOutcome == .pasted(raw: true))
    }

    @Test func disabledEnhancementSkipsEnhancer() async {
        let (controller, fakes) = makeController(enhancementEnabled: false)
        await dictate(controller)
        #expect(fakes.enhancer.received.isEmpty)
        #expect(fakes.inserter.pasted == ["euh fais un pouche"])
        #expect(controller.lastOutcome == .pasted(raw: false))
    }

    @Test func cancelledPressDiscardsRecording() {
        let (controller, fakes) = makeController()
        controller.handle(.pressed)
        controller.handle(.cancelled)
        #expect(controller.phase == .idle)
        #expect(!fakes.recorder.isRecording)
        #expect(fakes.transcriber.live?.cancelled == true)
        #expect(fakes.transcriber.live?.finished == false)
    }

    @Test func silentAudioInsertsNothing() async {
        let (controller, fakes) = makeController(samples: [Float](repeating: 0, count: 16_000))
        await dictate(controller)
        #expect(fakes.transcriber.live?.cancelled == true)
        #expect(fakes.transcriber.live?.finished == false)
        #expect(controller.lastOutcome == .discarded)
    }

    @Test func emptyTranscriptInsertsNothing() async {
        let (controller, fakes) = makeController(transcript: .success("   "))
        await dictate(controller)
        #expect(fakes.enhancer.received.isEmpty)
        #expect(fakes.inserter.pasted.isEmpty)
        #expect(controller.lastOutcome == .discarded)
    }

    @Test func transcriberErrorReportsFailure() async {
        let (controller, fakes) = makeController(transcript: .failure(FakeError()))
        await dictate(controller)
        #expect(fakes.inserter.pasted.isEmpty)
        if case .failed = controller.lastOutcome {} else {
            Issue.record("expected failure, got \(String(describing: controller.lastOutcome))")
        }
    }

    @Test func pressWhileProcessingIsIgnored() async {
        let (controller, fakes) = makeController(enhancerDelay: .milliseconds(100))
        controller.handle(.pressed)
        controller.handle(.released)
        controller.handle(.pressed)
        #expect(controller.phase == .transcribing)
        await controller.waitUntilIdle()
        #expect(fakes.recorder.startCount == 1)
    }

    @Test func phaseIsEnhancingWhileClaudeCorrects() async throws {
        let (controller, _) = makeController(enhancerDelay: .milliseconds(150))
        controller.handle(.pressed)
        controller.handle(.released)
        #expect(controller.phase == .transcribing)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.phase == .enhancing)
        await controller.waitUntilIdle()
        #expect(controller.phase == .idle)
    }

    @Test func recorderFailureReportsFailure() {
        let (controller, fakes) = makeController()
        fakes.recorder.startError = FakeError()
        controller.handle(.pressed)
        #expect(controller.phase == .idle)
        if case .failed = controller.lastOutcome {} else {
            Issue.record("expected failure")
        }
    }
}

// MARK: - Fakes

private struct FakeError: Error {}

@MainActor
private struct Fakes {
    let recorder: FakeRecorder
    let transcriber: FakeTranscriber
    let enhancer: FakeEnhancer
    let focus: FakeFocus
    let inserter: FakeInserter
}

@MainActor
private final class FakeRecorder: AudioRecording {
    let samples: [Float]
    var onSamples: (@Sendable ([Float]) -> Void)?
    var isRecording = false
    var startCount = 0
    var startError: Error?

    init(samples: [Float]) { self.samples = samples }

    func start() throws {
        if let startError { throw startError }
        startCount += 1
        isRecording = true
    }

    func stop() -> [Float] {
        isRecording = false
        // The whole recording arrives as one chunk.
        onSamples?(samples)
        return samples
    }
}

@MainActor
private final class FakeTranscriber: Transcriber {
    let result: Result<String, Error>
    var receivedVocabulary: [String] = []
    var live: FakeLiveTranscription?

    init(result: Result<String, Error>) { self.result = result }

    func startLive(vocabulary: [String]) -> any LiveTranscription {
        receivedVocabulary = vocabulary
        let live = FakeLiveTranscription(result: result)
        self.live = live
        return live
    }
}

private final class FakeLiveTranscription: LiveTranscription, @unchecked Sendable {
    let result: Result<String, Error>
    private let lock = NSLock()
    private var _appended: [Float] = []
    private var _finished = false
    private var _cancelled = false

    init(result: Result<String, Error>) { self.result = result }

    var appended: [Float] { lock.withLock { _appended } }
    var finished: Bool { lock.withLock { _finished } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func append(_ samples: [Float]) { lock.withLock { _appended += samples } }

    func finish() async throws -> String {
        lock.withLock { _finished = true }
        return try result.get()
    }

    func cancel() { lock.withLock { _cancelled = true } }
}

@MainActor
private final class FakeEnhancer: Enhancer {
    let result: Result<String, Error>
    let delay: Duration
    var received: [(transcript: String, category: AppCategory)] = []

    init(result: Result<String, Error>, delay: Duration) {
        self.result = result
        self.delay = delay
    }

    func enhance(transcript: String, category: AppCategory) async throws -> String {
        received.append((transcript, category))
        try await Task.sleep(for: delay)
        return try result.get()
    }
}

@MainActor
private final class FakeFocus: FocusInspecting {
    let editable: Bool
    let bundleID: String?

    init(editable: Bool, bundleID: String?) {
        self.editable = editable
        self.bundleID = bundleID
    }

    func frontmostBundleID() -> String? { bundleID }
    func hasEditableFocus() -> Bool { editable }
}

@MainActor
private final class FakeInserter: TextInserting {
    var pasted: [String] = []
    var copied: [String] = []

    func paste(_ text: String) async { pasted.append(text) }
    func copyToPasteboard(_ text: String) { copied.append(text) }
}
