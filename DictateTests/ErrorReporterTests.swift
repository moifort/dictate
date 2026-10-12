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
