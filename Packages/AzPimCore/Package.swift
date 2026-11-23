// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AzPimCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AzPimCore", targets: ["AzPimCore"])
    ],
    targets: [
        // Resources: the core's String Catalog (English source, French).
        .target(name: "AzPimCore", resources: [.process("Resources")]),
        .testTarget(name: "AzPimCoreTests", dependencies: ["AzPimCore"])
    ]
)
