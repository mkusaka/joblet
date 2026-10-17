// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Joblet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JobletCore", targets: ["JobletCore"]),
    ],
    targets: [
        .target(name: "JobletCore"),
        .testTarget(name: "JobletCoreTests", dependencies: ["JobletCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
