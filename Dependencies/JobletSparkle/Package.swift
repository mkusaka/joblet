// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "JobletSparkle",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "JobletSparkle",
            targets: ["JobletSparkle"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.10.0"
        ),
    ],
    targets: [
        .target(
            name: "JobletSparkle",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
    ]
)
