import Foundation

nonisolated enum FnKeyEvent: Equatable, Sendable {
    case fnDown(at: TimeInterval)
    case fnUp(at: TimeInterval)
    /// Any other key or modifier pressed while `fn` may be held.
    case otherKeyDown(at: TimeInterval)
}

nonisolated enum FnKeyGestureOutput: Equatable, Sendable {
    case pressed
    case released
    case cancelled
}

/// Turns raw `fn` key events into push-to-talk gestures.
///
/// Recording starts on `pressed` so no speech is lost. A press shorter than
/// `minimumDuration`, or `fn` used as a modifier for another key within that
/// same window, ends with `cancelled` instead of `released`. Past the window
/// the user is dictating: a stray key is ignored and the dictation goes on.
nonisolated struct FnKeyGesture: Sendable {
    var minimumDuration: TimeInterval = 0.3

    private var downAt: TimeInterval?
    private var interrupted = false

    /// A press is under way: the key went down and no key-up came yet.
    var isHeld: Bool { downAt != nil }

    /// Ends the press when the key, read from the system, is no longer down:
    /// the key-up never reached the monitor (event tap disabled by a timeout,
    /// secure input), and the microphone would otherwise stay open.
    mutating func resync(keyIsDown: Bool, at time: TimeInterval) -> FnKeyGestureOutput? {
        guard isHeld, !keyIsDown else { return nil }
        return handle(.fnUp(at: time))
    }

    mutating func handle(_ event: FnKeyEvent) -> FnKeyGestureOutput? {
        switch event {
        case .fnDown(let time):
            guard downAt == nil else { return nil }
            downAt = time
            interrupted = false
            return .pressed

        case .otherKeyDown(let time):
            guard let start = downAt, !interrupted, time - start < minimumDuration else { return nil }
            interrupted = true
            return .cancelled

        case .fnUp(let time):
            guard let start = downAt else { return nil }
            downAt = nil
            if interrupted { return nil }
            return time - start < minimumDuration ? .cancelled : .released
        }
    }
}
