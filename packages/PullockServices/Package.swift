// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullockServices", platforms: [.macOS("27.0")],
    products: [.library(name: "PullockServices", targets: ["PullockServices"])],
    dependencies: [.package(path: "../PullockCore"), .package(path: "../PullockIPC")],
    targets: [
        .target(name: "PullockServices", dependencies: [
            .product(name: "PullockCore", package: "PullockCore"),
            .product(name: "PullockIPC", package: "PullockIPC")]),
        .testTarget(name: "PullockServicesTests", dependencies: ["PullockServices"]),
    ]
)
