import AppKit
import AVFoundation
import ApplicationServices

/// Checks and requests everything Dictate needs from macOS.
enum Permissions {
    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Needed by the listen-only event tap watching `fn`.
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    /// Needed to read the focused field and to post `Cmd+V`.
    static var accessibility: Bool { AXIsProcessTrusted() }

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

    static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    static func openPrivacySettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
