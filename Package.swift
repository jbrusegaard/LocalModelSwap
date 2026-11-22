// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ModelSwitch",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .target(
            name: "ModelSwitchCore",
            path: "Sources/ModelSwitchCore"
        ),
        .executableTarget(
            name: "ModelSwitch",
            dependencies: ["ModelSwitchCore"],
            path: "Sources/ModelSwitch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "ModelSwitchCoreTests",
            dependencies: ["ModelSwitchCore"],
            path: "Tests/ModelSwitchCoreTests"
        ),
    ]
)
