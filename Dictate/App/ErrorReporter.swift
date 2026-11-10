import Foundation
import Sentry
import os

/// Sends errors and crashes to Sentry. Release builds only: a Debug build or
/// a test run would fill the project with the developer's own mistakes.
///
/// Never given what the user said or wrote: only error descriptions, scrubbed
/// of paths and secrets, the phase they happened in and the settings that
/// matter to reproduce them.
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
            // A 5xx from GitHub or anyone else is already told apart and reported,
            // with its context, by the code that made the request: the SDK's own
            // event for the same answer only said "504", twice.
            options.enableCaptureFailedRequests = false
            // A last pass over what the SDK built itself, crash reasons included.
            options.beforeSend = { event in
                for exception in event.exceptions ?? [] {
                    exception.value = exception.value.map(scrubbed)
                }
                return event
            }
        }
    }

    /// The longest error text sent: enough to tell errors apart, too short
    /// for a tool's whole output.
    static let maximumTextLength = 300

    /// An error's text without what could identify the user or leak a
    /// secret: home folder paths, e-mail addresses and API keys are masked,
    /// and the text is cut. The `claude` CLI's standard error and the first
    /// bytes of an API's answer end up in error descriptions.
    static func scrubbed(_ text: String) -> String {
        var text = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let masks: [(pattern: String, replacement: String)] = [
            (#"/Users/[^/\s"']+"#, "/Users/…"),
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "…@…"),
            (#"\b(sk-(ant-)?|AIza)[A-Za-z0-9_\-*.]{6,}"#, "[key]"),
        ]
        for mask in masks {
            text = text.replacingOccurrences(
                of: mask.pattern, with: mask.replacement, options: [.regularExpression, .caseInsensitive]
            )
        }
        guard text.count > maximumTextLength else { return text }
        return String(text.prefix(maximumTextLength)) + "…"
    }

    /// What is sent for `error`: its domain, its code and its scrubbed text.
    /// Never the error itself, whose bridged user info carries its whole text.
    static func reportable(_ error: Error) -> NSError {
        let bridged = error as NSError
        return NSError(domain: bridged.domain, code: bridged.code, userInfo: [
            NSLocalizedDescriptionKey: scrubbed(error.localizedDescription),
        ])
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
        let reported = reportable(error)
        SentrySDK.capture(error: reported) { scope in
            scope.setLevel(level)
            scope.setTag(value: category, key: "category")
            scope.setExtra(value: scrubbed(message), key: "message")
            scope.setExtra(value: reported.localizedDescription, key: "description")
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
