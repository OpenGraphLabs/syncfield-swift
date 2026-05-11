// swift-tools-version: 5.9

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let insta360SDKRelativePath = "mobile/ios/Frameworks/Insta360/INSCameraServiceSDK.xcframework"
let insta360SDKBinaryTargetName = "INSCameraServiceSDK"
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

func relativePath(from baseDirectory: URL, to target: URL) -> String {
    let baseComponents = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    let targetComponents = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    var commonPrefixCount = 0

    while commonPrefixCount < baseComponents.count,
          commonPrefixCount < targetComponents.count,
          baseComponents[commonPrefixCount] == targetComponents[commonPrefixCount] {
        commonPrefixCount += 1
    }

    let parentTraversal = Array(repeating: "..", count: baseComponents.count - commonPrefixCount)
    let targetSuffix = Array(targetComponents.dropFirst(commonPrefixCount))
    let components = parentTraversal + targetSuffix

    return components.isEmpty ? "." : components.joined(separator: "/")
}

let syncFieldInsta360BinaryTargets: [Target] =
    shouldUseLocalInsta360SDK && localInsta360SDK != nil
    ? [
        .binaryTarget(
            name: insta360SDKBinaryTargetName,
            path: relativePath(from: packageDirectory, to: localInsta360SDK!)
        ),
    ]
    : []

let syncFieldInsta360Dependencies: [Target.Dependency] = {
    var dependencies: [Target.Dependency] = ["SyncField"]

    if shouldUseLocalInsta360SDK {
        dependencies.append(
            .target(
                name: insta360SDKBinaryTargetName,
                condition: .when(platforms: [.iOS])
            )
        )
    }

    return dependencies
}()

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
            dependencies: syncFieldInsta360Dependencies,
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ]),
        .testTarget(name: "SyncFieldTests", dependencies: ["SyncField"]),
        .testTarget(name: "SyncFieldInsta360Tests", dependencies: ["SyncFieldInsta360"]),
    ] + syncFieldInsta360BinaryTargets
)
