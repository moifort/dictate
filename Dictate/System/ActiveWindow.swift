import AppKit
import ApplicationServices

/// Where the window the user is typing in sits, through the Accessibility API.
enum ActiveWindow {
    /// The frontmost app's focused window, in AppKit coordinates (origin at the
    /// bottom left of the primary screen), or nil if the app does not expose it.
    @MainActor static func frame() -> CGRect? {
        #if APP_STORE
        nil
        #else
        guard let app = NSWorkspace.shared.frontmostApplication,
              let primary = NSScreen.screens.first else { return nil }
        // Called as `fn` goes down: a busy app must not delay the pill.
        let ax = AXReader(messagingTimeout: 0.1)
        guard let window = ax.focusedWindow(pid: app.processIdentifier),
              let position = ax.point(window, kAXPositionAttribute),
              let size = ax.size(window, kAXSizeAttribute) else { return nil }
        return appKitFrame(axOrigin: position, size: size, primaryHeight: primary.frame.height)
        #endif
    }

    /// Accessibility measures from the top left of the primary screen, AppKit from its bottom left.
    nonisolated static func appKitFrame(axOrigin: CGPoint, size: CGSize, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: axOrigin.x, y: primaryHeight - axOrigin.y - size.height, width: size.width, height: size.height)
    }

    /// The screen holding most of `window`, else the one under the mouse.
    nonisolated static func screenIndex(for window: CGRect?, mouse: CGPoint, screens: [CGRect]) -> Int? {
        if let window {
            let areas = screens.map { screen -> CGFloat in
                let overlap = screen.intersection(window)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
                return best
            }
        }
        return screens.firstIndex { $0.contains(mouse) }
    }
}
