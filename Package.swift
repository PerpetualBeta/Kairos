// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kairos",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kairos",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-framework", "AppKit"]),
            ]
        )
    ]
)
