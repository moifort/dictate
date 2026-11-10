import Testing
@testable import Dictate

struct PushToTalkGestureTests {
    @Test func pressThenLongReleaseEmitsPressedThenReleased() {
        var gesture = PushToTalkGesture()
        #expect(gesture.handle(.keyDown(at: 10)) == .pressed)
        #expect(gesture.handle(.keyUp(at: 11)) == .released)
    }

    @Test func shortPressIsCancelled() {
        var gesture = PushToTalkGesture()
        #expect(gesture.handle(.keyDown(at: 10)) == .pressed)
        #expect(gesture.handle(.keyUp(at: 10.2)) == .cancelled)
    }

    @Test func shortcutRightAfterPressCancelsImmediatelyAndIgnoresRelease() {
        var gesture = PushToTalkGesture()
        #expect(gesture.handle(.keyDown(at: 10)) == .pressed)
        #expect(gesture.handle(.otherKeyDown(at: 10.1)) == .cancelled)
        #expect(gesture.handle(.keyUp(at: 12)) == nil)
    }

    /// A key hit by mistake mid-dictation must not lose what was said.
    @Test func otherKeyWhileDictatingIsIgnored() {
        var gesture = PushToTalkGesture()
        #expect(gesture.handle(.keyDown(at: 10)) == .pressed)
        #expect(gesture.handle(.otherKeyDown(at: 11)) == nil)
        #expect(gesture.handle(.otherKeyDown(at: 11.5)) == nil)
        #expect(gesture.handle(.keyUp(at: 12)) == .released)
    }

    @Test func repeatedDownWhileHeldIsIgnored() {
        var gesture = PushToTalkGesture()
        #expect(gesture.handle(.keyDown(at: 10)) == .pressed)
        #expect(gesture.handle(.keyDown(at: 10.5)) == nil)
        #expect(gesture.handle(.keyUp(at: 11)) == .released)
    }

    @Test func otherKeyOrReleaseWithoutPressIsIgnored() {
        var gesture = PushToTalkGesture()
        #expect(gesture.handle(.otherKeyDown(at: 0)) == nil)
        #expect(gesture.handle(.keyUp(at: 1)) == nil)
    }

    @Test func gestureResetsAfterCancellation() {
        var gesture = PushToTalkGesture()
        _ = gesture.handle(.keyDown(at: 10))
        _ = gesture.handle(.otherKeyDown(at: 10.1))
        _ = gesture.handle(.keyUp(at: 11))
        #expect(gesture.handle(.keyDown(at: 20)) == .pressed)
        #expect(gesture.handle(.keyUp(at: 21)) == .released)
    }

    /// A key-up the tap never received: the key state read later ends the press.
    @Test func aMissedReleaseIsCaughtByTheKeyState() {
        var gesture = PushToTalkGesture()
        #expect(gesture.handle(.keyDown(at: 10)) == .pressed)
        #expect(gesture.resync(keyIsDown: true, at: 11) == nil)
        #expect(gesture.isHeld)
        #expect(gesture.resync(keyIsDown: false, at: 12) == .released)
        #expect(!gesture.isHeld)
        // The next press works as usual.
        #expect(gesture.handle(.keyDown(at: 20)) == .pressed)
    }

    @Test func theKeyStateMeansNothingWithoutAPress() {
        var gesture = PushToTalkGesture()
        #expect(gesture.resync(keyIsDown: false, at: 1) == nil)
    }

    /// control held a while, then C: a shortcut, never a dictation of the room.
    @Test func withControlAKeyCancelsEvenLate() {
        var gesture = PushToTalkKey.control.gesture
        #expect(gesture.handle(.keyDown(at: 10)) == .pressed)
        #expect(gesture.handle(.otherKeyDown(at: 25)) == .cancelled)
        #expect(gesture.handle(.keyUp(at: 26)) == nil)
    }

    /// Shift for a capital mid-dictation is not a shortcut: past the window, ignored.
    @Test func withControlALateModifierIsIgnored() {
        var gesture = PushToTalkKey.control.gesture
        #expect(gesture.handle(.keyDown(at: 10)) == .pressed)
        #expect(gesture.handle(.otherModifierDown(at: 11)) == nil)
        #expect(gesture.handle(.keyUp(at: 12)) == .released)
    }

    @Test func withFnALateKeyIsStillIgnored() {
        var gesture = PushToTalkKey.fn.gesture
        #expect(gesture.handle(.keyDown(at: 10)) == .pressed)
        #expect(gesture.handle(.otherKeyDown(at: 11)) == nil)
        #expect(gesture.handle(.keyUp(at: 12)) == .released)
    }
}
