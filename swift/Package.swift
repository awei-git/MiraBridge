// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MiraBridge",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MiraBridge", targets: ["MiraBridge"]),
    ],
    targets: [
        .target(name: "MiraBridge"),
    ]
)
