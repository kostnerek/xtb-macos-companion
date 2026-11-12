// swift-tools-version: 6.0
import PackageDescription

// Sources/xtb-spike is intentionally not a target: it was the exploratory native client
// and is not part of the app.
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
