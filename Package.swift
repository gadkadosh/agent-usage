// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "AgentUsage"),
        .testTarget(name: "AgentUsageTests", dependencies: ["AgentUsage"])
    ]
)
