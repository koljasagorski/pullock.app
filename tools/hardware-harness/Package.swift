// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullockHardwareProbe",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "pullock-probe", targets: ["PullockProbe"])],
    dependencies: [.package(path: "../../packages/PullockUSB")],
    targets: [
        .target(name: "ProbeSupport"),
        .target(name: "PowerMessagesC"),
        .executableTarget(name: "PullockProbe", dependencies: ["ProbeSupport", "PowerMessagesC", .product(name: "PullockUSB", package: "PullockUSB")]),
        .testTarget(name: "ProbeSupportTests", dependencies: ["ProbeSupport", .product(name: "PullockUSB", package: "PullockUSB")]),
    ]
)
