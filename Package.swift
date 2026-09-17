// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "DeviceHarbor",
    platforms: [
        .macOS(.v27),
        .iOS(.v27)
    ],
    products: [
        .library(
            name: "DeviceHarborTransport",
            targets: ["DeviceHarborTransport"]
        ),
        .library(
            name: "DeviceHarborCore",
            targets: ["DeviceHarborCore"]
        ),
        .executable(
            name: "DeviceHarbor",
            targets: ["DeviceHarbor"]
        ),
        .executable(
            name: "DeviceHarborRelay",
            targets: ["DeviceHarborRelay"]
        )
    ],
    targets: [
        .target(
            name: "DeviceHarborTransport",
            path: "Sources/DeviceHarborTransport"
        ),
        .target(
            name: "DeviceHarborCore",
            dependencies: ["DeviceHarborTransport"],
            path: "Sources/DeviceHarborCore"
        ),
        .executableTarget(
            name: "DeviceHarbor",
            dependencies: ["DeviceHarborCore", "DeviceHarborTransport"],
            path: "Sources/DeviceHarbor"
        ),
        .executableTarget(
            name: "DeviceHarborRelay",
            dependencies: ["DeviceHarborTransport"],
            path: "Sources/DeviceHarborRelay"
        ),
        .testTarget(
            name: "DeviceHarborCoreTests",
            dependencies: ["DeviceHarborCore", "DeviceHarborTransport"],
            path: "Tests/DeviceHarborCoreTests"
        ),
        .testTarget(
            name: "DeviceHarborTransportTests",
            dependencies: ["DeviceHarborTransport"],
            path: "Tests/DeviceHarborTransportTests"
        )
    ]
)
