// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullockUSB",
    platforms: [.macOS("27.0")],
    products: [.library(name: "PullockUSB", targets: ["PullockUSB"])],
    dependencies: [.package(path: "../PullockCore")],
    targets: [
        .target(name: "PullockUSB", dependencies: [.product(name: "PullockCore", package: "PullockCore")]),
        .testTarget(name: "PullockUSBTests", dependencies: ["PullockUSB"]),
    ]
)
