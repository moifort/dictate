import AVFoundation
import AppKit
import ApplicationServices

/// Checks and requests everything Dictate needs from macOS.
enum Permissions {
    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    #if APP_STORE
    /// The hot key needs no permission.
    static let inputMonitoring = true
    /// Dictations stay in the pasteboard: nothing to read or post.
    static let accessibility = true
    #else
    /// Needed by the listen-only event tap watching `fn`.
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    /// Needed to read the focused field and to post `Cmd+V`.
    static var accessibility: Bool { AXIsProcessTrusted() }
    #endif

    /// The 🌐 key must do nothing, otherwise macOS opens emoji or dictation.
    static var fnKeyFree: Bool {
        // 0 = Do Nothing. The key is absent while the system default (emoji) applies.
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int == 0
    }

    /// The system prompt only appears once: after a refusal, only System Settings can grant it.
    static func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            openPrivacySettings("Privacy_Microphone")
        }
    }

    #if !APP_STORE
    static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    #endif

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// The "Apple Intelligence & Siri" pane, where the on-device model is turned on.
    static func openAppleIntelligenceSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
    }

    static func openPrivacySettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
