// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullockCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PullockCore", targets: ["PullockCore"]),
        .library(name: "PullockSimulation", targets: ["PullockSimulation"]),
    ],
    targets: [
        .target(name: "PullockCore"),
        .target(name: "PullockSimulation", dependencies: ["PullockCore"]),
        .testTarget(name: "PullockCoreTests", dependencies: ["PullockCore", "PullockSimulation"]),
    ]
)
