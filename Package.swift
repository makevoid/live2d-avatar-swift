// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Live2DAvatar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Live2DAvatar", targets: ["Live2DAvatar"]),
        .library(name: "GPTLiveSwift", targets: ["GPTLiveSwift"])
    ],
    dependencies: [
        .package(path: "vendor/swift-cubism"),
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "154.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .executableTarget(
            name: "Live2DAvatar",
            dependencies: ["GPTLiveSwift", "AvatarBehavior", .product(name: "Cubism", package: "swift-cubism")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .target(name: "GPTLiveSwift", dependencies: [.product(name: "WebRTC", package: "WebRTC")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "AvatarBehavior", dependencies: ["GPTLiveSwift", .product(name: "Yams", package: "Yams")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "GPTLiveSwiftTests", dependencies: ["GPTLiveSwift", "AvatarBehavior"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
