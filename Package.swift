// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MobileRemote",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ADBKit", targets: ["ADBKit"]),
        .library(name: "ScrcpyKit", targets: ["ScrcpyKit"]),
        .library(name: "VideoKit", targets: ["VideoKit"]),
        .library(name: "MirrorKit", targets: ["MirrorKit"]),
        .library(name: "AppleDeviceKit", targets: ["AppleDeviceKit"]),
        .executable(name: "mrctl", targets: ["mrctl"]),
        .executable(name: "MobileRemote", targets: ["MobileRemote"]),
    ],
    targets: [
        .target(name: "ADBKit"),
        .target(
            name: "ScrcpyKit",
            dependencies: ["ADBKit"],
            resources: [.copy("Resources/scrcpy-server-v4.1")]
        ),
        .target(name: "VideoKit"),
        .target(name: "MirrorKit", dependencies: ["ADBKit", "ScrcpyKit", "VideoKit"]),
        .target(name: "AppleDeviceKit", dependencies: ["VideoKit", "MirrorKit"]),
        .executableTarget(name: "mrctl", dependencies: ["ADBKit", "ScrcpyKit", "VideoKit", "MirrorKit", "AppleDeviceKit"]),
        .executableTarget(
            name: "MobileRemote",
            dependencies: ["ADBKit", "ScrcpyKit", "VideoKit", "MirrorKit", "AppleDeviceKit"],
            resources: [.copy("Resources/AppLogo.png")]
        ),
        .testTarget(name: "ADBKitTests", dependencies: ["ADBKit"]),
        .testTarget(name: "ScrcpyKitTests", dependencies: ["ScrcpyKit"]),
        .testTarget(name: "VideoKitTests", dependencies: ["VideoKit"]),
        .testTarget(name: "MirrorKitTests", dependencies: ["MirrorKit"]),
        .testTarget(name: "AppleDeviceKitTests", dependencies: ["AppleDeviceKit"]),
    ]
)
