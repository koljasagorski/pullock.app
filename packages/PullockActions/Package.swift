// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullockActions", platforms: [.macOS("27.0")],
    products: [.library(name: "PullockActions", targets: ["PullockActions"])],
    targets: [
        .target(name: "PullockActions"),
        .testTarget(name: "PullockActionsTests", dependencies: ["PullockActions"]),
    ]
)
