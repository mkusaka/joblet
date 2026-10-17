// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Joblet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JobletCore", targets: ["JobletCore"]),
        .library(name: "JobletMCPKit", targets: ["JobletMCPKit"]),
        .executable(name: "joblet-mcp", targets: ["JobletMCP"]),
    ],
    targets: [
        .target(name: "JobletCore"),
        .target(name: "JobletMCPKit", dependencies: ["JobletCore"]),
        .executableTarget(name: "JobletMCP", dependencies: ["JobletMCPKit"]),
        .testTarget(name: "JobletCoreTests", dependencies: ["JobletCore"]),
        .testTarget(name: "JobletMCPTests", dependencies: ["JobletMCPKit", "JobletCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
