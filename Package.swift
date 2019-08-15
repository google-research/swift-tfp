// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ShapeAnalyzer",
    dependencies: [
         .package(url: "/Users/apaszke/libsil", .branch("improvements")),
         // FIXME: We need this for command-line argument parsing only.
         .package(url: "https://github.com/apple/swift-package-manager.git", from: "0.1.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "ShapeAnalyzer",
            dependencies: [
              "SIL",
              "SPMUtility"]),
        .testTarget(
            name: "ShapeAnalyzerTests",
            dependencies: ["ShapeAnalyzer"]),
    ]
)
