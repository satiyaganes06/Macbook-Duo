// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacbookDuo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacbookDuo", targets: ["MacbookDuo"]),
        .library(name: "DuoCore", targets: ["DuoCore"]),
    ],
    targets: [
        // Everything that is not AppKit glue lives here so it can be unit tested.
        .target(
            name: "DuoCore",
            path: "Sources/DuoCore",
            exclude: ["Shaders/Shaders.metal"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Menu bar app: status item, hot key, app lifecycle.
        .executableTarget(
            name: "MacbookDuo",
            dependencies: ["DuoCore"],
            path: "Sources/MacbookDuo",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "DuoCoreTests",
            dependencies: ["DuoCore"],
            path: "Tests/DuoCoreTests"
        ),
    ]
)
