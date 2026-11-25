// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PithCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PithCore",
            targets: ["PithCore"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "PithFFI",
            path: "PithFFI.xcframework"
        ),
        .target(
            name: "PithCore",
            dependencies: ["PithFFI"],
            path: "Sources/PithCore"
        )
    ]
)
