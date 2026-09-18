// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DisplayMaster",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DisplayMaster",
            path: "Sources/DisplayMaster",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
