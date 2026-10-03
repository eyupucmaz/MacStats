// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacStats",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MacStats",
            targets: ["MacStats"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MacStats",
            path: "Sources/MacStats",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "MacStatsTests",
            dependencies: ["MacStats"],
            path: "Tests/MacStatsTests"
        )
    ]
)
