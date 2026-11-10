import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import Dictate

struct KeyTapMonitorTests {
    @Test func fnFlagsChangeWithFlagIsDown() {
        let event = KeyTapMonitor.classify(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn, time: 5)
        #expect(event == .keyDown(at: 5))
    }

    @Test func fnFlagsChangeWithoutFlagIsUp() {
        let event = KeyTapMonitor.classify(type: .flagsChanged, keyCode: 63, flags: [], time: 6)
        #expect(event == .keyUp(at: 6))
    }

    @Test func otherModifierOrKeyIsOtherKey() {
        #expect(KeyTapMonitor.classify(type: .flagsChanged, keyCode: 56, flags: .maskShift, time: 0) == .otherModifierDown(at: 0))
        #expect(KeyTapMonitor.classify(type: .keyDown, keyCode: 0, flags: .maskSecondaryFn, time: 0) == .otherKeyDown(at: 0))
    }

    @Test func modifierReleaseIsIgnored() {
        #expect(KeyTapMonitor.classify(type: .flagsChanged, keyCode: 56, flags: [], time: 0) == nil)
        #expect(KeyTapMonitor.classify(type: .flagsChanged, keyCode: 56, flags: .maskSecondaryFn, time: 0) == nil)
    }

    @Test func unrelatedEventsAreIgnored() {
        #expect(KeyTapMonitor.classify(type: .keyUp, keyCode: 0, flags: [], time: 0) == nil)
    }

    @Test func eitherControlKeyIsThePushToTalkKey() {
        for keyCode: Int64 in [59, 62] {
            #expect(KeyTapMonitor.classify(key: .control, type: .flagsChanged, keyCode: keyCode, flags: .maskControl, time: 1) == .keyDown(at: 1))
            #expect(KeyTapMonitor.classify(key: .control, type: .flagsChanged, keyCode: keyCode, flags: [], time: 2) == .keyUp(at: 2))
        }
    }

    /// Releasing one control while the other is still held keeps the flag set.
    @Test func controlStaysDownWhileTheOtherControlIsHeld() {
        #expect(KeyTapMonitor.classify(key: .control, type: .flagsChanged, keyCode: 62, flags: .maskControl, time: 3) == .keyDown(at: 3))
    }

    @Test func withControlTheOtherModifiersStillInterrupt() {
        #expect(KeyTapMonitor.classify(key: .control, type: .flagsChanged, keyCode: 55, flags: [.maskControl, .maskCommand], time: 0) == .otherModifierDown(at: 0))
        #expect(KeyTapMonitor.classify(key: .control, type: .keyDown, keyCode: 8, flags: .maskControl, time: 0) == .otherKeyDown(at: 0))
    }

    @Test func withControlHeldAModifierReleaseIsIgnored() {
        #expect(KeyTapMonitor.classify(key: .control, type: .flagsChanged, keyCode: 56, flags: .maskControl, time: 0) == nil)
    }

    @Test func withControlTheFnKeyIsNotThePushToTalkKey() {
        #expect(KeyTapMonitor.classify(key: .control, type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn, time: 0) == nil)
    }
}

/// The App Store build's hot keys.
struct HotKeyMonitorTests {
    @Test func eachShortcutHasItsModifiers() {
        #expect(HotKeyMonitor.modifiers(of: .optionSpace) == UInt32(optionKey))
        #expect(HotKeyMonitor.modifiers(of: .controlOptionSpace) == UInt32(optionKey | controlKey))
    }

    /// ⌃⌥Space ends when either modifier is let go.
    @Test func bothModifiersMustStayHeld() {
        #expect(PushToTalkKey.controlOptionSpace.flag == [.maskControl, .maskAlternate])
        #expect(!CGEventFlags.maskAlternate.contains(PushToTalkKey.controlOptionSpace.flag))
    }
}
