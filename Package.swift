// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "visualize",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DatabaseDriver", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "visualize",
            dependencies: ["DatabaseDriver"],
            path: "Sources/Visualize"
        ),
        .testTarget(
            name: "VisualizeTests",
            dependencies: ["visualize"],
            path: "Tests/VisualizeTests"
        ),
    ]
)
