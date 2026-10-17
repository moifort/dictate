import Foundation
import Testing
@testable import Dictate

@MainActor
struct DictationControllerTests {
    private let speech = [Float](repeating: 0.2, count: 16_000)

    private func makeController(
        samples: [Float]? = nil,
        transcript: Result<String, Error> = .success("euh fais un pouche"),
        words: [Transcription.Word] = [],
        enhanced: Result<String, Error> = .success("Fais un push."),
        enhancerDelay: Duration = .zero,
        transcriberDelay: Duration = .zero,
        precedingTextDelay: Duration = .zero,
        editableFocus: Bool = true,
        enhancementEnabled: Bool = true,
        shareFieldContext: Bool = true,
        engine: TranscriptionEngine = .parakeet,
        reviewer: Reviewer? = .claude,
        loadingEngine: TranscriptionEngine? = nil,
        tail: ((Fakes) async -> Void)? = nil
    ) -> (DictationController, Fakes) {
        let events = EventLog()
        let fakes = Fakes(
            recorder: FakeRecorder(samples: samples ?? speech, events: events),
            transcriber: FakeTranscriber(result: transcript, words: words, delay: transcriberDelay, events: events),
            enhancer: FakeEnhancer(result: enhanced, delay: enhancerDelay),
            focus: FakeFocus(editable: editableFocus, bundleID: "com.apple.Terminal", delay: precedingTextDelay, events: events),
            inserter: FakeInserter(),
            events: events
        )
        let controller = DictationController(
            recorder: fakes.recorder,
            transcriber: fakes.transcriber,
            enhancer: fakes.enhancer,
            focus: fakes.focus,
            inserter: fakes.inserter,
            language: { "fr" },
            enhancementEnabled: { enhancementEnabled },
            shareFieldContext: { shareFieldContext },
            transcriptionEngine: { engine },
            reviewer: { reviewer },
            loadingEngine: { loadingEngine },
            enhancementTimeout: .milliseconds(200),
            sleep: { duration in
                fakes.events.append("tail of \(duration) started")
                await tail?(fakes)
                fakes.events.append("tail ended")
            }
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

    @Test func pressWhileModelLoadsReportsItWithoutRecording() {
        let (controller, fakes) = makeController(loadingEngine: .parakeet)
        controller.handle(.pressed)
        #expect(controller.phase == .idle)
        #expect(!fakes.recorder.isRecording)
        #expect(controller.lastOutcome == .modelLoading(.parakeet))
        controller.handle(.released)
        #expect(controller.phase == .idle)
    }

    @Test func fullDictationPastesEnhancedTextWithCategory() async {
        let (controller, fakes) = makeController()
        await dictate(controller)
        #expect(fakes.inserter.pasted == ["Fais un push."])
        #expect(fakes.enhancer.received.first?.context.category == .code)
        #expect(fakes.enhancer.received.first?.context.appName == "Terminal")
        #expect(fakes.transcriber.receivedLanguage == "fr")
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

    @Test func precedingTextReachesTheEnhancer() async {
        let (controller, fakes) = makeController()
        await dictate(controller)
        #expect(fakes.enhancer.received.first?.context.precedingText == "Salut Guillaume,")
    }

    @Test func precedingTextIsReadWhileTheAudioIsTranscribed() async {
        let (controller, fakes) = makeController(
            transcriberDelay: .milliseconds(100),
            precedingTextDelay: .milliseconds(100)
        )
        await dictate(controller)
        let events = fakes.events.entries
        // Each started before the other ended: they overlapped.
        #expect(events.firstIndex(of: "read started")! < events.firstIndex(of: "transcription ended")!)
        #expect(events.firstIndex(of: "transcription started")! < events.firstIndex(of: "read ended")!)
        #expect(fakes.enhancer.received.first?.context.precedingText == "Salut Guillaume,")
    }

    @Test func slowPrecedingTextReadIsAwaitedBeforeClaude() async {
        let (controller, fakes) = makeController(precedingTextDelay: .milliseconds(100))
        await dictate(controller)
        #expect(fakes.events.entries.suffix(2) == ["transcription ended", "read ended"])
        #expect(fakes.enhancer.received.first?.context.precedingText == "Salut Guillaume,")
    }

    @Test func fieldContextReachesTheEnhancer() async {
        let (controller, fakes) = makeController()
        fakes.focus.field = FieldContext(
            followingText: " demain", fieldLabel: "Message #general", windowTitle: "general", webHost: nil
        )
        await dictate(controller)
        let context = fakes.enhancer.received.first?.context
        #expect(context?.followingText == " demain")
        #expect(context?.fieldLabel == "Message #general")
        #expect(context?.windowTitle == "general")
    }

    @Test func browserTabHostSetsTheCategory() async {
        let (controller, fakes) = makeController()
        fakes.focus.bundleID = "com.apple.Safari"
        fakes.focus.field.webHost = "mail.google.com"
        await dictate(controller)
        #expect(fakes.enhancer.received.first?.context.category == .mail)
        #expect(fakes.enhancer.received.first?.context.webHost == "mail.google.com")
    }

    @Test func precedingTextIsNotReadWhenSharingIsOff() async {
        let (controller, fakes) = makeController(shareFieldContext: false)
        await dictate(controller)
        #expect(fakes.focus.fieldContextReads == 0)
        #expect(fakes.enhancer.received.first?.context.precedingText == nil)
    }

    @Test func precedingTextIsNotReadWithoutClaude() async {
        let (controller, fakes) = makeController(enhancementEnabled: false)
        await dictate(controller)
        #expect(fakes.focus.fieldContextReads == 0)
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

    @Test func wordConfidencesReachTheEnhancer() async {
        let words = [
            Transcription.Word(text: "fais", confidence: 0.98),
            Transcription.Word(text: "un", confidence: 0.97),
            Transcription.Word(text: "pouche", confidence: 0.2),
        ]
        let (controller, fakes) = makeController(transcript: .success(" fais un pouche "), words: words)
        await dictate(controller)
        #expect(fakes.enhancer.received.first?.transcription == Transcription(text: "fais un pouche", words: words))
    }

    @Test(arguments: [true, false])
    func rawTranscriptNeverCarriesMarkers(enhancementEnabled: Bool) async {
        let words = [
            Transcription.Word(text: "fais", confidence: 0.98),
            Transcription.Word(text: "un", confidence: 0.97),
            Transcription.Word(text: "pouche", confidence: 0.2),
        ]
        let (controller, fakes) = makeController(
            transcript: .success("fais un pouche"), words: words,
            enhanced: .failure(FakeError()), enhancementEnabled: enhancementEnabled
        )
        await dictate(controller)
        #expect(fakes.inserter.pasted == ["fais un pouche"])
    }

    @Test func claudeReceivesTheUnknownTokenAsParakeetWroteIt() async {
        let (controller, fakes) = makeController(
            transcript: .success("écris à moi <unk> exemple.com"), enhanced: .success("Écris à moi@exemple.com")
        )
        await dictate(controller)
        #expect(fakes.enhancer.received.first?.transcription.text == "écris à moi <unk> exemple.com")
        #expect(fakes.inserter.pasted == ["Écris à moi@exemple.com"])
    }

    @Test(arguments: [true, false])
    func rawTranscriptGetsGuillemetsForTheUnknownTokens(enhancementEnabled: Bool) async {
        let (controller, fakes) = makeController(
            transcript: .success("qui s'appelait <unk> routine <unk> et"),
            enhanced: .failure(FakeError()), enhancementEnabled: enhancementEnabled
        )
        await dictate(controller)
        #expect(fakes.inserter.pasted == ["qui s'appelait « routine » et"])
    }

    @Test func anUnknownTokenClaudeLeftInIsResolvedToo() async {
        let (controller, fakes) = makeController(
            transcript: .success("dire <unk> oui <unk>"), enhanced: .success("Dire <unk> oui <unk>.")
        )
        await dictate(controller)
        #expect(fakes.inserter.pasted == ["Dire « oui »."])
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
        #expect(fakes.transcriber.callCount == 0)
    }

    @Test func silentAudioInsertsNothing() async {
        let (controller, fakes) = makeController(samples: [Float](repeating: 0, count: 16_000))
        await dictate(controller)
        #expect(fakes.transcriber.callCount == 0)
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

    @Test func insertedDictationIsRecordedWithItsTimings() async {
        let (controller, _) = makeController()
        var records: [DictationRecord] = []
        controller.onRecord = { records.append($0) }
        await dictate(controller)
        #expect(records.count == 1)
        #expect(records.first?.words == 3)
        #expect(records.first?.audio == 1)
        #expect(records.first?.enhancement != nil)
    }

    @Test func dictationIsRecordedWithItsEngine() async {
        let (controller, _) = makeController(engine: .parakeet)
        var records: [DictationRecord] = []
        controller.onRecord = { records.append($0) }
        await dictate(controller)
        #expect(records.first?.engine == .parakeet)
    }

    @Test func dictationWithoutClaudeIsRecordedWithoutEnhancement() async {
        let (controller, _) = makeController(editableFocus: false, enhancementEnabled: false)
        var records: [DictationRecord] = []
        controller.onRecord = { records.append($0) }
        await dictate(controller)
        #expect(records.first?.words == 4)
        #expect(records.first?.enhancement == nil)
        #expect(records.first?.reviewer == nil)
    }

    @Test func dictationIsRecordedWithTheModelThatCleanedItUp() async {
        let (controller, _) = makeController(reviewer: .apple)
        var records: [DictationRecord] = []
        controller.onRecord = { records.append($0) }
        await dictate(controller)
        #expect(records.first?.reviewer == .apple)
    }

    @Test func discardedDictationIsNotRecorded() async {
        let (controller, _) = makeController(transcript: .success("   "))
        var records: [DictationRecord] = []
        controller.onRecord = { records.append($0) }
        await dictate(controller)
        #expect(records.isEmpty)
    }

    @Test func samplesAreOnlyHandedOverWhenAsked() async {
        let (controller, _) = makeController()
        var samples: [DictationSample] = []
        controller.onSample = { samples.append($0) }
        await dictate(controller)
        #expect(samples.isEmpty)
    }

    @Test func keptSampleCarriesTheAudioBothTextsAndTheFieldBeforeThePaste() async {
        let (controller, _) = makeController()
        let reader = FakeFieldReader(text: "Salut, ")
        controller.insertionObserver = PostInsertionObserver(reader: reader, delay: .milliseconds(10))
        controller.keepSamples = { true }
        var samples: [DictationSample] = []
        controller.onSample = { samples.append($0) }
        await dictate(controller)
        let sample = samples.first
        let before = await sample?.followUp?.value?.before.text
        #expect(samples.count == 1)
        #expect(sample?.samples == speech)
        #expect(sample?.transcript == "euh fais un pouche")
        #expect(sample?.inserted == "Fais un push.")
        #expect(sample?.enhanced == true)
        #expect(sample?.engine == .parakeet)
        #expect(sample?.language == "fr")
        #expect(sample?.bundleID == "com.apple.Terminal")
        #expect(sample?.category == .code)
        #expect(before == "Salut, ")
    }

    @Test func rawInsertionIsKeptAsNotEnhanced() async {
        let (controller, _) = makeController(enhanced: .failure(FakeError()))
        controller.keepSamples = { true }
        var samples: [DictationSample] = []
        controller.onSample = { samples.append($0) }
        await dictate(controller)
        #expect(samples.first?.enhanced == false)
        #expect(samples.first?.inserted == "euh fais un pouche")
        #expect(samples.first?.followUp == nil)
    }

    @Test func copiedDictationIsNotKept() async {
        let (controller, _) = makeController(editableFocus: false)
        controller.keepSamples = { true }
        var samples: [DictationSample] = []
        controller.onSample = { samples.append($0) }
        await dictate(controller)
        #expect(samples.isEmpty)
    }

    @Test func followedInsertionHandsTheUsersFixesOver() async throws {
        let (controller, _) = makeController()
        let reader = FakeFieldReader(text: "Salut, ")
        controller.insertionObserver = PostInsertionObserver(reader: reader, delay: .milliseconds(50))
        controller.followInsertions = { true }
        var followUps: [InsertionFollowUp] = []
        controller.onFollowUp = { followUps.append($0) }
        await dictate(controller)
        reader.text = "Salut, Fais un push sur Main."
        try await eventually { !followUps.isEmpty }
        #expect(followUps.first?.inserted == "Fais un push.")
        #expect(followUps.first?.corrected == "Fais un push sur Main.")
    }

    @Test func aFieldIsReadOnceForBothTheCorpusAndTheFollowUp() async throws {
        let (controller, _) = makeController()
        let reader = FakeFieldReader(text: "Salut, ")
        controller.insertionObserver = PostInsertionObserver(reader: reader, delay: .milliseconds(10))
        controller.keepSamples = { true }
        controller.followInsertions = { true }
        var samples: [DictationSample] = []
        var followUps: [InsertionFollowUp] = []
        controller.onSample = { samples.append($0) }
        controller.onFollowUp = { followUps.append($0) }
        await dictate(controller)
        try await eventually { !followUps.isEmpty }
        let sampled = await samples.first?.followUp?.value
        #expect(sampled == followUps.first)
        #expect(reader.focusedFieldCalls == 1)
        // Once before the paste, once after the delay.
        #expect(reader.snapshots == 2)
    }

    @Test func aTermFixedAfterThePasteBecomesASuggestion() async throws {
        let (controller, _) = makeController(enhanced: .success("On en parle avec cloud."))
        let reader = FakeFieldReader(text: "Salut, ")
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ControllerSuggestions-\(UUID().uuidString).json")
        let suggestions = VocabularySuggestions(file: file)
        controller.insertionObserver = PostInsertionObserver(reader: reader, delay: .milliseconds(30))
        controller.followInsertions = { true }
        controller.onFollowUp = { suggestions.consider($0, vocabulary: []) }
        controller.onFieldContext = { suggestions.consider(precedingText: $0.precedingText ?? "", vocabulary: []) }
        await dictate(controller)
        reader.text = "Salut, On en parle avec Claude."
        try await eventually { !suggestions.state.pending.isEmpty }
        #expect(suggestions.state.pending.map(\.term) == ["Claude"])
        #expect(suggestions.state.sightings["guillaume"]?.count == 1)
    }

    @Test func insertionsAreNotFollowedUnlessAsked() async throws {
        let (controller, _) = makeController()
        let reader = FakeFieldReader(text: "Salut, ")
        controller.insertionObserver = PostInsertionObserver(reader: reader, delay: .milliseconds(10))
        var followUps: [InsertionFollowUp] = []
        controller.onFollowUp = { followUps.append($0) }
        await dictate(controller)
        try await Task.sleep(for: .milliseconds(50))
        #expect(followUps.isEmpty)
        #expect(reader.focusedFieldCalls == 0)
    }

    @Test func copiedDictationIsNotFollowed() async throws {
        let (controller, _) = makeController(editableFocus: false)
        let reader = FakeFieldReader(text: "Salut, ")
        controller.insertionObserver = PostInsertionObserver(reader: reader, delay: .milliseconds(10))
        controller.followInsertions = { true }
        controller.onFollowUp = { _ in Issue.record("no follow-up expected") }
        await dictate(controller)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reader.focusedFieldCalls == 0)
    }

    @Test func fieldContextIsHandedOver() async {
        let (controller, _) = makeController()
        var contexts: [DictationContext] = []
        controller.onFieldContext = { contexts.append($0) }
        await dictate(controller)
        #expect(contexts.map(\.precedingText) == ["Salut Guillaume,"])
    }

    @Test func unreadFieldContextIsNotHandedOver() async {
        let (controller, _) = makeController(shareFieldContext: false)
        var contexts: [DictationContext] = []
        controller.onFieldContext = { contexts.append($0) }
        await dictate(controller)
        #expect(contexts.isEmpty)
    }

    /// Polls `condition` until it holds, failing after a second.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition never held")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Release tail

    @Test func recordingGoesOnForTheTailAfterRelease() async {
        let (controller, fakes) = makeController()
        await dictate(controller)
        let events = fakes.events.entries
        #expect(events.contains("tail of \(DictationController.defaultReleaseTail) started"))
        #expect(events.firstIndex(of: "tail ended")! < events.firstIndex(of: "recording stopped")!)
    }

    @Test func samplesCapturedDuringTheTailAreTranscribed() async {
        let tailSpeech = [Float](repeating: 0.3, count: 4_000)
        let (controller, fakes) = makeController(tail: { fakes in fakes.recorder.samples += tailSpeech })
        await dictate(controller)
        #expect(fakes.transcriber.receivedSamples == speech + tailSpeech)
    }

    @Test func phaseLeavesRecordingAsSoonAsTheKeyIsReleased() async {
        let (controller, fakes) = makeController(tail: { _ in try? await Task.sleep(for: .milliseconds(50)) })
        controller.handle(.pressed)
        controller.handle(.released)
        #expect(controller.phase == .transcribing)
        // Still capturing the tail.
        #expect(fakes.recorder.isRecording)
        await controller.waitUntilIdle()
        #expect(!fakes.recorder.isRecording)
        #expect(controller.lastOutcome == .pasted(raw: false))
    }

    @Test func fieldContextReadStartsBeforeTheTailEnds() async {
        let (controller, fakes) = makeController(tail: { _ in try? await Task.sleep(for: .milliseconds(50)) })
        await dictate(controller)
        let events = fakes.events.entries
        #expect(events.firstIndex(of: "read started")! < events.firstIndex(of: "tail ended")!)
    }

    @Test func pressDuringTheTailIsIgnoredAndTheDictationCompletes() async {
        let (controller, fakes) = makeController(tail: { _ in try? await Task.sleep(for: .milliseconds(50)) })
        controller.handle(.pressed)
        controller.handle(.released)
        controller.handle(.pressed)
        #expect(controller.phase == .transcribing)
        controller.handle(.cancelled)
        controller.handle(.released)
        #expect(controller.phase == .transcribing)
        await controller.waitUntilIdle()
        #expect(fakes.recorder.startCount == 1)
        #expect(fakes.transcriber.callCount == 1)
        #expect(fakes.inserter.pasted == ["Fais un push."])
    }

    @Test func tooShortARecordingIsDiscardedEvenWithTheTail() async {
        let short = [Float](repeating: 0.2, count: 1_000)
        let (controller, fakes) = makeController(samples: short, tail: { fakes in fakes.recorder.samples += short })
        await dictate(controller)
        #expect(fakes.transcriber.callCount == 0)
        #expect(controller.lastOutcome == .discarded)
    }

    @Test func silentTailDoesNotMakeSilenceWorthTranscribing() async {
        let silence = [Float](repeating: 0, count: 16_000)
        let (controller, fakes) = makeController(
            samples: silence, tail: { fakes in fakes.recorder.samples += [Float](repeating: 0, count: 4_000) }
        )
        await dictate(controller)
        #expect(fakes.transcriber.callCount == 0)
        #expect(controller.lastOutcome == .discarded)
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
    let events: EventLog
}

/// Start and end of the transcription and of the preceding-text read, in order.
@MainActor
private final class EventLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) { entries.append(entry) }
}

@MainActor
private final class FakeRecorder: AudioRecording {
    /// Everything captured so far; a tail appends to it to mimic speech after the release.
    var samples: [Float]
    let events: EventLog
    var isRecording = false
    var startCount = 0
    var startError: Error?

    init(samples: [Float], events: EventLog) {
        self.samples = samples
        self.events = events
    }

    func start() throws {
        if let startError { throw startError }
        startCount += 1
        isRecording = true
    }

    func stop() -> [Float] {
        isRecording = false
        events.append("recording stopped")
        return samples
    }
}

@MainActor
private final class FakeTranscriber: Transcriber {
    let result: Result<String, Error>
    let words: [Transcription.Word]
    let delay: Duration
    let events: EventLog
    var callCount = 0
    var receivedLanguage = ""
    var receivedSamples: [Float] = []

    init(result: Result<String, Error>, words: [Transcription.Word], delay: Duration, events: EventLog) {
        self.result = result
        self.words = words
        self.delay = delay
        self.events = events
    }

    func transcribe(samples: [Float], language: String) async throws -> String {
        callCount += 1
        receivedLanguage = language
        events.append("transcription started")
        try await Task.sleep(for: delay)
        events.append("transcription ended")
        return try result.get()
    }

    func transcription(samples: [Float], language: String) async throws -> Transcription {
        receivedSamples = samples
        return Transcription(text: try await transcribe(samples: samples, language: language), words: words)
    }
}

@MainActor
private final class FakeEnhancer: Enhancer {
    let result: Result<String, Error>
    let delay: Duration
    var received: [(transcription: Transcription, context: DictationContext)] = []

    init(result: Result<String, Error>, delay: Duration) {
        self.result = result
        self.delay = delay
    }

    func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String {
        received.append((transcription, context))
        try await Task.sleep(for: delay)
        return try result.get()
    }
}

@MainActor
private final class FakeFocus: FocusInspecting {
    let editable: Bool
    var bundleID: String?
    let delay: Duration
    let events: EventLog
    var field = FieldContext(precedingText: "Salut Guillaume,")
    private(set) var fieldContextReads = 0

    init(editable: Bool, bundleID: String?, delay: Duration, events: EventLog) {
        self.editable = editable
        self.bundleID = bundleID
        self.delay = delay
        self.events = events
    }

    func frontmostBundleID() -> String? { bundleID }
    func frontmostAppName() -> String? { "Terminal" }
    func hasEditableFocus() -> Bool { editable }

    func fieldContext(maxLength: Int) async -> FieldContext {
        fieldContextReads += 1
        events.append("read started")
        try? await Task.sleep(for: delay)
        events.append("read ended")
        return field
    }
}

@MainActor
private final class FakeFieldReader: FieldReading, ReadableField {
    var text: String
    private(set) var focusedFieldCalls = 0
    private(set) var snapshots = 0

    init(text: String) { self.text = text }

    func focusedField() -> (any ReadableField)? {
        focusedFieldCalls += 1
        return self
    }

    func snapshot() -> FieldSnapshot? {
        snapshots += 1
        return FieldSnapshot(text: text, selection: NSRange(location: (text as NSString).length, length: 0))
    }
}

@MainActor
private final class FakeInserter: TextInserting {
    var pasted: [String] = []
    var copied: [String] = []

    func paste(_ text: String) async { pasted.append(text) }
    func copyToPasteboard(_ text: String) { copied.append(text) }
}
