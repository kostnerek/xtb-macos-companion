// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XTBKit",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "xtb-spike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
