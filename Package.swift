// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoulseekiOS",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SoulseekProtocol", targets: ["SoulseekProtocol"]),
    ],
    targets: [
        .target(name: "SoulseekProtocol"),
        .executableTarget(name: "slsk-spike", dependencies: ["SoulseekProtocol"]),
        .testTarget(name: "SoulseekProtocolTests", dependencies: ["SoulseekProtocol"]),
    ]
)