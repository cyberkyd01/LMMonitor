// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LMMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LMMonitor",
            path: "Sources/LMMonitor",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Metal"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
