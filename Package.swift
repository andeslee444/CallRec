// swift-tools-version: 5.9
// Package.swift — SPM dependencies for CallRec

import PackageDescription

let package = Package(
    name: "CallRec",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/rnine/SimplyCoreAudio.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "CallRecApp",
            dependencies: ["SimplyCoreAudio"],
            path: "CallRecApp"
        ),
    ]
)
