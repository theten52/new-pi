// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NewPiCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "NewPiCore",
            targets: ["NewPiCore"]
        ),
        .executable(
            name: "new-pi",
            targets: ["NewPiCLI"]
        ),
    ],
    targets: [
        .target(
            name: "NewPiCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "NewPiCLI",
            dependencies: ["NewPiCore"]
        ),
        .testTarget(
            name: "NewPiCoreTests",
            dependencies: ["NewPiCore"]
        ),
    ]
)
