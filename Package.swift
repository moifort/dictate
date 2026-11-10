// swift-tools-version: 6.2
import PackageDescription

// Offers DictateKit, Dictate's hearing and transcription, to apps that add this
// repository as a Swift package:
//
//     .package(url: "https://github.com/moifort/dictate", branch: "main")
//
// The same target as Packages/DictateKit/Package.swift, which Dictate itself and
// the package's tests use: keep the two in step. Not for building Dictate: run
// `swift build` or `swift test` in Packages/DictateKit, never here, where SwiftPM
// would rewrite the app's Package.resolved without its other pins.
let package = Package(
    name: "DictateKit",
    defaultLocalization: "fr",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "DictateKit", targets: ["DictateKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.18.2")
    ],
    targets: [
        .target(
            name: "DictateKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Packages/DictateKit/Sources/DictateKit",
            resources: [.process("Resources")],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        )
    ]
)
