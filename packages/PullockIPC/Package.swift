// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullockIPC",
    platforms: [.macOS("27.0")],
    products: [.library(name: "PullockIPC", targets: ["PullockIPC"])],
    dependencies: [.package(path: "../PullockCore")],
    targets: [
        .target(name: "PullockIPC", dependencies: [.product(name: "PullockCore", package: "PullockCore")]),
        .testTarget(name: "PullockIPCTests", dependencies: ["PullockIPC"]),
    ]
)
