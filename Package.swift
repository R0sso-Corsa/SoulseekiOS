// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoulseekiOS",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SoulseekProtocol", targets: ["SoulseekProtocol"]),
        .library(name: "SoulseekCore", targets: ["SoulseekCore"]),
    ],
    targets: [
        .target(name: "SoulseekProtocol"),
        .target(name: "SoulseekCore", dependencies: ["SoulseekProtocol"]),
        .executableTarget(name: "slsk-spike", dependencies: ["SoulseekProtocol"]),
        .testTarget(name: "SoulseekProtocolTests", dependencies: ["SoulseekProtocol"]),
        .testTarget(name: "SoulseekCoreTests", dependencies: ["SoulseekCore"]),
    ]
)