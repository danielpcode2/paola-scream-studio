// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiRecorder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MiRecorder",
            path: "Sources/MiRecorder"
        ),
        .testTarget(
            name: "MiRecorderTests",
            dependencies: ["MiRecorder"],
            path: "Tests/MiRecorderTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
