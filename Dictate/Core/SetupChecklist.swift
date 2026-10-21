import Foundation

/// One thing Dictate needs before the first dictation, in the order the onboarding asks for it.
nonisolated enum SetupStep: Int, CaseIterable, Identifiable, Sendable {
    case language
    case microphone
    case inputMonitoring
    case accessibility
    case fnKey
    case transcriptionModel
    /// The chosen reviewer is ready.
    case review

    var id: Int { rawValue }

    /// Dictation works without a reviewer: the raw transcript is inserted instead.
    var isOptional: Bool { self == .review }
}

/// A snapshot of what is ready. Built from the system by `AppModel`, kept pure for tests.
nonisolated struct SetupChecklist: Equatable, Sendable {
    /// The user confirmed the dictation language.
    var language = false
    var microphone = false
    var inputMonitoring = false
    var accessibility = false
    var fnKeyFree = false
    /// The push-to-talk key is 🌐 fn, which macOS must leave alone; control needs nothing.
    var fnKeyNeeded = true
    var transcriptionModel = false
    /// The chosen reviewer is ready (Apple Intelligence available, or the
    /// `claude` CLI found), or the user chose to dictate without one.
    var review = false

    func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .language: language
        case .microphone: microphone
        case .inputMonitoring: inputMonitoring
        case .accessibility: accessibility
        case .fnKey: fnKeyFree
        case .transcriptionModel: transcriptionModel
        case .review: review
        }
    }

    /// The steps that apply to the chosen push-to-talk key, in order.
    var steps: [SetupStep] { SetupStep.allCases.filter { $0 != .fnKey || fnKeyNeeded } }

    var pending: [SetupStep] { steps.filter { !isDone($0) } }

    /// The step the onboarding should show: the first one still missing.
    var current: SetupStep? { pending.first }

    var isComplete: Bool { pending.isEmpty }

    /// Dictation cannot work yet. The optional review is left out: at launch
    /// it is still being checked, and the raw transcript works without it.
    var needsOnboarding: Bool { pending.contains { !$0.isOptional } }

    /// The user went through at least the first page: only the onboarding
    /// confirms the language, whereas macOS may already have granted the rest.
    var hasStarted: Bool { language }

    var completedCount: Int { steps.count - pending.count }
}
