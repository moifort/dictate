import os

/// `log stream --predicate 'subsystem == "com.thibautmottet.dictate"'`
nonisolated enum Log {
    static let app = Logger(subsystem: "com.thibautmottet.dictate", category: "app")
    static let hotkey = Logger(subsystem: "com.thibautmottet.dictate", category: "hotkey")
    static let dictation = Logger(subsystem: "com.thibautmottet.dictate", category: "dictation")
    static let indicator = Logger(subsystem: "com.thibautmottet.dictate", category: "indicator")
}
