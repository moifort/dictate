import Testing
@testable import Dictate

struct SetupChecklistTests {
    private let ready = SetupChecklist(
        language: true, microphone: true, inputMonitoring: true, accessibility: true,
        fnKeyFree: true, whisperModel: true, claude: true
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
        checklist.claude = false
        #expect(checklist.current == .fnKey)
        #expect(checklist.pending == [.fnKey, .claude])
        #expect(checklist.completedCount == 5)
    }

    @Test func completeWhenEverythingIsReady() {
        #expect(ready.isComplete)
        #expect(ready.current == nil)
    }

    @Test func onlyClaudeIsOptional() {
        #expect(SetupStep.allCases.filter(\.isOptional) == [.claude])
    }
}
