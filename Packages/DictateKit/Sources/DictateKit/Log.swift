import os

/// The same subsystem and category as Dictate's own dictation log:
/// `log stream --predicate 'subsystem == "com.thibautmottet.dictate"'`.
nonisolated enum Log {
    static let dictation = Logger(subsystem: "com.thibautmottet.dictate", category: "dictation")
}
