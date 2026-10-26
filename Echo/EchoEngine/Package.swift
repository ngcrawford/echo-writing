// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EchoEngine",
    platforms: [.macOS(.v14)],
    products: [.library(name: "EchoEngine", targets: ["EchoEngine"])],
    targets: [
        .target(name: "EchoEngine", resources: [.copy("Resources/zipf-en.tsv")]),
        .testTarget(name: "EchoEngineTests", dependencies: ["EchoEngine"]),
    ]
)
