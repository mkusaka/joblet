// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Joblet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JobletCore", targets: ["JobletCore"]),
        .executable(name: "joblet-mcp", targets: ["joblet-mcp"]),
    ],
    targets: [
        .target(name: "JobletCore"),
        .target(name: "JobletMCP", dependencies: ["JobletCore"]),
        .executableTarget(name: "joblet-mcp", dependencies: ["JobletMCP", "JobletCore"]),
        .testTarget(name: "JobletCoreTests", dependencies: ["JobletCore"]),
        .testTarget(name: "JobletMCPTests", dependencies: ["JobletMCP", "JobletCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
