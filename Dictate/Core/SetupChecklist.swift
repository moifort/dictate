import Foundation

/// One thing Dictate needs before the first dictation, in the order the onboarding asks for it.
nonisolated enum SetupStep: Int, CaseIterable, Identifiable, Sendable {
    case language
    case microphone
    case inputMonitoring
    case accessibility
    case fnKey
    case transcriptionModel
    case claude

    var id: Int { rawValue }

    /// Dictation works without Claude: the raw transcript is inserted instead.
    var isOptional: Bool { self == .claude }
}

/// A snapshot of what is ready. Built from the system by `AppModel`, kept pure for tests.
nonisolated struct SetupChecklist: Equatable, Sendable {
    /// The user confirmed the dictation language.
    var language = false
    var microphone = false
    var inputMonitoring = false
    var accessibility = false
    var fnKeyFree = false
    var transcriptionModel = false
    /// The CLI was found, or the user chose to dictate without Claude.
    var claude = false

    func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .language: language
        case .microphone: microphone
        case .inputMonitoring: inputMonitoring
        case .accessibility: accessibility
        case .fnKey: fnKeyFree
        case .transcriptionModel: transcriptionModel
        case .claude: claude
        }
    }

    var pending: [SetupStep] { SetupStep.allCases.filter { !isDone($0) } }

    /// The step the onboarding should show: the first one still missing.
    var current: SetupStep? { pending.first }

    var isComplete: Bool { pending.isEmpty }

    var completedCount: Int { SetupStep.allCases.count - pending.count }
}
