import Foundation

/// How this copy of Dictate reached the Mac.
///
/// The Mac App Store build (`AppStore` configuration, `APP_STORE` flag) runs in
/// the App Sandbox, which changes three things:
/// - the `claude` CLI is out of reach: the sandbox hides the home folder, and a
///   child process would inherit the sandbox anyway, so Claude Code could not
///   read its own credentials. Only Apple Intelligence reviews;
/// - the App Store installs the updates: the built-in updater stays off;
/// - deleting the app from Applications removes its sandbox container: the
///   built-in uninstaller, which runs `tccutil`, stays off.
nonisolated enum Distribution {
    #if APP_STORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
}
