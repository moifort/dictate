import Carbon.HIToolbox

/// Reports push-to-talk gestures from a global hot key, ⌥Space.
///
/// The App Store build's monitor: Carbon hot keys need no permission and the
/// app sees this one shortcut only, never the rest of the keyboard, which is
/// what App Review asks for (guideline 2.4.5).
final class HotKeyMonitor {
    var onGesture: ((FnKeyGestureOutput) -> Void)?

    /// There is only one shortcut: kept to match `FnKeyMonitor`.
    var key: PushToTalkKey = .optionSpace

    private var gesture = FnKeyGesture()
    private let watch = KeyStateWatch()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isRunning: Bool { hotKey != nil }

    /// Returns false when macOS refuses the shortcut.
    @discardableResult
    func start() -> Bool {
        guard hotKey == nil else { return true }
        var events = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        guard InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyCallback,
            events.count,
            &events,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        ) == noErr else { return false }

        let id = EventHotKeyID(signature: 0x4449_4354, id: 1)
        guard RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(optionKey), id, GetEventDispatcherTarget(), 0, &hotKey
        ) == noErr else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        watch.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    fileprivate func handle(pressed: Bool) {
        let time = ProcessInfo.processInfo.systemUptime
        if let output = gesture.handle(pressed ? .fnDown(at: time) : .fnUp(at: time)) {
            onGesture?(output)
        }
        watch.update(isHeld: gesture.isHeld) { [weak self] in self?.resync() }
    }

    /// Releases a press whose key-up was missed: option no longer held.
    private func resync() {
        let time = ProcessInfo.processInfo.systemUptime
        if let output = gesture.resync(keyIsDown: KeyStateWatch.isDown(key.flag), at: time) {
            onGesture?(output)
        }
        watch.update(isHeld: gesture.isHeld) { [weak self] in self?.resync() }
    }
}

/// Carbon dispatches on the main run loop, so callbacks arrive on the main thread.
nonisolated private func hotKeyCallback(
    handlerCall: EventHandlerCallRef?,
    event: EventRef?,
    userInfo: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handle(pressed: pressed)
    }
    return noErr
}
