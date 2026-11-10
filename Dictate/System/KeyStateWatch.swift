import AppKit
import CoreGraphics

/// Reads the push-to-talk key's actual state while a press is under way, so
/// a key-up the monitor never received still ends the dictation. The event
/// tap misses events while macOS has it disabled (a slow callback) and while
/// secure input is on (a password field).
final class KeyStateWatch {
    /// Often enough that a missed release costs half a second of recording at most.
    static let interval: TimeInterval = 0.5

    private var timer: Timer?

    /// Calls `check` every `interval` while `isHeld` is true, then stops.
    func update(isHeld: Bool, check: @escaping @MainActor () -> Void) {
        guard isHeld else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether `flag` is held on the keyboard right now, from the hardware state.
    static func isDown(_ flag: CGEventFlags) -> Bool {
        CGEventSource.flagsState(.hidSystemState).contains(flag)
    }
}
