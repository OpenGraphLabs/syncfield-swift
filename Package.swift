// swift-tools-version: 5.9

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let defaultLocalInsta360SDKPath =
    packageDirectory
        .appendingPathComponent("../og-skill/mobile/ios/Frameworks/Insta360/INSCameraServiceSDK.xcframework")
        .standardizedFileURL
        .path
let localInsta360SDKPath =
    ProcessInfo.processInfo.environment["SYNCFIELD_INSTA360_SDK_PATH"] ?? defaultLocalInsta360SDKPath
let localInsta360SDK = URL(fileURLWithPath: localInsta360SDKPath)
    .standardizedFileURL
let shouldUseLocalInsta360SDK =
    ProcessInfo.processInfo.environment["SYNCFIELD_DISABLE_LOCAL_INSTA360_SDK"] == nil &&
    FileManager.default.fileExists(atPath: localInsta360SDK.path)

let syncFieldInsta360SwiftSettings: [SwiftSetting] =
    shouldUseLocalInsta360SDK
    ? [.unsafeFlags([
        "-F", localInsta360SDK.appendingPathComponent("ios-arm64-simulator").path,
        "-F", localInsta360SDK.appendingPathComponent("ios-arm64").path,
    ], .when(platforms: [.iOS]))]
    : []

let syncFieldInsta360LinkerSettings: [LinkerSetting] =
    shouldUseLocalInsta360SDK
    ? [.unsafeFlags([
        "-F", localInsta360SDK.appendingPathComponent("ios-arm64-simulator").path,
        "-F", localInsta360SDK.appendingPathComponent("ios-arm64").path,
        "-framework", "INSCameraServiceSDK",
    ], .when(platforms: [.iOS]))]
    : []

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
        .target(
            name: "SyncField",
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ]),
        .target(name: "SyncFieldUIKit", dependencies: ["SyncField"]),
        .target(
            name: "SyncFieldInsta360",
            dependencies: ["SyncField"],
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: syncFieldInsta360SwiftSettings,
            linkerSettings: syncFieldInsta360LinkerSettings),
        .testTarget(name: "SyncFieldTests", dependencies: ["SyncField"]),
        .testTarget(name: "SyncFieldInsta360Tests", dependencies: ["SyncFieldInsta360"]),
    ]
)
