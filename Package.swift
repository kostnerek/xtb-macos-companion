// swift-tools-version: 6.0
import PackageDescription

// XTBKit: decoding xStation's messages, folding them into per-account snapshots, and history.
let package = Package(
    name: "XTBKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "XTBKit", targets: ["XTBKit"]),
    ],
    targets: [
        .target(name: "XTBKit"),
        .testTarget(name: "XTBKitTests", dependencies: ["XTBKit"], resources: [.copy("Fixtures")]),
    ]
)
