// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaolaScreenStudio",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "PaolaScreenStudio",
            path: "Sources/PaolaScreenStudio"
        ),
        .testTarget(
            name: "PaolaScreenStudioTests",
            dependencies: ["PaolaScreenStudio"],
            path: "Tests/PaolaScreenStudioTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
