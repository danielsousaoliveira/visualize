// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "visualize",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "visualize",
            path: "Sources/Visualize"
        ),
        .testTarget(
            name: "VisualizeTests",
            dependencies: ["visualize"],
            path: "Tests/VisualizeTests"
        ),
    ]
)
