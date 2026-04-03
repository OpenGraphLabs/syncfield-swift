// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SyncField",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "SyncField", targets: ["SyncField"]),
    ],
    targets: [
        .target(name: "SyncField"),
        .testTarget(name: "SyncFieldTests", dependencies: ["SyncField"]),
    ]
)
