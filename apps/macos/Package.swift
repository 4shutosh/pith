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
        .target(
            name: "PithMacCore",
            dependencies: [
                .product(name: "PithCore", package: "PithCore")
            ],
            path: "Sources/PithMacCore"
        ),
        .executableTarget(
            name: "PithMacApp",
            dependencies: [
                "PithMacCore",
                .product(name: "PithCore", package: "PithCore")
            ],
            path: "Sources/PithMacApp"
        ),
        .testTarget(
            name: "PithMacTests",
            dependencies: [
                "PithMacCore",
                .product(name: "PithCore", package: "PithCore")
            ],
            path: "Tests/PithMacTests"
        )
    ]
)
