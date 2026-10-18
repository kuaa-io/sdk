// swift-tools-version:6.0
// KUAA's SDK for Swift, written by sdk/generator; do not edit. The
// repository's root Package.swift builds these same sources, so SwiftPM can
// depend on https://github.com/kuaa-io/sdk.
import PackageDescription

let package = Package(
    name: "KuaaSDK",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "KuaaSDK", targets: ["Kuaa"])
    ],
    targets: [
        .target(name: "Kuaa"),
        .testTarget(name: "KuaaTests", dependencies: ["Kuaa"], exclude: ["webhook-vectors.json"]),
    ]
)
