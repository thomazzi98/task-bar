// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TaskBar", targets: ["TaskBar"]),
        .library(name: "TaskBarCore", targets: ["TaskBarCore"])
    ],
    targets: [
        // Pure logic: models, persistence, Claude Code parsing, system probes. No UI.
        .target(name: "TaskBarCore"),
        // The menu bar app: AppKit shell, SwiftUI views, view models.
        .executableTarget(name: "TaskBar", dependencies: ["TaskBarCore"]),
        .testTarget(name: "TaskBarCoreTests", dependencies: ["TaskBarCore"])
    ]
)
