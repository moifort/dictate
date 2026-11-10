import CoreGraphics

/// The modifier held to dictate.
nonisolated enum PushToTalkKey: String, CaseIterable, Identifiable, Sendable {
    /// Either control key: the default, works out of the box on any keyboard.
    case control
    /// 🌐 fn: macOS must be told to leave it alone.
    case fn
    /// ⌥Space, the App Store build's default: a global hot key needs no
    /// permission, but a modifier alone cannot be one.
    case optionSpace
    /// ⌃⌥Space, the App Store build's other choice: ⌥Space types the
    /// non-breaking space on French keyboards, among others.
    case controlOptionSpace

    var id: String { rawValue }

    /// What this build can listen to, the default first.
    static var available: [PushToTalkKey] {
        Distribution.isAppStore ? [.optionSpace, .controlOptionSpace] : [.control, .fn]
    }

    var displayName: String {
        switch self {
        case .fn: "fn"
        case .control: "control"
        case .optionSpace: String(localized: "option + espace")
        case .controlOptionSpace: String(localized: "control + option + espace")
        }
    }

    var symbol: String {
        switch self {
        case .fn: "globe"
        case .control: "control"
        case .optionSpace: "option"
        case .controlOptionSpace: "control"
        }
    }

    /// Virtual key codes of the physical keys: left and right for control.
    var keyCodes: Set<Int64> {
        switch self {
        case .fn: [63]
        case .control: [59, 62]
        case .optionSpace, .controlOptionSpace: [49]
        }
    }

    /// The flags that stay set while the key is held.
    var flag: CGEventFlags {
        switch self {
        case .fn: .maskSecondaryFn
        case .control: .maskControl
        case .optionSpace: .maskAlternate
        case .controlOptionSpace: [.maskControl, .maskAlternate]
        }
    }

    /// Control is mostly a shortcut modifier: a key typed while it is held is a
    /// shortcut, however long it was held first. fn and ⌥Space keep the short
    /// window, past which a stray key does not cost the dictation.
    var cancelsOnAnyKey: Bool { self == .control }

    /// A fresh gesture recognizer for this key.
    var gesture: PushToTalkGesture { PushToTalkGesture(cancelsOnAnyKey: cancelsOnAnyKey) }

    /// Only fn has a system action of its own that must be disabled.
    var needsSystemKeyFreed: Bool { self == .fn }
}
