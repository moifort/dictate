import CoreGraphics
import Testing
@testable import Dictate

struct ActiveWindowTests {
    /// A 1440×900 built-in screen, with a 2560×1440 external one on its right.
    private let screens = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 1440, y: 0, width: 2560, height: 1440),
    ]

    @Test func picksTheScreenOfTheWindowOverTheMouse() {
        let window = CGRect(x: 1600, y: 200, width: 800, height: 600)
        #expect(ActiveWindow.screenIndex(for: window, mouse: CGPoint(x: 100, y: 100), screens: screens) == 1)
    }

    @Test func picksTheScreenHoldingMostOfAStraddlingWindow() {
        let window = CGRect(x: 1240, y: 100, width: 800, height: 600)
        #expect(ActiveWindow.screenIndex(for: window, mouse: CGPoint(x: 100, y: 100), screens: screens) == 1)
    }

    @Test func fallsBackToTheMouseWithoutAWindow() {
        #expect(ActiveWindow.screenIndex(for: nil, mouse: CGPoint(x: 2000, y: 500), screens: screens) == 1)
        #expect(ActiveWindow.screenIndex(for: nil, mouse: CGPoint(x: 100, y: 500), screens: screens) == 0)
    }

    @Test func fallsBackToTheMouseWhenTheWindowIsOffScreen() {
        let window = CGRect(x: -5000, y: -5000, width: 100, height: 100)
        #expect(ActiveWindow.screenIndex(for: window, mouse: CGPoint(x: 100, y: 100), screens: screens) == 0)
    }

    @Test func flipsAccessibilityCoordinates() {
        let frame = ActiveWindow.appKitFrame(
            axOrigin: CGPoint(x: 10, y: 100), size: CGSize(width: 400, height: 300), primaryHeight: 900
        )
        #expect(frame == CGRect(x: 10, y: 500, width: 400, height: 300))
    }
}
