// swift-tools-version:6.0
// SwiftPM reads a package at the root of its repository, so this file exposes
// the Swift SDK that sdk/generator writes under swift/ to
// .package(url: "https://github.com/kuaa-io/sdk", from: "X.Y.Z"). It is
// written by hand: keep it equal to swift/Package.swift but for the paths.
import PackageDescription

let package = Package(
    name: "KuaaSDK",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "KuaaSDK", targets: ["Kuaa"])
    ],
    targets: [
        .target(name: "Kuaa", path: "swift/Sources/Kuaa"),
        .testTarget(
            name: "KuaaTests", dependencies: ["Kuaa"], path: "swift/Tests/KuaaTests", exclude: ["webhook-vectors.json"]),
    ]
)
