import Testing
@testable import Dictate

struct SetupViewTests {
    @Test func freshInstallOpensOnTheWelcomePage() {
        var checklist = SetupChecklist()
        checklist.fnKeyFree = true
        checklist.transcriptionModel = true
        #expect(SetupView.firstPage(for: checklist) == .welcome)
    }

    @Test func resumedSetupOpensOnTheFirstMissingStep() {
        var checklist = SetupChecklist()
        checklist.language = true
        checklist.microphone = true
        #expect(SetupView.firstPage(for: checklist) == .step(.inputMonitoring))
    }

    @Test func completeSetupOpensOnTheTryItPage() {
        let checklist = SetupChecklist(
            language: true, microphone: true, inputMonitoring: true, accessibility: true,
            fnKeyFree: true, transcriptionModel: true, claude: true
        )
        #expect(SetupView.firstPage(for: checklist) == .tryIt)
    }
}
