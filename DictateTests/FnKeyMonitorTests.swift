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
        #expect(FnKeyMonitor.classify(type: .flagsChanged, keyCode: 56, flags: .maskShift, time: 0) == .otherKeyDown)
        #expect(FnKeyMonitor.classify(type: .keyDown, keyCode: 0, flags: .maskSecondaryFn, time: 0) == .otherKeyDown)
    }

    @Test func unrelatedEventsAreIgnored() {
        #expect(FnKeyMonitor.classify(type: .keyUp, keyCode: 0, flags: [], time: 0) == nil)
    }
}
