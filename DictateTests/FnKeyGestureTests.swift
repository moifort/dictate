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

    @Test func otherKeyWhileHeldCancelsImmediatelyAndIgnoresRelease() {
        var gesture = FnKeyGesture()
        #expect(gesture.handle(.fnDown(at: 10)) == .pressed)
        #expect(gesture.handle(.otherKeyDown) == .cancelled)
        #expect(gesture.handle(.fnUp(at: 12)) == nil)
    }

    @Test func repeatedDownWhileHeldIsIgnored() {
        var gesture = FnKeyGesture()
        #expect(gesture.handle(.fnDown(at: 10)) == .pressed)
        #expect(gesture.handle(.fnDown(at: 10.5)) == nil)
        #expect(gesture.handle(.fnUp(at: 11)) == .released)
    }

    @Test func otherKeyOrReleaseWithoutPressIsIgnored() {
        var gesture = FnKeyGesture()
        #expect(gesture.handle(.otherKeyDown) == nil)
        #expect(gesture.handle(.fnUp(at: 1)) == nil)
    }

    @Test func gestureResetsAfterCancellation() {
        var gesture = FnKeyGesture()
        _ = gesture.handle(.fnDown(at: 10))
        _ = gesture.handle(.otherKeyDown)
        _ = gesture.handle(.fnUp(at: 11))
        #expect(gesture.handle(.fnDown(at: 20)) == .pressed)
        #expect(gesture.handle(.fnUp(at: 21)) == .released)
    }
}
