import Testing
@testable import Dictate

struct FnKeyGestureTests {
    @Test func pressThenLongReleaseEmitsPressedThenReleased() {
        var gesture = FnKeyGesture()
        #expect(gesture.handle(.fnDown(at: 10)) == .pressed)
        #expect(gesture.handle(.fnUp(at: 11)) == .released)
    }

    @Test func shortPressIsCancelled() {
        var gesture = FnKeyGesture()
        #expect(gesture.handle(.fnDown(at: 10)) == .pressed)
        #expect(gesture.handle(.fnUp(at: 10.2)) == .cancelled)
    }

    @Test func shortcutRightAfterPressCancelsImmediatelyAndIgnoresRelease() {
        var gesture = FnKeyGesture()
        #expect(gesture.handle(.fnDown(at: 10)) == .pressed)
        #expect(gesture.handle(.otherKeyDown(at: 10.1)) == .cancelled)
        #expect(gesture.handle(.fnUp(at: 12)) == nil)
    }

    /// A key hit by mistake mid-dictation must not lose what was said.
    @Test func otherKeyWhileDictatingIsIgnored() {
        var gesture = FnKeyGesture()
        #expect(gesture.handle(.fnDown(at: 10)) == .pressed)
        #expect(gesture.handle(.otherKeyDown(at: 11)) == nil)
        #expect(gesture.handle(.otherKeyDown(at: 11.5)) == nil)
        #expect(gesture.handle(.fnUp(at: 12)) == .released)
    }

    @Test func repeatedDownWhileHeldIsIgnored() {
        var gesture = FnKeyGesture()
        #expect(gesture.handle(.fnDown(at: 10)) == .pressed)
        #expect(gesture.handle(.fnDown(at: 10.5)) == nil)
        #expect(gesture.handle(.fnUp(at: 11)) == .released)
    }

    @Test func otherKeyOrReleaseWithoutPressIsIgnored() {
        var gesture = FnKeyGesture()
        #expect(gesture.handle(.otherKeyDown(at: 0)) == nil)
        #expect(gesture.handle(.fnUp(at: 1)) == nil)
    }

    @Test func gestureResetsAfterCancellation() {
        var gesture = FnKeyGesture()
        _ = gesture.handle(.fnDown(at: 10))
        _ = gesture.handle(.otherKeyDown(at: 10.1))
        _ = gesture.handle(.fnUp(at: 11))
        #expect(gesture.handle(.fnDown(at: 20)) == .pressed)
        #expect(gesture.handle(.fnUp(at: 21)) == .released)
    }
}
