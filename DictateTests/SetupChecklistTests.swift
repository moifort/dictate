import Testing
@testable import Dictate

struct SetupChecklistTests {
    private let ready = SetupChecklist(
        language: true, microphone: true, inputMonitoring: true, accessibility: true,
        fnKeyFree: true, transcriptionModel: true, review: true
    )

    @Test func freshInstallStartsWithTheLanguage() {
        let checklist = SetupChecklist()
        #expect(checklist.current == .language)
        #expect(checklist.pending == SetupStep.allCases)
        #expect(!checklist.isComplete)
        #expect(checklist.completedCount == 0)
    }

    @Test func currentIsTheFirstMissingStepInOrder() {
        var checklist = ready
        checklist.fnKeyFree = false
        checklist.review = false
        #expect(checklist.current == .fnKey)
        #expect(checklist.pending == [.fnKey, .review])
        #expect(checklist.completedCount == 5)
    }

    @Test func completeWhenEverythingIsReady() {
        #expect(ready.isComplete)
        #expect(ready.current == nil)
    }

    /// The language page is the first one and only the onboarding confirms it,
    /// so it tells a fresh install from a resumed setup whatever macOS already granted.
    @Test func startsOnceTheLanguageIsConfirmed() {
        var checklist = SetupChecklist()
        checklist.fnKeyFree = true
        checklist.microphone = true
        #expect(!checklist.hasStarted)
        checklist.language = true
        #expect(checklist.hasStarted)
    }

    @Test func onlyTheReviewIsOptional() {
        #expect(SetupStep.allCases.filter(\.isOptional) == [.review])
    }

    /// control has nothing for macOS to give up: the 🌐 step is not listed at all.
    @Test func theFnStepIsOnlyListedForTheFnKey() {
        var checklist = ready
        checklist.fnKeyFree = false
        checklist.fnKeyNeeded = false
        #expect(!checklist.steps.contains(.fnKey))
        #expect(checklist.isComplete)
        #expect(checklist.completedCount == checklist.steps.count)
    }

    /// The review is checked by a slow probe of the claude command, still
    /// running when the launch decides whether to open the onboarding.
    @Test func onlyAMissingRequiredStepNeedsTheOnboarding() {
        var checklist = ready
        checklist.review = false
        #expect(!checklist.isComplete)
        #expect(!checklist.needsOnboarding)
        checklist.microphone = false
        #expect(checklist.needsOnboarding)
    }
}
