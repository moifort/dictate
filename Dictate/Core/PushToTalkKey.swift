import CoreGraphics

/// The modifier held to dictate.
nonisolated enum PushToTalkKey: String, CaseIterable, Identifiable, Sendable {
    /// Either control key: the default, works out of the box on any keyboard.
    case control
    /// 🌐 fn: macOS must be told to leave it alone.
    case fn
    /// ⌥Space, the App Store build's only key: a global hot key needs no
    /// permission, but a modifier alone cannot be one.
    case optionSpace

    var id: String { rawValue }

    /// What this build can listen to, the default first.
    static var available: [PushToTalkKey] {
        Distribution.isAppStore ? [.optionSpace] : [.control, .fn]
    }

    var displayName: String {
        switch self {
        case .fn: "fn"
        case .control: "control"
        case .optionSpace: String(localized: "option + espace")
        }
    }

    var symbol: String {
        switch self {
        case .fn: "globe"
        case .control: "control"
        case .optionSpace: "option"
        }
    }

    /// Virtual key codes of the physical keys: left and right for control.
    var keyCodes: Set<Int64> {
        switch self {
        case .fn: [63]
        case .control: [59, 62]
        case .optionSpace: [49]
        }
    }

    /// The flag that stays set while the key is held.
    var flag: CGEventFlags {
        switch self {
        case .fn: .maskSecondaryFn
        case .control: .maskControl
        case .optionSpace: .maskAlternate
        }
    }

    /// Only fn has a system action of its own that must be disabled.
    var needsSystemKeyFreed: Bool { self == .fn }
}
