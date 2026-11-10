// swift-tools-version: 6.2
import PackageDescription

// Dictate's hearing and transcription, reusable by other apps: the microphone,
// the audio analysis and Parakeet.
// The root Package.swift offers the same target to other apps through GitHub:
// keep the two in step.
let package = Package(
    name: "DictateKit",
    defaultLocalization: "fr",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "DictateKit", targets: ["DictateKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.18.2"),
    ],
    targets: [
        .target(
            name: "DictateKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            resources: [.process("Resources")],
            swiftSettings: settings
        ),
        .testTarget(
            name: "DictateKitTests",
            dependencies: ["DictateKit", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: settings
        ),
    ]
)

/// The same as the app (project.yml): Swift 6 mode, main actor by default,
/// and approachable concurrency, whose two features not already on in Swift 6
/// are these. Change them together.
var settings: [SwiftSetting] {
    [
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
    ]
}
