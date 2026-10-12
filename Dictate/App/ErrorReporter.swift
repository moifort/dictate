import Foundation
import Sentry
import os

/// Sends errors and crashes to Sentry. Release builds only: a Debug build or
/// a test run would fill the project with the developer's own mistakes.
///
/// Never given what the user said or wrote: only error descriptions, the
/// phase they happened in and the settings that matter to reproduce them.
nonisolated enum ErrorReporter {
    static let dsn = "https://62ee408852523f7fe415ffb8442943e5@o4510952263909376.ingest.de.sentry.io/4512244932673616"

    /// Debug builds and tests keep their errors in the console.
    static var isEnabled: Bool {
        #if DEBUG
        false
        #else
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
    }

    /// Call as early as possible, before anything that can fail or crash.
    static func start(bundle: Bundle = .main) {
        guard isEnabled else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = release(
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            )
            options.environment = "production"
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            options.tracesSampleRate = 0
        }
    }

    /// `dictate@1.2.0+45`, the form Sentry splits into version and build.
    static func release(version: String?, build: String?) -> String {
        let version = version?.isEmpty == false ? version! : "0.0.0"
        guard let build, !build.isEmpty else { return "dictate@\(version)" }
        return "dictate@\(version)+\(build)"
    }

    /// An error that was caught: `message` says what was being attempted.
    static func capture(_ error: Error, _ message: String, category: String, level: SentryLevel = .error) {
        guard isEnabled else { return }
        SentrySDK.capture(error: error) { scope in
            scope.setLevel(level)
            scope.setTag(value: category, key: "category")
            scope.setExtra(value: message, key: "message")
            scope.setExtra(value: error.localizedDescription, key: "description")
        }
    }

    /// A failure with no `Error` behind it, say a status code or a missing screen.
    static func capture(message: String, category: String, level: SentryLevel = .error) {
        guard isEnabled else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
            scope.setTag(value: category, key: "category")
        }
    }

    /// A step on the way to an error, shown with the next event.
    static func breadcrumb(_ message: String, category: String) {
        guard isEnabled else { return }
        let crumb = Breadcrumb(level: .info, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Settings worth knowing when reading an event. Searchable in Sentry.
    static func setTags(_ tags: [String: String]) {
        guard isEnabled else { return }
        SentrySDK.configureScope { scope in
            for (key, value) in tags { scope.setTag(value: value, key: key) }
        }
    }
}
