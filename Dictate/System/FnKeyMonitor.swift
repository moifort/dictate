#if !APP_STORE
import AppKit
import CoreGraphics

/// Listens to the push-to-talk key system-wide and reports gestures.
///
/// Uses a listen-only event tap, so it needs the Input Monitoring permission.
/// With `fn`, the system action of the 🌐 key must be set to "Do Nothing".
final class FnKeyMonitor {
    var onGesture: ((FnKeyGestureOutput) -> Void)?

    /// Switching keys mid-press drops the press rather than leaving it stuck.
    var key: PushToTalkKey = .fn {
        didSet { if key != oldValue { gesture = key.gesture } }
    }

    private var gesture = PushToTalkKey.fn.gesture
    private let watch = KeyStateWatch()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// Returns false when the event tap cannot be created (permission missing).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: fnKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        watch.stop()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // The key may have gone up while the tap was off.
            resync()
        default:
            guard let keyEvent = Self.classify(
                key: key,
                type: type,
                keyCode: keyCode,
                flags: flags,
                time: ProcessInfo.processInfo.systemUptime
            ) else { return }
            if let output = gesture.handle(keyEvent) {
                onGesture?(output)
            }
            watch.update(isHeld: gesture.isHeld) { [weak self] in self?.resync() }
        }
    }

    /// Releases a press whose key-up was missed.
    private func resync() {
        let time = ProcessInfo.processInfo.systemUptime
        if let output = gesture.resync(keyIsDown: KeyStateWatch.isDown(key.flag), at: time) {
            Log.hotkey.notice("key-up missed: \(String(describing: output), privacy: .public) from the key state")
            onGesture?(output)
        }
        watch.update(isHeld: gesture.isHeld) { [weak self] in self?.resync() }
    }

    /// Maps a raw keyboard event to a push-to-talk gesture event.
    nonisolated static func classify(
        key: PushToTalkKey = .fn,
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        time: TimeInterval
    ) -> FnKeyEvent? {
        let otherModifiers = CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand]).subtracting(key.flag)
        return switch type {
        case .flagsChanged where key.keyCodes.contains(keyCode):
            // With both controls held, the flag stays set until the last one is released.
            flags.contains(key.flag) ? .fnDown(at: time) : .fnUp(at: time)
        case .flagsChanged:
            // Only a modifier going down counts: releasing Shift mid-dictation is not a shortcut.
            flags.isDisjoint(with: otherModifiers) ? nil : .otherModifierDown(at: time)
        case .keyDown:
            .otherKeyDown(at: time)
        default:
            nil
        }
    }
}

/// The tap is installed on the main run loop, so callbacks arrive on the main thread.
nonisolated private func fnKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Our own Cmd+V: not the user's keyboard.
    if let userInfo, event.getIntegerValueField(.eventSourceUserData) != TextInserter.eventMarker {
        let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        MainActor.assumeIsolated {
            monitor.handle(type: type, keyCode: keyCode, flags: flags)
        }
    }
    return Unmanaged.passUnretained(event)
}
#endif
