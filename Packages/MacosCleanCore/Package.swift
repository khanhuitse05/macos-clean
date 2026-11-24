// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacosCleanCore",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MacosCleanCore", targets: ["MacosCleanCore"]),
    ],
    targets: [
        .target(
            name: "MacosCleanCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MacosCleanCoreTests",
            dependencies: ["MacosCleanCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
