import DictateKit
import os

/// `log stream --predicate 'subsystem == "com.polyforms.dictate"'`, DictateKit included.
nonisolated enum Log {
    static let app = Logger(subsystem: LogSubsystem.name, category: "app")
    static let hotkey = Logger(subsystem: LogSubsystem.name, category: "hotkey")
    static let dictation = Logger(subsystem: LogSubsystem.name, category: "dictation")
    static let indicator = Logger(subsystem: LogSubsystem.name, category: "indicator")
}
