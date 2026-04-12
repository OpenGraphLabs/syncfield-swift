// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SyncField",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "SyncField",         targets: ["SyncField"]),
        .library(name: "SyncFieldUIKit",    targets: ["SyncFieldUIKit"]),
        .library(name: "SyncFieldInsta360", targets: ["SyncFieldInsta360"]),
    ],
    targets: [
        .target(name: "SyncField"),
        .target(name: "SyncFieldUIKit",    dependencies: ["SyncField"]),
        .target(name: "SyncFieldInsta360", dependencies: ["SyncField"]),
        .testTarget(name: "SyncFieldTests", dependencies: ["SyncField"]),
    ]
)
