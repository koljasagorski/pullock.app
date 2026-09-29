// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullockServices", platforms: [.macOS("27.0")],
    products: [.library(name: "PullockServices", targets: ["PullockServices"]),
               .library(name: "PullockDaemonRuntime", targets: ["PullockDaemonRuntime"])],
    dependencies: [.package(path: "../PullockCore"), .package(path: "../PullockIPC"), .package(path: "../PullockUSB")],
    targets: [
        .target(name: "PullockServices", dependencies: [
            .product(name: "PullockCore", package: "PullockCore"),
            .product(name: "PullockIPC", package: "PullockIPC")]),
        .target(name: "DaemonPowerMessages"),
        .target(name: "PullockDaemonRuntime", dependencies: ["PullockServices", "DaemonPowerMessages",
            .product(name: "PullockUSB", package: "PullockUSB")]),
        .testTarget(name: "PullockServicesTests", dependencies: ["PullockServices"]),
        .testTarget(name: "PullockDaemonRuntimeTests", dependencies: ["PullockDaemonRuntime"]),
    ]
)
