// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "AgentUsage", dependencies: ["CSQLite"]),
        .testTarget(name: "AgentUsageTests", dependencies: ["AgentUsage", "CSQLite"]),
    ]
)
