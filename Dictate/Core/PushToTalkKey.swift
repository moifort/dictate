import CoreGraphics

/// The modifier held to dictate.
nonisolated enum PushToTalkKey: String, CaseIterable, Identifiable, Sendable {
    /// 🌐 fn: the default, but macOS must be told to leave it alone.
    case fn
    /// Either control key: works out of the box, on any keyboard.
    case control

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: "fn"
        case .control: "control"
        }
    }

    var symbol: String {
        switch self {
        case .fn: "globe"
        case .control: "control"
        }
    }

    /// Virtual key codes of the physical keys: left and right for control.
    var keyCodes: Set<Int64> {
        switch self {
        case .fn: [63]
        case .control: [59, 62]
        }
    }

    /// The flag that stays set while the key is held.
    var flag: CGEventFlags {
        switch self {
        case .fn: .maskSecondaryFn
        case .control: .maskControl
        }
    }

    /// Only fn has a system action of its own that must be disabled.
    var needsSystemKeyFreed: Bool { self == .fn }
}
