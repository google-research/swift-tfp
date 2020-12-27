// swift-tools-version:5.1

// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import PackageDescription

let package = Package(
    name: "TensorsFittingPerfectly",
    dependencies: [
         .package(url: "https://github.com/tensorflow/swift", .branch("main")),
         // FIXME: We need this for command-line argument parsing only.
         .package(url: "https://github.com/apple/swift-tools-support-core.git", from: "0.1.12"),
    ],
    targets: [
        .target(
            name: "doesitfit",
            dependencies: [
              "LibTFP",
              "SIL",
              "SwiftToolsSupport"]),
        .target(
            name: "LibTFP",
            dependencies: [
              "SIL",
              "libz3",
            ]),
        .systemLibrary(
            name: "libz3",
            pkgConfig: "z3",
            providers: [
                .brew(["z3"]),
                .apt(["libz3-dev"])
            ]),
        .testTarget(
            name: "TFPTests",
            dependencies: ["LibTFP"]),
    ]
)
