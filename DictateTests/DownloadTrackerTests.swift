import FluidAudio
import Foundation
import Synchronization
import Testing
@testable import Dictate

struct DownloadTrackerTests {
    /// The sequence FluidAudio 0.17.7 reported while downloading Parakeet Ultra.
    @Test func reportsTheFirstPassAsTheDownloadThenOneWhenCompiling() {
        let reports = Mutex<[Double]>([])
        let tracker = DownloadTracker { fraction in reports.withLock { $0.append(fraction) } }
        let events: [DownloadProgress] = [
            .init(fractionCompleted: 0, phase: .listing),
            .init(fractionCompleted: 0, phase: .downloading(completedFiles: 0, totalFiles: 20)),
            .init(fractionCompleted: 0.2, phase: .downloading(completedFiles: 5, totalFiles: 20)),
            .init(fractionCompleted: 0.5, phase: .downloading(completedFiles: 20, totalFiles: 20)),
            .init(fractionCompleted: 0.5, phase: .compiling(modelName: "Preprocessor.mlmodelc")),
            .init(fractionCompleted: 1, phase: .compiling(modelName: "")),
            // Every following model restarts from 0.5 while being compiled.
            .init(fractionCompleted: 0.5, phase: .downloading(completedFiles: 0, totalFiles: 0)),
            .init(fractionCompleted: 0.5, phase: .compiling(modelName: "Encoder.mlmodelc")),
        ]
        events.forEach(tracker.update)
        #expect(reports.withLock { $0 } == [0, 0.4, 0.99, 1])
    }
}
