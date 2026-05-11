// swift-tools-version: 5.9

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let insta360SDKRelativePath = "mobile/ios/Frameworks/Insta360/INSCameraServiceSDK.xcframework"
let environment = ProcessInfo.processInfo.environment
let hostAppRootCandidates = [
    environment["PROJECT_DIR"],
    environment["SRCROOT"],
    environment["SOURCE_ROOT"],
    environment["WORKSPACE_DIR"],
    environment["PWD"],
].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
let homeDirectory = environment["HOME"].map { URL(fileURLWithPath: $0) }

let localInsta360SDKCandidates: [URL] = ([
    ProcessInfo.processInfo.environment["SYNCFIELD_INSTA360_SDK_PATH"].map {
        URL(fileURLWithPath: $0)
    },
    packageDirectory.appendingPathComponent("../og-skill/\(insta360SDKRelativePath)"),
    currentDirectory.appendingPathComponent(insta360SDKRelativePath),
    currentDirectory.appendingPathComponent("ios/Frameworks/Insta360/INSCameraServiceSDK.xcframework"),
    currentDirectory.appendingPathComponent("Frameworks/Insta360/INSCameraServiceSDK.xcframework"),
] + hostAppRootCandidates.flatMap { root -> [URL?] in
    [
        root.appendingPathComponent("Frameworks/Insta360/INSCameraServiceSDK.xcframework"),
        root.appendingPathComponent("ios/Frameworks/Insta360/INSCameraServiceSDK.xcframework"),
        root.appendingPathComponent(insta360SDKRelativePath),
    ]
} + [
    homeDirectory?.appendingPathComponent("Documents/og-skill/\(insta360SDKRelativePath)"),
]).compactMap { $0?.standardizedFileURL }
let localInsta360SDK = localInsta360SDKCandidates.first {
    FileManager.default.fileExists(atPath: $0.path)
}
let shouldUseLocalInsta360SDK =
    ProcessInfo.processInfo.environment["SYNCFIELD_DISABLE_LOCAL_INSTA360_SDK"] == nil &&
    localInsta360SDK != nil

let syncFieldInsta360SwiftSettings: [SwiftSetting] =
    shouldUseLocalInsta360SDK && localInsta360SDK != nil
    ? [.unsafeFlags([
        "-F", localInsta360SDK!.appendingPathComponent("ios-arm64-simulator").path,
        "-F", localInsta360SDK!.appendingPathComponent("ios-arm64").path,
    ], .when(platforms: [.iOS]))]
    : []

let syncFieldInsta360LinkerSettings: [LinkerSetting] =
    shouldUseLocalInsta360SDK && localInsta360SDK != nil
    ? [.unsafeFlags([
        "-F", localInsta360SDK!.appendingPathComponent("ios-arm64-simulator").path,
        "-F", localInsta360SDK!.appendingPathComponent("ios-arm64").path,
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
