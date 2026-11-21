// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AzPimCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AzPimCore", targets: ["AzPimCore"])
    ],
    targets: [
        .target(name: "AzPimCore"),
        .testTarget(name: "AzPimCoreTests", dependencies: ["AzPimCore"])
    ]
)
