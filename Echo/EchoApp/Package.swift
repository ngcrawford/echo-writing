// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Echo",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../EchoEngine")],
    targets: [
        .executableTarget(name: "Echo", dependencies: [.product(name: "EchoEngine", package: "EchoEngine")]),
    ]
)
