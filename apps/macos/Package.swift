// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PithMac",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "PithCore")
    ],
    targets: [
        .executableTarget(
            name: "PithMacApp",
            dependencies: [
                .product(name: "PithCore", package: "PithCore")
            ],
            path: "Sources/PithMacApp"
        ),
        .testTarget(
            name: "PithMacTests",
            dependencies: [
                .product(name: "PithCore", package: "PithCore")
            ],
            path: "Tests/PithMacTests"
        )
    ]
)
