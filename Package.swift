// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenVoxTTSBuddy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenVoxTTSBuddy",
            path: "Sources/OpenVoxTTSBuddy"
        )
    ]
)
