// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftADB",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "SwiftADB", targets: ["SwiftADB"]),
        .library(name: "SwiftADBTransport", targets: ["SwiftADBTransport"]),
        .library(name: "SwiftADBAuthentication", targets: ["SwiftADBAuthentication"]),
        .library(name: "SwiftADBPairing", targets: ["SwiftADBPairing"]),
        .library(name: "SwiftADBDeviceDiscovery", targets: ["SwiftADBDeviceDiscovery"]),
        .library(name: "SwiftADBClient", targets: ["SwiftADBClient"]),
        .library(name: "SwiftADBShell", targets: ["SwiftADBShell"]),
        .library(name: "SwiftADBFileSync", targets: ["SwiftADBFileSync"]),
        .library(name: "SwiftADBPortForward", targets: ["SwiftADBPortForward"]),
        .library(name: "SwiftADBLogcat", targets: ["SwiftADBLogcat"]),
        .library(name: "SwiftADBiOSKit", targets: ["SwiftADBiOSKit"]),
        .executable(name: "SwiftADBDemo", targets: ["SwiftADBDemo"]),
        .executable(name: "SwiftADBMacApp", targets: ["SwiftADBMacApp"]),
        .executable(name: "SwiftADBTestApp", targets: ["SwiftADBTestApp"]),
    ],
    targets: [
        .target(
            name: "SwiftADBTransport",
            path: "Sources/Transport"
        ),
        .target(
            name: "SwiftADBAuthentication",
            dependencies: ["SwiftADBTransport"],
            path: "Sources/Authentication"
        ),
        .target(
            name: "SwiftADBPairing",
            dependencies: ["SwiftADBTransport", "SwiftADBAuthentication"],
            path: "Sources/Pairing"
        ),
        .target(
            name: "SwiftADBDeviceDiscovery",
            dependencies: ["SwiftADBTransport"],
            path: "Sources/DeviceDiscovery"
        ),
        .target(
            name: "SwiftADBClient",
            dependencies: [
                "SwiftADBTransport",
                "SwiftADBAuthentication",
                "SwiftADBPairing",
                "SwiftADBDeviceDiscovery",
            ],
            path: "Sources/Client"
        ),
        .target(
            name: "SwiftADBShell",
            dependencies: ["SwiftADBClient"],
            path: "Sources/Shell"
        ),
        .target(
            name: "SwiftADBFileSync",
            dependencies: ["SwiftADBClient"],
            path: "Sources/FileSync"
        ),
        .target(
            name: "SwiftADBPortForward",
            dependencies: ["SwiftADBClient"],
            path: "Sources/PortForward"
        ),
        .target(
            name: "SwiftADBLogcat",
            dependencies: ["SwiftADBClient", "SwiftADBShell"],
            path: "Sources/Logcat"
        ),
        .target(
            name: "SwiftADBiOSKit",
            dependencies: ["SwiftADB"],
            path: "Sources/SwiftADBiOSKit"
        ),
        .target(
            name: "SwiftADB",
            dependencies: [
                "SwiftADBClient",
                "SwiftADBShell",
                "SwiftADBFileSync",
                "SwiftADBPortForward",
                "SwiftADBLogcat",
            ],
            path: "Sources/SwiftADB"
        ),
        .executableTarget(
            name: "SwiftADBDemo",
            dependencies: ["SwiftADB"],
            path: "Examples/SwiftADBDemo"
        ),
        .executableTarget(
            name: "SwiftADBMacApp",
            dependencies: ["SwiftADBiOSKit"],
            path: "Examples/SwiftADBMacApp"
        ),
        .executableTarget(
            name: "SwiftADBTestApp",
            dependencies: ["SwiftADB", "SwiftADBiOSKit"],
            path: "Examples/SwiftADBTestApp",
            exclude: ["README.md", "project.yml", "Info-iOS.plist"]
        ),
        .testTarget(
            name: "SwiftADBTests",
            dependencies: ["SwiftADB"],
            path: "Tests/SwiftADBTests"
        ),
    ]
)
