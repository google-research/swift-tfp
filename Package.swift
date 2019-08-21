// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ShapeChecker",
    dependencies: [
         .package(url: "https://github.com/tensorflow/swift", .branch("master")),
         // FIXME: We need this for command-line argument parsing only.
         .package(url: "https://github.com/apple/swift-package-manager.git", from: "0.1.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "ShapeChecker",
            dependencies: [
              "LibShapeChecker",
              "SIL",
              "SPMUtility"]),
        .target(
            name: "LibShapeChecker",
            dependencies: [
              "SIL",
            ]),
        .testTarget(
            name: "ShapeCheckerTests",
            dependencies: ["ShapeChecker"]),
    ]
)
