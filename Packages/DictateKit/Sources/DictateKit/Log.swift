import os

/// Where Dictate and DictateKit log, one subsystem for both:
/// `log stream --predicate 'subsystem == "com.polyforms.dictate"'`.
public nonisolated enum LogSubsystem {
    public static let name = "com.polyforms.dictate"
}

nonisolated enum Log {
    static let dictation = Logger(subsystem: LogSubsystem.name, category: "dictation")
}
