// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iSnip",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AirSnipCore", targets: ["AirSnipCore"]),
        .executable(name: "iSnip", targets: ["AirSnipApp"])
    ],
    targets: [
        .target(
            name: "AirSnipCore",
            path: "Sources/AirSnipCore"
        ),
        .executableTarget(
            name: "AirSnipApp",
            dependencies: ["AirSnipCore"],
            path: "Sources/AirSnipApp"
        ),
        .testTarget(
            name: "AirSnipCoreTests",
            dependencies: ["AirSnipCore"],
            path: "Tests/AirSnipCoreTests"
        )
    ]
)
