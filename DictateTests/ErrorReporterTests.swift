import Foundation
import Testing
@testable import Dictate

struct ErrorReporterTests {
    @Test func releaseCarriesVersionAndBuild() {
        #expect(ErrorReporter.release(version: "1.2.0", build: "45") == "dictate@1.2.0+45")
    }

    @Test func releaseWithoutBuildKeepsTheVersionAlone() {
        #expect(ErrorReporter.release(version: "1.2.0", build: nil) == "dictate@1.2.0")
        #expect(ErrorReporter.release(version: "1.2.0", build: "") == "dictate@1.2.0")
    }

    @Test func releaseWithoutVersionFallsBackToZero() {
        #expect(ErrorReporter.release(version: nil, build: "7") == "dictate@0.0.0+7")
    }

    /// The test host must never send the suite's deliberate failures to Sentry.
    @Test func reportingIsOffUnderTests() {
        #expect(!ErrorReporter.isEnabled)
    }
}

/// What reaches Sentry from an error's text.
struct ErrorScrubbingTests {
    @Test func homePathsAreMasked() {
        let text = ErrorReporter.scrubbed("cannot open \(NSHomeDirectory())/.claude/settings.json or /Users/alice/x")
        #expect(text == "cannot open ~/.claude/settings.json or /Users/…/x")
    }

    @Test func secretsAndAddressesAreMasked() {
        let text = ErrorReporter.scrubbed("Incorrect API key provided: sk-proj-abc123XYZ****wxyz for jane.doe@example.com, AIzaSyD-1234567890")
        #expect(!text.contains("abc123"))
        #expect(!text.contains("jane.doe"))
        #expect(!text.contains("AIzaSy"))
    }

    @Test func longTextsAreCut() {
        let text = ErrorReporter.scrubbed(String(repeating: "x", count: 5_000))
        #expect(text.count == ErrorReporter.maximumTextLength + 1)
    }

    /// The bridged user info carries the whole description: only the scrubbed one is sent.
    @Test func theReportedErrorKeepsOnlyItsScrubbedText() {
        let error = ClaudeCLIError.noResult("Error: ENOENT \(NSHomeDirectory())/.claude.json")
        let reported = ErrorReporter.reportable(error)
        #expect(reported.domain == (error as NSError).domain)
        #expect(reported.code == (error as NSError).code)
        #expect(!reported.localizedDescription.contains(NSHomeDirectory()))
        #expect(reported.userInfo.count == 1)
    }
}
