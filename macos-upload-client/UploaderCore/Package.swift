// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UploaderCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UploaderCore", targets: ["UploaderCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "UploaderCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "UploaderCoreTests",
            dependencies: ["UploaderCore"]
        ),
    ]
)
