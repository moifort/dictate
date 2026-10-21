import CoreGraphics
import Testing
@testable import Dictate

struct FnKeyMonitorTests {
    @Test func fnFlagsChangeWithFlagIsDown() {
        let event = FnKeyMonitor.classify(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn, time: 5)
        #expect(event == .fnDown(at: 5))
    }

    @Test func fnFlagsChangeWithoutFlagIsUp() {
        let event = FnKeyMonitor.classify(type: .flagsChanged, keyCode: 63, flags: [], time: 6)
        #expect(event == .fnUp(at: 6))
    }

    @Test func otherModifierOrKeyIsOtherKey() {
        #expect(FnKeyMonitor.classify(type: .flagsChanged, keyCode: 56, flags: .maskShift, time: 0) == .otherKeyDown(at: 0))
        #expect(FnKeyMonitor.classify(type: .keyDown, keyCode: 0, flags: .maskSecondaryFn, time: 0) == .otherKeyDown(at: 0))
    }

    @Test func modifierReleaseIsIgnored() {
        #expect(FnKeyMonitor.classify(type: .flagsChanged, keyCode: 56, flags: [], time: 0) == nil)
        #expect(FnKeyMonitor.classify(type: .flagsChanged, keyCode: 56, flags: .maskSecondaryFn, time: 0) == nil)
    }

    @Test func unrelatedEventsAreIgnored() {
        #expect(FnKeyMonitor.classify(type: .keyUp, keyCode: 0, flags: [], time: 0) == nil)
    }

    @Test func eitherControlKeyIsThePushToTalkKey() {
        for keyCode: Int64 in [59, 62] {
            #expect(FnKeyMonitor.classify(key: .control, type: .flagsChanged, keyCode: keyCode, flags: .maskControl, time: 1) == .fnDown(at: 1))
            #expect(FnKeyMonitor.classify(key: .control, type: .flagsChanged, keyCode: keyCode, flags: [], time: 2) == .fnUp(at: 2))
        }
    }

    /// Releasing one control while the other is still held keeps the flag set.
    @Test func controlStaysDownWhileTheOtherControlIsHeld() {
        #expect(FnKeyMonitor.classify(key: .control, type: .flagsChanged, keyCode: 62, flags: .maskControl, time: 3) == .fnDown(at: 3))
    }

    @Test func withControlTheOtherModifiersStillInterrupt() {
        #expect(FnKeyMonitor.classify(key: .control, type: .flagsChanged, keyCode: 55, flags: [.maskControl, .maskCommand], time: 0) == .otherKeyDown(at: 0))
        #expect(FnKeyMonitor.classify(key: .control, type: .keyDown, keyCode: 8, flags: .maskControl, time: 0) == .otherKeyDown(at: 0))
    }

    @Test func withControlHeldAModifierReleaseIsIgnored() {
        #expect(FnKeyMonitor.classify(key: .control, type: .flagsChanged, keyCode: 56, flags: .maskControl, time: 0) == nil)
    }

    @Test func withControlTheFnKeyIsNotThePushToTalkKey() {
        #expect(FnKeyMonitor.classify(key: .control, type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn, time: 0) == nil)
    }
}
