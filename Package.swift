// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "DeviceHarbor",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .library(
            name: "DeviceHarborCore",
            targets: ["DeviceHarborCore"]
        ),
        .executable(
            name: "DeviceHarbor",
            targets: ["DeviceHarbor"]
        )
    ],
    targets: [
        .target(
            name: "DeviceHarborCore",
            path: "Sources/DeviceHarborCore"
        ),
        .executableTarget(
            name: "DeviceHarbor",
            dependencies: ["DeviceHarborCore"],
            path: "Sources/DeviceHarbor"
        ),
        .testTarget(
            name: "DeviceHarborCoreTests",
            dependencies: ["DeviceHarborCore"],
            path: "Tests/DeviceHarborCoreTests"
        )
    ]
)
