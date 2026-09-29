// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullockHardwareProbe",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "pullock-probe", targets: ["PullockProbe"])],
    targets: [
        .target(name: "ProbeSupport"),
        .target(name: "PowerMessagesC"),
        .executableTarget(name: "PullockProbe", dependencies: ["ProbeSupport", "PowerMessagesC"]),
        .testTarget(name: "ProbeSupportTests", dependencies: ["ProbeSupport"]),
    ]
)
