// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XTBKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "XTBKit", targets: ["XTBKit"]),
    ],
    targets: [
        .target(name: "XTBKit"),
        .executableTarget(
            name: "xtb-spike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "XTBKitTests", dependencies: ["XTBKit"]),
    ]
)
